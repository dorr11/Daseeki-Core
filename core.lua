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

    Each feature addon keeps its own SavedVariables; Core only stores hub window
    state in DaseekiCoreDB.
--]]

local ADDON, Core = ...

-- Expose globally so the other Daseeki addons can register into the hub.
DaseekiSuite = Core
_G.DaseekiSuite = Core

Core.available = true
Core.sections  = {}   -- id -> section definition table

local DB_DEFAULTS = {
    point        = "CENTER",
    relPoint     = "CENTER",
    x            = 0,
    y            = 0,
    lastSection  = nil,   -- legacy (last addon id); kept for back-compat
    lastAddon    = nil,   -- last selected top-level addon id
    minimapAngle = 220,
    minimapHide  = false,
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
    Core.db = DaseekiCoreDB
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
        def.sections = { {
            id      = "_main",
            title   = def.title,
            build   = def.build,
            options = def.options,
            refresh = def.refresh,
        } }
    end
    self.sections[def.id] = def
    -- If the hub window already exists, rebuild the tab rows so the new addon appears.
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
