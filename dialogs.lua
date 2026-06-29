--[[
    Daseeki Core — shared modal dialogs (single-line name input + multi-line text).
    Deduplicated from Daseeki-Buff-Tracker. Reusable across the suite for profile
    rename/clone and import/export flows.
--]]

local _, Core = ...

local _nameDlg, _textDlg

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
        dlg:SetScript("OnShow", function(self) Core.ApplySkin(self) end)
        dlg.title = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dlg.title:SetPoint("TOP", dlg, "TOP", 0, -12); dlg.title:SetTextColor(1, 0.82, 0)
        dlg.eb = CreateFrame("EditBox", nil, dlg, "InputBoxTemplate")
        dlg.eb:SetSize(240, 20); dlg.eb:SetPoint("TOP", dlg, "TOP", 0, -40)
        dlg.eb:SetFontObject(ChatFontNormal); dlg.eb:SetAutoFocus(true)
        dlg.eb:SetScript("OnEnterPressed", function(self)
            local v = strtrim(self:GetText())
            if v ~= "" and dlg.onConfirm then dlg.onConfirm(v) end; dlg:Hide()
        end)
        dlg.eb:SetScript("OnEscapePressed", function() dlg:Hide() end)
        Core.MakeButton(dlg, "OK", 60, 76, 80, 22, function()
            local v = strtrim(dlg.eb:GetText())
            if v ~= "" and dlg.onConfirm then dlg.onConfirm(v) end; dlg:Hide()
        end)
        Core.MakeButton(dlg, "Cancel", 160, 76, 80, 22, function() dlg:Hide() end)
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
        dlg:SetScript("OnShow", function(self) Core.ApplySkin(self) end)
        dlg.title = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dlg.title:SetPoint("TOP", dlg, "TOP", 0, -12); dlg.title:SetTextColor(1, 0.82, 0)
        local sf = CreateFrame("ScrollFrame", nil, dlg, "UIPanelScrollFrameTemplate")
        sf:SetSize(450, 220); sf:SetPoint("TOP", dlg, "TOP", 0, -40)
        dlg.eb = CreateFrame("EditBox", nil, sf)
        dlg.eb:SetSize(430, 210); dlg.eb:SetMultiLine(true)
        dlg.eb:SetAutoFocus(false); dlg.eb:SetFontObject(ChatFontNormal); dlg.eb:SetMaxLetters(0)
        dlg.eb:SetScript("OnEscapePressed", function() dlg:Hide() end)
        sf:SetScrollChild(dlg.eb)
        Core.MakeButton(dlg, "Close", 210, 300, 80, 22, function() dlg:Hide() end)
        dlg.confirmBtn = Core.MakeButton(dlg, "Import", 110, 300, 80, 22, function()
            if dlg.onConfirm then dlg.onConfirm(strtrim(dlg.eb:GetText())) end; dlg:Hide()
        end)
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
