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
print("\n=====================================================")
if #failures == 0 then
  print(("OVERALL: ALL PASS  (%d checks)"):format(checks))
  os.exit(0)
end
print(("OVERALL: %d FAILURE(S) of %d checks"):format(#failures, checks))
for _, f in ipairs(failures) do print("  - " .. f) end
os.exit(1)
