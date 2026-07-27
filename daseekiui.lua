--[[
    Daseeki Core — DaseekiUI layout engine + widget set (v1).

    Structurally immune to the two audited defect classes:
      * Every content pane is a ScrollFrame with SetClipsChildren(true) — nothing can
        render outside the window; tall content scrolls.
      * There are NO caller-supplied y-offsets. Vertical position is a running cursor
        computed from measured element heights + theme rowGap / sectionGap.

    Flow API (the object passed to a new-style section's build(flow)):
        flow:AddSection(title)      -> section  (serif header + hairline; returns a flow
                                                  scoped to indent rows beneath it)
        flow:AddRow()               -> row      (widgets append left-to-right)
        flow:AddChecklist(items)    -> lays a 2-col checkbox grid (collapses to 1 col
                                       when the pane is narrow — resize-safe)
        flow:AddSeparator()         -> hairline rule
        flow:Label(text[, opts])    -> Label + optional Hint
        flow:Hint(text)
        -- widget constructors also usable inline on a row (row:Checkbox{...} etc.):
        Checkbox, Slider, Dropdown, EditBox, Button, SegmentedChoice, List, EditorCard

    Widget constructor opts are documented at each factory. Every visual reads theme
    tokens at render and re-skins on ThemeChanged.

    Public helpers used by the hub + wave-2/3 addons:
        DaseekiUI.CreatePane(parent)        -> flow pane (scroll + clip) for new sections
        DaseekiUI.CreateLegacyPane(parent)  -> scroll + clip wrapper for legacy build(panel)
        DaseekiUI.Confirm(opts)             -> token-skinned confirm modal
        DaseekiUI.FlatFrame(parent, bg, brd)
        DaseekiUI.Skin(obj, fn)             -> run fn now + on every ThemeChanged
--]]

local ADDON, Core = ...
local UI = DaseekiUI

-- ── Metrics ───────────────────────────────────────────────────────────────────
local PANE_PAD   = 14   -- inner padding of a content pane
local ITEM_GAP   = 8    -- horizontal gap between widgets in a row
local BAR_W      = 10   -- scrollbar gutter width
local INDENT     = 8    -- section content indent
local LABEL_GAP  = 4    -- gap between a control label and its control

local function rowGap()     return UI.Token("rowGap")     or 10 end
local function sectionGap() return UI.Token("sectionGap") or 22 end

-- Flat 1px-border backdrop, colored entirely from tokens (no Blizzard art tint).
local FLAT_BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
}
-- Export immediately (Bug 2): consumers (e.g. Armory's icon button) reference
-- UI.FLAT_BACKDROP; exporting at definition removes any load-order fragility.
UI.FLAT_BACKDROP = FLAT_BACKDROP

-- ── Re-skin registry ──────────────────────────────────────────────────────────
-- Run fn now and again on every ThemeChanged. Widgets are long-lived (panes build
-- lazily once and are reused), so the callback set stays bounded.
function UI.Skin(obj, fn)
    fn(obj)
    UI.OnThemeChanged(function()
        if obj and not obj.__dead then fn(obj) end
    end)
    return obj
end

-- A flat token-colored frame (BackdropTemplate) — panels, cards, inputs.
function UI.FlatFrame(parent, bgToken, borderToken)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    UI.Skin(f, function(self)
        self:SetBackdrop(FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color(bgToken or "panel"))
        self:SetBackdropBorderColor(UI.Color(borderToken or "border"))
    end)
    return f
end

-- Anchor helpers — all offsets pass through here so computed (never literal) values
-- reach SetPoint, keeping the layout free of magic y-offsets.
local function anchorTL(child, parent, x, y)
    child:ClearAllPoints()
    child:SetPoint("TOPLEFT", parent, "TOPLEFT", x or 0, y or 0)
end

-- A themed FontString using one of the shared re-tinted FontObjects.
local function fontString(parent, fontKey)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(UI.fonts[fontKey] or UI.fonts.body)
    return fs
end

-- ════════════════════════════════════════════════════════════════════════════
--  WIDGET SET (v1)
--  Every factory returns a frame carrying .uiHeight and .uiWidth so the flow
--  engine can measure it without querying live geometry mid-build.
-- ════════════════════════════════════════════════════════════════════════════

-- 1 ── Checkbox ────────────────────────────────────────────────────────────────
-- opts = { label=, get=function()->bool, set=function(bool), tooltip= }
function UI.MakeCheckbox(parent, opts)
    opts = opts or {}
    local BOX = 18
    local cb = CreateFrame("Button", nil, parent)
    cb:SetHeight(math.max(BOX, 20))

    local box = UI.FlatFrame(cb, "inset", "controlBorder")
    box:SetSize(BOX, BOX)
    box:SetPoint("LEFT", cb, "LEFT", 0, 0)

    local check = box:CreateTexture(nil, "ARTWORK")
    local ci = 3   -- check inset within the box
    check:SetPoint("TOPLEFT", box, "TOPLEFT", ci, -ci)
    check:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -ci, ci)
    check:SetColorTexture(1, 1, 1, 1)
    UI.Skin(check, function(self) self:SetColorTexture(UI.Color("accent")) end)

    local lbl = fontString(cb, "body")
    lbl:SetPoint("LEFT", box, "RIGHT", 6, 0)
    lbl:SetText(opts.label or "")

    cb._get, cb._set = opts.get, opts.set
    function cb:Refresh()
        local on = cb._get and cb._get()
        check:SetShown(on and true or false)
    end
    cb:SetScript("OnClick", function(self)
        local nv = not (self._get and self._get())
        if self._set then self._set(nv) end
        self:Refresh()
    end)
    cb:SetScript("OnShow", function(self) self:Refresh() end)
    if opts.tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(opts.label or "", UI.Color("text"))
            GameTooltip:AddLine(opts.tooltip, UI.Color("muted"))
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    cb:Refresh()

    lbl:SetWidth(0)
    cb.uiHeight = math.max(BOX, 20)
    cb.uiWidth  = BOX + 6 + (lbl:GetStringWidth() or 60) + 4
    -- Self-size the button's width. A checkbox placed by raw SetPoint (the
    -- AddChecklist grid does exactly this) otherwise stays width-0, and a zero-width
    -- frame inside the clipping ScrollChild has its box + label culled — the very
    -- invisible-widget class the row path already dodged by setting the width itself.
    -- Setting it here makes every checkbox render regardless of who places it.
    cb:SetWidth(cb.uiWidth)
    cb._label = lbl
    return cb
end

-- 2 ── Slider (with value readout) ─────────────────────────────────────────────
-- opts = { label=, min=, max=, step=, get=, set=, format=function(v)->str, width= }
function UI.MakeSlider(parent, opts)
    opts = opts or {}
    local width = opts.width or 200
    local minV, maxV = opts.min or 0, opts.max or 1
    local step = opts.step or 0.1
    local fmt  = opts.format or function(v) return tostring(v) end

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width, 44)

    local lbl = fontString(frame, "body")
    anchorTL(lbl, frame, 0, 0)
    lbl:SetText(opts.label or "")

    local val = fontString(frame, "accent")
    val:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    val:SetJustifyH("RIGHT")

    local trackY = -24
    local track = UI.FlatFrame(frame, "inset", "border")
    track:SetHeight(6)
    track:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, trackY)
    track:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, trackY)

    local slider = CreateFrame("Slider", nil, frame)
    slider:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, trackY)
    slider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, trackY)
    slider:SetHeight(16)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 16)
    slider:SetThumbTexture(thumb)
    UI.Skin(thumb, function(self) self:SetColorTexture(UI.Color("accent")) end)

    local function snap(v)
        local s = minV + math.floor((v - minV) / step + 0.5) * step
        return math.max(minV, math.min(maxV, s))
    end
    slider._set = opts.set
    slider:SetScript("OnValueChanged", function(self, v)
        v = snap(v)
        val:SetText(fmt(v))
        if self._set and not self._silent then self._set(v) end
    end)
    frame.Refresh = function()
        local v = snap(opts.get and opts.get() or minV)
        slider._silent = true
        slider:SetValue(v)
        slider._silent = false
        val:SetText(fmt(v))
    end
    frame:SetScript("OnShow", function() frame.Refresh() end)
    frame.Refresh()

    frame.uiHeight = 44
    frame.uiWidth  = width
    frame._fillWidth = true      -- stretch to available width in a row
    return frame
end

-- 3 ── Dropdown (owned popup at TOOLTIP strata, click-away close, NO OnUpdate) ──
-- opts = { label=, choices = { {value=, text=}, ... } OR { "A", "B" }, get=, set=, width= }
function UI.MakeDropdown(parent, opts)
    opts = opts or {}
    local width = opts.width or 180

    -- normalize choices to {value,text}
    local choices = {}
    for _, c in ipairs(opts.choices or {}) do
        if type(c) == "table" then choices[#choices + 1] = { value = c.value, text = c.text or tostring(c.value) }
        else choices[#choices + 1] = { value = c, text = tostring(c) } end
    end

    local frame = CreateFrame("Frame", nil, parent)
    local hasLabel = opts.label and opts.label ~= ""
    local lbl
    if hasLabel then
        lbl = fontString(frame, "body")
        anchorTL(lbl, frame, 0, 0)
        lbl:SetText(opts.label)
    end
    local btnY = hasLabel and -20 or 0
    frame:SetSize(width, (hasLabel and 20 or 0) + 24)

    local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, btnY)
    btn:SetSize(width, 24)
    UI.Skin(btn, function(self)
        self:SetBackdrop(FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("control"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)

    local cur = fontString(btn, "body")
    cur:SetPoint("LEFT", btn, "LEFT", 8, 0)
    cur:SetPoint("RIGHT", btn, "RIGHT", -20, 0)
    cur:SetJustifyH("LEFT")
    cur:SetWordWrap(false)

    local arrow = fontString(btn, "muted")
    arrow:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
    arrow:SetText("v")

    btn._value = nil
    function btn:GetValue() return self._value end
    local function textFor(v)
        for _, c in ipairs(choices) do if c.value == v then return c.text end end
        return v ~= nil and tostring(v) or ""
    end
    function btn:SetValue(v, fire)
        self._value = v
        cur:SetText(textFor(v))
        if fire and opts.set then opts.set(v) end
    end

    -- Owned popup — created once, no polling. A fullscreen invisible "closer" frame
    -- captures the next click anywhere outside and closes it (click-away close).
    local popup, closer
    local function buildPopup()
        popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        popup:SetFrameStrata("TOOLTIP")
        popup:EnableMouse(true)
        popup:Hide()
        UI.Skin(popup, function(self)
            self:SetBackdrop(FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("panel"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))
        end)
        popup._rows = {}

        closer = CreateFrame("Button", nil, UIParent)
        closer:SetFrameStrata("FULLSCREEN_DIALOG")
        closer:SetAllPoints(UIParent)
        closer:Hide()
        closer:SetScript("OnClick", function() popup:Hide() end)
        popup:SetScript("OnHide", function() closer:Hide() end)

        for i, c in ipairs(choices) do
            local row = CreateFrame("Button", nil, popup)
            row:SetSize(width - 6, 20)
            row:SetPoint("TOPLEFT", popup, "TOPLEFT", 3, -((i - 1) * 20 + 3))
            local hover = row:CreateTexture(nil, "BACKGROUND")
            hover:SetAllPoints()
            hover:Hide()
            UI.Skin(hover, function(self) self:SetColorTexture(UI.Color("accent", 0.25)) end)
            local rl = fontString(row, "body")
            rl:SetPoint("LEFT", row, "LEFT", 6, 0)
            rl:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            rl:SetJustifyH("LEFT")
            rl:SetWordWrap(false)
            rl:SetText(c.text)
            row:SetScript("OnEnter", function() hover:Show() end)
            row:SetScript("OnLeave", function() hover:Hide() end)
            row:SetScript("OnClick", function()
                btn:SetValue(c.value, true)
                popup:Hide()
            end)
            popup._rows[i] = row
        end
        popup:SetSize(width, math.max(1, #choices) * 20 + 6)
    end

    btn:SetScript("OnClick", function(self)
        if popup and popup:IsShown() then popup:Hide(); return end
        if not popup then buildPopup() end
        local dropGap = 2
        popup:ClearAllPoints()
        popup:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -dropGap)
        closer:Show()
        popup:Show()
    end)

    frame.Refresh = function()
        btn:SetValue(opts.get and opts.get() or (choices[1] and choices[1].value))
    end
    frame:SetScript("OnShow", function() frame.Refresh() end)
    frame.Refresh()

    frame.button = btn
    frame.uiHeight = (hasLabel and 20 or 0) + 24
    frame.uiWidth  = width
    return frame
end

-- 4 ── EditBox ─────────────────────────────────────────────────────────────────
-- opts = { label=, get=, set=, width=, numeric=bool }
function UI.MakeEditBox(parent, opts)
    opts = opts or {}
    local width = opts.width or 200
    local frame = CreateFrame("Frame", nil, parent)
    local hasLabel = opts.label and opts.label ~= ""
    local lbl
    if hasLabel then
        lbl = fontString(frame, "body")
        anchorTL(lbl, frame, 0, 0)
        lbl:SetText(opts.label)
    end
    local boxY = hasLabel and -20 or 0
    frame:SetSize(width, (hasLabel and 20 or 0) + 24)

    local box = CreateFrame("EditBox", nil, frame, "BackdropTemplate")
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, boxY)
    box:SetSize(width, 24)
    box:SetAutoFocus(false)
    box:SetFontObject(UI.fonts.body)
    box:SetTextInsets(8, 8, 0, 0)
    if opts.numeric then box:SetNumeric(true) end
    UI.Skin(box, function(self)
        self:SetBackdrop(FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    local function commit(self)
        if opts.set then opts.set(self:GetText()) end
        self:ClearFocus()
    end
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText(opts.get and opts.get() or "")
        self:ClearFocus()
    end)
    frame.Refresh = function() box:SetText(opts.get and (opts.get() or "") or "") end
    frame:SetScript("OnShow", function() frame.Refresh() end)
    frame.Refresh()

    frame.editBox = box
    frame.uiHeight = (hasLabel and 20 or 0) + 24
    frame.uiWidth  = width
    frame._fillWidth = true
    return frame
end

-- 5 ── Button (normal / quiet / danger) ────────────────────────────────────────
-- opts = { text=, onClick=, variant="normal"|"quiet"|"danger", width=, height= }
function UI.MakeButton(parent, opts)
    opts = opts or {}
    local variant = opts.variant or "normal"
    local h = opts.height or 24
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetHeight(h)

    local fill = { normal = "control", quiet = "panel", danger = "control" }
    local brd  = { normal = "accentDim", quiet = "controlBorder", danger = "danger" }
    local txt  = { normal = "text", quiet = "muted", danger = "danger" }

    local label = fontString(btn, txt[variant] and (variant == "danger" and "danger" or "body") or "body")
    label:SetPoint("CENTER", btn, "CENTER", 0, 0)
    label:SetText(opts.text or "")
    if variant == "danger" then label:SetFontObject(UI.fonts.danger)
    elseif variant == "quiet" then label:SetFontObject(UI.fonts.muted)
    else label:SetFontObject(UI.fonts.body) end

    local hover = btn:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    UI.Skin(hover, function(self) self:SetColorTexture(UI.Color("accent", 0.14)) end)
    btn:SetHighlightTexture(hover)

    UI.Skin(btn, function(self)
        self:SetBackdrop(FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color(fill[variant] or "raised"))
        self:SetBackdropBorderColor(UI.Color(brd[variant] or "border"))
    end)
    if opts.onClick then btn:SetScript("OnClick", opts.onClick) end

    local w = opts.width or math.max(80, (label:GetStringWidth() or 40) + 28)
    btn:SetWidth(w)
    btn.uiHeight = h
    btn.uiWidth  = w
    btn._label = label
    return btn
end

-- 6 ── Section header (serif accent title over a hairline rule) ────────────────
function UI.MakeSectionHeader(parent, text)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(26)
    local lbl = fontString(frame, "header")
    anchorTL(lbl, frame, 0, 0)
    lbl:SetText(text or "")
    local rule = frame:CreateTexture(nil, "ARTWORK")
    local ruleY = -22   -- hairline sits under the title inside the 26px header
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, ruleY)
    rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, ruleY)
    UI.Skin(rule, function(self) self:SetColorTexture(UI.Color("borderLite")) end)
    frame.uiHeight = 26
    frame._label = lbl
    return frame
end

-- 7 ── Label + Hint ────────────────────────────────────────────────────────────
function UI.MakeLabel(parent, text, opts)
    opts = opts or {}
    local frame = CreateFrame("Frame", nil, parent)
    local lbl = fontString(frame, opts.muted and "muted" or "body")
    anchorTL(lbl, frame, 0, 0)
    lbl:SetText(text or "")
    local h = 18
    lbl:SetHeight(h)
    frame.uiHeight = h
    frame._label = lbl
    return frame
end

function UI.MakeHint(parent, text)
    local frame = CreateFrame("Frame", nil, parent)
    local lbl = fontString(frame, "small")
    anchorTL(lbl, frame, 0, 0)
    lbl:SetText(text or "")
    lbl:SetJustifyH("LEFT")
    frame._label = lbl
    frame._fillWidth = true
    frame.uiHeight = 16
    frame._multiHeight = true   -- height recomputed from wrapped text at layout
    return frame
end

-- 8 ── SegmentedChoice (pill row; replaces overlapping toggle rows) ────────────
-- opts = { choices = { {value=, text=}, ... }, get=, set= }
function UI.MakeSegmented(parent, opts)
    opts = opts or {}
    local frame = CreateFrame("Frame", nil, parent)
    local h = 24
    frame:SetHeight(h)

    local segs = {}
    local function refresh()
        local v = opts.get and opts.get()
        for _, s in ipairs(segs) do s:_setActive(s._value == v) end
    end

    local x = 0
    for _, c in ipairs(opts.choices or {}) do
        local value = (type(c) == "table") and c.value or c
        local text  = (type(c) == "table") and (c.text or tostring(c.value)) or tostring(c)
        local seg = CreateFrame("Button", nil, frame, "BackdropTemplate")
        seg._value = value
        seg:SetHeight(h)
        local sl = fontString(seg, "body")
        sl:SetPoint("CENTER", seg, "CENTER", 0, 0)
        sl:SetText(text)
        seg:SetWidth(math.max(52, (sl:GetStringWidth() or 30) + 22))
        seg._active = false
        seg._setActive = function(self, on)
            self._active = on
            self:SetBackdrop(FLAT_BACKDROP)
            if on then
                self:SetBackdropColor(UI.Color("accent", 0.28))
                self:SetBackdropBorderColor(UI.Color("accent"))
                sl:SetFontObject(UI.fonts.accent)
            else
                self:SetBackdropColor(UI.Color("control"))
                self:SetBackdropBorderColor(UI.Color("controlBorder"))
                sl:SetFontObject(UI.fonts.muted)
            end
        end
        UI.Skin(seg, function(self) self:_setActive(self._active) end)
        seg:SetScript("OnClick", function(self)
            if opts.set then opts.set(self._value) end
            refresh()
        end)
        seg:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0)
        x = x + seg:GetWidth() + 4
        segs[#segs + 1] = seg
    end

    frame:SetScript("OnShow", refresh)
    frame.Refresh = refresh
    refresh()
    frame.uiHeight = h
    frame.uiWidth  = math.max(1, x - 4)
    return frame
end

-- 9 ── List (scrolling selection list with status dots) ────────────────────────
-- opts = { items = function()->{ {text=, status="ok"|"danger"|"muted", value=} },
--          onSelect = function(value), height=, selected= }
function UI.MakeList(parent, opts)
    opts = opts or {}
    local height = opts.height or 160
    local frame = UI.FlatFrame(parent, "inset", "controlBorder")
    frame:SetHeight(height)

    local scroll = CreateFrame("ScrollFrame", nil, frame)
    local li = 4   -- list viewport inset
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", li, -li)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -li, li)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 24)))
    end)

    frame._rows = {}
    frame._selected = opts.selected

    local ROW_H = 22
    function frame:Rebuild()
        local items = (opts.items and opts.items()) or {}
        local width = scroll:GetWidth()
        if width < 1 then width = frame:GetWidth() - 8 end
        child:SetWidth(width)
        for _, r in ipairs(self._rows) do r:Hide() end
        for i, item in ipairs(items) do
            local row = self._rows[i]
            if not row then
                row = CreateFrame("Button", nil, child)
                row:SetHeight(ROW_H)
                row.hl = row:CreateTexture(nil, "BACKGROUND")
                row.hl:SetAllPoints()
                row.hl:Hide()
                row.dot = row:CreateTexture(nil, "ARTWORK")
                row.dot:SetSize(8, 8)
                row.dot:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.lbl = fontString(row, "body")
                row.lbl:SetPoint("LEFT", row, "LEFT", 20, 0)
                row.lbl:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                row.lbl:SetJustifyH("LEFT")
                row.lbl:SetWordWrap(false)
                row:SetScript("OnEnter", function(s) if not s._sel then s.hl:Show(); s.hl:SetColorTexture(UI.Color("accent", 0.12)) end end)
                row:SetScript("OnLeave", function(s) if not s._sel then s.hl:Hide() end end)
                self._rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -((i - 1) * ROW_H))
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -((i - 1) * ROW_H))
            row.lbl:SetText(item.text or "")
            local dotToken = item.status == "ok" and "ok" or item.status == "danger" and "danger" or "faint"
            row.dot:SetColorTexture(UI.Color(dotToken))
            row._value = item.value
            row._sel = (self._selected ~= nil and item.value == self._selected)
            row.hl:SetShown(row._sel)
            if row._sel then row.hl:SetColorTexture(UI.Color("accent", 0.22)) end
            row:SetScript("OnClick", function(s)
                frame._selected = s._value
                frame:Rebuild()
                if opts.onSelect then opts.onSelect(s._value) end
            end)
            row:Show()
        end
        child:SetHeight(math.max(1, #items * ROW_H))
    end
    function frame:GetSelected() return self._selected end
    function frame:SetSelected(v) self._selected = v; self:Rebuild() end

    UI.Skin(frame, function() if frame.Rebuild then frame:Rebuild() end end)
    frame:SetScript("OnShow", function(self) self:Rebuild() end)
    frame:SetScript("OnSizeChanged", function(self) self:Rebuild() end)

    frame.uiHeight = height
    frame._fillWidth = true
    return frame
end

-- 10 ── EditorCard (raised card that hosts a nested flow — list+editor pattern) ─
-- opts = { title=, height= }.  Returns card; card.flow is a flow you add rows to.
function UI.MakeEditorCard(parent, opts)
    opts = opts or {}
    local card = UI.FlatFrame(parent, "raised", "controlBorder")
    local pad = 10
    local titleH = 0
    if opts.title then
        local t = fontString(card, "accent")
        t:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -pad)
        t:SetText(opts.title)
        titleH = 22
    end

    -- inner flow region (its own clipping pane keeps the card self-contained)
    local pane = UI.CreatePane(card, { padTop = pad + titleH, padBottom = pad, padX = pad, noBar = true })
    pane:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
    pane:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", 0, 0)

    card.flow = pane.flow
    card.pane = pane
    card.uiHeight = opts.height or 180
    card._fillWidth = true
    function card:Relayout() pane:Layout() end
    return card
end

-- 11 ── Separator (hairline rule) ──────────────────────────────────────────────
function UI.MakeSeparatorLine(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(1)
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    UI.Skin(tex, function(self) self:SetColorTexture(UI.Color("border")) end)
    frame.uiHeight = 1
    frame._fillWidth = true
    return frame
end

-- ════════════════════════════════════════════════════════════════════════════
--  FLOW LAYOUT ENGINE
-- ════════════════════════════════════════════════════════════════════════════

-- Debug overlay: 1px token-colored outline + block index around every laid block.
-- Toggled by `/daseekiui debug`; off by default and never created until enabled.
UI._debug = UI._debug or false
UI._panes = UI._panes or {}            -- top-level flow panes, re-laid on toggle
local DBG_TOKENS = { "accent", "ok", "danger", "borderLite", "muted" }
local DBG_PAD = 1                       -- index-label inset from the outline corner

local function debugOutline(blk, idx)
    local f = blk.frame
    local d = f._dbgBox
    if not d then
        d = CreateFrame("Frame", nil, f, "BackdropTemplate")
        d:SetAllPoints(f)
        d:SetFrameLevel(f:GetFrameLevel() + 20)
        d:EnableMouse(false)
        d.idx = d:CreateFontString(nil, "OVERLAY")
        d.idx:SetFontObject(UI.fonts.small)
        d.idx:SetPoint("TOPLEFT", d, "TOPLEFT", DBG_PAD, -DBG_PAD)
        f._dbgBox = d
    end
    local tok = DBG_TOKENS[((idx - 1) % #DBG_TOKENS) + 1]
    d:SetBackdrop(FLAT_BACKDROP)
    d:SetBackdropColor(UI.Color("ground", 0))          -- transparent fill (token, alpha 0)
    d:SetBackdropBorderColor(UI.Color(tok))
    d.idx:SetText(tostring(idx))
    d.idx:SetTextColor(UI.Color(tok))
    d:Show()
end

local function hideDebug(blk)
    local d = blk.frame._dbgBox
    if d then d:Hide() end
end

-- Shared block stacker used by both the scroll pane and column primitive. Places
-- each block at a running vertical cursor within `avail` width and returns the
-- total content height (padTop..padBot inclusive). A per-block arrange error is
-- routed to geterrorhandler() (never silently swallowed) so an invisible-layout
-- regression like the historical zero-width-row bug can never hide again.
local function stackBlocks(blocks, container, padX, padTop, padBot, avail)
    local y = padTop
    for i, blk in ipairs(blocks) do
        if i > 1 then y = y + blk.topGap end
        local ok, h = pcall(blk.arrange, avail)
        if not ok then
            geterrorhandler()(h)
            h = 0
        end
        h = h or 0
        local f = blk.frame
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", container, "TOPLEFT", padX, -y)
        -- SAFETY NET (make the invisible-block class impossible): a block whose arrange
        -- forgets a dimension leaves its frame zero-sized, and a zero-sized frame inside
        -- the clipping ScrollChild culls it and every child (the historical bug twice
        -- fixed by hand). Enforce a resolvable rect for any LAID block (h > 0), patching
        -- ONLY an unset/zero dimension:
        --   * width  -> the block's content width (avail minus its indent)
        --   * height -> the height the arrange just reported (h)
        -- Guards preserve intentional geometry: a frame that set its own (non-zero)
        -- width/height reports GetWidth/GetHeight >= 1, so the patch is skipped and a
        -- deliberately smaller size is never clobbered. Collapsed blocks return h == 0
        -- (and Hide() themselves), so they are skipped entirely — never force-shown.
        if h > 0 then
            if (f:GetHeight() or 0) < 1 then f:SetHeight(h) end
            local wantW = avail - (blk.indent or 0)
            if wantW > 0 and (f:GetWidth() or 0) < 1 then f:SetWidth(wantW) end
        end
        if UI._debug then debugOutline(blk, i) else hideDebug(blk) end
        y = y + h
    end
    return y + padBot
end

-- Toggle the layout debug overlay and re-lay every registered pane so outlines
-- (or their removal) take effect immediately.
function UI.SetDebug(on)
    UI._debug = on and true or false
    for pane in pairs(UI._panes) do
        if pane.Layout then pane:Layout() end
    end
    return UI._debug
end
function UI.ToggleDebug() return UI.SetDebug(not UI._debug) end

-- A Row: horizontal container. Widgets append left-to-right; one may be right-pinned.
local function newRow(pane, indent)
    local row = CreateFrame("Frame", nil, pane.child)
    row._items = {}
    row._indent = indent or 0

    -- widget adders (inline). `pin="right"` right-aligns the item.
    local function adder(factory)
        return function(self, o)
            o = o or {}
            local w = factory(row, o)
            row._items[#row._items + 1] = { w = w, pin = o.pin }
            return w
        end
    end
    row.Checkbox        = adder(UI.MakeCheckbox)
    row.Slider          = adder(UI.MakeSlider)
    row.Dropdown        = adder(UI.MakeDropdown)
    row.EditBox         = adder(UI.MakeEditBox)
    row.Button          = adder(UI.MakeButton)
    row.SegmentedChoice = adder(UI.MakeSegmented)
    row.List            = adder(UI.MakeList)
    row.EditorCard      = adder(UI.MakeEditorCard)
    function row:Label(text, o) local w = UI.MakeLabel(row, text, o); row._items[#row._items + 1] = { w = w, pin = o and o.pin }; return w end

    row.arrange = function(width)
        -- BUG-1 ROOT FIX: give the row a real width. Without this the row frame
        -- stays at width 0, so its child widgets have no resolvable rect inside the
        -- clipping ScrollChild and never render or receive mouse input — while every
        -- other block (header/separator/hint/custom blocks) sets its width and shows.
        row:SetWidth(math.max(width, 1))
        local avail = width - row._indent

        -- Place an item at horizontal offset x. vAlign == "center" anchors by the item's
        -- LEFT (its mid-height) to the row's LEFT, so items of differing heights (e.g. a
        -- 46px icon button beside a 24px EditBox) are vertically centered against each
        -- other; the default tops-aligns via TOPLEFT. The row height is the tallest item
        -- either way, so centering has real vertical room to work in.
        local function place(w, x)
            w:ClearAllPoints()
            if row._vAlign == "center" then
                w:SetPoint("LEFT", row, "LEFT", x, 0)
            else
                w:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
            end
        end

        -- Centered row (opt-in via AddRow{ align = "center" }): a general primitive
        -- that lays every item left-to-right at its intrinsic width, then offsets the
        -- whole run so it is centered in the available width. Ignores `pin` (centering
        -- and edge-pinning are mutually exclusive) and does not stretch _fillWidth items
        -- (they use their authored uiWidth). Used by Armory's builder column.
        if row._align == "center" then
            local n = #row._items
            local widths, h, total = {}, 0, 0
            for i, it in ipairs(row._items) do
                local w = it.w
                -- intrinsic width: authored uiWidth, else a real measured width, else a
                -- label's string width (Label/Hint frames carry no uiWidth and report a
                -- GetWidth of 0 until sized), else a floor so centering never collapses.
                local ww = w.uiWidth
                if not ww or ww <= 0 then
                    local gw = w:GetWidth() or 0
                    if gw > 0 then ww = gw
                    elseif w._label and w._label.GetStringWidth then ww = w._label:GetStringWidth()
                    else ww = 80 end
                end
                widths[i] = ww
                total = total + ww
                h = math.max(h, w.uiHeight or w:GetHeight())
            end
            if n > 1 then total = total + (n - 1) * ITEM_GAP end
            local leftX = row._indent + math.max(0, (avail - total) / 2)
            for i, it in ipairs(row._items) do
                local ww = widths[i]
                it.w:SetWidth(ww)
                place(it.w, leftX)
                leftX = leftX + ww + ITEM_GAP
            end
            row:SetHeight(math.max(h, 1))
            return math.max(h, 1)
        end

        local leftX, h = row._indent, 0
        -- right-pinned first (measure), place after lefts
        local rights = {}
        for _, it in ipairs(row._items) do
            local w = it.w
            local ww = w._fillWidth and nil or (w.uiWidth or w:GetWidth())
            it._w = ww
            if it.pin == "right" then rights[#rights + 1] = it end
            h = math.max(h, w.uiHeight or w:GetHeight())
        end
        local rightX = width
        for i = #rights, 1, -1 do
            local it = rights[i]
            local ww = it._w or 100
            it.w:SetWidth(ww)
            rightX = rightX - ww
            place(it.w, rightX)
            rightX = rightX - ITEM_GAP
        end
        -- lefts fill the remaining space; a single _fillWidth left item stretches
        local nLeft = 0
        for _, it in ipairs(row._items) do if it.pin ~= "right" then nLeft = nLeft + 1 end end
        for _, it in ipairs(row._items) do
            if it.pin ~= "right" then
                local w = it.w
                place(it.w, leftX)
                local ww = it._w
                if w._fillWidth then
                    ww = math.max(40, (#rights > 0 and (rightX) or width) - leftX)
                end
                if ww then w:SetWidth(ww) end
                leftX = leftX + (ww or (w.uiWidth or 80)) + ITEM_GAP
                if w._multiHeight and w._label then
                    w._label:SetWidth((ww or avail))
                    local lh = w._label:GetStringHeight() or 14
                    w:SetHeight(lh)
                    h = math.max(h, lh)
                end
            end
        end
        row:SetHeight(math.max(h, 1))
        return math.max(h, 1)
    end

    return row
end

-- A Flow: appends blocks to a pane's scroll child at a running cursor.
local function newFlow(pane, indent)
    local flow = { pane = pane, _indent = indent or 0 }

    function flow:AddRow(opts)
        local row = newRow(self.pane, self._indent)
        if opts then
            if opts.align  then row._align  = opts.align  end
            if opts.vAlign then row._vAlign = opts.vAlign end
        end
        self.pane:AddBlock(row, row.arrange, rowGap())
        return row
    end

    function flow:AddSection(title)
        local hdr = UI.MakeSectionHeader(self.pane.child, title)
        hdr._indent = self._indent
        self.pane:AddBlock(hdr, function(width)
            hdr:SetWidth(width - self._indent)
            return hdr.uiHeight
        end, sectionGap(), self._indent)
        -- content beneath a section indents one step
        return newFlow(self.pane, self._indent + INDENT)
    end

    function flow:AddSeparator()
        local sep = UI.MakeSeparatorLine(self.pane.child)
        self.pane:AddBlock(sep, function(width) sep:SetWidth(width - self._indent); return 1 end, rowGap(), self._indent)
        return sep
    end

    -- Two-column checkbox grid; collapses to one column on a narrow pane.
    -- items = { {label=, get=, set=, tooltip=}, ... }
    function flow:AddChecklist(items)
        local grid = CreateFrame("Frame", nil, self.pane.child)
        grid._boxes = {}
        for _, it in ipairs(items or {}) do
            grid._boxes[#grid._boxes + 1] = UI.MakeCheckbox(grid, it)
        end
        local COLLAPSE_W = 460
        local ROW_H = 24
        grid.arrange = function(width)
            grid:SetWidth(math.max(width, 1))   -- same width-0 fix as newRow (Bug 1 class)
            local cols = (width >= COLLAPSE_W) and 2 or 1
            local colW = (width - self._indent) / cols
            local rows = math.ceil(#grid._boxes / cols)
            for i, box in ipairs(grid._boxes) do
                local col = (i - 1) % cols
                local rowN = math.floor((i - 1) / cols)
                box:ClearAllPoints()
                box:SetPoint("TOPLEFT", grid, "TOPLEFT", self._indent + col * colW, -(rowN * ROW_H))
                -- Give each checkbox a real, column-bounded width (specific-arrange fix
                -- for the invisible-checklist class): the click target stays on the
                -- box+label but never spills past its column. MakeCheckbox also self-sizes,
                -- so this is belt-and-suspenders, not the sole guarantee.
                box:SetWidth(math.max(1, math.min(box.uiWidth or colW, colW - ITEM_GAP)))
            end
            local h = math.max(1, rows * ROW_H)
            grid:SetHeight(h)
            return h
        end
        self.pane:AddBlock(grid, grid.arrange, rowGap())
        return grid
    end

    -- Convenience single-widget rows (also available inline on a row).
    function flow:Label(text, o) local r = self:AddRow(); return r:Label(text, o) end
    function flow:Hint(text)
        local h = UI.MakeHint(self.pane.child, text)
        self.pane:AddBlock(h, function(width)
            h:SetWidth(width - self._indent)
            h._label:SetWidth(width - self._indent)
            local hh = h._label:GetStringHeight() or 16
            h:SetHeight(hh)
            return hh
        end, math.floor(rowGap() / 2), self._indent)
        return h
    end
    local function convenience(name)
        flow[name] = function(self, o) local r = self:AddRow(); return r[name](r, o) end
    end
    convenience("Checkbox"); convenience("Slider"); convenience("Dropdown")
    convenience("EditBox");  convenience("Button"); convenience("SegmentedChoice")
    convenience("List");     convenience("EditorCard")

    return flow
end

-- ── Pane (scroll + clip content host) ─────────────────────────────────────────
-- opts (optional) = { padTop=, padBottom=, padX=, noBar= }
function UI.CreatePane(parent, opts)
    opts = opts or {}
    local padX  = opts.padX or PANE_PAD
    local padTop = opts.padTop or PANE_PAD
    local padBot = opts.padBottom or PANE_PAD
    local barGutter = opts.noBar and 0 or BAR_W

    local pane = CreateFrame("Frame", nil, parent)
    if parent.GetObjectType then pane:SetAllPoints(parent) end

    local scroll = CreateFrame("ScrollFrame", nil, pane)
    scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -barGutter, 0)
    scroll:SetClipsChildren(true)     -- STRUCTURAL: content cannot escape the pane
    scroll:EnableMouseWheel(true)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)

    pane.scroll, pane.child = scroll, child
    pane.blocks = {}
    pane._padX, pane._padTop, pane._padBot = padX, padTop, padBot

    -- thin token-skinned scrollbar
    local bar
    if not opts.noBar then
        bar = CreateFrame("Slider", nil, pane)
        bar:SetWidth(6)
        bar:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -2, -padTop)
        bar:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -2, padBot)
        bar:SetOrientation("VERTICAL")
        bar:SetValueStep(1)
        bar:SetObeyStepOnDrag(true)
        local track = bar:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints()
        UI.Skin(track, function(self) self:SetColorTexture(UI.Color("inset", 0.6)) end)
        local thumb = bar:CreateTexture(nil, "OVERLAY")
        thumb:SetSize(6, 40)
        bar:SetThumbTexture(thumb)
        UI.Skin(thumb, function(self) self:SetColorTexture(UI.Color("borderLite")) end)
        bar:SetMinMaxValues(0, 0)
        bar:SetScript("OnValueChanged", function(self, v) scroll:SetVerticalScroll(v) end)
        bar:Hide()
        pane.bar = bar
    end

    scroll:SetScript("OnMouseWheel", function(self, delta)
        if not pane.bar then return end
        pane.bar:SetValue(pane.bar:GetValue() - delta * 32)
    end)
    scroll:SetScript("OnSizeChanged", function() pane:Layout() end)

    -- flow object the section's build(flow) receives
    pane.flow = newFlow(pane, 0)

    function pane:AddBlock(frame, arrange, topGap, indent)
        self.blocks[#self.blocks + 1] = { frame = frame, arrange = arrange, topGap = topGap or rowGap(), indent = indent or 0 }
    end

    function pane:Layout()
        local sw = self.scroll:GetWidth()
        if not sw or sw < 1 then return end
        self.child:SetWidth(sw)     -- child spans the viewport; clip/scroll unchanged
        -- Compose blocks within min(paneInnerWidth, contentMaxW), left-aligned.
        local inner = sw - self._padX * 2
        local maxW  = UI.Token("contentMaxW") or 880
        local avail = math.min(inner, maxW)
        if avail < 1 then avail = 1 end
        self._contentW = avail      -- consumers (e.g. two-pane blocks) read this
        local y = stackBlocks(self.blocks, self.child, self._padX, self._padTop, self._padBot, avail)
        self.child:SetHeight(math.max(y, 1))
        -- scrollbar range
        if self.bar then
            local maxScroll = math.max(0, self.child:GetHeight() - self.scroll:GetHeight())
            if maxScroll > 0 then
                self.bar:SetMinMaxValues(0, maxScroll)
                local cur = self.bar:GetValue()
                if cur > maxScroll then self.bar:SetValue(maxScroll) end
                self.bar:Show()
            else
                self.bar:SetValue(0)
                self.bar:SetMinMaxValues(0, 0)
                self.bar:Hide()
            end
        end
    end

    UI._panes[pane] = true      -- registered so /daseekiui debug can re-lay it
    return pane
end

-- ── Column (non-scrolling flow region) ────────────────────────────────────────
-- A plain content column that stacks flow blocks and sizes ITSELF to its content
-- (no scroll/clip of its own — the host pane scrolls). Used to compose side-by-side
-- columns (e.g. Armory's two-pane Sets layout). Drive it with col:Layout(width).
--   col.frame  — the container frame (parent it / anchor it yourself)
--   col.flow   — a flow; add rows/sections/widgets exactly as on a pane
--   col:Layout(width) -> total content height (also sets frame size)
function UI.CreateColumn(parent, opts)
    opts = opts or {}
    local col = {
        blocks  = {},
        _padX   = opts.padX or 0,
        _padTop = opts.padTop or 0,
        _padBot = opts.padBottom or 0,
    }
    local frame = CreateFrame("Frame", nil, parent)
    col.frame, col.child = frame, frame     -- blocks parent to `frame` via the flow

    function col:AddBlock(f, arrange, topGap, indent)
        self.blocks[#self.blocks + 1] = { frame = f, arrange = arrange, topGap = topGap or rowGap(), indent = indent or 0 }
    end

    function col:Layout(width)
        width = math.max(width or frame:GetWidth() or 1, 1)
        frame:SetWidth(width)
        local avail = width - self._padX * 2
        if avail < 1 then avail = 1 end
        local total = stackBlocks(self.blocks, frame, self._padX, self._padTop, self._padBot, avail)
        frame:SetHeight(math.max(total, 1))
        return total
    end

    col.flow = newFlow(col, 0)
    return col
end

-- ── Legacy pane: scroll + clip wrapper for un-migrated build(panel) callers ────
-- The legacy addon builds into pane.child with its own absolute SetPoint offsets;
-- we contain that in a clipping scroll viewport so any overflow scrolls instead of
-- escaping the window. Call pane:FinalizeLegacy(minHeight) after the build.
function UI.CreateLegacyPane(parent)
    local pane = UI.CreatePane(parent)
    pane._legacyHeight = 720   -- authored against a ~630px ceiling; give headroom
    pane._authoredWidth = 886  -- old hub content width legacy panels expect

    -- Legacy panes hold no flow blocks, so the block-stacking Layout must NOT run
    -- (it would collapse the fixed content height). Keep the child at least as wide
    -- as the authored width so no control is squished; the viewport clips and pans.
    function pane:Layout()
        local sw = self.scroll:GetWidth()
        if not sw or sw < 1 then return end
        local cw = math.max(sw, self._authoredWidth)
        self.child:SetWidth(cw)
        -- clamp any active horizontal pan to the new range
        local maxH = math.max(0, cw - sw)
        if self.scroll:GetHorizontalScroll() > maxH then self.scroll:SetHorizontalScroll(maxH) end
        if self.bar then
            local maxScroll = math.max(0, self.child:GetHeight() - self.scroll:GetHeight())
            self.bar:SetMinMaxValues(0, maxScroll)
            local cur = self.bar:GetValue()
            if cur > maxScroll then self.bar:SetValue(maxScroll) end
            self.bar:SetShown(maxScroll > 0)
        end
    end

    -- Vertical wheel scrolls; Shift+wheel pans horizontally so far-right controls
    -- on a wide legacy panel stay reachable in the narrower sidebar content area.
    pane.scroll:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            local limit = math.max(0, pane.child:GetWidth() - self:GetWidth())
            local target = self:GetHorizontalScroll() - delta * 40
            self:SetHorizontalScroll(math.max(0, math.min(limit, target)))
        elseif pane.bar then
            pane.bar:SetValue(pane.bar:GetValue() - delta * 32)
        end
    end)

    function pane:FinalizeLegacy(minHeight)
        self.child:SetHeight(math.max(minHeight or self._legacyHeight, 1))
        local sw = self.scroll:GetWidth()
        self.child:SetWidth(math.max(sw > 1 and sw or 640, self._authoredWidth))
        self:Layout()
    end
    return pane
end

-- ── ConfirmPopup (token-skinned modal; delegates to the dialogs.lua pattern) ──
-- opts = { title=, text=, acceptText=, cancelText=, onAccept=, danger=bool }
function UI.Confirm(opts)
    opts = opts or {}
    local dlg = UI._confirm
    if not dlg then
        dlg = CreateFrame("Frame", "DaseekiUIConfirm", UIParent, "BackdropTemplate")
        dlg:SetSize(380, 150)
        dlg:SetFrameStrata("FULLSCREEN_DIALOG")
        dlg:SetPoint("CENTER")
        dlg:EnableMouse(true)
        dlg:Hide()
        UI.Skin(dlg, function(self)
            self:SetBackdrop(FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("panel"))
            self:SetBackdropBorderColor(UI.Color("accent"))
        end)
        local mpad, titleY, bodyY = 16, -14, -44   -- fixed modal chrome insets
        dlg.title = fontString(dlg, "accent")
        dlg.title:SetPoint("TOPLEFT", dlg, "TOPLEFT", mpad, titleY)
        dlg.title:SetFontObject(UI.fonts.header)
        dlg.body = fontString(dlg, "body")
        dlg.body:SetPoint("TOPLEFT", dlg, "TOPLEFT", mpad, bodyY)
        dlg.body:SetPoint("TOPRIGHT", dlg, "TOPRIGHT", -mpad, bodyY)
        dlg.body:SetJustifyH("LEFT")
        dlg.body:SetJustifyV("TOP")
        dlg.body:SetHeight(56)
        dlg.accept = UI.MakeButton(dlg, { text = "OK", variant = "normal", width = 100 })
        dlg.accept:SetPoint("BOTTOMRIGHT", dlg, "BOTTOMRIGHT", -16, 14)
        dlg.cancel = UI.MakeButton(dlg, { text = "Cancel", variant = "quiet", width = 100 })
        dlg.cancel:SetPoint("RIGHT", dlg.accept, "LEFT", -8, 0)
        dlg.cancel:SetScript("OnClick", function() dlg:Hide() end)
        UI._confirm = dlg
    end
    dlg.title:SetText(opts.title or "Confirm")
    dlg.body:SetText(opts.text or "")
    dlg.accept._label:SetText(opts.acceptText or "OK")
    dlg.accept._label:SetFontObject(opts.danger and UI.fonts.danger or UI.fonts.body)
    dlg.cancel._label:SetText(opts.cancelText or "Cancel")
    dlg.accept:SetScript("OnClick", function()
        dlg:Hide()
        if opts.onAccept then opts.onAccept() end
    end)
    dlg:Show()
    return dlg
end

-- UI.FLAT_BACKDROP is exported at its definition (top of file, Bug 2).
UI.PANE_PAD = PANE_PAD
