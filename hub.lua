--[[
    Daseeki Core — the combined options window (DaseekiUI chrome, Direction B).

    Left sidebar navigation:
      * "SUITE" group — registered addons in REGISTRATION ORDER; the active addon's
        sections indent beneath it.
      * "CORE" group — Core-owned pages (Appearance theme picker + future slots).

    The content area hosts each (addon, section) pane, built lazily:
      * New flow sections: a DaseekiUI scroll+clip pane; build(flow) uses the flow API.
      * Legacy build(panel) sections: wrapped in a scroll+clip pane so their existing
        absolute-offset layout is contained (overflow scrolls instead of escaping).

    Window is resizable (min 760x560); geometry persists per character. Title bar
    drag-moves; a corner grip drag-resizes. Everything reads theme tokens and
    re-skins live on ThemeChanged.
--]]

local ADDON, Core = ...
local UI = DaseekiUI

local DEFAULT_W, DEFAULT_H = 1024, 680
local MIN_W, MIN_H = 760, 560
local TITLE_H   = 34
local SIDEBAR_W = 190
local PAD       = 12

local GEM_ICON      = "Interface\\AddOns\\Daseeki-Core\\art\\nightblade"
local GEM_FALLBACK  = "Interface\\Icons\\INV_Misc_Gem_02"

-- ── Geometry persistence (per character) ──────────────────────────────────────
local function SaveGeometry(win)
    local db = Core.charDb
    if not db then return end
    local point, _, relPoint, x, y = win:GetPoint()
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
    db.width, db.height = math.floor(win:GetWidth() + 0.5), math.floor(win:GetHeight() + 0.5)
end

local function RestoreGeometry(win)
    local db = Core.charDb or {}
    win:SetSize(math.max(MIN_W, db.width or DEFAULT_W), math.max(MIN_H, db.height or DEFAULT_H))
    win:ClearAllPoints()
    win:SetPoint(db.point or "CENTER", UIParent, db.relPoint or "CENTER", db.x or 0, db.y or 0)
end

-- ── Section / last-selection persistence ──────────────────────────────────────
local function LastSectionFor(addonId)
    local db = Core.db
    return db and db.lastSectionByAddon and db.lastSectionByAddon[addonId]
end
local function SetLastSection(addonId, sectionId)
    local db = Core.db; if not db then return end
    db.lastSectionByAddon = db.lastSectionByAddon or {}
    db.lastSectionByAddon[addonId] = sectionId
end

-- ── Sidebar entry button ──────────────────────────────────────────────────────
-- kind: "group" (non-clickable heading) | "addon" | "section"
local function MakeNavButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(24)

    b.selBar = b:CreateTexture(nil, "ARTWORK")
    b.selBar:SetWidth(3)
    b.selBar:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.selBar:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    b.selBar:Hide()

    b.hl = b:CreateTexture(nil, "BACKGROUND")
    b.hl:SetAllPoints()
    b.hl:Hide()

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:Hide()

    b.label = b:CreateFontString(nil, "OVERLAY")
    b.label:SetJustifyH("LEFT")
    b.label:SetWordWrap(false)

    b:SetScript("OnEnter", function(self)
        if self._kind ~= "group" and not self._selected then
            self.hl:SetColorTexture(UI.Color("accent", 0.10)); self.hl:Show()
        end
    end)
    b:SetScript("OnLeave", function(self) if not self._selected then self.hl:Hide() end end)

    function b:Style(kind, selected)
        self._kind = kind
        self._selected = selected
        if kind == "group" then
            self.label:SetFontObject(UI.fonts.small)
            self.label:SetTextColor(UI.Color("faint"))
            self.selBar:Hide(); self.hl:Hide()
        elseif kind == "section" then
            self.label:SetFontObject(selected and UI.fonts.accent or UI.fonts.muted)
            self.selBar:SetColorTexture(UI.Color("accent"))
            self.selBar:SetShown(selected)
            self.hl:SetColorTexture(UI.Color("accent", 0.16)); self.hl:SetShown(selected)
        else -- addon
            self.label:SetFontObject(selected and UI.fonts.accent or UI.fonts.body)
            self.selBar:SetColorTexture(UI.Color("accent"))
            self.selBar:SetShown(selected)
            self.hl:SetColorTexture(UI.Color("accent", 0.16)); self.hl:SetShown(selected)
        end
    end
    return b
end

-- ── Sidebar rebuild ────────────────────────────────────────────────────────────
function Core:RebuildNav()
    local win = self.window
    if not win then return end
    self._navButtons = self._navButtons or {}
    for _, b in ipairs(self._navButtons) do b:Hide() end

    local idx, y = 0, 0
    local function nextButton()
        idx = idx + 1
        local b = self._navButtons[idx]
        if not b then b = MakeNavButton(win.sidebar); self._navButtons[idx] = b end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", win.sidebar, "TOPLEFT", 0, -y)
        b:SetPoint("TOPRIGHT", win.sidebar, "TOPRIGHT", 0, -y)
        b:Show()
        return b
    end

    local function addGroup(text)
        if idx > 0 then y = y + 8 end
        local b = nextButton()
        b:SetHeight(18)
        b.icon:Hide()
        b.label:ClearAllPoints()
        b.label:SetPoint("LEFT", b, "LEFT", 10, 0)
        b.label:SetText(text:upper())
        b:Style("group", false)
        b:SetScript("OnClick", nil)
        b:EnableMouse(false)
        y = y + 18 + 2
    end

    local function addEntry(def, kind, addonId, sectionId)
        local b = nextButton()
        b:SetHeight(24)
        b:EnableMouse(true)
        local indent = (kind == "section") and 26 or 10
        if kind == "addon" and def.icon then
            b.icon:SetTexture(def.icon)
            b.icon:ClearAllPoints()
            b.icon:SetPoint("LEFT", b, "LEFT", 8, 0)
            b.icon:Show()
            indent = 30
        else
            b.icon:Hide()
        end
        b.label:ClearAllPoints()
        b.label:SetPoint("LEFT", b, "LEFT", indent, 0)
        b.label:SetPoint("RIGHT", b, "RIGHT", -6, 0)
        b.label:SetText(def.title or def.id or "")
        local selected = (kind == "section")
            and (self._currentAddon == addonId and self._currentSection == sectionId)
            or  (kind == "addon" and self._currentAddon == addonId)
        b:Style(kind, selected)
        b:SetScript("OnClick", function() Core:ShowAddon(addonId, sectionId) end)
        y = y + 24
    end

    -- SUITE group (registration order)
    if #self.regOrder > 0 then addGroup("Suite") end
    for _, id in ipairs(self.regOrder) do
        local def = self.sections[id]
        if def then
            addEntry(def, "addon", id, nil)
            -- Sections indent under the ACTIVE addon only.
            if self._currentAddon == id and #(def.sections or {}) > 1 then
                for _, s in ipairs(def.sections) do
                    addEntry({ title = s.title or s.id }, "section", id, s.id)
                end
            end
        end
    end

    -- CORE group
    if #self.coreOrder > 0 then addGroup("Core") end
    for _, id in ipairs(self.coreOrder) do
        local def = self.sections[id]
        if def then addEntry(def, "addon", id, nil) end
    end
end

-- ── Content: build a section's pane lazily ────────────────────────────────────
local function BuildSectionPane(section, content)
    if section.legacy then
        local pane = UI.CreateLegacyPane(content)
        section._pane = pane
        section._legacyPane = true
        if section.build then
            section.build(pane.child)
        elseif section.options then
            Core.BuildMenu(pane.child, section.options(), 16, 16)
        end
        pane:FinalizeLegacy()
    else
        local pane = UI.CreatePane(content)
        section._pane = pane
        if section.build then section.build(pane.flow) end
        pane:Layout()
    end
    return section._pane
end

-- ── Show a given addon + section ──────────────────────────────────────────────
function Core:ShowAddon(addonId, sectionId)
    self:EnsureHub()
    local addon = self.sections[addonId]
    if not addon then return end

    sectionId = sectionId or LastSectionFor(addonId)
    local section = self:GetAddonSection(addonId, sectionId)
    if not section then return end

    -- Hide every built pane across all addons/pages.
    for _, a in pairs(self.sections) do
        for _, s in ipairs(a.sections or {}) do
            if s._pane then s._pane:Hide() end
        end
    end

    if not section._pane then BuildSectionPane(section, self.window.content) end
    if not section._built then
        section._built = true
    end

    section._pane:Show()
    if not section._legacyPane and section._pane.Layout then section._pane:Layout() end
    if section.refresh then section.refresh(section._pane.child) end

    self._currentAddon   = addonId
    self._currentSection = section.id
    if self.db then
        self.db.lastAddon   = addonId
        self.db.lastSection = addonId  -- legacy mirror
    end
    SetLastSection(addonId, section.id)

    local win = self.window
    win.headerCrumb:SetText((addon.title or addonId)
        .. ((#(addon.sections or {}) > 1) and ("  ›  " .. (section.title or section.id)) or ""))

    self:RebuildNav()
end

-- Back-compat alias (older callers used ShowSection(addonId)).
function Core:ShowSection(id) self:ShowAddon(id) end

-- ── Appearance (Core-owned theme picker page) ─────────────────────────────────
local function BuildAppearance(flow)
    local appear = flow:AddSection("Appearance")
    appear:Hint("Choose a color theme for the entire Daseeki suite. Changes apply live.")

    local row = appear:AddRow()
    row:Dropdown({
        label   = "Theme",
        width   = 220,
        choices = UI.GetThemeNames(),
        get     = function() return UI.GetThemeName() end,
        set     = function(v) UI.SetTheme(v) end,
    })

    appear:AddSeparator()
    appear:Hint("Active palette")

    -- Live swatch strip — re-colors itself on theme change.
    local swatchRow = appear:AddRow()
    local names = { "ground", "panel", "raised", "accent", "text", "muted", "ok", "danger" }
    local strip = CreateFrame("Frame", nil, swatchRow)
    strip.uiHeight = 30
    strip._fillWidth = true
    local cells = {}
    for i, tok in ipairs(names) do
        local c = UI.FlatFrame(strip, "border", "borderLite")
        c:SetSize(30, 30)
        c:SetPoint("LEFT", strip, "LEFT", (i - 1) * 36, 0)
        local fill = c:CreateTexture(nil, "ARTWORK")
        local fi = 2   -- swatch fill inset
        fill:SetPoint("TOPLEFT", c, "TOPLEFT", fi, -fi)
        fill:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -fi, fi)
        c._tok = tok
        UI.Skin(fill, function(self) self:SetColorTexture(UI.Color(tok)) end)
        cells[i] = c
    end
    swatchRow._items[#swatchRow._items + 1] = { w = strip }
end

-- ── Window creation ───────────────────────────────────────────────────────────
function Core:EnsureHub()
    if self.window then return self.window end

    local win = CreateFrame("Frame", "DaseekiSuiteHub", UIParent, "BackdropTemplate")
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:SetResizable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    if win.SetResizeBounds then win:SetResizeBounds(MIN_W, MIN_H) end
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("ground"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)

    tinsert(UISpecialFrames, "DaseekiSuiteHub")

    -- Title bar (drag to move).
    local titleBar = CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLE_H)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() win:StopMovingOrSizing(); SaveGeometry(win) end)
    local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
    local bi = 1   -- 1px border inset so the bar bg sits inside the window frame
    tbBg:SetPoint("TOPLEFT", titleBar, "TOPLEFT", bi, -bi)
    tbBg:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -bi, 0)
    UI.Skin(tbBg, function(self) self:SetColorTexture(UI.Color("panel")) end)

    local gem = titleBar:CreateTexture(nil, "ARTWORK")
    gem:SetSize(18, 18)
    gem:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    gem:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    gem:SetTexture(GEM_ICON)
    if not gem:GetTexture() then gem:SetTexture(GEM_FALLBACK) end

    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.header)
    title:SetPoint("LEFT", gem, "RIGHT", 8, 0)
    title:SetText("Daseeki Suite")

    local ver = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
    local verFS = titleBar:CreateFontString(nil, "OVERLAY")
    verFS:SetFontObject(UI.fonts.small)
    local verBaseline = -1   -- nudge version string to the title baseline
    verFS:SetPoint("LEFT", title, "RIGHT", 8, verBaseline)
    verFS:SetText(ver and ("v" .. ver) or "")

    -- Breadcrumb (active addon › section), right side of the title bar.
    local crumb = titleBar:CreateFontString(nil, "OVERLAY")
    crumb:SetFontObject(UI.fonts.muted)
    crumb:SetPoint("RIGHT", titleBar, "RIGHT", -34, 0)
    crumb:SetJustifyH("RIGHT")
    win.headerCrumb = crumb

    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY")
    cx:SetFontObject(UI.fonts.body)
    cx:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
    cx:SetText("X")
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body) end)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    -- Hairline under the title bar.
    local titleRule = win:CreateTexture(nil, "ARTWORK")
    titleRule:SetHeight(1)
    titleRule:SetPoint("TOPLEFT", win, "TOPLEFT", 1, -TITLE_H)
    titleRule:SetPoint("TOPRIGHT", win, "TOPRIGHT", -1, -TITLE_H)
    UI.Skin(titleRule, function(self) self:SetColorTexture(UI.Color("borderLite")) end)

    -- Sidebar.
    local sidebarBox = UI.FlatFrame(win, "inset", "border")
    sidebarBox:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, -(TITLE_H + PAD))
    sidebarBox:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", PAD, PAD)
    sidebarBox:SetWidth(SIDEBAR_W)
    win.sidebarBox = sidebarBox

    local sidebar = CreateFrame("Frame", nil, sidebarBox)
    local sx, sy = 6, 8   -- sidebar inner padding
    sidebar:SetPoint("TOPLEFT", sidebarBox, "TOPLEFT", sx, -sy)
    sidebar:SetPoint("BOTTOMRIGHT", sidebarBox, "BOTTOMRIGHT", -sx, sy)
    win.sidebar = sidebar

    -- Content host (right of the sidebar).
    local content = CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT", sidebarBox, "TOPRIGHT", PAD, 0)
    content:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD, PAD)
    win.content = content

    -- Corner resize grip.
    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -2, 2)
    for i = 1, 3 do
        local ln = grip:CreateTexture(nil, "OVERLAY")
        ln:SetSize(2, 2 + (i - 1) * 4)
        ln:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -(i - 1) * 4, 2)
        UI.Skin(ln, function(self) self:SetColorTexture(UI.Color("borderLite")) end)
    end
    grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp",   function() win:StopMovingOrSizing(); SaveGeometry(win); Core:RelayoutCurrent() end)

    win:SetScript("OnSizeChanged", function() Core:RelayoutCurrent() end)
    win:SetScript("OnShow", function(self) Core:RelayoutCurrent() end)

    self.window = win
    RestoreGeometry(win)

    -- Register the Core-owned Appearance page (idempotent).
    if not self.sections["__appearance"] then
        self:RegisterCorePage({
            id = "__appearance", title = "Appearance",
            sections = { { id = "_main", title = "Appearance", build = BuildAppearance, legacy = false } },
        })
    end

    self:RebuildNav()

    -- Default selection: last addon, else first registered addon, else Appearance.
    local startId = self.db and self.db.lastAddon
    if not (startId and self.sections[startId]) then
        startId = self.regOrder[1] or self.coreOrder[1]
    end
    if startId then self:ShowAddon(startId) end

    return win
end

-- Relayout the currently visible flow pane (called on resize / show).
function Core:RelayoutCurrent()
    local addon = self._currentAddon and self.sections[self._currentAddon]
    if not addon then return end
    local section = self:GetAddonSection(self._currentAddon, self._currentSection)
    if section and section._pane and not section._legacyPane and section._pane.Layout then
        section._pane:Layout()
    end
end
