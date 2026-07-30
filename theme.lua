--[[
    Daseeki Core — DaseekiUI theme-token system.

    Every visual constant in the DaseekiUI framework lives in a named token table.
    Widgets NEVER hardcode a color or font — they read tokens at render and re-skin
    live on ThemeChanged (no /reload). A theme is DATA, not code:

        DaseekiUI.RegisterTheme(name, tokens)   -- add / override a palette
        DaseekiUI.SetTheme(name)                -- activate + persist + re-skin
        DaseekiUI.GetThemeName()                -- active theme name
        DaseekiUI.GetThemeNames()               -- registered names (register order)
        DaseekiUI.Color(name[, alphaOverride])  -> r, g, b, a   (active theme)
        DaseekiUI.Token(name)                   -> raw token value (number/table/string)
        DaseekiUI.OnThemeChanged(fn)            -- register a re-skin callback

    Color tokens are {r, g, b[, a]} in 0..1. Spacing tokens are numbers. Font tokens
    are a face path + size; the framework's shared FontObjects are re-tinted on every
    theme change so any FontString using them re-colors for free.
--]]

local ADDON, Core = ...

-- Public library namespace (owner-approved: DaseekiUI is the wave-2/3 public API).
DaseekiUI      = DaseekiUI or {}
_G.DaseekiUI   = DaseekiUI
Core.UI        = DaseekiUI
local UI       = DaseekiUI

UI.themes      = UI.themes or {}     -- name -> merged token table
UI._themeOrder = UI._themeOrder or {}
UI._active     = UI._active or nil   -- active token table
UI._activeName = UI._activeName or nil
UI._skins      = UI._skins or {}     -- ordered list of re-skin callbacks

-- Friz Quadrata is the game's serif-capable titling face — closest match to the
-- Classic Era quest/section titling the design asks for. Body text reuses it at a
-- smaller size (the default WoW UI face), so headers read as titling by size+color.
local FACE_SERIF = "Fonts\\FRIZQT__.TTF"
local FACE_BODY  = "Fonts\\FRIZQT__.TTF"

-- ── Default token table ───────────────────────────────────────────────────────
-- RegisterTheme merges a (possibly partial) palette over this, so a theme only has
-- to state what it changes. Defaults double as the "Ashenvale Gold" warm palette.
local DEFAULT_TOKENS = {
    ground     = { 0.0863, 0.0745, 0.0588 }, -- #16130F  window ground
    panel      = { 0.1176, 0.1020, 0.0784 }, -- #1E1A14  panels / content
    raised     = { 0.1490, 0.1294, 0.0980 }, -- #262119  raised cards / hover
    inset      = { 0.0706, 0.0627, 0.0471 }, -- #12100C  sunken inputs
    border     = { 0.2353, 0.2039, 0.1490 }, -- #3C3426  default hairline border
    borderLite = { 0.3020, 0.2627, 0.1922 }, -- #4D4331  lighter border / dividers
    accent     = { 0.7882, 0.6353, 0.3020 }, -- #C9A24D  accent (headers, selection)
    accentDim  = { 0.5412, 0.4471, 0.2235 }, -- #8A7239  dim accent
    text       = { 0.9137, 0.8784, 0.8039 }, -- #E9E0CD  primary text
    muted      = { 0.6039, 0.5608, 0.4745 }, -- #9A8F79  secondary text
    faint      = { 0.4275, 0.3922, 0.3137 }, -- #6D6450  faint text / disabled
    ok         = { 0.5098, 0.7490, 0.4196 }, -- #82BF6B  positive / on
    danger     = { 0.8118, 0.3647, 0.2902 }, -- #CF5D4A  destructive / off
    warn       = { 0.9600, 0.7600, 0.1800 }, -- #F5C22E  caution / below-normal (amber-gold)

    -- Field Ledger tokens (NEW; every theme defines them so no consumer breaks on a
    -- missing key). Legacy default keeps a GOLD seal — per BRAND_SPEC §2, gold survives
    -- inside legacy themes. brand=theme selection color; bronze=metallic keyline;
    -- idle=calm/owned neutral. These re-derive per theme (accent / accentDim / faint).
    brand      = { 0.7882, 0.6353, 0.3020 }, -- = accent (gold seal in the legacy theme)
    brandBright= { 0.8623, 0.7629, 0.5463 }, -- accent brightened toward white (urgency)
    bronze     = { 0.5412, 0.4471, 0.2235 }, -- = accentDim (keyline/ornament ONLY)
    bronzeDim  = { 0.3788, 0.3130, 0.1565 }, -- bronze * 0.7 (dim ornament)
    idle       = { 0.4275, 0.3922, 0.3137 }, -- = faint (calm/owned/held state)

    -- control surfaces (contrast step-up): button/input/list/card fills & borders
    -- read as controls at in-game gamma — brighter than raised/borderLite, same warmth.
    control       = { 0.1961, 0.1686, 0.1255 }, -- #322B20  raised control fill (vs raised #262119)
    controlBorder = { 0.4157, 0.3608, 0.2510 }, -- #6A5C40  control border (vs borderLite #4D4331)

    -- spacing (owner-approved constants; single source of truth)
    rowGap     = 10,
    sectionGap = 22,

    -- max composed content width; panes lay blocks within min(paneInnerW, contentMaxW)
    contentMaxW = 880,

    -- fonts
    headerFace = FACE_SERIF, headerSize = 15,
    bodyFace   = FACE_BODY,  bodySize   = 12,
    smallSize  = 11,
}

-- ── Token / color accessors ───────────────────────────────────────────────────
function UI.Token(name)
    local t = UI._active or DEFAULT_TOKENS
    local v = t[name]
    if v == nil then v = DEFAULT_TOKENS[name] end
    return v
end

-- Returns r, g, b, a from the active theme. `alpha` overrides the token's own alpha.
function UI.Color(name, alpha)
    local c = UI.Token(name)
    if type(c) ~= "table" then return 1, 1, 1, alpha or 1 end
    return c[1] or 1, c[2] or 1, c[3] or 1, alpha or c[4] or 1
end

-- ── Shared FontObjects (re-tinted per theme) ──────────────────────────────────
local function newFont(name) return _G[name] or CreateFont(name) end
UI.fonts = UI.fonts or {
    header = newFont("DaseekiUIFontHeader"),
    body   = newFont("DaseekiUIFontBody"),
    muted  = newFont("DaseekiUIFontMuted"),
    small  = newFont("DaseekiUIFontSmall"),
    accent = newFont("DaseekiUIFontAccent"),
    danger = newFont("DaseekiUIFontDanger"),
    -- Field Ledger type roles (NEW; existing keys above are untouched). MORPHEUS is
    -- ceremonial (>=16 floor), ARIALN for uppercase micro-labels and outlined numerals
    -- (BRAND_SPEC §3). Faces ship with every WoW client (zero shipped fonts, §3).
    ceremonial = newFont("DaseekiUIFontCeremonial"),
    microLabel = newFont("DaseekiUIFontMicroLabel"),
    numeral    = newFont("DaseekiUIFontNumeral"),
}

-- Ledger face + size constants (ceremonial size honors the >=16 floor; the runtime
-- getter UI.GetCeremonialFont clamps requested sizes too).
local FACE_CEREMONIAL = "Fonts\\MORPHEUS.TTF"
local FACE_CONDENSED  = "Fonts\\ARIALN.TTF"
local CEREMONIAL_SIZE = 16   -- >=16 floor (BRAND_SPEC §3/§7)
local MICRO_SIZE      = 11
local NUMERAL_SIZE    = 13

local function applyFonts()
    local hs, bs, ss = UI.Token("headerSize"), UI.Token("bodySize"), UI.Token("smallSize")
    local hf, bf     = UI.Token("headerFace"), UI.Token("bodyFace")
    UI.fonts.header:SetFont(hf, hs, "")
    UI.fonts.header:SetTextColor(UI.Color("accent"))
    UI.fonts.header:SetJustifyH("LEFT")
    UI.fonts.body:SetFont(bf, bs, "")
    UI.fonts.body:SetTextColor(UI.Color("text"))
    UI.fonts.body:SetJustifyH("LEFT")
    UI.fonts.muted:SetFont(bf, bs, "")
    UI.fonts.muted:SetTextColor(UI.Color("muted"))
    UI.fonts.muted:SetJustifyH("LEFT")
    UI.fonts.small:SetFont(bf, ss, "")
    UI.fonts.small:SetTextColor(UI.Color("muted"))
    UI.fonts.small:SetJustifyH("LEFT")
    UI.fonts.accent:SetFont(bf, bs, "")
    UI.fonts.accent:SetTextColor(UI.Color("accent"))
    UI.fonts.accent:SetJustifyH("LEFT")
    UI.fonts.danger:SetFont(bf, bs, "")
    UI.fonts.danger:SetTextColor(UI.Color("danger"))
    UI.fonts.danger:SetJustifyH("LEFT")

    -- Ledger roles (NEW). ceremonial: MORPHEUS >=16 in cream text; microLabel: ARIALN
    -- muted; numeral: ARIALN + OUTLINE in cream (telemetry values/countdowns).
    UI.fonts.ceremonial:SetFont(FACE_CEREMONIAL, math.max(16, CEREMONIAL_SIZE), "")
    UI.fonts.ceremonial:SetTextColor(UI.Color("text"))
    UI.fonts.ceremonial:SetJustifyH("LEFT")
    UI.fonts.microLabel:SetFont(FACE_CONDENSED, MICRO_SIZE, "")
    UI.fonts.microLabel:SetTextColor(UI.Color("muted"))
    UI.fonts.microLabel:SetJustifyH("LEFT")
    UI.fonts.numeral:SetFont(FACE_CONDENSED, NUMERAL_SIZE, "OUTLINE")
    UI.fonts.numeral:SetTextColor(UI.Color("text"))
    UI.fonts.numeral:SetJustifyH("LEFT")
end

-- ── ThemeChanged pub/sub ──────────────────────────────────────────────────────
function UI.OnThemeChanged(fn)
    if type(fn) == "function" then UI._skins[#UI._skins + 1] = fn end
end

local function fireThemeChanged()
    for _, fn in ipairs(UI._skins) do pcall(fn) end
end

-- ── Registration / activation ─────────────────────────────────────────────────
function UI.RegisterTheme(name, tokens)
    if type(name) ~= "string" then return end
    local merged = {}
    for k, v in pairs(DEFAULT_TOKENS) do merged[k] = v end
    if type(tokens) == "table" then
        for k, v in pairs(tokens) do merged[k] = v end
    end
    if not UI.themes[name] then UI._themeOrder[#UI._themeOrder + 1] = name end
    UI.themes[name] = merged
    return merged
end

function UI.SetTheme(name)
    local tokens = UI.themes[name]
    if not tokens then
        name   = UI._themeOrder[1]
        tokens = name and UI.themes[name]
    end
    if not tokens then return end
    UI._active     = tokens
    UI._activeName = name
    if Core.db then Core.db.theme = name end
    applyFonts()
    fireThemeChanged()
end

function UI.GetThemeName()  return UI._activeName end
function UI.GetThemeNames() return UI._themeOrder end

-- ── "Field Ledger" — the LOCKED default, registered FIRST ─────────────────────
-- Registration order IS the theme-picker order (UI.GetThemeNames) AND the SetTheme
-- fallback (_themeOrder[1]); Field Ledger must lead both, so its RegisterTheme runs
-- before every sibling. BRAND_SPEC §2 hexes, verbatim. Warm worn ink-on-parchment.
-- accent=brand crimson (selection/urgency; rubricated headers read as a field-ledger's
-- red headings); accentDim=bronzeDim (bronze keylines on buttons). Gold is retired here
-- (survives only in the legacy themes below, §2).
UI.RegisterTheme("Field Ledger", {
    ground        = { 0.0902, 0.0784, 0.0667 }, -- #171411
    panel         = { 0.1255, 0.1059, 0.0824 }, -- #201B15
    raised        = { 0.1647, 0.1412, 0.1098 }, -- #2A241C
    inset         = { 0.0706, 0.0627, 0.0471 }, -- #12100C  (flat, no grain)
    border        = { 0.1961, 0.1647, 0.1255 }, -- #322A20
    borderLite    = { 0.2706, 0.2275, 0.1686 }, -- #453A2B
    control       = { 0.1725, 0.1451, 0.1098 }, -- #2C251C
    controlBorder = { 0.2902, 0.2431, 0.1765 }, -- #4A3E2D  (cborder)
    accent        = { 0.7529, 0.2824, 0.2353 }, -- = brand (crimson; selection/urgency)
    accentDim     = { 0.4314, 0.3412, 0.1882 }, -- = bronzeDim (bronze keylines/borders)
    brand         = { 0.7529, 0.2824, 0.2353 }, -- #C0483C  wax crimson
    brandBright   = { 0.9098, 0.4196, 0.3529 }, -- #E86B5A  brighten target
    bronze        = { 0.6118, 0.4784, 0.2706 }, -- #9C7A45  keylines/ornament ONLY
    bronzeDim     = { 0.4314, 0.3412, 0.1882 }, -- #6E5730
    text          = { 0.9255, 0.8902, 0.8157 }, -- #ECE3D0
    muted         = { 0.6549, 0.6078, 0.5176 }, -- #A79B84  (>=4.5:1 on ground)
    faint         = { 0.4314, 0.3882, 0.3137 }, -- #6E6350
    idle          = { 0.3608, 0.3255, 0.2667 }, -- #5C5344  calm/owned state
    ok            = { 0.4824, 0.6510, 0.3686 }, -- #7BA65E
    warn          = { 0.8392, 0.6353, 0.2902 }, -- #D6A24A
    danger        = { 0.8078, 0.2902, 0.2196 }, -- #CE4A38  (its own red, != brand)
})

-- ── "Daseeki" — the owner's original suite look (dark mode + red, gold titles) ──
-- Reconstructed from the Daseeki-Bags 1.x skin: near-black window ground (skin
-- defaults.lua `color = {0,0,0,0.85}` and the button Bg `<Color r=0 g=0 b=0/>`),
-- stepped up for panel/raised the way every DaseekiUI theme steps its grounds; a
-- blood-red accent/border family for the owner's remembered "red accents"; and the
-- warm title gold {1,0.82,0} that Bags' Title uses (GameFontNormalLeft, per
-- skin/frame.lua) carried into warn + the bronze keyline. danger is pushed to
-- orange-red so destructive state never reads as the blood-red accent.
-- Placed right after Field Ledger; it does NOT change the default.
UI.RegisterTheme("Daseeki", {
    ground        = { 0.0471, 0.0392, 0.0392 }, -- #0C0A0A  near-black window ground (1.x {0,0,0} bg)
    panel         = { 0.0784, 0.0627, 0.0627 }, -- #141010  panels / content (stepped)
    raised        = { 0.1098, 0.0863, 0.0863 }, -- #1C1616  raised cards / hover
    inset         = { 0.0314, 0.0235, 0.0235 }, -- #080606  sunken inputs (below ground)
    border        = { 0.2275, 0.1176, 0.1176 }, -- #3A1E1E  dark blood-brown hairline
    borderLite    = { 0.3529, 0.1804, 0.1725 }, -- #5A2E2C  lighter blood-brown divider
    control       = { 0.1255, 0.0941, 0.0941 }, -- #201818  raised control fill (vs raised #1C1616)
    controlBorder = { 0.4314, 0.2275, 0.2118 }, -- #6E3A36  control border (vs borderLite #5A2E2C)
    accent        = { 0.7098, 0.1216, 0.1412 }, -- = brand (blood-red; headers/selection/urgency)
    accentDim     = { 0.4941, 0.0784, 0.0902 }, -- #7E1417  dim blood-red
    brand         = { 0.7098, 0.1216, 0.1412 }, -- #B51F24  Daseeki blood-red
    brandBright   = { 0.8392, 0.2941, 0.3098 }, -- #D64B4F  accent brightened toward white (urgency)
    bronze        = { 0.7804, 0.6078, 0.2314 }, -- #C79B3B  metallic gold keyline (1.x title gold, keyline weight)
    bronzeDim     = { 0.5451, 0.4235, 0.1608 }, -- #8B6C29  bronze * 0.7 (dim ornament)
    text          = { 0.9294, 0.9020, 0.8706 }, -- #EDE6DE  warm off-white primary text
    muted         = { 0.6549, 0.6118, 0.5765 }, -- #A79C93  secondary text (>=4.5:1 on ground)
    faint         = { 0.4314, 0.3843, 0.3529 }, -- #6E625A  faint text / disabled
    idle          = { 0.2902, 0.2510, 0.2353 }, -- #4A403C  calm/owned neutral (dark warm grey)
    ok            = { 0.3725, 0.7216, 0.4196 }, -- #5FB86B  positive green (readable on black, hue ~128)
    warn          = { 1.0000, 0.8196, 0.0000 }, -- #FFD100  the 1.x title gold, as warn/highlight (hue ~49)
    danger        = { 0.8784, 0.3333, 0.1569 }, -- #E05528  orange-red (hue ~15) — distinct from blood-red accent
})

-- ── Ship the legacy warm/cool themes (gold survives here only, §2) ─────────────
-- "Ashenvale Gold" is the warm-dark placeholder from the mockups (== defaults).
UI.RegisterTheme("Ashenvale Gold", nil)

-- "Neutral Slate" — cool desaturated blue-grey grounds with a steel accent.
UI.RegisterTheme("Neutral Slate", {
    ground     = { 0.0784, 0.0902, 0.1098 }, -- #14171C
    panel      = { 0.1098, 0.1255, 0.1529 }, -- #1C2027
    raised     = { 0.1490, 0.1686, 0.2000 }, -- #262B33
    inset      = { 0.0627, 0.0745, 0.0941 }, -- #101318
    border     = { 0.2118, 0.2392, 0.2784 }, -- #363D47
    borderLite = { 0.2902, 0.3255, 0.3804 }, -- #4A5361
    accent     = { 0.4980, 0.6588, 0.7882 }, -- #7FA8C9
    accentDim  = { 0.3373, 0.4784, 0.5882 }, -- #567A96
    text       = { 0.8627, 0.8863, 0.9176 }, -- #DCE2EA
    muted      = { 0.5412, 0.5804, 0.6353 }, -- #8A94A2
    faint      = { 0.3608, 0.4000, 0.4588 }, -- #5C6675
    ok         = { 0.4353, 0.7490, 0.5569 }, -- #6FBF8E
    danger     = { 0.8157, 0.4157, 0.3529 }, -- #D06A5A
    warn       = { 0.9098, 0.7020, 0.2431 }, -- #E8B33E  warm amber against cool slate

    -- Ledger tokens (re-derived: brand=accent, bronze=accentDim, idle=faint).
    brand      = { 0.4980, 0.6588, 0.7882 },
    brandBright= { 0.6737, 0.7782, 0.8623 },
    bronze     = { 0.3373, 0.4784, 0.5882 },
    bronzeDim  = { 0.2361, 0.3349, 0.4117 },
    idle       = { 0.3608, 0.4000, 0.4588 },

    -- control surfaces (contrast step-up) — brighter than raised/borderLite, same slate.
    control       = { 0.1843, 0.2078, 0.2471 }, -- #2F353F  (vs raised #262B33)
    controlBorder = { 0.3882, 0.4353, 0.5059 }, -- #636F81  (vs borderLite #4A5361)
})

-- ── Four WoW-flavored themes (round-5) ────────────────────────────────────────

-- "Orgrimmar Ember" — Horde forge-dark: umber-brown grounds, ember-orange accent,
-- parchment-warm text; danger is a cooler crimson so it never reads as the accent.
UI.RegisterTheme("Orgrimmar Ember", {
    ground     = { 0.0902, 0.0627, 0.0392 }, -- #17100A  dark umber ground
    panel      = { 0.1412, 0.0941, 0.0745 }, -- #241813
    raised     = { 0.1804, 0.1255, 0.1020 }, -- #2E201A
    inset      = { 0.0706, 0.0471, 0.0314 }, -- #120C08
    border     = { 0.2392, 0.1647, 0.1216 }, -- #3D2A1F
    borderLite = { 0.3216, 0.2235, 0.1647 }, -- #52392A
    accent     = { 0.9098, 0.4784, 0.1333 }, -- #E87A22  ember orange (hue ~27)
    accentDim  = { 0.6588, 0.3529, 0.0941 }, -- #A85A18
    text       = { 0.9294, 0.8863, 0.8000 }, -- #EDE2CC  parchment-warm
    muted      = { 0.6980, 0.6078, 0.4863 }, -- #B29B7C
    faint      = { 0.4863, 0.4078, 0.3216 }, -- #7C6852
    ok         = { 0.4353, 0.7098, 0.3373 }, -- #6FB556  positive green (hue ~104)
    danger     = { 0.7686, 0.1922, 0.2745 }, -- #C43146  cooler crimson (hue ~351)
    warn       = { 0.9490, 0.7569, 0.3059 }, -- #F2C14E  golden-yellow, pushed off the ember accent (hue ~45)

    -- Ledger tokens (re-derived: brand=accent, bronze=accentDim, idle=faint).
    brand      = { 0.9098, 0.4784, 0.1333 },
    brandBright= { 0.9414, 0.6610, 0.4366 },
    bronze     = { 0.6588, 0.3529, 0.0941 },
    bronzeDim  = { 0.4612, 0.2470, 0.0659 },
    idle       = { 0.4863, 0.4078, 0.3216 },

    -- control surfaces (contrast step-up) — brighter than raised/borderLite, same umber.
    control       = { 0.2000, 0.1333, 0.1020 }, -- #33221A  (vs raised #2E201A)
    controlBorder = { 0.4196, 0.2902, 0.2039 }, -- #6B4A34  (vs borderLite #52392A)
})

-- "Stormwind Regalia" — Alliance royal: midnight-navy grounds, royal-blue accent with a
-- gold-leaning dim accent (the blue+gold heraldry read), cool-white text.
UI.RegisterTheme("Stormwind Regalia", {
    ground     = { 0.0471, 0.0706, 0.1255 }, -- #0C1220  midnight navy
    panel      = { 0.0745, 0.1098, 0.1882 }, -- #131C30
    raised     = { 0.1059, 0.1490, 0.2471 }, -- #1B263F
    inset      = { 0.0353, 0.0549, 0.0980 }, -- #090E19
    border     = { 0.1490, 0.2000, 0.2863 }, -- #263349
    borderLite = { 0.2157, 0.2784, 0.3725 }, -- #37475F
    accent     = { 0.3059, 0.4824, 0.8392 }, -- #4E7BD6  royal blue (hue ~220)
    accentDim  = { 0.7882, 0.6353, 0.3020 }, -- #C9A24D  gold-leaning dim accent
    text       = { 0.9176, 0.9333, 0.9647 }, -- #EAEEF6  cool white
    muted      = { 0.6039, 0.6510, 0.7373 }, -- #9AA6BC
    faint      = { 0.4118, 0.4627, 0.5725 }, -- #697692
    ok         = { 0.3725, 0.7216, 0.4980 }, -- #5FB87F  positive green
    danger     = { 0.8157, 0.3412, 0.2980 }, -- #D0574C
    warn       = { 0.9412, 0.7686, 0.2353 }, -- #F0C43C  brighter yellow-gold, distinct from the gold accentDim

    -- Ledger tokens (re-derived: brand=accent, bronze=accentDim[gold], idle=faint).
    brand      = { 0.3059, 0.4824, 0.8392 },
    brandBright= { 0.5488, 0.6636, 0.8955 },
    bronze     = { 0.7882, 0.6353, 0.3020 },
    bronzeDim  = { 0.5517, 0.4447, 0.2114 },
    idle       = { 0.4118, 0.4627, 0.5725 },

    -- control surfaces (contrast step-up) — brighter than raised/borderLite, same navy.
    control       = { 0.1176, 0.1608, 0.2471 }, -- #1E293F  (vs raised #1B263F)
    controlBorder = { 0.2627, 0.3451, 0.4784 }, -- #43587A  (vs borderLite #37475F)
})

-- "Felwood" — fel corruption: near-black green-tinted grounds, toxic fel-green accent;
-- ok is shifted to teal so on-state stays distinct from the accent, danger red pops.
UI.RegisterTheme("Felwood", {
    ground     = { 0.0431, 0.0706, 0.0471 }, -- #0B120C  near-black, green-tinted
    panel      = { 0.0706, 0.1098, 0.0745 }, -- #121C13
    raised     = { 0.0980, 0.1529, 0.1020 }, -- #19271A
    inset      = { 0.0314, 0.0588, 0.0353 }, -- #080F09
    border     = { 0.1451, 0.2157, 0.1490 }, -- #253726
    borderLite = { 0.2157, 0.3137, 0.2275 }, -- #37503A
    accent     = { 0.5255, 0.8314, 0.1686 }, -- #86D42B  fel green (hue ~88)
    accentDim  = { 0.3529, 0.5804, 0.1255 }, -- #5A9420
    text       = { 0.8941, 0.9373, 0.8667 }, -- #E4EFDD  pale green-white
    muted      = { 0.6275, 0.7020, 0.6039 }, -- #A0B39A
    faint      = { 0.4118, 0.4627, 0.3961 }, -- #697665
    ok         = { 0.2471, 0.7216, 0.6039 }, -- #3FB89A  teal on-state (hue ~165, off the accent)
    danger     = { 0.8392, 0.2588, 0.1961 }, -- #D64232  red pops (hue ~6)
    warn       = { 0.8784, 0.7059, 0.1608 }, -- #E0B429  amber (hue ~45), clear of the fel-green accent and teal ok

    -- Ledger tokens (re-derived: brand=accent, bronze=accentDim, idle=faint).
    brand      = { 0.5255, 0.8314, 0.1686 },
    brandBright= { 0.6916, 0.8904, 0.4596 },
    bronze     = { 0.3529, 0.5804, 0.1255 },
    bronzeDim  = { 0.2470, 0.4063, 0.0879 },
    idle       = { 0.4118, 0.4627, 0.3961 },

    -- control surfaces (contrast step-up) — brighter than raised/borderLite, same fel tint.
    control       = { 0.1216, 0.1804, 0.1137 }, -- #1F2E1D  (vs raised #19271A)
    controlBorder = { 0.2784, 0.3765, 0.2353 }, -- #47603C  (vs borderLite #37503A)
})

-- "Winterspring Frost" — icy tundra: dark blue-slate grounds (darker and bluer than
-- Neutral Slate), pale ice-blue accent, frosty cool-white text.
UI.RegisterTheme("Winterspring Frost", {
    ground     = { 0.0431, 0.0627, 0.0980 }, -- #0B1019  dark blue-slate (darker+bluer than Slate)
    panel      = { 0.0706, 0.1020, 0.1569 }, -- #121A28
    raised     = { 0.1020, 0.1412, 0.2118 }, -- #1A2436
    inset      = { 0.0314, 0.0471, 0.0745 }, -- #080C13
    border     = { 0.1412, 0.2000, 0.2824 }, -- #243348
    borderLite = { 0.2078, 0.2824, 0.4157 }, -- #35486A
    accent     = { 0.6902, 0.8471, 0.9412 }, -- #B0D8F0  pale ice-blue (hue ~203)
    accentDim  = { 0.4353, 0.6510, 0.8000 }, -- #6FA6CC
    text       = { 0.9098, 0.9451, 0.9725 }, -- #E8F1F8  frosty cool-white
    muted      = { 0.6275, 0.7020, 0.7804 }, -- #A0B3C7
    faint      = { 0.4078, 0.4745, 0.5529 }, -- #68798D
    ok         = { 0.3608, 0.7216, 0.5412 }, -- #5CB88A  positive green
    danger     = { 0.8431, 0.3569, 0.2902 }, -- #D75B4A  red pops on ice
    warn       = { 0.9216, 0.7608, 0.2980 }, -- #EBC24C  warm amber pops against the icy palette

    -- Ledger tokens (re-derived: brand=accent, bronze=accentDim, idle=faint).
    brand      = { 0.6902, 0.8471, 0.9412 },
    brandBright= { 0.7986, 0.9006, 0.9618 },
    bronze     = { 0.4353, 0.6510, 0.8000 },
    bronzeDim  = { 0.3047, 0.4557, 0.5600 },
    idle       = { 0.4078, 0.4745, 0.5529 },

    -- control surfaces (contrast step-up) — brighter than raised/borderLite, same frost slate.
    control       = { 0.1098, 0.1569, 0.2196 }, -- #1C2838  (vs raised #1A2436)
    controlBorder = { 0.2549, 0.3490, 0.4863 }, -- #41597C  (vs borderLite #35486A)
})

-- Activate a provisional theme immediately so any widgets created before login
-- render correctly; the saved choice is re-applied once SavedVariables load. Field
-- Ledger is the LOCKED default for fresh installs; existing saved choices are honored
-- by the ADDON_LOADED re-apply below and are never overwritten.
UI.SetTheme("Field Ledger")

-- Re-apply the persisted theme after DaseekiCoreDB is available. core.lua registers
-- its ADDON_LOADED handler first (earlier file), so Core.db exists by the time this
-- one runs for our addon.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    if Core.db and Core.db.theme and UI.themes[Core.db.theme] then
        UI.SetTheme(Core.db.theme)
    else
        UI.SetTheme(UI._activeName or "Field Ledger")
    end
    self:UnregisterEvent("ADDON_LOADED")
end)
