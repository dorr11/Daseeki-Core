--[[
    Daseeki Core — reusable UI widgets.
    Extracted from Daseeki-Buff-Tracker/options.lua and generalized to hold no
    addon state (every helper takes an explicit `parent`). Exposed on the Core
    table AND on DaseekiSuite so feature addons can build sections with them.

    Helpers:
        Core.MakeSlider(parent, x, y, w, labelText, minV, maxV, step, getter, setter, fmtFn)
        Core.MakeLabel(parent, text, size, x, y)
        Core.MakeSectionHeader(parent, text, x, y, w)
        Core.MakeButton(parent, text, x, y, w, h, fn)
        Core.MakeEditBox(parent, x, y, w)
        Core.MakeCheckbox(parent, text, x, y, getter, setter)
        Core.MakeSimpleDropdown(parent, x, y, w, choices, onChange)  -- :GetValue()/:SetValue(v)
        Core.MakeSeparator(parent, x, y, w, rightOffset)
        Core.MakeTableHeader(parent, text, w, px, py)
        Core.AttachSearchDropdown(eb, dropW, getResults, displayField, valueField, onSelect, iconGetter)
        Core.BuildMenu(parent, optionsTable, x, y)  -- declarative builder
--]]

local _, Core = ...

-- DaseekiUI is created by theme.lua (loaded earlier). UI.FLAT_BACKDROP / UI.Skin are
-- added by daseekiui.lua, which loads AFTER this file — so they are referenced only at
-- runtime inside the factories (never at file scope). The token dress here retires the
-- legacy Blizzard tooltip-art backdrop + hardcoded Blizzard-blue/gray (BRAND_SPEC §11).
local UI = DaseekiUI

-- ── Slider ────────────────────────────────────────────────────────────────────
local _sliderSeq = 0
function Core.MakeSlider(parent, x, y, w, labelText, minV, maxV, step, getter, setter, fmtFn)
    _sliderSeq = _sliderSeq + 1
    if labelText then
        local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetText(labelText)
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -(y - 14))
    end
    local s = CreateFrame("Slider", "DaseekiCoreSlider" .. _sliderSeq, parent)
    s:SetSize(w, 16)
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetOrientation("HORIZONTAL")
    s:SetObeyStepOnDrag(true)
    local bg = s:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
    bg:SetPoint("LEFT",  s, "LEFT",  3, 0)
    bg:SetPoint("RIGHT", s, "RIGHT", -3, 0)
    bg:SetHeight(8); bg:SetTexCoord(0, 1, 0.333, 0.666)
    local edgeL = s:CreateTexture(nil, "BACKGROUND")
    edgeL:SetTexture("Interface\\Buttons\\UI-SliderBar-Border")
    edgeL:SetSize(4, 16); edgeL:SetPoint("RIGHT", bg, "LEFT", 0, 0)
    edgeL:SetTexCoord(0, 0.125, 0, 1)
    local edgeR = s:CreateTexture(nil, "BACKGROUND")
    edgeR:SetTexture("Interface\\Buttons\\UI-SliderBar-Border")
    edgeR:SetSize(4, 16); edgeR:SetPoint("LEFT", bg, "RIGHT", 0, 0)
    edgeR:SetTexCoord(0.875, 1, 0, 1)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local mn = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mn:SetPoint("RIGHT", s, "LEFT", -4, 0); mn:SetText(tostring(minV))
    local mx = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mx:SetPoint("LEFT", s, "RIGHT", 4, 0); mx:SetText(tostring(maxV))
    local valLbl = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    valLbl:SetPoint("BOTTOM", s, "TOP", 0, 2)
    s._valLbl = valLbl
    local function snap(v)
        local snapped = minV + math.floor((v - minV) / step + 0.5) * step
        return math.max(minV, math.min(maxV, snapped))
    end
    s:SetScript("OnShow", function(self)
        local v = snap(getter())
        self:SetValue(v)
        self._valLbl:SetText(fmtFn and fmtFn(v) or tostring(v))
    end)
    s:SetScript("OnValueChanged", function(self, v)
        v = snap(v)
        self._valLbl:SetText(fmtFn and fmtFn(v) or tostring(v))
        setter(v)
    end)
    return s
end

-- ── Label ─────────────────────────────────────────────────────────────────────
function Core.MakeLabel(parent, text, size, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if size then fs:SetFont(fs:GetFont(), size) end
    fs:SetText(text); fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    return fs
end

-- ── Section header (line + bold title) ────────────────────────────────────────
function Core.MakeSectionHeader(parent, text, x, y, w)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1); line:SetColorTexture(0.4, 0.4, 0.4, 0.7)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y); line:SetWidth(w or 200)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -(y + 6))
    lbl:SetText(text); lbl:SetTextColor(1, 1, 1, 1)
    return lbl
end

-- ── Button ────────────────────────────────────────────────────────────────────
function Core.MakeButton(parent, text, x, y, w, h, fn)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w or 90, h or 22); btn:SetText(text)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    btn:SetScript("OnClick", fn)
    return btn
end

-- ── EditBox ───────────────────────────────────────────────────────────────────
function Core.MakeEditBox(parent, x, y, w)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(w, 20); eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal)
    return eb
end

-- ── Checkbox ──────────────────────────────────────────────────────────────────
function Core.MakeCheckbox(parent, text, x, y, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y); cb:SetSize(24, 24)
    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0); lbl:SetText(text)
    cb:SetScript("OnShow",  function(self) self:SetChecked(getter()) end)
    cb:SetScript("OnClick", function(self) setter(self:GetChecked()) end)
    return cb
end

-- ── Simple fixed-set dropdown (button with :GetValue()/:SetValue(v)) ──────────
function Core.MakeSimpleDropdown(parent, x, y, w, choices, onChange)
    local current = choices[1]
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w, 22)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)

    function btn:GetValue() return current end
    function btn:SetValue(v)
        current = v
        btn:SetText((v or choices[1]) .. " v")
    end
    btn:SetValue(choices[1])

    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetFrameStrata("TOOLTIP")
    popup:SetWidth(w)
    UI.Skin(popup, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("panel"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)
    popup:SetHeight(#choices * 22 + 8)
    popup:Hide()

    for i, choice in ipairs(choices) do
        local row = CreateFrame("Button", nil, popup)
        row:SetSize(w - 6, 20)
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", 3, -(i - 1) * 22 - 4)
        local rbg = row:CreateTexture(nil, "BACKGROUND"); rbg:SetAllPoints()
        rbg:Hide()
        local rlbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rlbl:SetPoint("LEFT", row, "LEFT", 6, 0); rlbl:SetText(choice)
        row:SetScript("OnEnter", function() rbg:SetColorTexture(UI.Color("accent", 0.28)); rbg:Show() end)
        row:SetScript("OnLeave", function() rbg:Hide() end)
        row:SetScript("OnClick", function()
            btn:SetValue(choice)
            popup:Hide()
            if onChange then onChange(choice) end
        end)
    end

    btn:SetScript("OnClick", function()
        if popup:IsShown() then popup:Hide()
        else
            popup:ClearAllPoints()
            popup:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            popup:Show()
        end
    end)
    popup:SetScript("OnUpdate", function()
        if not btn:IsShown() then popup:Hide() end
    end)

    return btn
end

-- ── Separator (omit w to stretch to parent right edge) ────────────────────────
function Core.MakeSeparator(parent, x, y, w, rightOffset)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    tex:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    if w then
        tex:SetSize(w, 1)
    else
        tex:SetHeight(1)
        tex:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(rightOffset or x), -y)
    end
    return tex
end

-- ── Table column header ───────────────────────────────────────────────────────
function Core.MakeTableHeader(parent, text, w, px, py)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local f, _, fl = h:GetFont(); h:SetFont(f, 13, fl)
    h:SetTextColor(1, 1, 1, 1)
    h:SetText(text); h:SetWidth(w); h:SetJustifyH("LEFT")
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", px, -py)
    return h
end

-- (Core.MakeTabButton removed — BRAND_SPEC §11. It was the last SN-gold {1,0.82,0}
-- literal in the legacy path and had ZERO consumers across all suite addons; the hub's
-- own MakeNavButton (hub.lua, token-driven, brand spine) is the only tab surface.)

-- ── Live-search autocomplete dropdown attached to an EditBox ──────────────────
-- getResults(query) -> array of tables; displayField shown in rows; valueField
-- placed in the editbox on select; onSelect(item) for side-effects; iconGetter
-- optional (adds a 16px icon per row).
function Core.AttachSearchDropdown(eb, dropW, getResults, displayField, valueField, onSelect, iconGetter)
    local ROW_H = iconGetter and 22 or 20
    local LBL_X = iconGetter and 24 or 6

    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetFrameStrata("TOOLTIP")
    popup:SetWidth(dropW)
    UI.Skin(popup, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("panel"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)
    popup:Hide()
    popup._rows = {}

    local function HidePopup() popup:Hide() end

    local function UpdatePopup()
        local query = eb:GetText()
        local results = getResults(query)
        for _, r in ipairs(popup._rows) do r:Hide() end
        local shown = 0
        for i, item in ipairs(results) do
            if i > 9 then break end
            shown = shown + 1
            local row = popup._rows[i]
            if not row then
                row = CreateFrame("Button", nil, popup)
                row:SetHeight(ROW_H)
                row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints()
                row.bg:Hide()
                if iconGetter then
                    row.icon = row:CreateTexture(nil, "ARTWORK")
                    row.icon:SetSize(16, 16)
                    row.icon:SetPoint("LEFT", row, "LEFT", 3, 0)
                    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                end
                row.lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.lbl:SetPoint("LEFT", row, "LEFT", LBL_X, 0)
                row.lbl:SetWidth(dropW - LBL_X - 10); row.lbl:SetJustifyH("LEFT")
                row:SetScript("OnEnter", function(s) s.bg:SetColorTexture(UI.Color("accent", 0.28)); s.bg:Show() end)
                row:SetScript("OnLeave", function(s) s.bg:Hide() end)
                popup._rows[i] = row
            end
            row:ClearAllPoints()
            row:SetWidth(dropW - 6)
            row:SetPoint("TOPLEFT", popup, "TOPLEFT", 3, -(i - 1) * ROW_H - 4)
            row.lbl:SetText(item[displayField] or "")
            if row.icon and iconGetter then
                row.icon:SetTexture(iconGetter(item) or "Interface\\Icons\\INV_Misc_QuestionMark")
            end
            row._data = item
            row:SetScript("OnClick", function(s)
                local d = s._data
                eb:SetText(d[valueField] or "")
                if onSelect then onSelect(d) end
                HidePopup()
            end)
            row:Show()
        end
        if shown > 0 then
            popup:SetHeight(shown * ROW_H + 8)
            popup:ClearAllPoints()
            popup:SetPoint("TOPLEFT", eb, "BOTTOMLEFT", 0, -2)
            popup:Show()
        else
            HidePopup()
        end
    end

    popup:SetScript("OnUpdate", function()
        if not eb:IsShown() then HidePopup() end
    end)

    eb:SetScript("OnTextChanged",     function(self, userInput) if userInput then UpdatePopup() end end)
    eb:SetScript("OnEditFocusGained", UpdatePopup)
    eb:SetScript("OnEditFocusLost",   function() C_Timer.After(0.15, HidePopup) end)
    eb:SetScript("OnEscapePressed",   function(self) self:ClearFocus(); HidePopup() end)
    eb:SetScript("OnEnterPressed",    function(self) self:ClearFocus(); HidePopup() end)

    return popup
end

-- ── Declarative menu builder (Details!-style) ─────────────────────────────────
-- Auto-builds a simple vertical options list from a table of entries:
--   {type="label",     name="Heading"}
--   {type="toggle",    name=, desc=, get=function() end, set=function(v) end}
--   {type="range",     name=, min=, max=, step=, get=, set=, fmt=function(v) end}
--   {type="select",    name=, choices={"A","B"}, get=, set=}
--   {type="execute",   name=, func=function() end}
--   {type="textentry", name=, width=, get=, set=}
--   {type="blank"}
-- Returns the total height consumed (so callers can size scroll children).
function Core.BuildMenu(parent, options, x, y)
    x = x or 16
    local cy = y or 16
    local LABEL_W = 150
    for _, opt in ipairs(options) do
        local t = opt.type
        if t == "label" then
            Core.MakeSectionHeader(parent, opt.name or "", x, cy, opt.width or 260)
            cy = cy + 30
        elseif t == "blank" then
            cy = cy + (opt.height or 14)
        elseif t == "toggle" then
            Core.MakeCheckbox(parent, opt.name or "", x, cy, opt.get, opt.set)
            cy = cy + 28
        elseif t == "range" then
            Core.MakeSlider(parent, x + 6, cy + 16, opt.width or 180, opt.name,
                opt.min or 0, opt.max or 1, opt.step or 0.1, opt.get, opt.set, opt.fmt)
            cy = cy + 44
        elseif t == "select" then
            Core.MakeLabel(parent, opt.name or "", nil, x, cy + 4)
            local dd = Core.MakeSimpleDropdown(parent, x + LABEL_W, cy, opt.width or 110,
                opt.choices or {}, function(v) if opt.set then opt.set(v) end end)
            if opt.get then dd:SetValue(opt.get()) end
            cy = cy + 28
        elseif t == "execute" then
            Core.MakeButton(parent, opt.name or "", x, cy, opt.width or 140, 22, opt.func)
            cy = cy + 28
        elseif t == "textentry" then
            Core.MakeLabel(parent, opt.name or "", nil, x, cy + 4)
            local eb = Core.MakeEditBox(parent, x + LABEL_W, cy, opt.width or 180)
            if opt.get then eb:SetText(opt.get() or "") end
            eb:SetScript("OnEnterPressed", function(self)
                if opt.set then opt.set(self:GetText()) end
                self:ClearFocus()
            end)
            cy = cy + 28
        end
    end
    return cy
end

-- Mirror everything onto the public global so feature addons can call them.
Core.Widgets = Core
