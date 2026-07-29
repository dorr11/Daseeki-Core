--[[
    Daseeki Core — DaseekiUI "Field Ledger" Phase-0 kit (BRAND_SPEC §9).

    PURELY ADDITIVE to the DaseekiUI framework. Every symbol here is NEW; nothing in
    theme.lua / daseekiui.lua changes signature or behavior because of this file. Loads
    AFTER daseekiui.lua (so UI.Color/UI.Token/UI.Skin/UI.fonts exist) and consumes the
    ledger tokens theme.lua now defines (brand/brandBright/bronze/bronzeDim/idle).

    New public surface (R1 waves code against these EXACT signatures):

      UI.MakeStatusBar(parent, opts) -> bar
          opts = { min=, max=, value=, fillToken="brand", bgToken="inset",
                   spark=bool, text=bool, textFont="numeral", height=, width=, speed= }
          bar:SetBarValue(v[, immediate])   -- animates fill toward v (spark tracks edge)
          bar:SetBarRange(min, max)
          bar:GetBarValue() -> v            -- the TARGET value (not the tweened frame)
          bar:SetBarText(str)               -- live text readout (requires opts.text)
          bar:SetUrgent(bool)               -- raises luminance of fill+text; NEVER dims

      UI.Animate.FadeIn(frame[, ms])   -> group      (ms default 120, capped 120)
      UI.Animate.FadeOut(frame[, ms])  -> group
      UI.Animate.ScaleReveal(frame[, ms]) -> group   (95%->100% + fade)
      UI.Animate.Stop(frame)                          -- stop the kit's group on a frame
          (no-op fallback: if CreateAnimationGroup is unavailable the helpers snap the
           frame to its final visual state and return a stub with :Play()/:Stop().)

      UI.MaskTexture(texture[, maskPath]) -> mask     (defaults to the diamond mask)

      UI.Hairline(parent[, opts]) -> line
          opts = { token="border", layer="ARTWORK", vertical=bool }
          1px physical rule, pixel-snapped; re-snaps on UI_SCALE_CHANGED/DISPLAY_SIZE_CHANGED.

      UI.PaintLedgerGround(frame[, opts]) -> painter   (grain + vignette + bronze keyline)
          opts = { grainToken="panel", grainAlpha=0.5, vignetteToken="ground",
                   keylineToken="bronze", keyline=true }
          LAYERING CONTRACT: paints BACKGROUND draw-layers ONLY. Text/numerals/hairlines
          must live on child frames with their own flat fill so glyphs never sit on grain
          (BRAND_SPEC §4 "never under text").

      UI.MakerMark(parent[, opts]) -> mark             (bronze diamond frame + crimson "D")
          opts = { size=20 }.  Titlebar hallmark only (BRAND_SPEC §4/§5 one per window).

      UI.GetCeremonialFont(size) -> FontObject          (MORPHEUS, size clamped >= 16)
      UI.LedgerSelfTest() -> ok, report                 (theme-token completeness)
      UI.PrintKitDebug()                                (dumps primitives + active tokens)

    New font roles on UI.fonts (added in theme.lua, listed here for callers):
      UI.fonts.ceremonial  — MORPHEUS >=16, ceremonial titles ONLY
      UI.fonts.microLabel  — ARIALN, uppercase letter-spaced micro-labels (caller uppercases)
      UI.fonts.numeral     — ARIALN + OUTLINE, telemetry numerals (countdowns/values)
--]]

local ADDON = ...
local UI = DaseekiUI

-- Asset paths (shipped under Core/textures/, power-of-two, brand-original).
UI.TEX_GRAIN   = "Interface\\AddOns\\Daseeki-Core\\textures\\ledger-grain"
UI.TEX_DIAMOND = "Interface\\AddOns\\Daseeki-Core\\textures\\diamond-mask"
local WHITE    = "Interface\\Buttons\\WHITE8X8"

-- Brighten a token color toward white (never darkens). t in 0..1 = fraction of the
-- remaining headroom to white. Used for the urgency-brighten law (BRAND_SPEC §7/§8).
local function brighten(r, g, b, t)
    t = t or 0.35
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

-- ════════════════════════════════════════════════════════════════════════════
--  1 ── UI.MakeStatusBar — native StatusBar, smooth fill, optional spark, brighten
-- ════════════════════════════════════════════════════════════════════════════
function UI.MakeStatusBar(parent, opts)
    opts = opts or {}
    local bar = CreateFrame("StatusBar", nil, parent)
    if opts.width  then bar:SetWidth(opts.width)   end
    bar:SetHeight(opts.height or 14)
    local minV, maxV = opts.min or 0, opts.max or 1
    bar:SetMinMaxValues(minV, maxV)

    bar:SetStatusBarTexture(WHITE)              -- flat fill; color comes from token
    local fillTex = bar:GetStatusBarTexture()
    local fillToken = opts.fillToken or "brand"
    local bgToken   = opts.bgToken or "inset"

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)

    -- Optional spark riding the fill edge — the HUD's only continuous motion (§8).
    local spark
    if opts.spark then
        spark = bar:CreateTexture(nil, "OVERLAY")
        spark:SetTexture(WHITE)
        spark:SetBlendMode("ADD")
        spark:SetWidth(2)
    end

    -- Optional live text readout ("Rend 41:04", "Onyxia (H): Open") — approved keep (§7).
    local textFS
    if opts.text then
        textFS = bar:CreateFontString(nil, "OVERLAY")
        textFS:SetFontObject(UI.fonts[opts.textFont or "numeral"] or UI.fonts.body)
        textFS:SetPoint("LEFT", bar, "LEFT", 4, 0)
        textFS:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
        textFS:SetJustifyH(opts.textJustify or "LEFT")
        bar._textFS = textFS
    end

    bar._urgent = false
    -- Single skin closure: applies tokens now, on every ThemeChanged (via UI.Skin), and
    -- on SetUrgent. Urgency re-applies inside so a brightened bar stays brightened across
    -- a live theme switch. Brighten NEVER dims (BRAND_SPEC §7/§8).
    bar.__reskin = function(self)
        local fr, fg, fb = UI.Color(fillToken)
        if self._urgent then fr, fg, fb = brighten(fr, fg, fb) end
        self:SetStatusBarColor(fr, fg, fb)
        bg:SetColorTexture(UI.Color(bgToken))
        if spark then spark:SetVertexColor(brighten(fr, fg, fb, 0.5)) end
        if textFS then
            local tr, tg, tb = UI.Color("text")
            if self._urgent then tr, tg, tb = brighten(tr, tg, tb) end
            textFS:SetTextColor(tr, tg, tb)
        end
    end
    UI.Skin(bar, bar.__reskin)

    -- Smooth value interpolation: tween a frame value toward the target each OnUpdate.
    -- Own-code lerp (not the native SetValue interpolation arg) so behavior is identical
    -- on every 1.15 client and the spark can be positioned from the tweened value.
    bar._val    = opts.value or minV
    bar._target = bar._val
    bar:SetValue(bar._val)
    local SPEED = opts.speed or 8           -- higher = snappier approach
    local EPS   = (maxV - minV) * 0.0005

    local function positionSpark()
        if not spark then return end
        local lo, hi = bar:GetMinMaxValues()
        local frac = (hi > lo) and ((bar._val - lo) / (hi - lo)) or 0
        frac = math.max(0, math.min(1, frac))
        local w = bar:GetWidth() or 0
        if w <= 0 or frac <= 0 or frac >= 1 then spark:Hide(); return end
        spark:ClearAllPoints()
        spark:SetPoint("TOP", bar, "TOPLEFT", w * frac, 0)
        spark:SetPoint("BOTTOM", bar, "BOTTOMLEFT", w * frac, 0)
        spark:Show()
    end

    bar:SetScript("OnUpdate", function(self, dt)
        if self._val == self._target then return end
        local d = self._target - self._val
        if math.abs(d) <= EPS then
            self._val = self._target
        else
            self._val = self._val + d * math.min(1, dt * SPEED)
        end
        self:SetValue(self._val)
        positionSpark()
    end)

    function bar:SetBarValue(v, immediate)
        local lo, hi = self:GetMinMaxValues()
        v = math.max(lo, math.min(hi, v or lo))
        self._target = v
        if immediate then
            self._val = v
            self:SetValue(v)
            positionSpark()
        end
    end
    function bar:GetBarValue() return self._target end
    function bar:SetBarRange(lo, hi)
        self:SetMinMaxValues(lo, hi)
        self:SetBarValue(self._target, true)
    end
    function bar:SetBarText(s) if self._textFS then self._textFS:SetText(s or "") end end
    -- Brighten fill + text; NEVER dims (idempotent; false restores base tokens).
    function bar:SetUrgent(on)
        on = on and true or false
        if self._urgent == on then return end
        self._urgent = on
        self.__reskin(self)
    end

    positionSpark()
    bar.uiHeight = opts.height or 14
    if opts.width then bar.uiWidth = opts.width end
    bar._fillWidth = opts.width and nil or true
    return bar
end

-- ════════════════════════════════════════════════════════════════════════════
--  2 ── UI.Animate — 120ms fade/scale helpers (CreateAnimationGroup + no-op fallback)
-- ════════════════════════════════════════════════════════════════════════════
local ANIM_CAP = 120   -- BRAND_SPEC §8: transitions <=120ms
local HAS_ANIM = type(CreateFrame) == "function"
do
    -- Probe once: does the frame type expose CreateAnimationGroup on this client?
    local probe = CreateFrame("Frame")
    HAS_ANIM = probe.CreateAnimationGroup ~= nil
end

local function capMs(ms) return math.min(ANIM_CAP, ms or ANIM_CAP) / 1000 end

-- Reuse ONE kit-owned group per frame per kind so repeated calls don't leak groups.
local function kitGroup(frame, key, builder)
    frame.__anim = frame.__anim or {}
    local g = frame.__anim[key]
    if not g then
        g = frame:CreateAnimationGroup()
        frame.__anim[key] = g
    end
    g:Stop()
    -- clear prior child anims by re-creating lazily is costly; instead reuse stored anim
    return g
end

UI.Animate = UI.Animate or {}

if HAS_ANIM then
    function UI.Animate.FadeIn(frame, ms)
        local g = kitGroup(frame, "fade")
        local a = g.__a or g:CreateAnimation("Alpha"); g.__a = a
        a:SetFromAlpha(frame:GetAlpha() or 0)
        a:SetToAlpha(1)
        a:SetDuration(capMs(ms))
        g:SetScript("OnFinished", function() frame:SetAlpha(1) end)
        frame:SetAlpha(frame:GetAlpha() or 0)
        frame:Show()
        g:Play()
        return g
    end
    function UI.Animate.FadeOut(frame, ms, hide)
        local g = kitGroup(frame, "fade")
        local a = g.__a or g:CreateAnimation("Alpha"); g.__a = a
        a:SetFromAlpha(frame:GetAlpha() or 1)
        a:SetToAlpha(0)
        a:SetDuration(capMs(ms))
        g:SetScript("OnFinished", function()
            frame:SetAlpha(0)
            if hide ~= false then frame:Hide() end
        end)
        g:Play()
        return g
    end
    function UI.Animate.ScaleReveal(frame, ms)
        local g = kitGroup(frame, "reveal")
        local s = g.__s or g:CreateAnimation("Scale"); g.__s = s
        local a = g.__a or g:CreateAnimation("Alpha"); g.__a = a
        s:SetScaleFrom(0.95, 0.95)
        s:SetScaleTo(1, 1)
        s:SetOrigin("CENTER", 0, 0)
        s:SetDuration(capMs(ms))
        a:SetFromAlpha(0)
        a:SetToAlpha(1)
        a:SetDuration(capMs(ms))
        g:SetScript("OnFinished", function() frame:SetAlpha(1); frame:SetScale(1) end)
        frame:SetAlpha(0)
        frame:Show()
        g:Play()
        return g
    end
    function UI.Animate.Stop(frame)
        if frame.__anim then for _, g in pairs(frame.__anim) do g:Stop() end end
    end
else
    -- No-op fallback: snap to final visual state, return a stub honoring :Play()/:Stop().
    local STUB = { Play = function() end, Stop = function() end,
                   SetScript = function() end, IsPlaying = function() return false end }
    local function stub() return STUB end
    function UI.Animate.FadeIn(frame)  frame:SetAlpha(1); frame:Show(); return stub() end
    function UI.Animate.FadeOut(frame, _, hide) frame:SetAlpha(0); if hide ~= false then frame:Hide() end; return stub() end
    function UI.Animate.ScaleReveal(frame) frame:SetAlpha(1); frame:Show(); return stub() end
    function UI.Animate.Stop() end
end
UI.Animate.available = HAS_ANIM

-- ════════════════════════════════════════════════════════════════════════════
--  3 ── UI.MaskTexture — attach a mask (default: the suite diamond) to a texture
-- ════════════════════════════════════════════════════════════════════════════
function UI.MaskTexture(texture, maskPath)
    local host = texture:GetParent()
    local mask = host:CreateMaskTexture()
    mask:SetAllPoints(texture)
    -- CLAMPTOBLACKADDITIVE keeps the region outside the mask fully clipped.
    mask:SetTexture(maskPath or UI.TEX_DIAMOND, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    texture:AddMaskTexture(mask)
    return mask
end

-- ════════════════════════════════════════════════════════════════════════════
--  4 ── UI.Hairline — 1px physical, pixel-snapped, re-snaps on scale/resize
-- ════════════════════════════════════════════════════════════════════════════
-- Shared driver: one frame listens for the two display events and re-snaps every live
-- hairline (dead ones self-prune). Verified events: Event.UI.UiScaleChanged ==
-- "UI_SCALE_CHANGED"; Event.Video.DisplaySizeChanged == "DISPLAY_SIZE_CHANGED".
local hairlines = {}
local snapDriver = CreateFrame("Frame")
snapDriver:RegisterEvent("UI_SCALE_CHANGED")
snapDriver:RegisterEvent("DISPLAY_SIZE_CHANGED")

-- One physical pixel expressed in `frame`'s local coordinate units (mirrors Blizzard's
-- PixelUtil math: uiUnitPerPixel = 768/physicalHeight, then / effective scale).
local function onePixel(frame)
    local _, physH = GetPhysicalScreenSize()
    if not physH or physH <= 0 then physH = 1080 end
    local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
    if scale <= 0 then scale = 1 end
    return (768 / physH) / scale
end

snapDriver:SetScript("OnEvent", function()
    for line in pairs(hairlines) do
        if line.__dead then hairlines[line] = nil
        elseif line._snap then line._snap() end
    end
end)

function UI.Hairline(parent, opts)
    opts = opts or {}
    local vertical = opts.vertical and true or false
    local line = parent:CreateTexture(nil, opts.layer or "ARTWORK")
    line:SetTexture(WHITE)
    -- Crisp-edge setup per the deliverable contract.
    line:SetSnapToPixelGrid(true)
    line:SetTexelSnappingBias(0)

    local token = opts.token or "border"
    UI.Skin(line, function(self) self:SetColorTexture(UI.Color(token)) end)

    line._snap = function()
        local px = onePixel(parent)
        if vertical then line:SetWidth(px) else line:SetHeight(px) end
    end
    line._snap()
    -- Effective scale is only reliable once realized; re-snap on first show + defer once.
    parent:HookScript("OnShow", line._snap)
    if C_Timer and C_Timer.After then C_Timer.After(0, line._snap) end

    hairlines[line] = true
    -- mark dead when the parent is released, if the caller sets __dead (mirrors UI.Skin)
    return line
end

-- ════════════════════════════════════════════════════════════════════════════
--  5 ── UI.PaintLedgerGround — grain substrate + aged-edge vignette + bronze keyline
-- ════════════════════════════════════════════════════════════════════════════
-- LAYERING CONTRACT (BRAND_SPEC §4): everything here is BACKGROUND draw-layer. Callers
-- put text/numerals on child frames with a flat fill so grain never sits under glyphs.
function UI.PaintLedgerGround(frame, opts)
    opts = opts or {}
    local painter = frame.__ledgerGround
    if not painter then
        painter = {}
        -- grain overlay (tiled), tinted by SetVertexColor; low alpha keeps amplitude tiny
        local grain = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
        grain:SetTexture(UI.TEX_GRAIN, "REPEAT", "REPEAT")
        grain:SetAllPoints(frame)
        grain:SetHorizTile(true)
        grain:SetVertTile(true)
        painter.grain = grain

        -- aged-edge vignette: four inward-fading darkened bars (no extra asset).
        painter.vig = {
            top    = frame:CreateTexture(nil, "BACKGROUND", nil, 2),
            bottom = frame:CreateTexture(nil, "BACKGROUND", nil, 2),
            left   = frame:CreateTexture(nil, "BACKGROUND", nil, 2),
            right  = frame:CreateTexture(nil, "BACKGROUND", nil, 2),
        }
        local VIG = 14
        local v = painter.vig
        v.top:SetTexture(WHITE);    v.top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);        v.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);       v.top:SetHeight(VIG)
        v.bottom:SetTexture(WHITE); v.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0); v.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0); v.bottom:SetHeight(VIG)
        v.left:SetTexture(WHITE);   v.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -VIG);     v.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, VIG);  v.left:SetWidth(VIG)
        v.right:SetTexture(WHITE);  v.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -VIG);  v.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, VIG); v.right:SetWidth(VIG)

        -- 1px bronze keyline (four pixel-snapped edges) — ONE per window (§4/§5).
        painter.keyline = {
            UI.Hairline(frame, { token = opts.keylineToken or "bronze", layer = "BORDER" }),
            UI.Hairline(frame, { token = opts.keylineToken or "bronze", layer = "BORDER" }),
            UI.Hairline(frame, { token = opts.keylineToken or "bronze", layer = "BORDER", vertical = true }),
            UI.Hairline(frame, { token = opts.keylineToken or "bronze", layer = "BORDER", vertical = true }),
        }
        local k = painter.keyline
        k[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);     k[1]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        k[2]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0); k[2]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        k[3]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);     k[3]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        k[4]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);   k[4]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

        frame.__ledgerGround = painter
    end

    local grainToken   = opts.grainToken or "panel"
    local grainAlpha   = opts.grainAlpha or 0.5
    local vigToken     = opts.vignetteToken or "ground"
    local showKeyline  = opts.keyline ~= false

    UI.Skin(frame, function()
        painter.grain:SetVertexColor(UI.Color(grainToken))
        painter.grain:SetAlpha(grainAlpha)
        local vr, vg, vb = UI.Color(vigToken)
        for edge, t in pairs(painter.vig) do
            local horiz = (edge == "top" or edge == "bottom")
            -- darken inward: opaque at the edge -> transparent toward center
            local o = (edge == "top" or edge == "left")
            local orient = horiz and "VERTICAL" or "HORIZONTAL"
            local c0 = CreateColor and CreateColor(vr, vg, vb, 0.55) or { r=vr, g=vg, b=vb, a=0.55 }
            local c1 = CreateColor and CreateColor(vr, vg, vb, 0.0)  or { r=vr, g=vg, b=vb, a=0.0 }
            if edge == "top" or edge == "left" then
                t:SetGradient(orient, c0, c1)
            else
                t:SetGradient(orient, c1, c0)
            end
        end
        for _, ln in ipairs(painter.keyline) do
            ln:SetShown(showKeyline)
        end
    end)
    return painter
end

-- ════════════════════════════════════════════════════════════════════════════
--  6 ── UI.MakerMark — bronze rotated-square frame + crimson MORPHEUS "D" (titlebar)
-- ════════════════════════════════════════════════════════════════════════════
function UI.MakerMark(parent, opts)
    opts = opts or {}
    local sz = opts.size or 20
    local mark = CreateFrame("Frame", nil, parent)
    mark:SetSize(sz, sz)

    local RAD = math.rad(45)
    -- outer bronze diamond (solid square rotated 45)
    local outer = mark:CreateTexture(nil, "ARTWORK")
    outer:SetTexture(WHITE)
    outer:SetSize(sz * 0.72, sz * 0.72)
    outer:SetPoint("CENTER")
    outer:SetRotation(RAD)
    -- inner ground diamond, 1px smaller each side -> leaves a thin bronze ring outline
    local inner = mark:CreateTexture(nil, "ARTWORK")
    inner:SetTexture(WHITE)
    inner:SetSize(sz * 0.72 - 3, sz * 0.72 - 3)
    inner:SetPoint("CENTER")
    inner:SetRotation(RAD)
    inner:SetDrawLayer("ARTWORK", 1)
    -- crimson ceremonial "D" (not rotated), centered in the diamond
    local d = mark:CreateFontString(nil, "OVERLAY")
    d:SetFontObject(UI.GetCeremonialFont(math.max(16, math.floor(sz * 0.8))))
    d:SetPoint("CENTER", mark, "CENTER", 0, 0)
    d:SetText("D")

    UI.Skin(mark, function()
        outer:SetColorTexture(UI.Color(opts.frameToken or "bronze"))
        inner:SetColorTexture(UI.Color(opts.innerToken or "ground"))
        d:SetTextColor(UI.Color(opts.letterToken or "brand"))
    end)

    mark.uiHeight, mark.uiWidth = sz, sz
    return mark
end

-- ════════════════════════════════════════════════════════════════════════════
--  7 ── Ceremonial font getter (MORPHEUS, size clamped >= 16)
-- ════════════════════════════════════════════════════════════════════════════
UI._ceremonialCache = UI._ceremonialCache or {}
function UI.GetCeremonialFont(size)
    local s = math.max(16, math.floor(size or 16))   -- >=16 floor (BRAND_SPEC §3/§7)
    local f = UI._ceremonialCache[s]
    if not f then
        f = CreateFont("DaseekiUICeremonial" .. s)
        UI._ceremonialCache[s] = f
    end
    f:SetFont("Fonts\\MORPHEUS.TTF", s, "")
    f:SetTextColor(UI.Color("text"))
    return f
end
-- Re-tint cached ceremonial fonts whenever the theme changes.
UI.OnThemeChanged(function()
    for _, f in pairs(UI._ceremonialCache) do f:SetTextColor(UI.Color("text")) end
end)

-- ════════════════════════════════════════════════════════════════════════════
--  8 ── Theme-token completeness self-test + debug dump
-- ════════════════════════════════════════════════════════════════════════════
-- Every token every theme must define (color + spacing + font + the new ledger tokens).
UI.REQUIRED_TOKENS = {
    "ground","panel","raised","inset","border","borderLite","control","controlBorder",
    "accent","accentDim","brand","brandBright","bronze","bronzeDim","idle",
    "text","muted","faint","ok","warn","danger",
    "rowGap","sectionGap","contentMaxW",
    "headerFace","headerSize","bodyFace","bodySize","smallSize",
}

function UI.LedgerSelfTest()
    local ok, lines = true, {}
    for _, name in ipairs(UI.GetThemeNames()) do
        local tokens = UI.themes[name]
        local missing = {}
        for _, key in ipairs(UI.REQUIRED_TOKENS) do
            if tokens[key] == nil then missing[#missing + 1] = key end
        end
        if #missing > 0 then
            ok = false
            lines[#lines + 1] = name .. " MISSING: " .. table.concat(missing, ", ")
        else
            lines[#lines + 1] = name .. " OK (" .. #UI.REQUIRED_TOKENS .. " tokens)"
        end
    end
    return ok, lines
end

local function hex(name)
    local r, g, b = UI.Color(name)
    if type(UI.Token(name)) ~= "table" then return tostring(UI.Token(name)) end
    return string.format("#%02X%02X%02X", r * 255, g * 255, b * 255)
end

function UI.PrintKitDebug()
    local P = "|cff00ccff[Ledger Kit]|r "
    print(P .. "Phase-0 primitives:")
    local prims = {
        "MakeStatusBar", "MaskTexture", "Hairline", "PaintLedgerGround",
        "MakerMark", "GetCeremonialFont",
    }
    for _, n in ipairs(prims) do
        print(P .. "  UI." .. n .. " " .. (type(UI[n]) == "function" and "|cff82bf6b✓|r" or "|cffcf5d4a✗|r"))
    end
    print(P .. "  UI.Animate " .. (UI.Animate and "|cff82bf6b✓|r" or "|cffcf5d4a✗|r") ..
          " (native=" .. tostring(UI.Animate and UI.Animate.available) .. ")")
    for _, n in ipairs({ "ceremonial", "microLabel", "numeral" }) do
        print(P .. "  UI.fonts." .. n .. " " .. (UI.fonts[n] and "|cff82bf6b✓|r" or "|cffcf5d4a✗|r"))
    end
    print(P .. "Active theme: |cffece3d0" .. tostring(UI.GetThemeName()) .. "|r")
    for _, n in ipairs({ "brand", "brandBright", "bronze", "bronzeDim", "idle", "accent" }) do
        print(P .. "  " .. n .. " = " .. hex(n))
    end
    local ok, lines = UI.LedgerSelfTest()
    print(P .. "Token completeness: " .. (ok and "|cff82bf6bALL THEMES OK|r" or "|cffcf5d4aFAILURES|r"))
    for _, l in ipairs(lines) do print(P .. "  " .. l) end
end
