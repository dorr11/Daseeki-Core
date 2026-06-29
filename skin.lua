--[[
    Daseeki Core — shared skin / backdrop helper.
    Deduplicated from Daseeki-Buff-Tracker/options.lua and Daseeki-Raid-Prep/options.lua,
    which both carried identical copies. Honors Daseeki-Bags' skin system when present,
    otherwise falls back to a plain tooltip backdrop.
--]]

local _, Core = ...

Core.BACKDROP = {
    bgFile   = 'Interface/Tooltips/UI-Tooltip-Background',
    edgeFile = 'Interface/Tooltips/UI-Tooltip-Border',
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

Core.DROPDOWN_BACKDROP = {
    bgFile   = 'Interface/Tooltips/UI-Tooltip-Background',
    edgeFile = 'Interface/Tooltips/UI-Tooltip-Border',
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

function Core.ApplySkin(f)
    if not f then return end
    local DB      = _G['Daseeki-Bags']
    local Skins   = DB and DB.Skins
    local profile = DB and DB.player and DB.player.profile and DB.player.profile['inventory']
    if Skins and Skins.Acquire and profile then
        if f.bgSkin then f.bgSkin:Release() end
        f.bgSkin = Skins:Acquire(profile.skin, f)
        local border = profile.borderColor or { 0.3, 0.3, 0.3, 1 }
        local center = profile.color       or { 0, 0, 0, 0.85 }
        f.bgSkin('load')
        f.bgSkin('borderColor', border[1], border[2], border[3], border[4])
        f.bgSkin('centerColor', center[1], center[2], center[3], center[4])
        if f.GetBackdrop and f:GetBackdrop() then f:SetBackdrop(nil) end
    else
        if f.bgSkin then f.bgSkin:Release(); f.bgSkin = nil end
        f:SetBackdrop(Core.BACKDROP)
        f:SetBackdropColor(0, 0, 0, 0.85)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end
end
