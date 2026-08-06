-- =====================================================================
-- Daseeki-Core headless self-test harness  (REAL Lua 5.1)
--
-- Follows the Daseeki-Nexus mock-harness pattern (nexus-test-harness/harness):
-- stub the WoW API surface, load the addon files in .toc order under a real
-- Lua 5.1 interpreter, assert behavior, exit non-zero on any failure.
--
-- Gates, in order:
--   0) TOC PARSE GATE  -- loadfile (parse, no execute) EVERY .lua the .toc lists.
--                         A file that does not compile aborts the run before a
--                         single case runs. Reads the .toc, not a hardcoded list,
--                         so a newly added file cannot escape the gate.
--   1) FONT LOAD GUARD -- the unreadable-font-file cases (see CASES below).
--   2) FIREWALL        -- core.lua + theme.lua may create ONLY the documented
--                         globals. Any other leaked global fails the run.
--   3) VERSION GUARD   -- CORE_VERSION reads the .toc; RequireCore compares,
--                         talks once, and never raises (NW-6).
--   4) SIDEBAR ORDER   -- the hub nav plan: CORE group above SUITE, suite addons
--                         alphabetical by display name at RENDER time (so a late
--                         registration slots mid-list), sections under the active
--                         entry only.
--   5) HUB WORDMARK    -- the titlebar "Daseeki Suite" wordmark asks the theme for
--                         the ACCENT token through UI.Skin (no baked |cff escape),
--                         the version suffix stays muted metadata, and the
--                         ThemeChanged ordering that keeps that paint on top holds.
--   6) BRAND MARK      -- the minimap button's CUSTOM_ICON resolves to a texture the
--                         client can actually READ (.tga/.blp, never .jpg), in the
--                         suite's 64x64 BGRA format, carrying the maker's-mark
--                         diamond. Disk-level, because SetTexture fails silently.
--
-- Each case executes core.lua + theme.lua in a FRESH global environment
-- (setfenv), so the guard's session caches (UI._faceProbe / _fallbackTold /
-- _fallbackEpoch) start clean every time and cases cannot bleed into each other.
--
-- Usage:  lua5.1 harness.lua [CORE_DIR]
--   CORE_DIR defaults to the repo path below. Exit code 0 = all pass.
-- =====================================================================

local CORE_DIR = arg[1]
  or [[C:\Users\Drew\Claude\Claude Projects\WoW Addons\Daseeki-Core]]
local function slash(p) return (p:gsub("\\", "/")) end
CORE_DIR = slash(CORE_DIR)
local function P(rel) return CORE_DIR .. "/" .. rel end

local TOC_FILE   = "Daseeki-Core.toc"
local ADDON_NAME = "Daseeki-Core"
local FRIZ       = "Fonts\\FRIZQT__.TTF"
local FIRA       = "Interface\\AddOns\\Daseeki-Core\\fonts\\FiraSansCondensed-Medium.ttf"

----------------------------------------------------------------------
-- tiny assert framework
----------------------------------------------------------------------
local failures, checks = {}, 0
local caseName = "?"
local function ok(cond, what)
  checks = checks + 1
  if not cond then
    failures[#failures + 1] = ("[%s] %s"):format(caseName, what)
    print(("  FAIL  %s"):format(what))
  else
    print(("  ok    %s"):format(what))
  end
  return cond and true or false
end
local function eq(got, want, what)
  return ok(got == want, ("%s (got %s, want %s)"):format(what, tostring(got), tostring(want)))
end

----------------------------------------------------------------------
-- 0) TOC PARSE GATE
--
-- .toc grammar: "## Key: value" directives and "#" comments are skipped; every
-- other non-blank line is a file path relative to the addon folder. Only .lua
-- entries are parseable by loadfile.
----------------------------------------------------------------------
local function readTocLuaFiles(tocPath)
  local fh, oerr = io.open(tocPath, "r")
  if not fh then return nil, "cannot open " .. tocPath .. ": " .. tostring(oerr) end
  local out = {}
  for line in fh:lines() do
    line = line:gsub("^\239\187\191", "")               -- strip UTF-8 BOM
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" and line:lower():sub(-4) == ".lua" then
      out[#out + 1] = (line:gsub("\\", "/"))
    end
  end
  fh:close()
  return out
end

print("== GATE 0: TOC parse ==")
local tocFiles, tocErr = readTocLuaFiles(P(TOC_FILE))
if not tocFiles then print("ABORT: " .. tostring(tocErr)) os.exit(1) end
if #tocFiles == 0 then print("ABORT: .toc lists no .lua files") os.exit(1) end
local parseBad = 0
for _, rel in ipairs(tocFiles) do
  local chunk, err = loadfile(P(rel))
  if chunk then
    print(("  ok    parse %s"):format(rel))
  else
    parseBad = parseBad + 1
    print(("  FAIL  parse %s -> %s"):format(rel, tostring(err)))
  end
end
if parseBad > 0 then
  print(("ABORT: %d file(s) failed to compile; no cases run."):format(parseBad))
  os.exit(1)
end
-- The .toc's own ## Version, read the same way the client would hand it to
-- GetAddOnMetadata. Gate 3 asserts Core republishes exactly this.
local function readTocVersion(tocPath)
  local fh = io.open(tocPath, "r")
  if not fh then return nil end
  local v
  for line in fh:lines() do
    v = v or line:match("^%s*##%s*Version%s*:%s*(%S+)")
  end
  fh:close()
  return v
end
local TOC_VERSION = readTocVersion(P(TOC_FILE))
if not TOC_VERSION then print("ABORT: .toc has no ## Version") os.exit(1) end

-- theme.lua must actually be in the .toc, or the guard ships unloaded.
local sawTheme, sawCore = false, false
for _, rel in ipairs(tocFiles) do
  if rel == "theme.lua" then sawTheme = true end
  if rel == "core.lua"  then sawCore  = true end
end
if not (sawTheme and sawCore) then
  print("ABORT: .toc must list core.lua and theme.lua")
  os.exit(1)
end

----------------------------------------------------------------------
-- WoW API mock
--
-- Font behavior is table-driven per PATH so a case can make one specific font
-- file "unreadable" in each of the four ways a client can report it:
--
--   "ok"        file loads. SetFont -> true, GetFont -> path, width > 0.
--   "boolfail"  SetFont -> false (the documented success:bool saying no;
--               wow-api-catalog 1.15.9.68808 functions.txt:3917/:3919).
--   "silent"    SetFont -> nil (the no-return overload, :3918) and the font is
--               left UNCHANGED -- GetFont still reports the previous face.
--   "nilread"   SetFont -> nil and the font is CLEARED -- GetFont -> nil
--               (the nullable "opt fontFile:FontAsset" return, :3146).
--   "widthzero" SetFont -> true and GetFont -> path, but the face measures ZERO
--               width: the API claims success while the text draws invisible.
--               This is the live incident's worst case.
--   "silentok"  SetFont -> nil (no-return overload) but the face LOADS fine.
--               The control case for false positives: must NOT fall back.
--
-- `denyProbe` makes CreateFrame return a parented frame with no CreateFontString,
-- i.e. no surface to hang the hidden probe on. The loader frame (unparented) is
-- unaffected, so the addon still boots.
----------------------------------------------------------------------
local function normp(p) return type(p) == "string" and (p:lower():gsub("\\", "/")) or p end

-- `metaVersion` is what the client reports for ## Version; false makes the
-- metadata API absent entirely (the unreadable-version case gate 3 covers).
local function buildEnv(fontModes, denyProbe, metaVersion)
  local env = {}
  env._G = env
  setmetatable(env, { __index = _G })

  if metaVersion == nil then metaVersion = TOC_VERSION end
  if metaVersion == false then
    env.C_AddOns = { GetAddOnMetadata = false }   -- present but not a function
    env.GetAddOnMetadata = false
  else
    local function meta(name, key)
      if name == ADDON_NAME and key == "Version" then return metaVersion end
      return nil
    end
    env.C_AddOns = { GetAddOnMetadata = meta }
    env.GetAddOnMetadata = meta
  end

  local modes = {}
  for path, m in pairs(fontModes or {}) do modes[normp(path)] = m end
  local function modeFor(p) return modes[normp(p)] or "ok" end

  -- Every SetFont call on a SHARED font object is logged, so a case can assert
  -- that a dead face was never even OFFERED to a visible font object.
  local setLog = {}
  env.__setLog = setLog
  local notices = {}
  env.__notices = notices
  local frames  = {}
  env.__frames  = frames

  local function newFontish(label)
    local st = { font = nil, size = nil, flags = nil, text = nil, zero = false }
    local o = { __label = label, __state = st }
    function o:SetText(t) st.text = t end
    function o:GetText() return st.text end
    function o:SetFont(path, size, flags)
      setLog[#setLog + 1] = { label = label, path = path, size = size, flags = flags }
      local m = modeFor(path)
      if m == "boolfail" then return false end
      if m == "silent"   then return nil end                       -- unchanged
      if m == "nilread"  then st.font = nil return nil end         -- cleared
      st.font, st.size, st.flags = path, size, flags
      st.zero = (m == "widthzero")
      if m == "silentok" then return nil end   -- loads fine, client just doesn't report
      return true
    end
    function o:GetFont() return st.font, st.size, st.flags end
    function o:GetStringWidth()
      if not st.font or st.zero then return 0 end
      return #(st.text or "") * 6
    end
    -- Colour is RECORDED, not swallowed: gate 5 asserts the shared ceremonial font
    -- object is already re-tinted by the time ThemeChanged subscribers run, which is
    -- what lets a per-FontString accent paint (the hub wordmark) land last and stick.
    function o:SetTextColor(r, g, b, a) st.r, st.g, st.b, st.a = r, g, b, a end
    function o:GetTextColor() return st.r, st.g, st.b, st.a end
    function o:SetJustifyH() end
    function o:SetShadowColor() end
    function o:SetShadowOffset() end
    return o
  end
  env.__newFontish = newFontish

  function env.CreateFont(name)
    local f = newFontish(name or "anon")
    if name then env[name] = f end     -- real CreateFont publishes the global
    return f
  end

  function env.CreateFrame(kind, name, parent)
    local f = { __shown = true, __events = {}, __scripts = {}, __strings = {} }
    function f:RegisterEvent(e)   self.__events[e] = true end
    function f:UnregisterEvent(e) self.__events[e] = nil end
    function f:SetScript(s, fn)   self.__scripts[s] = fn end
    function f:GetScript(s)       return self.__scripts[s] end
    function f:Hide()             self.__shown = false end
    function f:Show()             self.__shown = true end
    function f:IsShown()          return self.__shown end
    function f:SetPoint()  end
    function f:SetSize()   end
    function f:SetParent() end
    if denyProbe and parent ~= nil then
      f.CreateFontString = nil          -- no surface for the hidden probe
    else
      function f:CreateFontString(n, layer)
        local fs = newFontish("fontstring:" .. tostring(n or "anon"))
        fs.__owner = self
        self.__strings[#self.__strings + 1] = fs
        return fs
      end
    end
    if name then env[name] = f end
    frames[#frames + 1] = f
    return f
  end

  env.UIParent = { __label = "UIParent" }
  env.DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg) notices[#notices + 1] = msg end,
  }
  env.LibStub = nil                       -- LibSharedMedia deliberately absent
  env.GetLocale = function() return "enUS" end
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    notices[#notices + 1] = table.concat(parts, " ")
  end

  -- dispatch a WoW event to every frame that registered it
  function env.__fire(event, ...)
    for _, f in ipairs(frames) do
      if f.__events[event] and f.__scripts.OnEvent then
        f.__scripts.OnEvent(f, event, ...)
      end
    end
  end
  return env
end

-- Load core.lua + theme.lua into a fresh env. Returns env, Core, UI, leakedGlobals.
local function loadCore(fontModes, denyProbe, metaVersion)
  local env = buildEnv(fontModes, denyProbe, metaVersion)
  local before = {}
  for k in pairs(env) do before[k] = true end

  local Core = {}
  for _, rel in ipairs({ "core.lua", "theme.lua" }) do
    local chunk = assert(loadfile(P(rel)))
    setfenv(chunk, env)
    chunk(ADDON_NAME, Core)
  end

  local leaked = {}
  for k in pairs(env) do if not before[k] then leaked[#leaked + 1] = k end end
  table.sort(leaked)
  return env, Core, env.DaseekiUI, leaked
end

-- Fire the login sequence exactly as the client does.
local function login(env)
  env.__fire("ADDON_LOADED", ADDON_NAME)
  env.__fire("PLAYER_LOGIN")
end

-- The face each body-family shared font object ENDED UP on.
local BODY_ROLES = { "header", "body", "muted", "small", "accent", "danger", "microLabel", "numeral" }
local function bodyFaces(UI)
  local out = {}
  for _, role in ipairs(BODY_ROLES) do
    out[role] = select(1, UI.fonts[role]:GetFont())
  end
  return out
end
local function allBodyFacesAre(UI, want)
  for _, role in ipairs(BODY_ROLES) do
    local f = select(1, UI.fonts[role]:GetFont())
    if normp(f) ~= normp(want) then return false, role .. "=" .. tostring(f) end
  end
  return true
end
-- Did any VISIBLE shared font object ever get offered this path?
local function offeredToSharedFonts(env, path)
  for _, rec in ipairs(env.__setLog) do
    if normp(rec.path) == normp(path) and not tostring(rec.label):match("^fontstring:") then
      return true, rec.label
    end
  end
  return false
end
local function countNotices(env, pat)
  local n = 0
  for _, m in ipairs(env.__notices) do if m:find(pat, 1, true) then n = n + 1 end end
  return n
end

----------------------------------------------------------------------
-- 1) FONT LOAD GUARD CASES
----------------------------------------------------------------------
print("\n== GATE 1: font load guard ==")

-- ---- CASE 1: probe-success path is UNCHANGED -------------------------------
caseName = "probe-success unchanged"
print("\n-- " .. caseName)
do
  local env, Core, UI = loadCore(nil)                  -- every font loads
  login(env)
  ok(allBodyFacesAre(UI, FIRA), "body-family font objects use the picked Fira face")
  eq(select(1, UI.IsFaceFallback()), false, "no fallback engaged")
  eq(UI.FontFile(), FIRA, "FontFile returns the picked face")
  eq(Core.db.fontChoice, "Fira Sans Condensed Medium", "saved fontChoice untouched")
  eq(countNotices(env, "could not be loaded"), 0, "no chat notice printed")
  eq(select(1, UI.fonts.ceremonial:GetFont()), "Fonts\\MORPHEUS.TTF", "ceremonial stays MORPHEUS")
end

-- ---- CASES 2-5: each failure-report shape is detected -----------------------
for _, mode in ipairs({ "boolfail", "silent", "nilread", "widthzero" }) do
  caseName = "probe-failure via " .. mode
  print("\n-- " .. caseName)
  local env, Core, UI = loadCore({ [FIRA] = mode })
  local fired = 0
  UI.OnFontChanged(function() fired = fired + 1 end)
  login(env)

  ok(allBodyFacesAre(UI, FRIZ), "whole face fell back to Friz Quadrata")
  eq(select(1, UI.IsFaceFallback()), true, "fallback reported active")
  eq(select(2, UI.IsFaceFallback()), "Fira Sans Condensed Medium", "fallback names the failed face")
  eq(UI.FontFile(), FRIZ, "FontFile resolves to the fallback face")
  eq(Core.db.fontChoice, "Fira Sans Condensed Medium", "SAVED fontChoice preserved (restart honours the pick)")
  eq(countNotices(env, "could not be loaded"), 1, "exactly one chat notice")
  ok(env.__notices[#env.__notices]:find("full game restart", 1, true) ~= nil,
     "notice explains a full game restart is needed")
  ok(env.__notices[#env.__notices]:find("Friz Quadrata", 1, true) ~= nil,
     "notice names the face in use")
  ok(env.__notices[#env.__notices]:find("|c", 1, true) == nil,
     "notice is plain-copy text (no color escapes)")
  ok(fired > 0, "OnFontChanged fired so consumers re-skin coherently")

  if mode == "widthzero" then
    -- widthzero is the nastiest: the API says success. Prove the guard still
    -- kept the dead face away from every visible shared font object.
    eq(offeredToSharedFonts(env, FIRA), false, "dead face never offered to a shared font object")
  end
end

-- ---- CASE 6: picker selects a not-yet-restartable font LIVE ------------------
caseName = "picker live-select of unreadable font"
print("\n-- " .. caseName)
do
  local BAD = "Interface\\AddOns\\SomeAddon\\fonts\\JustInstalled.ttf"
  local env, Core, UI = loadCore({ [BAD] = "widthzero" })
  login(env)
  UI.RegisterFont("Just Installed", BAD)
  local fired = 0
  UI.OnFontChanged(function() fired = fired + 1 end)

  UI.SetFont("Just Installed")
  ok(allBodyFacesAre(UI, FRIZ), "UI stays readable on Friz instead of blanking")
  eq(select(1, UI.IsFaceFallback()), true, "fallback engaged from the dropdown")
  eq(Core.db.fontChoice, "Just Installed", "the user's own pick IS saved for next restart")
  eq(countNotices(env, "could not be loaded"), 1, "one notice for the picked face")
  ok(env.__notices[#env.__notices]:find("Just Installed", 1, true) ~= nil, "notice names the picked font")
  ok(fired > 0, "OnFontChanged fired on the fallback application")
  eq(offeredToSharedFonts(env, BAD), false, "dead face never reached a shared font object")

  -- ...and picking a working face afterwards LIFTS the fallback.
  UI.SetFont("2002")
  eq(select(1, UI.IsFaceFallback()), false, "fallback lifts when a working face is picked")
  ok(allBodyFacesAre(UI, "Fonts\\2002.TTF"), "the working face applies normally")
end

-- ---- CASE 7: the notice is printed ONCE, not once per re-apply ---------------
caseName = "notice printed once per face"
print("\n-- " .. caseName)
do
  local env, Core, UI = loadCore({ [FIRA] = "boolfail" })
  login(env)
  UI.SetFontScale(1.1); UI.SetFontScale(1.2); UI.SetFontScale(0.9)
  UI.SetTheme("Daseeki"); UI.SetTheme("Felwood")
  eq(countNotices(env, "could not be loaded"), 1, "still exactly one notice after 5 re-applies")
  ok(allBodyFacesAre(UI, FRIZ), "still on the fallback face")
  eq(Core.db.fontChoice, "Fira Sans Condensed Medium", "saved choice still preserved")
end

-- ---- CASE 8: startup self-check runs BEFORE applyFonts commits ---------------
caseName = "startup self-check"
print("\n-- " .. caseName)
do
  local env, Core, UI = loadCore({ [FIRA] = "widthzero" })
  env.__fire("ADDON_LOADED", ADDON_NAME)               -- login half 1 only
  local isFb, name = UI.SelfCheckFont()
  eq(isFb, true, "SelfCheckFont reports the saved face is unusable")
  eq(name, "Fira Sans Condensed Medium", "SelfCheckFont names the saved face")
  ok(allBodyFacesAre(UI, FRIZ), "fonts committed at ADDON_LOADED are already the fallback")
  eq(offeredToSharedFonts(env, FIRA), false, "the dead face was never committed at any point")
end

-- ---- CASE 9: SetTheme fires OnFontChanged when the fallback engages ----------
-- SetTheme normally fires only THEME callbacks. If the load guard first engages
-- during a theme change, font consumers must still be told.
caseName = "SetTheme fires OnFontChanged on fallback engage"
print("\n-- " .. caseName)
do
  local env, Core, UI = loadCore({ [FIRA] = "boolfail" })
  local fontFired, themeFired = 0, 0
  UI.OnFontChanged(function()  fontFired  = fontFired  + 1 end)
  UI.OnThemeChanged(function() themeFired = themeFired + 1 end)

  -- Rewind the guard to "has not run yet" so the NEXT call is where it first
  -- engages, and make that next call a SetTheme (which fires only THEME
  -- callbacks of its own accord).
  for k in pairs(UI._faceProbe) do UI._faceProbe[k] = nil end
  UI._faceFallback  = nil
  UI._fallbackEpoch = 0
  eq(select(1, UI.IsFaceFallback()), false, "guard rewound to not-yet-engaged")

  UI.SetTheme("Winterspring Frost")
  ok(themeFired > 0, "theme callbacks fired")
  ok(fontFired > 0, "font callbacks ALSO fired because the fallback engaged mid-SetTheme")
  eq(select(1, UI.IsFaceFallback()), true, "fallback engaged during the theme change")
  ok(allBodyFacesAre(UI, FRIZ), "the theme change landed on the fallback face")
end

-- ---- CASE 10: ambiguity is NOT failure (no false fallbacks) -----------------
-- A client whose SetFont overload declares no return (wow-api-catalog
-- functions.txt:3918) hands back nil for a face that loads perfectly well. That
-- must NOT be read as failure, or every such client loses its font picker.
caseName = "silent-but-working client does not false-fallback"
print("\n-- " .. caseName)
do
  local env, Core, UI = loadCore({ [FIRA] = "silentok" })
  login(env)
  eq(select(1, UI.IsFaceFallback()), false, "no fallback from a nil (unknown) SetFont return")
  ok(allBodyFacesAre(UI, FIRA), "the working face is applied")
  eq(countNotices(env, "could not be loaded"), 0, "no spurious chat notice")
end

-- ---- CASE 11: guard is inert when there is no probe surface -----------------
-- Very early / restricted environments may have no frame to hang a hidden
-- FontString on. With nothing to measure, the guard must pass the face through
-- rather than fall the whole UI back on a guess.
caseName = "no probe surface -> face passes through"
print("\n-- " .. caseName)
do
  local env, Core, UI = loadCore({ [FIRA] = "boolfail" }, true)   -- probe surface denied
  login(env)
  eq(select(1, UI.IsFaceFallback()), false, "no fallback engaged without a probe surface")
  eq(UI.FontFile(), FIRA, "the picked face passes through unverified")
  eq(countNotices(env, "could not be loaded"), 0, "no notice printed on an unprovable face")
end

----------------------------------------------------------------------
-- 2) FIREWALL: which globals may core.lua + theme.lua create?
----------------------------------------------------------------------
print("\n== GATE 2: global firewall ==")
caseName = "firewall"
do
  local ALLOWED = {
    DaseekiSuite = true, DaseekiUI = true,
    DaseekiCoreDB = true, DaseekiCoreCharDB = true,
    -- shared FontObjects: real CreateFont publishes these globals by name
    DaseekiUIFontHeader = true, DaseekiUIFontBody = true, DaseekiUIFontMuted = true,
    DaseekiUIFontSmall = true, DaseekiUIFontAccent = true, DaseekiUIFontDanger = true,
    DaseekiUIFontCeremonial = true, DaseekiUIFontMicroLabel = true, DaseekiUIFontNumeral = true,
  }
  local env, Core, UI, leaked = loadCore(nil)
  login(env)
  -- recompute after login (SavedVariables globals appear then)
  local post = {}
  for k in pairs(env) do
    if type(k) == "string" and k:match("^Daseeki") then post[#post + 1] = k end
  end
  table.sort(post)
  local bad = {}
  for _, k in ipairs(leaked) do
    if not ALLOWED[k] and not k:match("^__") then bad[#bad + 1] = k end
  end
  for _, k in ipairs(post) do
    if not ALLOWED[k] then
      local dup = false
      for _, b in ipairs(bad) do if b == k then dup = true end end
      if not dup then bad[#bad + 1] = k end
    end
  end
  eq(#bad, 0, "no unexpected globals leaked (" .. table.concat(bad, ", ") .. ")")
  ok(env.DaseekiUI ~= nil, "DaseekiUI published")
  ok(env.DaseekiSuite ~= nil, "DaseekiSuite published")
end

----------------------------------------------------------------------
-- 3) VERSION GUARD (NW-6): CORE_VERSION + RequireCore
--
-- The contract other addons build on: a stale Core must degrade with ONE chat
-- line, never a Lua error, and a current Core must never nag.
----------------------------------------------------------------------
print("\n== GATE 3: version guard ==")

caseName = "CORE_VERSION reads the .toc"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil)
  login(env)
  eq(Core.CORE_VERSION, TOC_VERSION, "CORE_VERSION is the .toc's ## Version")
  eq(env.DaseekiSuite.CORE_VERSION, TOC_VERSION, "published on the global DaseekiSuite")
  -- The .toc stamp is load-bearing: suite addons guard the ledger kit on 2.2.0,
  -- so an under-stamped Core reads as outdated to every guarded caller.
  ok(Core.CompareVersions(TOC_VERSION, "2.2.0") >= 0,
     "shipped .toc version is at least the 2.2.0 the suite guards on (got " .. tostring(TOC_VERSION) .. ")")
end

caseName = "CompareVersions"
print("\n-- " .. caseName)
do
  local _, Core = loadCore(nil)
  local C = Core.CompareVersions
  eq(C("2.2.0", "2.2.0"), 0, "equal versions compare equal")
  eq(C("2.2", "2.2.0"), 0, "a missing component reads as 0")
  eq(C("2.10.0", "2.9.0"), 1, "components compare NUMERICALLY, not as strings")
  eq(C("2.0.0", "2.2.0"), -1, "older minor is less")
  eq(C("3.0.0", "2.9.9"), 1, "newer major is greater")
  eq(C("2.2.0-n1", "2.2.0"), 0, "a pre-release tail is ignored")
  eq(C("2.2.1", "2.2.0"), 1, "newer patch is greater")
end

caseName = "RequireCore on a CURRENT Core"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil, nil, "2.2.0")
  login(env)
  eq(Core.RequireCore("2.2.0", "Nexus cards"), true, "exact match passes")
  eq(Core.RequireCore("2.0.0", "Nexus cards"), true, "older requirement passes")
  eq(Core:RequireCore("2.2.0", "Nexus cards"), true, "a colon call is tolerated, not an error")
  eq(countNotices(env, "update Daseeki-Core"), 0, "a current Core never nags")
end

caseName = "RequireCore on a STALE Core"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil, nil, "2.0.0")
  login(env)
  eq(Core.RequireCore("2.2.0", "Nexus character cards"), false, "stale Core fails the guard")
  eq(countNotices(env, "update Daseeki-Core"), 1, "exactly one chat line")
  local msg = env.__notices[#env.__notices]
  ok(msg:find("v2.2.0", 1, true) ~= nil, "notice names the version NEEDED")
  ok(msg:find("v2.0.0", 1, true) ~= nil, "notice names the version INSTALLED")
  ok(msg:find("Nexus character cards", 1, true) ~= nil, "notice names the caller")
  ok(msg:find("|c", 1, true) == nil, "notice is plain-copy text (no color escapes)")

  -- Once per session per caller: a guard inside a per-row builder must not
  -- narrate itself once per row.
  for _ = 1, 20 do Core.RequireCore("2.2.0", "Nexus character cards") end
  eq(countNotices(env, "update Daseeki-Core"), 1, "still one line after 20 more calls")
  -- ...but a DIFFERENT caller is still told about its own feature.
  eq(Core.RequireCore("2.2.0", "Nexus timers dock"), false, "second caller also gated")
  eq(countNotices(env, "update Daseeki-Core"), 2, "the second caller gets its own line")
end

caseName = "RequireCore never raises"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil, nil, "2.0.0")
  login(env)
  for _, bad in ipairs({ "", "not.a.version", "..", "2.x.0" }) do
    local okCall, res = pcall(Core.RequireCore, bad, "junk")
    ok(okCall, "RequireCore(" .. string.format("%q", bad) .. ") did not raise")
    ok(res == true or res == false, "...and returned a boolean (got " .. tostring(res) .. ")")
  end
  local okNil = pcall(Core.RequireCore, nil, "junk")
  ok(okNil, "RequireCore(nil) did not raise")
  eq(Core.RequireCore(nil, "junk"), true, "an unusable requirement passes rather than blocks")
end

caseName = "unreadable version metadata passes"
print("\n-- " .. caseName)
do
  -- No GetAddOnMetadata at all. Switching working features off over a version we
  -- could not read would be worse than the mixed-version risk.
  local env, Core = loadCore(nil, nil, false)
  login(env)
  eq(Core.CORE_VERSION, nil, "CORE_VERSION is nil when metadata is unreadable")
  eq(Core.RequireCore("9.9.9", "Nexus cards"), true, "guard passes rather than blocking")
  eq(countNotices(env, "update Daseeki-Core"), 0, "and says nothing")
end

----------------------------------------------------------------------
-- 4) SIDEBAR ORDER: Core-above-Suite + alphabetical suite
--
-- The nav ORDER is pure data in core.lua (Core:GetNavPlan / Core:GetSuiteOrder);
-- hub.lua only renders it. That is what makes it pinnable here without a frame
-- stack, and it is why these cases are the contract for the sidebar's layout.
----------------------------------------------------------------------
print("\n== GATE 4: sidebar order ==")

-- Register a suite addon with just an id + display title.
local function reg(Core, id, title, sections)
  return Core:RegisterAddon({ id = id, title = title, sections = sections })
end

-- The ids of the "addon" entries in a plan, in render order (groups dropped).
local function planAddonIds(plan)
  local out = {}
  for _, e in ipairs(plan) do
    if e.kind == "addon" then out[#out + 1] = e.id end
  end
  return out
end

-- The group headings in render order.
local function planGroups(plan)
  local out = {}
  for _, e in ipairs(plan) do
    if e.kind == "group" then out[#out + 1] = e.title end
  end
  return out
end

-- Index of the first entry matching a predicate (nil if absent).
local function indexOf(plan, pred)
  for i, e in ipairs(plan) do if pred(e) then return i end end
  return nil
end

local function joined(t) return table.concat(t, ",") end

-- ---- CASE: the CORE group renders ABOVE the SUITE group ---------------------
caseName = "Core group renders above Suite group"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil)
  login(env)
  -- The Appearance page exactly as hub.lua registers it.
  Core:RegisterCorePage({ id = "__appearance", title = "Appearance", flow = true,
    sections = { { id = "_main", title = "Appearance", legacy = false } } })
  reg(Core, "armory", "Armory")
  reg(Core, "nexus",  "Nexus")

  local plan = Core:GetNavPlan(nil)
  eq(joined(planGroups(plan)), "Core,Suite", "group headings render Core then Suite")

  local coreGroup  = indexOf(plan, function(e) return e.kind == "group" and e.title == "Core"  end)
  local suiteGroup = indexOf(plan, function(e) return e.kind == "group" and e.title == "Suite" end)
  local appear     = indexOf(plan, function(e) return e.kind == "addon" and e.id == "__appearance" end)
  local firstSuite = indexOf(plan, function(e) return e.kind == "addon" and e.id == "armory" end)
  ok(coreGroup < suiteGroup, "the Core heading precedes the Suite heading")
  ok(appear > coreGroup and appear < suiteGroup, "the Core page sits INSIDE the Core group")
  ok(firstSuite > suiteGroup, "suite addons sit below the Suite heading")
  eq(joined(planAddonIds(plan)), "__appearance,armory,nexus", "full render order is Core page, then suite")

  -- With no Core page registered at all there must be no empty Core heading.
  local _, Bare = loadCore(nil)
  reg(Bare, "armory", "Armory")
  eq(joined(planGroups(Bare:GetNavPlan(nil))), "Suite", "an empty Core group prints no heading")
end

-- ---- CASE: suite entries sort ALPHABETICALLY, not by registration -----------
caseName = "suite sorts alphabetically by display name"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil)
  login(env)
  -- Deliberately reverse-alphabetical registration order.
  reg(Core, "nexus",   "Nexus")
  reg(Core, "ledger",  "Ledger")
  reg(Core, "banker",  "Banker")
  reg(Core, "armory",  "Armory")

  eq(joined(Core:GetSuiteOrder()), "armory,banker,ledger,nexus",
     "sorted by TITLE regardless of registration order")
  eq(joined(Core.regOrder), "nexus,ledger,banker,armory",
     "regOrder is left untouched as the insertion log")
  eq(joined(planAddonIds(Core:GetNavPlan(nil))), "armory,banker,ledger,nexus",
     "the nav plan renders that same alphabetical order")

  -- Repeated calls must not shuffle (a non-total comparator would).
  eq(joined(Core:GetSuiteOrder()), joined(Core:GetSuiteOrder()), "the order is stable across calls")
end

-- ---- CASE: a LATE registration inserts MID-LIST -----------------------------
-- The whole reason the sort runs at render time: an addon loading after the hub
-- already exists must slot into its alphabetical place, not land at the bottom.
caseName = "late registration inserts mid-list"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil)
  login(env)
  reg(Core, "armory", "Armory")
  reg(Core, "nexus",  "Nexus")
  eq(joined(Core:GetSuiteOrder()), "armory,nexus", "two addons before the late load")

  -- ...now a third addon registers long after the hub was built.
  reg(Core, "compass", "Compass")
  eq(joined(Core:GetSuiteOrder()), "armory,compass,nexus",
     "the late addon lands BETWEEN the two, not at the end")
  eq(joined(Core.regOrder), "armory,nexus,compass", "and it was appended last to regOrder")

  -- One that sorts to the FRONT, and one to the BACK, from the same late position.
  reg(Core, "abacus", "Abacus")
  reg(Core, "zephyr", "Zephyr")
  eq(joined(Core:GetSuiteOrder()), "abacus,armory,compass,nexus,zephyr",
     "late registrations land at the front and the back correctly too")

  -- Re-registering an existing id must UPDATE it, not duplicate it, and a renamed
  -- addon must re-sort to its new place.
  reg(Core, "compass", "Yardstick")
  eq(#Core.regOrder, 5, "re-registering an id does not duplicate the entry")
  eq(joined(Core:GetSuiteOrder()), "abacus,armory,nexus,compass,zephyr",
     "a renamed addon re-sorts under its NEW display name")
end

-- ---- CASE: the sort is case-insensitive and totally ordered -----------------
caseName = "sort is case-insensitive with a stable tie-break"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil)
  login(env)
  -- A raw byte compare puts EVERY capitalised title ahead of every lowercase one
  -- ("Zephyr" < "armory" because Z=90 < a=97). Alphabetical means case-insensitive.
  reg(Core, "zephyr", "Zephyr")
  reg(Core, "armory", "armory")
  eq(joined(Core:GetSuiteOrder()), "armory,zephyr", "lowercase title still sorts before a capitalised Z")

  -- Two addons sharing a display name: break on id so the order is TOTAL and the
  -- same every session no matter which loaded first.
  local _, Tie = loadCore(nil)
  reg(Tie, "b_ledger", "Ledger")
  reg(Tie, "a_ledger", "Ledger")
  eq(joined(Tie:GetSuiteOrder()), "a_ledger,b_ledger", "equal titles break on addon id")

  -- A def with no title falls back to its id rather than sorting as "".
  local _, NoTitle = loadCore(nil)
  NoTitle:RegisterAddon({ id = "middle" })
  reg(NoTitle, "alpha", "Alpha")
  reg(NoTitle, "omega", "Omega")
  eq(joined(NoTitle:GetSuiteOrder()), "alpha,middle,omega", "a titleless addon sorts under its id")
end

-- ---- CASE: sub-sections indent under the ACTIVE entry only ------------------
caseName = "sections expand under the active entry only"
print("\n-- " .. caseName)
do
  local env, Core = loadCore(nil)
  login(env)
  reg(Core, "armory", "Armory", { { id = "gear", title = "Gear" }, { id = "sets", title = "Sets" } })
  reg(Core, "nexus",  "Nexus")

  local collapsed = Core:GetNavPlan(nil)
  eq(indexOf(collapsed, function(e) return e.kind == "section" end), nil,
     "nothing expands when no addon is active")

  local plan = Core:GetNavPlan("armory")
  local ids = {}
  for _, e in ipairs(plan) do
    if e.kind == "section" then ids[#ids + 1] = e.sectionId end
  end
  eq(joined(ids), "gear,sets", "the active addon's sections expand in declaration order")

  local armory = indexOf(plan, function(e) return e.kind == "addon" and e.id == "armory" end)
  local nexus  = indexOf(plan, function(e) return e.kind == "addon" and e.id == "nexus"  end)
  local firstS = indexOf(plan, function(e) return e.kind == "section" end)
  ok(firstS > armory and firstS < nexus, "they sit BETWEEN their own addon and the next one")

  -- A single-section addon stays collapsed even when active (no pointless child row).
  eq(indexOf(Core:GetNavPlan("nexus"), function(e) return e.kind == "section" end), nil,
     "a single-section addon does not expand")
end

----------------------------------------------------------------------
-- 5) HUB WORDMARK TINT
--
-- Owner directive (2026-08-03): the settings-hub "Daseeki Suite" wordmark reads
-- red, not cream — the same suite accent the Nexus NEXUS wordmark and the Raid
-- Prep title already wear. Two halves to that contract, pinned separately:
--
--   a) AUTHORING. hub.lua builds real frames, so it cannot execute under these
--      stubs; its wordmark lockup is pinned against SOURCE instead. That is the
--      right altitude anyway — the regressions this guards are authoring slips
--      (baking a |cff hex escape like the pre-fix Nexus wordmark did, dropping the
--      UI.Skin wrapper so the colour dies at the next theme change, or quietly
--      accenting the version suffix too), not runtime state.
--   b) ORDERING. The paint only survives because UI.SetTheme runs applyFonts()
--      BEFORE fireThemeChanged(): the shared ceremonial FontObject goes back to
--      cream first, then subscribers repaint. Flip that order and the wordmark
--      silently reverts to cream on every theme switch, with hub.lua unchanged --
--      which is exactly why this half is pinned on the live theme engine.
----------------------------------------------------------------------
print("\n== GATE 5: hub wordmark tint ==")

caseName = "the wordmark asks the theme for the accent token"
print("\n-- " .. caseName)
do
  local fh = io.open(P("hub.lua"), "r")
  local src = fh and fh:read("*a") or ""
  if fh then fh:close() end
  ok(#src > 0, "hub.lua is readable")

  -- The titlebar lockup: wordmark FontString through to the breadcrumb that closes it.
  local s = src:find("local title = titleBar:CreateFontString", 1, true)
  local e = s and src:find("-- Breadcrumb", s, true)
  ok(s ~= nil, "the titlebar wordmark FontString is still where the lockup starts")
  ok(e ~= nil, "the breadcrumb still closes the lockup (block bounds resolved)")
  local block = (s and e) and src:sub(s, e) or ""

  ok(block:find('SetText("Daseeki Suite")', 1, true) ~= nil,
     "the wordmark still reads \"Daseeki Suite\"")
  ok(block:find("title:SetFontObject(UI.fonts.ceremonial)", 1, true) ~= nil,
     "the MORPHEUS ceremonial FACE is untouched -- colour only")
  ok(block:find("UI.Skin(title,", 1, true) ~= nil,
     "the tint is registered through UI.Skin, so it re-runs on ThemeChanged")
  ok(block:find('SetTextColor(UI.Color("accent"))', 1, true) ~= nil,
     "and it reads the ACCENT token rather than a fixed colour")
  ok(block:find("|c", 1, true) == nil,
     "no baked |cff hex escape anywhere in the lockup")
  ok(block:find("SetTextColor%(%s*[%d%.]") == nil,
     "no literal rgb triple handed to SetTextColor")

  -- The version suffix is METADATA and stays muted: UI.fonts.small is tinted from
  -- `muted`, the same register as the breadcrumb on the far end of the same bar.
  ok(block:find("verFS:SetFontObject(UI.fonts.small)", 1, true) ~= nil,
     "the version suffix stays on the muted small role")
  local accents = select(2, block:gsub('UI%.Color%("accent"%)', ""))
  eq(accents, 1, "exactly ONE accent paint in the lockup (the wordmark, not the version)")
end

caseName = "the accent paint survives a theme change"
print("\n-- " .. caseName)
do
  local env, Core, UI = loadCore(nil)
  login(env)

  -- The fix is only visible if accent and text actually differ -- a theme whose
  -- accent WAS the body cream would make the whole directive a no-op.
  local ar, ag, ab = UI.Color("accent")
  local tr, tg, tb = UI.Color("text")
  ok(not (ar == tr and ag == tg and ab == tb),
     "accent is a distinct colour from body text in the shipped theme")
  ok(ar > ag and ar > ab, "and it is red-dominant -- the suite crimson the owner asked for")

  -- Stand in for the hub's UI.Skin subscriber: repaint on every ThemeChanged, and
  -- record what the shared ceremonial object looked like at that moment.
  local ceremonialAtCallback, painted = nil, nil
  UI.OnThemeChanged(function()
    ceremonialAtCallback = { UI.fonts.ceremonial:GetTextColor() }
    painted = { UI.Color("accent") }
  end)

  UI.SetTheme("Daseeki")
  ok(painted ~= nil, "the ThemeChanged subscriber ran on SetTheme")
  local cr, cg, cb = UI.fonts.ceremonial:GetTextColor()
  local wr, wg, wb = UI.Color("text")
  ok(ceremonialAtCallback ~= nil
     and ceremonialAtCallback[1] == cr
     and ceremonialAtCallback[2] == cg
     and ceremonialAtCallback[3] == cb,
     "applyFonts() runs BEFORE subscribers -- the wordmark repaint lands last and sticks")
  ok(cr == wr and cg == wg and cb == wb,
     "the ceremonial object itself is back on the new theme's text token")

  -- ...and the colour the subscriber painted tracked the NEW theme, not the old one.
  local nr, ng, nb = UI.Color("accent")
  ok(painted[1] == nr and painted[2] == ng and painted[3] == nb,
     "the repaint reads the NEW theme's accent (live re-tint, not a build-time bake)")
  ok(not (nr == ar and ng == ag and nb == ab),
     "and that accent genuinely moved with the theme")
end

----------------------------------------------------------------------
-- 6) BRAND MARK: the minimap button's face is a real, loadable texture
--
-- The regression this gate exists for shipped for months: art/nightblade.jpg. The
-- WoW client reads only .blp and .tga, so the icon path resolved to nothing,
-- SetTexture failed SILENTLY (it does not raise, and there is no error to catch),
-- and Core's minimap button wore Blizzard's INV_Misc_Gear_01 instead of the suite
-- brandmark. No Lua assertion can see that — the check has to be made on disk,
-- against the real bytes, which is why it lives in the harness and not in-game.
--
-- Pinned here:
--   a) minimap.lua's CUSTOM_ICON is extensionless and inside our own AddOns path,
--      and a file with a CLIENT-READABLE extension actually sits there.
--   b) no client-unreadable art (.jpg/.png/...) is left under that base name, and
--      nightblade.jpg specifically is gone.
--   c) the .tga is the suite texture format byte-for-byte: 18-byte uncompressed
--      true-colour header (type 2), 64x64, 32bpp BGRA, descriptor 0x28.
--   d) it is the MAKER'S MARK and not a placeholder: an L1 rhombus silhouette that
--      matches textures/diamond-mask.tga's shape family, brand crimson at the
--      centre, a bronze keyline at the edge, air in the corners.
--   e) the asset is REPRODUCIBLE — dev/gen-core-glyphs.lua, which authored it, is
--      still in the tree.
----------------------------------------------------------------------
do
  caseName = "brand mark"
  print("\n== GATE 6: minimap brandmark asset ==")

  local function slurp(path, mode)
    local fh = io.open(path, mode or "rb")
    if not fh then return nil end
    local s = fh:read("*a"); fh:close(); return s
  end

  -- (a) the path minimap.lua actually hands the client -------------------------
  local src = slurp(P("minimap.lua"), "r") or ""
  local iconPath = src:match("local%s+CUSTOM_ICON%s*=%s*[\"']([^\"']+)[\"']")
  ok(iconPath ~= nil, "minimap.lua declares a CUSTOM_ICON path")
  iconPath = iconPath or ""
  local norm = iconPath:gsub("\\", "/")
  -- Plain-text prefix compare, NOT a Lua pattern: "Daseeki-Core" contains a hyphen,
  -- which inside a pattern is the lazy quantifier and matches nothing here.
  local PREFIX = "Interface/AddOns/" .. ADDON_NAME .. "/"
  local inOurs = norm:sub(1, #PREFIX):lower() == PREFIX:lower()
  ok(inOurs, "CUSTOM_ICON points inside our own AddOns folder")
  ok(norm:match("%.%w+$") == nil,
     "CUSTOM_ICON is extensionless -- the client picks .blp/.tga itself")

  -- Repo-relative form: strip the Interface/AddOns/<Addon>/ prefix.
  local rel = inOurs and norm:sub(#PREFIX + 1) or norm
  local tga = slurp(P(rel .. ".tga"))
  local blp = slurp(P(rel .. ".blp"))
  ok(tga ~= nil or blp ~= nil,
     ("a client-readable texture exists at %s (.tga/.blp)"):format(rel))

  -- (b) nothing unreadable left behind ----------------------------------------
  local UNREADABLE = { "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "psd" }
  local strays = {}
  for _, ext in ipairs(UNREADABLE) do
    if slurp(P(rel .. "." .. ext)) then strays[#strays + 1] = ext end
  end
  eq(#strays, 0, "no client-unreadable art sits at the icon base name")
  ok(slurp(P("art/nightblade.jpg")) == nil,
     "art/nightblade.jpg is gone -- the .jpg that never rendered")

  -- (c) suite texture format ---------------------------------------------------
  if tga then
    eq(#tga, 18 + 64 * 64 * 4, "the mark is exactly 16402 bytes (64x64 BGRA + 18-byte header)")
    local h = { tga:byte(1, 18) }
    eq(h[2], 0, "no colour map")
    eq(h[3], 2, "TGA image type 2 (uncompressed true-colour)")
    eq(h[13] + h[14] * 256, 64, "width 64")
    eq(h[15] + h[16] * 256, 64, "height 64")
    eq(h[17], 32, "32 bits per pixel")
    eq(h[18], 0x28, "descriptor 0x28 -- 8-bit alpha, top-left origin")

    -- (d) it is the mark ------------------------------------------------------
    local function px(x, y)
      local o = 18 + (y * 64 + x) * 4
      local b, g, r, a = tga:byte(o + 1, o + 4)
      return r, g, b, a
    end
    local function near(v, want, tol) return math.abs(v - want) <= (tol or 3) end

    local c0 = select(4, px(0, 0))
    local c1 = select(4, px(63, 0))
    local c2 = select(4, px(0, 63))
    local c3 = select(4, px(63, 63))
    ok(c0 == 0 and c1 == 0 and c2 == 0 and c3 == 0,
       "all four corners are fully transparent -- a diamond, not a square")

    local cr, cg, cb, ca = px(32, 32)
    eq(ca, 255, "the centre is fully opaque")
    ok(near(cr, 192) and near(cg, 72) and near(cb, 60),
       ("the centre is brand crimson #C0483C (got #%02X%02X%02X)"):format(cr, cg, cb))

    -- First fully-opaque pixel scanning in along the widest row = the keyline.
    local ex, ey = nil, 32
    for x = 0, 63 do if select(4, px(x, ey)) >= 250 then ex = x break end end
    ok(ex ~= nil, "the widest row has an opaque edge")
    if ex then
      local br, bg, bb = px(ex, ey)
      ok(near(br, 156, 6) and near(bg, 122, 6) and near(bb, 69, 6),
         ("the edge is the bronze keyline #9C7A45 (got #%02X%02X%02X)"):format(br, bg, bb))
      ok(not (near(br, 255, 6) and near(bg, 255, 6) and near(bb, 255, 6)),
         "the mark ships COLOUR, not a white tint mask like the control glyphs")
    end

    -- L1 rhombus: the solid run per row must peak at the centre and fall off
    -- linearly toward both vertices. Three samples pin the slope; a square, a
    -- circle and a rounded blob all fail at least one of them.
    local function solidRun(y)
      local n = 0
      for x = 0, 63 do if select(4, px(x, y)) >= 250 then n = n + 1 end end
      return n
    end
    local wMid, wUp, wDn = solidRun(32), solidRun(16), solidRun(48)
    ok(wMid >= 54 and wMid <= 60,
       ("the mark spans the field at its waist (got %d px)"):format(wMid))
    ok(math.abs(wUp - (wMid - 32)) <= 3 and math.abs(wDn - (wMid - 32)) <= 3,
       ("the silhouette tapers 1:1 like the suite diamond stencil (waist %d, +/-16 rows %d/%d)")
         :format(wMid, wUp, wDn))
    eq(solidRun(0), 0, "the top edge row is empty -- the vertex clears the field")
    eq(solidRun(63), 0, "the bottom edge row is empty")
  end

  -- (e) reproducible ------------------------------------------------------------
  ok(slurp(P("dev/gen-core-glyphs.lua"), "r") ~= nil,
     "dev/gen-core-glyphs.lua is in the tree -- the mark can be regenerated")
end

----------------------------------------------------------------------
-- 7) PERFORMANCE LOG (perf.lua): the suite's third telemetry ring
--
-- The ring is the suite's THIRD (Bags sortLog, Conduit attachTrace), so the gates
-- it has to clear are the ones those two earned:
--
--   a) RING CAP enforced ON WRITE, and convergent when a cap is LOWERED between
--      builds -- not one stale entry leaked per sample forever.
--   b) ADDITIVE SV: a pre-existing DaseekiCoreDB gains exactly ONE new top-level
--      key (`perfLog`) and every value already in it is left alone.
--   c) ONE ENTRY PER SAMPLE KIND, driven through the real event + timer path:
--      login (after the warm-up), interval (the ticker), logout (PLAYER_LOGOUT).
--   d) PREFIX ENUMERATION from a FIXTURE addon list: every Daseeki-* addon that is
--      loaded is sampled, nothing else is, and a future "Daseeki-NewThing" is picked
--      up with no edit to perf.lua. This is the gate that would catch a hardcoded
--      roster -- the suite grows, and the newest addon is the one worth measuring.
--   e) PROFILER-ABSENT / SWITCHED-OFF: one honest entry, no Lua error, and NO ticker
--      is ever created.
--   f) TYPE-GUARDED READS: a profiler that returns strings, tables, nil, NaN or that
--      RAISES is recorded as absent -- never as a value, never as an error.
--   g) THE ENUM IS DISCOVERED, NOT NAMED. wow-api-catalog 1.15.9.68808 lists
--      Enum.AddOnProfilerMetric (doc-tables.txt:206) without its members, so the
--      sampler reads whatever the client has. Two fixtures with COMPLETELY different
--      metric key names must both come through, or something is hardcoded.
--   h) THE TOP-K SHAPE IS CAPTURED RAW (Conduit's GetSendMailItem trick), because
--      AddOnProfilerResult (doc-tables.txt:11) is a name with no fields.
--   i) BUILD STAMP on every entry -- a snapshot from stale code must be self-evident.
----------------------------------------------------------------------
print("\n== GATE 7: performance log ==")

do
  -- ---- the perf fixture environment ----------------------------------------
  -- Built on the same buildEnv the other gates use, plus the profiler surface.
  --
  -- Metric names here are FIXTURES, not claims about the client: the point of two
  -- differently-named sets is to prove perf.lua never asserts a name.
  local METRICS_A = {   -- CamelCase, plausible-Blizzard shape
    SessionAverageTime = 0, LastTime = 1, PeakTime = 2,
    EncounterAverageTime = 3, RecentAverageTime = 4,
    CountTimeOver1Ms = 5, CountTimeOver5Ms = 6,
  }
  local METRICS_B = {   -- a deliberately alien renumbered/renamed shape
    ["session_avg_ms"] = 40, ["peak_ms"] = 41, ["recent_avg_ms"] = 42,
  }

  local FIXTURE_ADDONS = {
    { name = "Blizzard_Something", loaded = true },
    { name = "Daseeki-Core",       loaded = true },
    { name = "SomeOtherAddon",     loaded = true },
    { name = "Daseeki-Bags",       loaded = true },
    { name = "NotDaseeki-Fork",    loaded = true },   -- contains, does not START with
    { name = "Daseeki-Armory",     loaded = false },  -- installed but not loaded
    { name = "Daseeki-NewThing",   loaded = true },   -- the FUTURE addon, adversarial
  }

  -- Deterministic fake readings so assertions can name exact numbers.
  local function fakeValue(name, metric)
    return ((#tostring(name) * 7 + metric * 3) % 97) / 100
  end

  -- opts:
  --   absent    -> no C_AddOnProfiler namespace at all
  --   off       -> IsEnabled() returns false
  --   metrics   -> the Enum.AddOnProfilerMetric fixture (nil = no Enum at all)
  --   addons    -> the addon list fixture
  --   garbage   -> GetAddOnMetric hands back junk instead of numbers
  --   raise     -> GetAddOnMetric raises
  --   topk      -> "named" | "generic" | "strings" | "notatable" | "none"
  local function buildPerfEnv(opts)
    opts = opts or {}
    local env = buildEnv(nil)

    local list = opts.addons or FIXTURE_ADDONS
    env.C_AddOns.GetNumAddOns  = function() return #list end
    env.C_AddOns.GetAddOnName  = function(i) return list[i] and list[i].name or nil end
    env.C_AddOns.IsAddOnLoaded = function(name)
      for _, r in ipairs(list) do if r.name == name then return r.loaded end end
      return false
    end

    env.Enum = opts.metrics and { AddOnProfilerMetric = opts.metrics } or nil

    local junk = { "1.5", {}, nil, 0 / 0, math.huge }
    local junkAt = 0
    local function metricValue(name, metric)
      if opts.raise then error("profiler exploded") end
      if opts.garbage then
        junkAt = (junkAt % #junk) + 1
        return junk[junkAt]
      end
      return fakeValue(name, metric)
    end

    if not opts.absent then
      local topkResults
      if opts.topk == "generic" then
        topkResults = { { name = "HeavyAddon", metric = 3.5 }, { name = "Daseeki-Bags", metric = 0.4 } }
      elseif opts.topk == "strings" then
        topkResults = { "HeavyAddon", "Daseeki-Bags" }
      elseif opts.topk == "notatable" then
        topkResults = "nope"
      elseif opts.topk == "none" then
        topkResults = nil
      else
        topkResults = {
          { addOnName = "HeavyAddon",    value = 3.5 },
          { addOnName = "AnotherAddon",  value = 1.25 },
          { addOnName = "Daseeki-Bags",  value = 0.4 },
          { addOnName = "Daseeki-Core",  value = 0.11 },
          { addOnName = "SmallAddon",    value = 0.02 },
          { addOnName = "TinyAddon",     value = 0.01 },
        }
      end
      env.C_AddOnProfiler = {
        IsEnabled                = function() return not opts.off end,
        GetAddOnMetric           = metricValue,
        GetOverallMetric         = function(m) return metricValue("__overall", m) end,
        GetApplicationMetric     = function(m) return metricValue("__app", m) end,
        GetTopKAddOnsForMetric   = function() return topkResults end,
        GetTicksPerSecond        = function() return opts.tps == nil and 1000000 or opts.tps end,
      }
    end

    local timers = { after = {}, tickers = {} }
    env.__timers = timers
    if not opts.noTimer then
      env.C_Timer = {
        After = function(sec, fn) timers.after[#timers.after + 1] = { sec = sec, fn = fn } end,
        NewTicker = function(sec, fn)
          local t = { sec = sec, fn = fn, cancelled = false }
          function t:Cancel() self.cancelled = true end
          timers.tickers[#timers.tickers + 1] = t
          return t
        end,
      }
    end

    env.GetServerTime = function() return 1770000000 end
    env.UnitName      = function() return "Daseeka", nil end
    env.GetRealmName  = function() return "Whitemane" end
    env.SlashCmdList  = {}
    env.strtrim = function(s)
      return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return env
  end

  -- Load core.lua + perf.lua + slash.lua into a perf env. Returns env, Core, leaked.
  local PERF_FILES = { "core.lua", "perf.lua", "slash.lua" }
  local function loadPerf(opts)
    local env = buildPerfEnv(opts)
    local before = {}
    for k in pairs(env) do before[k] = true end
    local Core = {}
    for _, rel in ipairs(PERF_FILES) do
      local chunk = assert(loadfile(P(rel)))
      setfenv(chunk, env)
      chunk(ADDON_NAME, Core)
    end
    local leaked = {}
    for k in pairs(env) do if not before[k] then leaked[#leaked + 1] = k end end
    table.sort(leaked)
    return env, Core, leaked
  end

  -- Drive the real client sequence: ADDON_LOADED, PLAYER_LOGIN, then the warm-up
  -- timer the login handler armed.
  local function bootAndWarm(env)
    env.__fire("ADDON_LOADED", ADDON_NAME)
    env.__fire("PLAYER_LOGIN")
    for _, t in ipairs(env.__timers.after) do t.fn() end
  end
  local function fireTickers(env, n)
    for _ = 1, (n or 1) do
      for _, t in ipairs(env.__timers.tickers) do
        if not t.cancelled then t.fn() end
      end
    end
  end
  local function ringOf(env) return env.DaseekiCoreDB and env.DaseekiCoreDB.perfLog end
  local function names(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].name end
    return table.concat(out, ",")
  end
  local function sortedKeys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return out
  end

  ------------------------------------------------------------------
  caseName = "perf: the toc actually loads it"
  print("\n-- " .. caseName)
  do
    local sawPerf = false
    for _, rel in ipairs(tocFiles) do if rel == "perf.lua" then sawPerf = true end end
    ok(sawPerf, "perf.lua is listed in the .toc -- the sampler ships loaded")
  end

  ------------------------------------------------------------------
  caseName = "perf: prefix enumeration, no hardcoded roster"
  print("\n-- " .. caseName)
  do
    local env, Core = loadPerf()
    local Perf = Core.Perf
    ok(Perf ~= nil, "perf.lua publishes Core.Perf")

    -- PURE, straight off the fixture list.
    local picked = Perf.SuiteAddOns(FIXTURE_ADDONS)
    eq(table.concat(picked, ","), "Daseeki-Core,Daseeki-Bags,Daseeki-NewThing",
       "only LOADED Daseeki-* addons are sampled, in client order")
    ok(Perf.IsSuiteName("Daseeki-NewThing"), "a future suite addon matches on the PREFIX")
    eq(Perf.IsSuiteName("NotDaseeki-Fork"), false, "a name that merely CONTAINS the prefix does not match")
    eq(Perf.IsSuiteName("SomeOtherAddon"), false, "an unrelated addon does not match")
    eq(Perf.IsSuiteName(nil), false, "a nil name is not a match, and not an error")
    eq(Perf.IsSuiteName(42), false, "a non-string name is not a match either")

    -- ...and there is no roster ANYWHERE in the executable source. A list of addon
    -- names in this file is precisely the regression the case exists to catch, so the
    -- check runs against the CODE with comments stripped (the header prose names the
    -- sibling addons the ring was modelled on, and should keep being allowed to).
    local src = io.open(P("perf.lua"), "r"):read("*a")
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
    local hits = select(2, code:gsub("[Dd]aseeki%-%w", ""))
    eq(hits, 0, "perf.lua's CODE names no individual suite addon (found " .. hits .. ")")
    ok(code:find(Perf.PREFIX, 1, true) ~= nil,
       "the only suite identity in the code is the PREFIX itself")

    -- An entirely different suite roster works with no code change.
    local FUTURE = {
      { name = "Daseeki-Zephyr", loaded = true },
      { name = "DaseekiCompact", loaded = true },   -- no hyphen at all
      { name = "daseeki-lower",  loaded = true },   -- case-insensitive
    }
    eq(table.concat(Perf.SuiteAddOns(FUTURE), ","), "Daseeki-Zephyr,DaseekiCompact,daseeki-lower",
       "an entirely unseen roster is picked up by prefix alone")
    eq(#Perf.SuiteAddOns("not a table"), 0, "a junk addon list yields nothing, not an error")

    -- The LIVE enumerator agrees with the pure one.
    bootAndWarm(env)
    local ring = ringOf(env)
    ok(ring ~= nil and #ring == 1, "the live enumeration produced one entry")
    eq(names(ring[1].addons), "Daseeki-Core,Daseeki-Bags,Daseeki-NewThing",
       "...covering exactly the loaded suite addons the client reported")
  end

  ------------------------------------------------------------------
  caseName = "perf: metrics are DISCOVERED from the client's own enum"
  print("\n-- " .. caseName)
  do
    -- Shape A.
    local env, Core = loadPerf({ metrics = METRICS_A })
    local Perf = Core.Perf
    bootAndWarm(env)
    local e = ringOf(env)[1]
    local m = e.addons[1].m
    ok(m.SessionAverageTime ~= nil and m.PeakTime ~= nil and m.RecentAverageTime ~= nil,
       "every metric the enum offered was read, under the enum's OWN key names")
    ok(m.EncounterAverageTime ~= nil,
       "encounter metrics ride along free when the enum has them (no combat machinery)")
    eq(table.concat(e.metricKeys, ","),
       "SessionAverageTime,LastTime,PeakTime,EncounterAverageTime,RecentAverageTime,CountTimeOver1Ms,CountTimeOver5Ms",
       "the first sample records the enum legend, ordered by the enum's own values")
    ok(e.overall ~= nil and e.app ~= nil, "the OVERALL and APPLICATION rollups are recorded too")
    eq(e.tps, 1000000, "ticksPerSecond is recorded once per session")

    -- Shape B: totally different names AND numbers. Anything hardcoded dies here.
    local env2, Core2 = loadPerf({ metrics = METRICS_B })
    bootAndWarm(env2)
    local e2 = ringOf(env2)[1]
    local m2 = e2.addons[1].m
    ok(m2["session_avg_ms"] ~= nil and m2["peak_ms"] ~= nil and m2["recent_avg_ms"] ~= nil,
       "an alien metric naming/numbering comes through unchanged")
    eq(m2.SessionAverageTime, nil, "...and no shape-A name was invented for it")
    eq(e2.topKMetric, "session_avg_ms", "the top-K ranks by the alien session-average key")

    -- No Enum at all: honest emptiness, no error.
    local env3, Core3 = loadPerf({ metrics = nil })
    bootAndWarm(env3)
    local e3 = ringOf(env3)[1]
    eq(#Core3.Perf.MetricList(nil), 0, "a missing enum yields no metrics")
    eq(e3.addons[1].m, nil, "...so the addon row carries no metric map")
    ok(e3.build ~= nil, "...but the entry is still written, stamped and readable")

    -- The metric list is capped and stably ordered.
    local big = {}
    for i = 1, 40 do big["M" .. i] = i end
    eq(#Perf.MetricList(big), Perf.MAX_METRICS, "the metric list is capped on read")
    eq(Perf.MetricList(big)[1].key, "M1", "...keeping the LOWEST enum values, deterministically")
  end

  ------------------------------------------------------------------
  caseName = "perf: top-K shape is normalised AND captured raw"
  print("\n-- " .. caseName)
  do
    for _, shape in ipairs({ "named", "generic", "strings" }) do
      local env, Core = loadPerf({ metrics = METRICS_A, topk = shape })
      bootAndWarm(env)
      local e = ringOf(env)[1]
      ok(e.topK ~= nil and #e.topK >= 2, ("(%s) the top-K rows came through"):format(shape))
      eq(e.topK[1].name, "HeavyAddon", ("(%s) ...with the addon NAME resolved by type"):format(shape))
      if shape ~= "strings" then
        eq(e.topK[1].value, 3.5, ("(%s) ...and its value"):format(shape))
      end
      ok(e.topKRaw ~= nil and #e.topKRaw >= 1,
         ("(%s) the RAW row shape is captured on the first sample"):format(shape))
    end

    -- The raw capture is what pins the undocumented shape: it must name the fields.
    local env, Core = loadPerf({ metrics = METRICS_A, topk = "named" })
    bootAndWarm(env)
    local e = ringOf(env)[1]
    ok(e.topKRaw[1]:find("addOnName=HeavyAddon", 1, true) ~= nil,
       "the raw capture records the client's REAL field names and values")
    ok(#e.topKRaw <= Core.Perf.MAX_RAW, "the raw capture is capped")

    -- The top-K includes NON-Daseeki addons on purpose: that is the context.
    local sawForeign = false
    for _, r in ipairs(e.topK) do if not Core.Perf.IsSuiteName(r.name) then sawForeign = true end end
    ok(sawForeign, "the top-K carries addons that are NOT ours -- the suite in context")

    -- Raw capture happens ONCE per session, not on every sample forever.
    fireTickers(env, 1)
    local ring = ringOf(env)
    eq(ring[2].topKRaw, nil, "later samples do not re-capture the raw shape")
    eq(ring[2].tps, nil, "...nor re-record ticksPerSecond")
    ok(ring[2].topK ~= nil and #ring[2].topK > 0, "...but they still carry the normalised top-K")

    -- A client that hands back something that is not a table at all.
    local envN, CoreN = loadPerf({ metrics = METRICS_A, topk = "notatable" })
    bootAndWarm(envN)
    local eN = ringOf(envN)[1]
    eq(eN.topK, nil, "a non-table top-K result yields no rows")
    ok(eN.topKRaw ~= nil and eN.topKRaw[1] == "nope",
       "...but WHAT it returned is captured, so the next build knows")
  end

  ------------------------------------------------------------------
  caseName = "perf: one entry per sample kind, on the real event path"
  print("\n-- " .. caseName)
  do
    local env, Core = loadPerf({ metrics = METRICS_A })
    local Perf = Core.Perf

    env.__fire("ADDON_LOADED", ADDON_NAME)
    env.__fire("PLAYER_LOGIN")
    eq(ringOf(env), nil, "nothing is sampled at login -- the warm-up has not elapsed")
    eq(#env.__timers.after, 1, "one warm-up timer was armed")
    eq(env.__timers.after[1].sec, Perf.WARMUP, "...for the warm-up delay, not immediately")

    env.__timers.after[1].fn()
    local ring = ringOf(env)
    ok(ring ~= nil and #ring == 1, "the warm-up sample landed")
    eq(ring[1].kind, "login", "...recorded as the login sample")
    eq(#env.__timers.tickers, 1, "and the interval ticker was started")
    eq(env.__timers.tickers[1].sec, Perf.INTERVAL, "...at the interval cadence")

    fireTickers(env, 2)
    eq(#ring, 3, "each ticker fire appends exactly one entry")
    eq(ring[2].kind, "interval", "...recorded as interval samples")
    eq(ring[3].kind, "interval", "...both of them")

    env.__fire("PLAYER_LOGOUT")
    eq(#ring, 4, "PLAYER_LOGOUT appends the closing sample")
    eq(ring[4].kind, "logout", "...recorded as the logout sample")

    -- Session identity + sequence, so a WTF read can tell sessions apart.
    eq(ring[1].session, ring[4].session, "every sample in a session shares one session id")
    eq(ring[1].seq, 1, "sequence numbers start at 1")
    eq(ring[4].seq, 4, "...and count the session's samples")
    eq(ring[1].char, "Daseeka-Whitemane", "the character is stamped on the entry")

    -- ZERO per-frame work: perf.lua must never hang a script on OnUpdate. Checked
    -- against the CODE, not the prose (the header explains the rule in words).
    local src = io.open(P("perf.lua"), "r"):read("*a")
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
    eq(code:find("OnUpdate", 1, true), nil,
       "perf.lua registers no OnUpdate -- the sampler is near-free between samples")
    local scripts = select(2, code:gsub("SetScript%(", ""))
    eq(scripts, 1, "exactly ONE script is set: the event handler")
  end

  ------------------------------------------------------------------
  caseName = "perf: build stamp on every entry"
  print("\n-- " .. caseName)
  do
    local env, Core = loadPerf({ metrics = METRICS_A })
    bootAndWarm(env)
    fireTickers(env, 1)
    env.__fire("PLAYER_LOGOUT")
    local ring = ringOf(env)
    for i = 1, #ring do
      ok(type(ring[i].build) == "string" and ring[i].build ~= "",
         ("entry %d carries a build stamp"):format(i))
    end
    ok(ring[1].build:find(TOC_VERSION, 1, true) ~= nil,
       "the stamp carries Core's ## Version (" .. tostring(TOC_VERSION) .. ")")
    ok(ring[1].build:find(Core.Perf.BUILD_TOKEN, 1, true) ~= nil,
       "...and the sampler's own build token (" .. tostring(Core.Perf.BUILD_TOKEN) .. ")")

    -- Unreadable version metadata must not cost us the stamp entirely.
    local envNV, CoreNV = loadPerf({ metrics = METRICS_A })
    envNV.C_AddOns.GetAddOnMetadata = false
    envNV.GetAddOnMetadata = false
    -- reload core+perf under the stripped metadata surface
    local Core2 = {}
    for _, rel in ipairs(PERF_FILES) do
      local chunk = assert(loadfile(P(rel))); setfenv(chunk, envNV); chunk(ADDON_NAME, Core2)
    end
    eq(Core2.Perf.Build(), "?+" .. Core2.Perf.BUILD_TOKEN,
       "an unreadable Core version still yields a stamped, honest build string")
  end

  ------------------------------------------------------------------
  caseName = "perf: ring cap enforced on write"
  print("\n-- " .. caseName)
  do
    local env, Core = loadPerf({ metrics = METRICS_A })
    local Perf = Core.Perf
    bootAndWarm(env)
    fireTickers(env, Perf.CAP + 10)
    local ring = ringOf(env)
    eq(#ring, Perf.CAP, "the ring never exceeds its cap, however long the session runs")
    eq(ring[#ring].seq, Perf.CAP + 11, "the NEWEST sample is at the end")
    ok(ring[1].seq > 1, "...and the oldest samples were dropped from the front")

    -- The cap is honoured on the pure Append too, and a LOWERED cap converges on
    -- the first write rather than leaking one stale entry per sample forever.
    local r = {}
    for i = 1, 12 do Perf.Append(r, { ts = i, kind = "interval" }, 5) end
    eq(#r, 5, "a bare ring respects the cap handed to Append")
    eq(r[1].ts, 8, "...dropping from the front")
    Perf.Append(r, { ts = 99, kind = "interval" }, 2)
    eq(#r, 2, "a cap LOWERED between builds converges on the very first append")
    eq(r[2].ts, 99, "...keeping the newest")
    Perf.Append(r, { ts = 100 }, 0)
    eq(#r, 1, "a nonsense cap of 0 is floored at 1 rather than emptying the ring")
    eq(Perf.Append("not a ring", {}), nil, "appending to a non-table is nil, not an error")

    -- Per-entry caps, all enforced on write.
    local many, tk = {}, {}
    for i = 1, 60 do many[i] = { name = "Daseeki-A" .. i, m = { X = i } } end
    for i = 1, 60 do tk[i] = { name = "N" .. i, value = i } end
    local e = Perf.NewEntry({ addons = many, topK = tk, topKRaw = many,
                              metricKeys = many, note = string.rep("x", 500),
                              char = string.rep("c", 500) })
    eq(#e.addons, Perf.MAX_ADDONS, "the addon list is capped on write")
    eq(#e.topK, Perf.MAX_TOPK, "the top-K list is capped on write")
    eq(#e.topKRaw, Perf.MAX_RAW, "the raw capture is capped on write")
    eq(#e.note, Perf.MAX_NOTE, "the note is truncated on write")
    eq(#e.char, Perf.MAX_NAME, "the character string is truncated on write")
    eq(Perf.NewEntry({ kind = "wat" }).kind, "interval", "an unknown sample kind is normalised")
    eq(Perf.NewEntry(nil).ts, 0, "a nil entry normalises rather than raising")
  end

  ------------------------------------------------------------------
  caseName = "perf: additive SavedVariables"
  print("\n-- " .. caseName)
  do
    -- A save from the shipped build, with the owner's own choices in it.
    local seedEnv = loadPerf({ metrics = METRICS_A })
    seedEnv.__fire("ADDON_LOADED", ADDON_NAME)
    local existing = {}
    for k, v in pairs(seedEnv.DaseekiCoreDB) do existing[k] = v end
    existing.theme          = "Winterspring Frost"
    existing.fontChoice     = "2002"
    existing.fontScale      = 1.15
    existing.minimapAngle   = 42
    existing.lastAddon      = "armory"
    local beforeKeys = table.concat(sortedKeys(existing), ",")
    local beforeVals = {}
    for k, v in pairs(existing) do beforeVals[k] = v end

    local env, Core = loadPerf({ metrics = METRICS_A })
    env.DaseekiCoreDB = existing
    bootAndWarm(env)
    fireTickers(env, 1)

    local afterKeys = sortedKeys(env.DaseekiCoreDB)
    local added = {}
    for _, k in ipairs(afterKeys) do
      if beforeKeys:find(k, 1, true) == nil then added[#added + 1] = k end
    end
    eq(table.concat(added, ","), "perfLog",
       "the log writes exactly ONE new SavedVariables key, `perfLog`")
    local changed = {}
    for k, v in pairs(beforeVals) do
      if env.DaseekiCoreDB[k] ~= v then changed[#changed + 1] = k end
    end
    eq(table.concat(changed, ","), "", "every pre-existing setting is left exactly as it was")
    ok(env.DaseekiCoreDB == existing, "...and it is the SAME table -- the save was not replaced")
    eq(type(env.DaseekiCoreDB.perfLog), "table", "the ring is a plain array on the settings DB")

    -- Clearing empties IN PLACE, so nothing holding a reference is left dangling.
    local live = env.DaseekiCoreDB.perfLog
    local n = Core.Perf.Count()
    ok(n >= 2, "there are samples to clear (" .. n .. ")")
    eq(Core.Perf.Clear(), n, "Clear reports how many it dropped")
    eq(#live, 0, "...the buffer is empty")
    ok(env.DaseekiCoreDB.perfLog == live, "...IN PLACE: the SV table identity survives a clear")
    eq(Core.Perf.Count(), 0, "...and the count agrees")

    -- Reading a ring that was never created is an empty list, not nil and not an error.
    eq(#Core.Perf.Records(nil), 0, "reading a missing ring yields an empty list")
    ok(Core.Perf.Records(live) ~= live, "Records hands back a COPY; the live SV table is never handed out")
  end

  ------------------------------------------------------------------
  caseName = "perf: profiler switched off / absent"
  print("\n-- " .. caseName)
  do
    -- (a) the player switched it off.
    local env, Core = loadPerf({ metrics = METRICS_A, off = true })
    bootAndWarm(env)
    local ring = ringOf(env)
    ok(ring ~= nil and #ring == 1, "exactly ONE entry is written when the profiler is off")
    eq(ring[1].kind, "off", "...marked as such")
    eq(ring[1].profiler, false, "...recording that the profiler said no")
    ok(type(ring[1].note) == "string" and ring[1].note:find("switched off", 1, true) ~= nil,
       "...with a note a human can act on")
    eq(ring[1].addons, nil, "...and nothing was sampled")
    eq(#env.__timers.tickers, 0, "NO ticker is created -- the sampler stops for the session")

    env.__fire("PLAYER_LOGOUT")
    eq(#ring, 1, "...and PLAYER_LOGOUT does not append a second one either")

    -- (b) the client has no profiler at all.
    local env2, Core2 = loadPerf({ metrics = METRICS_A, absent = true })
    bootAndWarm(env2)
    local ring2 = ringOf(env2)
    ok(ring2 ~= nil and #ring2 == 1, "an absent profiler also writes exactly one honest entry")
    eq(ring2[1].kind, "off", "...marked as an off sample")
    eq(ring2[1].profiler, nil,
       "...with the profiler state left NIL: 'we could not ask' is not 'it said no'")
    ok(ring2[1].note:find("no addon profiler", 1, true) ~= nil, "...and the note says why")
    eq(#env2.__timers.tickers, 0, "no ticker on a client with no profiler")

    -- (c) no timer service at all: still one sample, still no error.
    local env3, Core3 = loadPerf({ metrics = METRICS_A, noTimer = true })
    env3.__fire("ADDON_LOADED", ADDON_NAME)
    local okBoot = pcall(env3.__fire, "PLAYER_LOGIN")
    ok(okBoot, "a client with no C_Timer boots without raising")
    local r3 = ringOf(env3)
    ok(r3 ~= nil and #r3 == 1, "...and still takes one sample immediately (got "
       .. tostring(r3 and #r3) .. ")")
    eq(r3 and r3[1].kind, "login", "...recorded as the login sample")
  end

  ------------------------------------------------------------------
  caseName = "perf: type-guarded reads"
  print("\n-- " .. caseName)
  do
    -- (a) the profiler hands back strings, tables, nil, NaN and infinity.
    local env, Core = loadPerf({ metrics = METRICS_A, garbage = true })
    local okRun = pcall(bootAndWarm, env)
    ok(okRun, "a profiler returning junk does not raise")
    local e = ringOf(env)[1]
    ok(e ~= nil, "...an entry is still written")
    for i = 1, #(e.addons or {}) do
      eq(e.addons[i].m, nil, ("addon %d records the junk readings as ABSENT, not as values"):format(i))
    end

    -- (b) the profiler RAISES.
    local env2, Core2 = loadPerf({ metrics = METRICS_A, raise = true })
    local okRun2 = pcall(bootAndWarm, env2)
    ok(okRun2, "a profiler that RAISES does not take the login with it")
    local e2 = ringOf(env2)[1]
    ok(e2 ~= nil and e2.build ~= nil, "...and a stamped entry is still written")
    eq(e2.addons[1].m, nil, "...with the unreadable metrics recorded as absent")

    -- (c) the primitives, directly.
    local Perf = Core.Perf
    eq(Perf.Num("1.5"), nil, "a numeric STRING is not accepted as a metric")
    eq(Perf.Num(0 / 0), nil, "NaN is rejected -- it would poison the saved file")
    eq(Perf.Num(math.huge), nil, "infinity is rejected")
    eq(Perf.Num(-math.huge), nil, "negative infinity is rejected")
    eq(Perf.Num({}), nil, "a table is not a metric")
    eq(Perf.Num(nil), nil, "nil is not a metric")
    eq(Perf.Num(1.23456789), 1.2346, "real readings are kept to four decimals")
    eq(Perf.Num(0), 0, "a genuine zero survives (it is a reading, not an absence)")
    eq(Perf.Str({}), "<table>", "a table stringifies to its TYPE, never its address")
    eq(#Perf.Str(string.rep("x", 500)), Perf.MAX_STR, "long strings are truncated")
    eq(Perf.NormMetrics({ good = 1.5, bad = "x", worse = {} }).good, 1.5,
       "a metric map keeps the readable entries...")
    eq(Perf.NormMetrics({ good = 1.5, bad = "x" }).bad, nil, "...and drops the unreadable ones")
    eq(Perf.NormMetrics({ bad = "x" }), nil, "an all-unreadable map is nil rather than an empty husk")
    eq(Perf.NormMetrics("junk"), nil, "a non-table metric map is nil, not an error")
    eq(Perf.TopKRow(42), nil, "a nonsense top-K row is dropped")
    eq(Perf.TopKRow({}), nil, "an empty top-K row is dropped")
    eq(Perf.TopKRow({ junk = {} }), nil, "a row with no readable field is dropped")
    eq(Perf.TopKRow("Named").name, "Named", "a bare string row is accepted as a name")
    eq(Perf.TopKRow({ addOnName = "X", value = 2 }).value, 2, "a named row keeps its value")
    eq(Perf.TopKRow({ zzz = "X", aaa = 9 }).name, "X",
       "an unrecognised row falls back to the first string field, deterministically")
    eq(Perf.TopKRaw({ b = 2, a = "x" }), "a=x|b=2", "the raw capture is sorted and stable")
    eq(Perf.TopKRaw({}), "<empty table>", "an empty raw row says so rather than vanishing")
  end

  ------------------------------------------------------------------
  caseName = "perf: /daseeki perf reads it back"
  print("\n-- " .. caseName)
  do
    local env, Core = loadPerf({ metrics = METRICS_A })
    local Perf = Core.Perf
    local run = env.SlashCmdList["DASEEKISUITE"]
    ok(type(run) == "function", "the suite slash handler exists")

    -- Empty log: the command still ANSWERS, and says what to expect.
    local before = #env.__notices
    run("perf")
    ok(#env.__notices > before, "/daseeki perf answers on an empty log")
    ok(env.__notices[#env.__notices]:find("No performance samples yet", 1, true) ~= nil,
       "...explaining that the first sample lands after login")

    bootAndWarm(env)
    fireTickers(env, 1)
    before = #env.__notices
    run("perf")
    local printed = {}
    for i = before + 1, #env.__notices do printed[#printed + 1] = env.__notices[i] end
    local blob = table.concat(printed, "\n")
    ok(#printed >= 5, "/daseeki perf prints a multi-line report (" .. #printed .. " lines)")
    ok(blob:find("Addon performance", 1, true) ~= nil, "...headed as the performance report")
    ok(blob:find("2 of " .. Perf.CAP .. " samples kept", 1, true) ~= nil,
       "...stating ring occupancy against the cap")
    ok(blob:find("Daseeki%-Core") ~= nil, "...listing each sampled suite addon")
    ok(blob:find("Daseeki%-NewThing") ~= nil, "...including the future one")
    ok(blob:find("recent", 1, true) and blob:find("session", 1, true) and blob:find("peak", 1, true),
       "...under recent / session / peak columns")
    ok(blob:find("ms", 1, true) ~= nil, "...with millisecond-formatted timings")
    ok(blob:find("HeavyAddon", 1, true) ~= nil, "...and the top-5 overall for context")
    ok(blob:find("ALL ADDONS", 1, true) ~= nil, "...with the all-addons rollup to give it scale")

    -- clear
    before = #env.__notices
    run("perf clear")
    eq(Perf.Count(), 0, "/daseeki perf clear empties the ring")
    ok(env.__notices[#env.__notices]:find("cleared", 1, true) ~= nil, "...and says so")
    run("perf")
    ok(env.__notices[#env.__notices]:find("No performance samples yet", 1, true) ~= nil,
       "...leaving the log genuinely empty")

    -- The report is PURE, so its shape is pinnable without a chat frame.
    local lines = Perf.FormatEntry(nil, 0, Perf.CAP)
    ok(#lines == 1 and lines[1]:find("No performance samples", 1, true) ~= nil,
       "formatting a nil entry degrades to one honest line")
    local offLines = Perf.FormatEntry({ kind = "off", note = "profiler is off", ts = 0 }, 1, 60)
    ok(table.concat(offLines, "\n"):find("profiler is off", 1, true) ~= nil,
       "an off entry prints its note instead of empty columns")

    -- Columns resolve from whatever the client named its metrics -- both shapes.
    local colsA = Perf.Columns({ "SessionAverageTime", "PeakTime", "RecentAverageTime" })
    eq(colsA.session, "SessionAverageTime", "column resolution finds session average (shape A)")
    eq(colsA.recent, "RecentAverageTime", "...and recent average")
    eq(colsA.peak, "PeakTime", "...and peak")
    local colsB = Perf.Columns({ "session_avg_ms", "peak_ms", "recent_avg_ms" })
    eq(colsB.session, "session_avg_ms", "column resolution finds them under alien names too")
    eq(colsB.peak, "peak_ms", "...peak as well")
    eq(Perf.Columns({}).session, nil, "no metrics means no column, not a crash")
    eq(Perf.FormatValue("PeakTime", nil), "—", "a missing reading prints as a dash")
    eq(Perf.FormatValue("CountTimeOver1Ms", 12.4), "12", "counters print as integers")
    eq(Perf.FormatValue("PeakTime", 1.5), "1.50ms", "timings print in milliseconds")
    -- "EncounterAverageTime" CONTAINS the substring "count" (en-COUNT-eraverage). A
    -- loose match printed a 0.12ms encounter average as a flat "0".
    eq(Perf.FormatValue("EncounterAverageTime", 0.12), "0.12ms",
       "an encounter average is a DURATION, not a counter, despite spelling 'count'")
    eq(Perf.FormatValue("timeOver10Ms", 7), "7", "a threshold counter still reads as a count")

    -- ...and the same trap, end to end through the report, on a client whose enum
    -- HAS encounter metrics (METRICS_A does).
    local encEnv, encCore = loadPerf({ metrics = METRICS_A })
    bootAndWarm(encEnv)
    local encLine
    for _, l in ipairs(encCore.Perf.FormatEntry(encCore.Perf.Records(ringOf(encEnv))[1], 1, 60)) do
      if l:find("encounter avg", 1, true) then encLine = l end
    end
    ok(encLine ~= nil, "the report carries an encounter line when the enum offers one")
    ok(encLine and encLine:find("ms", 1, true) ~= nil,
       "...with millisecond timings, not flattened integers")

    -- A client with NO encounter metric simply has no such line -- and no combat
    -- machinery was built to invent one.
    local noEncEnv, noEncCore = loadPerf({ metrics = METRICS_B })
    bootAndWarm(noEncEnv)
    local sawEnc = false
    for _, l in ipairs(noEncCore.Perf.FormatEntry(noEncCore.Perf.Records(ringOf(noEncEnv))[1], 1, 60)) do
      if l:find("encounter", 1, true) then sawEnc = true end
    end
    eq(sawEnc, false, "a client without encounter metrics gets no encounter line")
  end

  ------------------------------------------------------------------
  caseName = "perf: global firewall"
  print("\n-- " .. caseName)
  do
    local ALLOWED = {
      DaseekiSuite = true, DaseekiCoreDB = true, DaseekiCoreCharDB = true,
      -- slash.lua's registrations, which the client requires to be globals
      SLASH_DASEEKISUITE1 = true, SLASH_DASEEKISUITE2 = true, SLASH_DASEEKIUI1 = true,
    }
    local env, Core, leaked = loadPerf({ metrics = METRICS_A })
    bootAndWarm(env)
    local bad = {}
    for k in pairs(env) do
      if type(k) == "string" and not ALLOWED[k] and not k:match("^__")
         and (k:match("^Daseeki") or k:match("^Perf") or k:match("^SLASH")) then
        bad[#bad + 1] = k
      end
    end
    table.sort(bad)
    eq(#bad, 0, "perf.lua leaks no globals of its own (" .. table.concat(bad, ", ") .. ")")
    ok(Core.Perf ~= nil, "the sampler lives on the addon namespace, not in _G")
    eq(env.Perf, nil, "...and `Perf` is not a global")
  end
end

----------------------------------------------------------------------
print("\n=====================================================")
if #failures == 0 then
  print(("OVERALL: ALL PASS  (%d checks)"):format(checks))
  os.exit(0)
end
print(("OVERALL: %d FAILURE(S) of %d checks"):format(#failures, checks))
for _, f in ipairs(failures) do print("  - " .. f) end
os.exit(1)
