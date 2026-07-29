--[[
    Daseeki Core — shared modal dialogs (single-line name input + multi-line text).

    Field Ledger dress (BRAND_SPEC §11): rebuilt on DaseekiUI primitives — token panel
    fill + a bronze keyline border, CEREMONIAL cream titles (the old SN-gold {1,0.82,0}
    titles are gone), token EditBoxes on an inset field, and UI.MakeButton controls (no
    Blizzard UIPanelButtonTemplate, no Core.ApplySkin tooltip backdrop). Everything reads
    tokens and re-skins live on ThemeChanged, exactly like the modern hub.

    PUBLIC SIGNATURES ARE UNCHANGED so every consumer keeps working byte-for-byte:
      Core.ShowNameInputDialog(title, defaultText, onConfirm)   — Armory (New/Rename Set),
                                                                   Conduit (Rename Rule)
      Core.ShowTextDialog(title, text, readOnly, onConfirm)     — Armory (Export/Import/
                                                                   Macro), Nexus + Raid-
                                                                   Mechanics (Export/Import/
                                                                   Log)  -> returns the frame
--]]

local _, Core = ...
local UI = DaseekiUI

local _nameDlg, _textDlg

-- A token-skinned modal shell: panel fill + bronze keyline border (re-skins on theme).
local function skinModal(dlg)
    UI.Skin(dlg, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("panel"))
        self:SetBackdropBorderColor(UI.Color("bronze"))
    end)
end

-- Ceremonial cream title (MORPHEUS >=16) — replaces the retired SN-gold title.
local function modalTitle(dlg)
    local t = dlg:CreateFontString(nil, "OVERLAY")
    t:SetFontObject(UI.fonts.ceremonial)
    return t
end

-- A plain token EditBox (cream body on an inset field). `multiline` for the text dialog.
local function tokenEditBox(parent, w, h, multiline)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetSize(w, h)
    eb:SetAutoFocus(false)
    eb:SetFontObject(UI.fonts.body)
    eb:SetTextInsets(6, 6, 4, 4)
    if multiline then eb:SetMultiLine(true); eb:SetMaxLetters(0) end
    return eb
end

-- Single-line name prompt. onConfirm(value) fires on OK / Enter with a trimmed,
-- non-empty value.
function Core.ShowNameInputDialog(title, defaultText, onConfirm)
    local dlg = _nameDlg
    if not dlg then
        dlg = CreateFrame("Frame", "DaseekiCoreNameInput", UIParent, "BackdropTemplate")
        dlg:SetSize(300, 110); dlg:SetFrameStrata("DIALOG")
        dlg:SetMovable(true); dlg:EnableMouse(true)
        dlg:SetScript("OnMouseDown", function(s, b) if b == "LeftButton" then s:StartMoving() end end)
        dlg:SetScript("OnMouseUp",   function(s) s:StopMovingOrSizing() end)
        skinModal(dlg)

        dlg.title = modalTitle(dlg)
        dlg.title:SetPoint("TOP", dlg, "TOP", 0, -12)

        local box = UI.FlatFrame(dlg, "inset", "controlBorder")
        box:SetSize(244, 24); box:SetPoint("TOP", dlg, "TOP", 0, -40)
        dlg.eb = tokenEditBox(box, 236, 20)
        dlg.eb:SetPoint("LEFT", box, "LEFT", 4, 0)
        dlg.eb:SetAutoFocus(true)
        dlg.eb:SetScript("OnEnterPressed", function(self)
            local v = strtrim(self:GetText())
            if v ~= "" and dlg.onConfirm then dlg.onConfirm(v) end; dlg:Hide()
        end)
        dlg.eb:SetScript("OnEscapePressed", function() dlg:Hide() end)

        local ok = UI.MakeButton(dlg, { text = "OK", variant = "normal", width = 80,
            onClick = function()
                local v = strtrim(dlg.eb:GetText())
                if v ~= "" and dlg.onConfirm then dlg.onConfirm(v) end; dlg:Hide()
            end })
        ok:SetPoint("BOTTOMLEFT", dlg, "BOTTOMLEFT", 60, 14)
        local cancel = UI.MakeButton(dlg, { text = "Cancel", variant = "quiet", width = 80,
            onClick = function() dlg:Hide() end })
        cancel:SetPoint("LEFT", ok, "RIGHT", 16, 0)
        _nameDlg = dlg
    end
    dlg.title:SetText(title); dlg.eb:SetText(defaultText or "")
    dlg.eb:HighlightText(); dlg.onConfirm = onConfirm
    dlg:SetPoint("CENTER"); dlg:Show(); dlg.eb:SetFocus()
    return dlg
end

-- Multi-line text box. readOnly = display/export; otherwise an Import button calls
-- onConfirm(text). Returns the dialog frame.
function Core.ShowTextDialog(title, text, readOnly, onConfirm)
    local dlg = _textDlg
    if not dlg then
        dlg = CreateFrame("Frame", "DaseekiCoreTextDlg", UIParent, "BackdropTemplate")
        dlg:SetSize(500, 340); dlg:SetFrameStrata("DIALOG")
        dlg:SetMovable(true); dlg:EnableMouse(true)
        dlg:SetScript("OnMouseDown", function(s, b) if b == "LeftButton" then s:StartMoving() end end)
        dlg:SetScript("OnMouseUp",   function(s) s:StopMovingOrSizing() end)
        skinModal(dlg)

        dlg.title = modalTitle(dlg)
        dlg.title:SetPoint("TOP", dlg, "TOP", 0, -12)

        local box = UI.FlatFrame(dlg, "inset", "controlBorder")
        box:SetSize(452, 224); box:SetPoint("TOP", dlg, "TOP", 0, -40)
        local sf = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -6)
        sf:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -26, 6)
        dlg.eb = tokenEditBox(sf, 410, 210, true)
        dlg.eb:SetScript("OnEscapePressed", function() dlg:Hide() end)
        sf:SetScrollChild(dlg.eb)

        local close = UI.MakeButton(dlg, { text = "Close", variant = "quiet", width = 80,
            onClick = function() dlg:Hide() end })
        close:SetPoint("BOTTOMRIGHT", dlg, "BOTTOMRIGHT", -16, 14)
        dlg.confirmBtn = UI.MakeButton(dlg, { text = "Import", variant = "normal", width = 80,
            onClick = function()
                if dlg.onConfirm then dlg.onConfirm(strtrim(dlg.eb:GetText())) end; dlg:Hide()
            end })
        dlg.confirmBtn:SetPoint("RIGHT", close, "LEFT", 16, 0)
        _textDlg = dlg
    end
    dlg.title:SetText(title); dlg.eb:SetText(text or "")
    dlg.onConfirm = (not readOnly) and onConfirm or nil
    dlg.confirmBtn:SetShown(not readOnly)
    dlg:SetPoint("CENTER"); dlg:Show()
    dlg.eb:SetFocus()
    if readOnly then dlg.eb:HighlightText() end
    return dlg
end
