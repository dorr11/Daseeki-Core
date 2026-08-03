--[[
    Daseeki Core
    Shared options hub + UI toolkit for the Daseeki addon suite.

    Public API (global DaseekiSuite):
        DaseekiSuite:RegisterAddon({
            id      = "bufftracker",            -- unique key (used by slash + nav)
            title   = "Buff Tracker",           -- left-nav label
            icon    = "Interface\\Icons\\...",  -- optional nav icon
            order   = 20,                        -- nav sort (lower = higher)
            build   = function(panel) ... end,   -- imperative section builder
            options = function() return {...} end,-- OR declarative options table
            refresh = function(panel) ... end,    -- called each time section shown
        })
        DaseekiSuite:Open(id)     -- show hub at a section (lazy-builds it)
        DaseekiSuite:Toggle(id)
        DaseekiSuite.available     -- truthy when Core is loaded (addons check this)
        DaseekiSuite.CORE_VERSION  -- this Core's ## Version string (nil if unreadable)
        DaseekiSuite.RequireCore(minVersion[, caller])  -- cross-addon API guard

    Each feature addon keeps its own SavedVariables; Core only stores hub window
    state in DaseekiCoreDB.
--]]

local ADDON, Core = ...

-- Expose globally so the other Daseeki addons can register into the hub.
DaseekiSuite = Core
_G.DaseekiSuite = Core

Core.available = true

-- ── Version identity + cross-addon API guard ──────────────────────────────────
-- Suite addons must guard a Core API against the Core VERSION that introduced it
-- and degrade with a message rather than a Lua error (ROLLOUT_CONTINUITY_AUDIT
-- gate D-13 / NW-6). The version comes from our own .toc so there is exactly one
-- source of truth, and is cached because GetAddOnMetadata is a C call.

local function readCoreVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
    if type(get) ~= "function" then return nil end
    local ok, v = pcall(get, ADDON, "Version")
    if not ok or type(v) ~= "string" or v == "" then return nil end
    return v
end

Core.CORE_VERSION = readCoreVersion()

-- Numeric-per-component compare. Missing components read as 0 ("2.2" == "2.2.0")
-- and a non-numeric tail is ignored, so a pre-release stamp like "2.2.0-n1"
-- compares as 2.2.0. Returns -1 / 0 / 1.
local function versionParts(v)
    local out = {}
    for chunk in tostring(v or ""):gmatch("[^%.]+") do
        out[#out + 1] = tonumber(chunk:match("^%s*(%d+)")) or 0
    end
    return out
end

function Core.CompareVersions(a, b)
    local pa, pb = versionParts(a), versionParts(b)
    local n = (#pa > #pb) and #pa or #pb
    for i = 1, n do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return (x < y) and -1 or 1 end
    end
    return 0
end

-- One chat line per session per (caller, minVersion) pair; a guard sitting in a
-- per-row builder must not narrate itself once per row.
local requireTold = {}

-- Plain text, no color escapes — the line is meant to be copied into a report.
local function requireNotice(msg)
    local out = _G.DEFAULT_CHAT_FRAME
    if out and type(out.AddMessage) == "function" then
        pcall(out.AddMessage, out, msg)
    elseif type(_G.print) == "function" then
        pcall(_G.print, msg)
    end
end

-- True when the installed Core is at least `minVersion`. On failure, prints one
-- explanatory line and returns false; NEVER raises. `caller` is a short label
-- for the feature being gated ("Nexus character cards") and only shapes the text.
function Core.RequireCore(minVersion, caller, callerIfColon)
    -- Tolerate a colon call (DaseekiSuite:RequireCore("2.2.0", "...")): a
    -- cross-addon entry point should not turn the wrong invocation style into
    -- an error, and the caller label must survive the shift.
    if minVersion == Core then minVersion, caller = caller, callerIfColon end
    if type(minVersion) ~= "string" and type(minVersion) ~= "number" then return true end

    local installed = Core.CORE_VERSION
    -- Metadata unreadable (odd client state): pass rather than switch off working
    -- features over a version we could not read.
    if not installed then return true end
    if Core.CompareVersions(installed, minVersion) >= 0 then return true end

    local key = tostring(caller or "?") .. "<" .. tostring(minVersion)
    if not requireTold[key] then
        requireTold[key] = true
        requireNotice(("Daseeki: %s needs Daseeki Core v%s, v%s installed — update Daseeki-Core. "
            .. "That part of the interface stays off until you do.")
            :format(tostring(caller or "a Daseeki addon"), tostring(minVersion), tostring(installed)))
    end
    return false
end

Core.sections  = {}   -- id -> section/addon definition table
Core.regOrder  = {}   -- suite addon ids in REGISTRATION ORDER (sidebar order)
Core.coreOrder = {}   -- Core-owned page ids (Appearance, future) — separate group

-- Account-wide state (shared across characters). Window GEOMETRY lives in the
-- per-character DB below so window size/position can differ per character.
local DB_DEFAULTS = {
    lastSection  = nil,   -- legacy (last addon id); kept for back-compat
    lastAddon    = nil,   -- last selected top-level addon id
    minimapAngle = 220,
    minimapHide  = false,
    theme        = "Field Ledger",    -- fresh-install default (BRAND_SPEC §2). Applied
                                       -- ONLY when DaseekiCoreDB.theme is nil, so an
                                       -- existing player's saved choice is never changed.
    materialPreset = "standard",       -- Field Ledger material dial (BRAND_SPEC §4/§5a):
                                       -- subtle | standard | strong. ledgerkit.lua applies
                                       -- this on ADDON_LOADED and /daseekiui debug material
                                       -- cycles it live. Additive; existing saves default in.
    fontChoice = "Fira Sans Condensed Medium",   -- fresh-install default face (vendored FiraSansCondensed-Medium.ttf, OFL 1.1). Owner's "too thin" fix. Applied ONLY when nil, so an existing saved choice is never changed.
    fontScale  = 1.0,               -- global text-size multiplier (0.85–1.3), default 100%.
}

-- Per-character window geometry (owner decision: size persisted per character).
local CHAR_DB_DEFAULTS = {
    point    = "CENTER",
    relPoint = "CENTER",
    x        = 0,
    y        = 0,
    width    = nil,   -- nil -> default window size on first open
    height   = nil,
}

-- ── SavedVariables ────────────────────────────────────────────────────────────
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON then return end
    DaseekiCoreDB = DaseekiCoreDB or {}
    for k, v in pairs(DB_DEFAULTS) do
        if DaseekiCoreDB[k] == nil then DaseekiCoreDB[k] = v end
    end
    DaseekiCoreCharDB = DaseekiCoreCharDB or {}
    for k, v in pairs(CHAR_DB_DEFAULTS) do
        if DaseekiCoreCharDB[k] == nil then DaseekiCoreCharDB[k] = v end
    end
    Core.db     = DaseekiCoreDB
    Core.charDb = DaseekiCoreCharDB
    loader:UnregisterEvent("ADDON_LOADED")
end)

-- ── Registry ──────────────────────────────────────────────────────────────────

-- Register (or re-register) an addon's options section.
-- An addon may declare multiple `sections` (each {id,title,build,refresh}); if it
-- doesn't, we synthesize a single implicit section from its build/options/refresh so
-- single-area addons keep working unchanged.
function Core:RegisterAddon(def)
    assert(type(def) == "table" and def.id, "DaseekiSuite:RegisterAddon requires a table with an id")
    def.order = def.order or 100
    def.title = def.title or def.id
    if not def.sections or #def.sections == 0 then
        -- Legacy imperative path: a single implicit section built from the
        -- addon-level build/options/refresh. build(panel) receives a raw frame.
        def.sections = { {
            id      = "_main",
            title   = def.title,
            build   = def.build,
            options = def.options,
            refresh = def.refresh,
            legacy  = true,
        } }
    else
        -- BACK-COMPAT IS THE DEFAULT. A def carrying `sections` is NOT assumed to be
        -- a new flow-API caller: the old RegisterAddon API already used `sections`
        -- (the old hub's sub-tab row). Flow rendering is opt-in ONLY via `flow = true`
        -- on the addon def. Without it, every section renders through the legacy
        -- raw-frame path (build(panel) receives a real Frame), exactly as before.
        -- A per-section `legacy` value always wins (a flow addon may force one section
        -- legacy, or a legacy addon may opt one section into flow).
        local defaultLegacy = not def.flow
        for i, s in ipairs(def.sections) do
            s.id = s.id or ("s" .. i)
            if s.legacy == nil then s.legacy = defaultLegacy end
        end
    end
    if not self.sections[def.id] then
        self.regOrder[#self.regOrder + 1] = def.id
    end
    self.sections[def.id] = def
    -- If the hub window already exists, rebuild the sidebar so the new addon appears.
    if self.RebuildNav then self:RebuildNav() end
    return def
end

-- Register a Core-owned page (Appearance, future) shown in the sidebar's "Core"
-- group rather than the registration-ordered Suite group. Same section machinery.
function Core:RegisterCorePage(def)
    assert(type(def) == "table" and def.id, "RegisterCorePage requires an id")
    def.title = def.title or def.id
    def.isCore = true
    if not def.sections or #def.sections == 0 then
        def.sections = { { id = "_main", title = def.title, build = def.build, refresh = def.refresh, legacy = def.legacy or false } }
    else
        -- Core pages follow the same opt-in rule as RegisterAddon: flow only when
        -- `flow = true`; otherwise legacy raw-frame. A per-section `legacy` wins.
        local defaultLegacy = not def.flow
        for i, s in ipairs(def.sections) do
            s.id = s.id or ("s" .. i)
            if s.legacy == nil then s.legacy = defaultLegacy end
        end
    end
    if not self.sections[def.id] then
        self.coreOrder[#self.coreOrder + 1] = def.id
    end
    self.sections[def.id] = def
    if self.RebuildNav then self:RebuildNav() end
    return def
end

-- The section table for an addon (always non-empty after RegisterAddon).
function Core:GetAddonSections(addonId)
    local a = self.sections[addonId]
    return a and a.sections or {}
end

-- Find a section def within an addon by id (nil -> first).
function Core:GetAddonSection(addonId, sectionId)
    local secs = self:GetAddonSections(addonId)
    if sectionId then
        for _, s in ipairs(secs) do if s.id == sectionId then return s end end
    end
    return secs[1]
end

-- Sections sorted by order then title (Details!-style "iterate the namespace").
function Core:GetSectionsSorted()
    local list = {}
    for _, s in pairs(self.sections) do list[#list + 1] = s end
    table.sort(list, function(a, b)
        if a.order == b.order then return (a.title or "") < (b.title or "") end
        return a.order < b.order
    end)
    return list
end

-- ── Public open/toggle (hub functions live in hub.lua) ────────────────────────

function Core:Open(id, sectionId)
    self:EnsureHub()
    if id then self:ShowAddon(id, sectionId) end
    self.window:Show()
end

function Core:Toggle(id, sectionId)
    self:EnsureHub()
    if self.window:IsShown() then
        self.window:Hide()
    else
        if id then self:ShowAddon(id, sectionId) end
        self.window:Show()
    end
end
