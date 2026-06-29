--[[
    Daseeki Core — the combined options window.
    Layout (ShadowNetwork-style): thin header ("Daseeki WoW Addon Suite") +
    a TOP horizontal tab row of addons (icon + title) + a SECONDARY horizontal tab
    row of that addon's sections (shown only when an addon declares >1 section) +
    a full-width content area that hosts each (addon, section) panel (built lazily).
--]]

local _, Core = ...

local WIN_W, WIN_H = 910, 712
local HEADER_H     = 30
local TABROW_Y     = HEADER_H + 8          -- top (addon) tab row top
local TABROW_H     = 28
local SUBROW_H     = 24
local PAD_X        = 12

-- ── Window position persistence ───────────────────────────────────────────────
local function SavePosition(win)
    local point, _, relPoint, x, y = win:GetPoint()
    local db = Core.db
    if not db then return end
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function RestorePosition(win)
    local db = Core.db or {}
    win:ClearAllPoints()
    win:SetPoint(db.point or "CENTER", UIParent, db.relPoint or "CENTER", db.x or 0, db.y or 0)
end

-- ── Section / last-selection persistence helpers ──────────────────────────────
local function LastSectionFor(addonId)
    local db = Core.db
    return db and db.lastSectionByAddon and db.lastSectionByAddon[addonId]
end
local function SetLastSection(addonId, sectionId)
    local db = Core.db; if not db then return end
    db.lastSectionByAddon = db.lastSectionByAddon or {}
    db.lastSectionByAddon[addonId] = sectionId
end

-- ── Top addon tab row ─────────────────────────────────────────────────────────
function Core:RebuildNav()
    local win = self.window
    if not win then return end
    self._addonTabs = self._addonTabs or {}
    local addons = self:GetSectionsSorted()

    for _, b in ipairs(self._addonTabs) do b:Hide() end

    local x = PAD_X
    for i, addon in ipairs(addons) do
        local b = self._addonTabs[i]
        if not b then
            b = Core.MakeTabButton(win.tabRow, { icon = addon.icon, text = addon.title })
            self._addonTabs[i] = b
        end
        -- Re-apply icon/text in case the addon set re-registered.
        if b.icon then
            if addon.icon then b.icon:SetTexture(addon.icon); b.icon:Show() else b.icon:Hide() end
        end
        b.label:SetText(addon.title)
        b:SetWidth(math.max(70, (b.icon and 30 or 10) + (b.label:GetStringWidth() or 40) + 12))
        b._addonId = addon.id
        b:SetScript("OnClick", function(self2) Core:ShowAddon(self2._addonId) end)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", win.tabRow, "TOPLEFT", x, 0)
        b:Show()
        x = x + b:GetWidth() + 6
    end

    self:HighlightNav(self._currentAddon)
end

function Core:HighlightNav(id)
    if self._addonTabs then
        for _, b in ipairs(self._addonTabs) do b:SetSelected(b._addonId == id) end
    end
end

-- ── Secondary section tab row (rebuilt per selected addon) ─────────────────────
function Core:RebuildSectionTabs(addonId)
    local win = self.window
    if not win then return end
    self._sectionTabs = self._sectionTabs or {}
    for _, b in ipairs(self._sectionTabs) do b:Hide() end

    local secs = self:GetAddonSections(addonId)
    local multi = #secs > 1
    win.subRow:SetShown(multi)

    if multi then
        local x = PAD_X
        for i, sec in ipairs(secs) do
            local b = self._sectionTabs[i]
            if not b then
                b = Core.MakeTabButton(win.subRow, {})
                self._sectionTabs[i] = b
            end
            b.label:SetText(sec.title or sec.id)
            b:SetWidth(math.max(48, 10 + (b.label:GetStringWidth() or 40) + 12))
            b._addonId, b._sectionId = addonId, sec.id
            b:SetScript("OnClick", function(self2) Core:ShowAddon(self2._addonId, self2._sectionId) end)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", win.subRow, "TOPLEFT", x, 0)
            b:Show()
            x = x + b:GetWidth() + 6
        end
    end

    -- Reposition the content area to sit below whichever rows are visible.
    win.content:ClearAllPoints()
    local top = TABROW_Y + TABROW_H + (multi and (SUBROW_H + 4) or 4)
    win.content:SetPoint("TOPLEFT",     win, "TOPLEFT",     PAD_X, -top)
    win.content:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD_X, PAD_X)

    self:HighlightSectionTabs(self._currentSection)
end

function Core:HighlightSectionTabs(sectionId)
    if self._sectionTabs then
        for _, b in ipairs(self._sectionTabs) do b:SetSelected(b._sectionId == sectionId) end
    end
end

-- ── Section content ───────────────────────────────────────────────────────────
local function BuildSectionPanel(section, content)
    local panel = CreateFrame("Frame", nil, content)
    panel:SetAllPoints(content)
    panel:Hide()
    section.frame = panel
    return panel
end

-- Show a given addon + section. sectionId nil -> last used (else first).
function Core:ShowAddon(addonId, sectionId)
    self:EnsureHub()
    local addon = self.sections[addonId]
    if not addon then return end

    sectionId = sectionId or LastSectionFor(addonId)
    local section = self:GetAddonSection(addonId, sectionId)
    if not section then return end

    -- Hide all built section panels across all addons.
    for _, a in pairs(self.sections) do
        for _, s in ipairs(a.sections or {}) do
            if s.frame then s.frame:Hide() end
        end
    end

    if not section.frame then
        BuildSectionPanel(section, self.window.content)
    end
    if not section._built then
        section._built = true
        if section.build then
            section.build(section.frame)
        elseif section.options then
            Core.BuildMenu(section.frame, section.options(), 16, 16)
        end
    end

    section.frame:Show()
    if section.refresh then section.refresh(section.frame) end

    self._currentAddon   = addonId
    self._currentSection = section.id
    if self.db then
        self.db.lastAddon = addonId
        self.db.lastSection = addonId   -- legacy mirror
    end
    SetLastSection(addonId, section.id)

    self:HighlightNav(addonId)
    self:RebuildSectionTabs(addonId)
end

-- Back-compat alias (older callers used ShowSection(addonId)).
function Core:ShowSection(id) self:ShowAddon(id) end

-- ── Window creation ───────────────────────────────────────────────────────────
function Core:EnsureHub()
    if self.window then return self.window end

    local win = CreateFrame("Frame", "DaseekiSuiteHub", UIParent, "BackdropTemplate")
    win:SetSize(WIN_W, WIN_H)
    win:SetFrameStrata("HIGH")
    win:SetMovable(true); win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:Hide()

    -- Close on Escape (Blizzard's UISpecialFrames system handles this by frame name).
    tinsert(UISpecialFrames, "DaseekiSuiteHub")
    win:SetScript("OnMouseDown", function(self2, b) if b == "LeftButton" then self2:StartMoving() end end)
    win:SetScript("OnMouseUp",   function(self2) self2:StopMovingOrSizing(); SavePosition(self2) end)
    win:SetScript("OnShow",      function(self2) Core.ApplySkin(self2) end)

    -- Header
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", win, "TOP", 0, -8)
    title:SetText("Daseeki WoW Addon Suite"); title:SetTextColor(1, 0.82, 0)

    local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    Core.MakeSeparator(win, 10, HEADER_H, nil, 10)

    -- Top addon tab row
    local tabRow = CreateFrame("Frame", nil, win)
    tabRow:SetPoint("TOPLEFT",  win, "TOPLEFT",  0, -TABROW_Y)
    tabRow:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -TABROW_Y)
    tabRow:SetHeight(TABROW_H)
    win.tabRow = tabRow

    -- Separator under the top tab row
    Core.MakeSeparator(win, 10, TABROW_Y + TABROW_H + 1, nil, 10)

    -- Secondary section tab row (shown only for multi-section addons)
    local subRow = CreateFrame("Frame", nil, win)
    subRow:SetPoint("TOPLEFT",  win, "TOPLEFT",  0, -(TABROW_Y + TABROW_H + 4))
    subRow:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -(TABROW_Y + TABROW_H + 4))
    subRow:SetHeight(SUBROW_H)
    subRow:Hide()
    win.subRow = subRow

    -- Content area (each section's panel SetAllPoints(this); repositioned in RebuildSectionTabs)
    local content = CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT",     win, "TOPLEFT",     PAD_X, -(TABROW_Y + TABROW_H + 4))
    content:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD_X, PAD_X)
    win.content = content

    self.window = win
    RestorePosition(win)
    self:RebuildNav()

    -- Default selection
    local startId = (self.db and (self.db.lastAddon or self.db.lastSection))
    if not (startId and self.sections[startId]) then
        local first = self:GetSectionsSorted()[1]
        startId = first and first.id
    end
    if startId then self:ShowAddon(startId) end

    return win
end
