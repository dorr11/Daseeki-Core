--[[
    Daseeki Core — slash commands.
    /daseeki or /das  → open the combined options hub.
    /daseeki <id>     → open directly to a registered section (e.g. /daseeki bufftracker).
--]]

local _, Core = ...

SLASH_DASEEKISUITE1 = "/daseeki"
SLASH_DASEEKISUITE2 = "/das"
SlashCmdList["DASEEKISUITE"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "minimap" or msg == "mm" then
        Core:ToggleMinimapButton()
        print("|cff00ccff[Daseeki Suite]|r Minimap button " ..
            ((Core.db and Core.db.minimapHide) and "hidden" or "shown") .. ".")
    elseif msg ~= "" and Core.sections[msg] then
        Core:Open(msg)
    else
        Core:Toggle()
    end
end
