--[[
    Daseeki Core — slash commands.
    /daseeki or /das  → open the combined options hub.
    /daseeki <id>     → open directly to a registered section (e.g. /daseeki bufftracker).
    /daseeki debug    → toggle the DaseekiUI layout debug overlay (block outlines).
    /daseekiui debug  → same overlay toggle (framework-scoped alias).
    /daseekiui debug material → cycle the Field Ledger material preset (subtle → standard
                        → strong) live so the owner can A/B the grain/vignette/keyline at
                        game gamma; the choice persists (BRAND_SPEC §4/§5a).
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

-- Cycle the material preset (subtle → standard → strong → subtle) and repaint every
-- registered ground live (BRAND_SPEC §4/§5a material A/B). Persists via SetMaterialPreset.
local function cycleMaterial()
    local UI = DaseekiUI
    if not (UI and UI.SetMaterialPreset and UI.GetMaterialPresetNames) then
        print("|cff00ccff[Daseeki Suite]|r Material presets unavailable.")
        return
    end
    local order = UI.GetMaterialPresetNames()
    local cur = UI.GetMaterialPreset()
    local idx = 1
    for i, n in ipairs(order) do if n == cur then idx = i break end end
    local nextName = order[(idx % #order) + 1]
    UI.SetMaterialPreset(nextName)
    local ap = UI.MATERIAL_PRESETS and UI.MATERIAL_PRESETS[nextName]
    print("|cff00ccff[Daseeki Suite]|r Material preset → |cffece3d0" .. nextName .. "|r" ..
        (ap and ("  (grain veil " .. math.floor(ap.grainAlpha * 100) .. "%, aged edge " ..
                 ap.vigWidth .. "px)") or "") ..
        ".  Open the suite window to A/B the parchment tooth + edges.")
end

SLASH_DASEEKISUITE1 = "/daseeki"
SLASH_DASEEKISUITE2 = "/das"
SlashCmdList["DASEEKISUITE"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "minimap" or msg == "mm" then
        Core:ToggleMinimapButton()
        print("|cff00ccff[Daseeki Suite]|r Minimap button " ..
            ((Core.db and Core.db.minimapHide) and "hidden" or "shown") .. ".")
    elseif msg == "debug material" or msg == "material" then
        cycleMaterial()
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
    if msg == "debug material" or msg == "material" then
        cycleMaterial()
    elseif msg == "" or msg == "debug" then
        toggleDebug()
    else
        Core:Toggle()
    end
end
