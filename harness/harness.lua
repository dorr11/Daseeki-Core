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

local function buildEnv(fontModes, denyProbe)
  local env = {}
  env._G = env
  setmetatable(env, { __index = _G })

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
    function o:SetTextColor() end
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
local function loadCore(fontModes, denyProbe)
  local env = buildEnv(fontModes, denyProbe)
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
print("\n=====================================================")
if #failures == 0 then
  print(("OVERALL: ALL PASS  (%d checks)"):format(checks))
  os.exit(0)
end
print(("OVERALL: %d FAILURE(S) of %d checks"):format(#failures, checks))
for _, f in ipairs(failures) do print("  - " .. f) end
os.exit(1)
