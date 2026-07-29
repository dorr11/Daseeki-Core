--[[
    Daseeki Core — slash commands.
    /daseeki or /das  → open the combined options hub.
    /daseeki <id>     → open directly to a registered section (e.g. /daseeki bufftracker).
    /daseeki debug    → toggle the DaseekiUI layout debug overlay (block outlines).
    /daseekiui debug  → same overlay toggle (framework-scoped alias).
--]]

local _, Core = ...

-- Toggle the DaseekiUI pane-block debug overlay (1px token-colored outlines +
-- block index around every laid block) for in-game layout iteration.
local function toggleDebug()
    local on = DaseekiUI and DaseekiUI.ToggleDebug and DaseekiUI.ToggleDebug()
    print("|cff00ccff[Daseeki Suite]|r Layout debug overlay " ..
        (on and "|cff82bf6bON|r" or "|cffcf5d4aOFF|r") .. ".")
    -- Also dump the Phase-0 ledger kit: new primitives, active-theme tokens, and the
    -- theme-token completeness self-test (BRAND_SPEC §9 debug requirement).
    if DaseekiUI and DaseekiUI.PrintKitDebug then DaseekiUI.PrintKitDebug() end
end

SLASH_DASEEKISUITE1 = "/daseeki"
SLASH_DASEEKISUITE2 = "/das"
SlashCmdList["DASEEKISUITE"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "minimap" or msg == "mm" then
        Core:ToggleMinimapButton()
        print("|cff00ccff[Daseeki Suite]|r Minimap button " ..
            ((Core.db and Core.db.minimapHide) and "hidden" or "shown") .. ".")
    elseif msg == "debug" then
        toggleDebug()
    elseif msg ~= "" and Core.sections[msg] then
        Core:Open(msg)
    else
        Core:Toggle()
    end
end

-- Framework-scoped alias: `/daseekiui debug` (bare `/daseekiui` also toggles it).
SLASH_DASEEKIUI1 = "/daseekiui"
SlashCmdList["DASEEKIUI"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "" or msg == "debug" then
        toggleDebug()
    else
        Core:Toggle()
    end
end
