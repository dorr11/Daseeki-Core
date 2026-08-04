-- Daseeki-Core — brand artwork generator (owned assets).
--
-- Authors the one texture Core ships as ICON art rather than as a UI-kit stencil:
--
--   art/maker-mark.tga — THE SUITE MAKER'S MARK. The minimap button's face, and the
--                        only place in the suite where the brandmark is BAKED into
--                        pixels instead of drawn from theme tokens at runtime.
--
-- ── Why this file exists ──────────────────────────────────────────────────────
-- Everywhere inside a Daseeki window the mark is drawn live by UI.MakerMark
-- (ledgerkit.lua §6): a bronze rotated-square keyline, a ground-token fill, and a
-- crimson MORPHEUS "D" — three theme tokens that re-tint on OnThemeChanged. The
-- minimap button cannot do that. Its face is a TEXTURE PATH handed to LibDBIcon (or
-- to our fallback button's ARTWORK texture); nothing skins it, nothing re-tints it,
-- and it is rendered at ~17-18px. So the mark has to be baked, and baked BOLD.
--
-- ── Geometry, and where it came from ──────────────────────────────────────────
-- SILHOUETTE: the L1 rhombus |x| + |y| <= R — byte-for-byte the same shape family as
-- textures/diamond-mask.tga (the suite's diamond stencil: a full-field rhombus with
-- its vertices on the edge midpoints, 6x-supersampled edges). Read off our own
-- asset, so the minimap face and every masked diamond in the suite share one
-- outline. The rhombus is also the RIGHT shape for this button: a minimap button is
-- a circular aperture, and a diamond's vertices sit at the aperture's cardinal
-- points with clean air in the corners — no round mask required, nothing clipped.
--
-- BANDS: two, from UI.MakerMark's own anatomy (bronze keyline outside, brand colour
-- inside), with the LEGIBILITY INVERSION the small size forces:
--
--   * The window mark is bronze-ring-dominant with crimson only in the letterform.
--     At 18px a 1px bronze ring is the whole read and the mark disappears into the
--     minimap's own gold-brown chrome. So the BRAND CRIMSON becomes the field and
--     the bronze becomes the keyline around it. BRAND_SPEC §2's "one crimson wax
--     seal is the brand's punctuation mark" and §5's crimson-seal grammar both
--     point the same way, and the owner's instruction for this asset names it "the
--     crimson diamond brand mark".
--   * The MORPHEUS "D" is DROPPED. BRAND_SPEC §3 puts a hard >=16px floor under
--     MORPHEUS; a "D" scaled to fit inside an 18px diamond is ~9px of counter-heavy
--     blackletter, i.e. three dark pixels. Dropping it is the brief's "keep it
--     bold/simple", and the mark stays unambiguous: colour + silhouette carry it.
--
-- RIM WEIGHT is measured PERPENDICULAR to the rhombus edge, which is why the radius
-- step below is RIM * sqrt(2): under the L1 metric the distance from a point to the
-- edge is (R - (|x| + |y|)) / sqrt(2). The suite's shared STROKE = 6 invariant
-- (Daseeki-Bags/dev/gen-bags-glyphs.lua, Daseeki-Raid-Prep/dev/gen-prep-glyphs.lua)
-- deliberately does NOT apply here: that number governs a GLYPH stroke on a
-- white-on-transparent control mask, and pushing 6 through a rhombus this small
-- costs half the mark's area to bronze — the thing stops reading as crimson. This is
-- a KEYLINE, and BRAND_SPEC §4 defines the keyline as 1px at draw size. RIM = 4.5 in
-- the 64px field is ~1.25px at the 18px draw — the minimap-scale reading of that
-- 1px rule — and leaves ~62% of the mark's area as brand crimson.
--
-- FACET: the crimson field carries a shallow vertical gradient, brandBright-ward at
-- the top vertex and brand-darkened at the bottom. That is the "faceted diamond"
-- the Nexus shell calls the mark (ui_shell.lua) and it stops the shape reading as a
-- flat pip at a glance. Amplitude is kept low enough that the mark is still one
-- colour at 18px.
--
-- ── Colours are BAKED, and that is deliberate ─────────────────────────────────
-- Field Ledger tokens, BRAND_SPEC §2 / theme.lua "Field Ledger":
--   bronze #9C7A45   brand #C0483C   brandBright #E86B5A
-- A themed surface would read UI.Color(); this is not a themed surface. It is the
-- MAKER'S MARK — brand identity, the same class of thing as the MORPHEUS wordmark
-- that BRAND_SPEC keeps brand-locked while the dashboard follows the font picker.
-- A Stormwind-blue minimap button would be a different company's button.
--
-- ── Format ────────────────────────────────────────────────────────────────────
-- Byte-matches the suite's texture format (Daseeki-Nexus/textures/icon-gear.tga,
-- Daseeki-Core/textures/diamond-mask.tga): 18-byte uncompressed true-colour TGA
-- header (type 2), 32-bit BGRA, descriptor 0x28 (top-left origin), 64x64 =>
-- 16402 bytes exactly. UNLIKE the control glyphs this one is FULL COLOUR, not white
-- on transparent: nothing tints it downstream, so the colour ships in the pixels.
--
-- The 64px field carries a 2px margin outside the rhombus vertices, so the art is
-- anchored with NO SetTexCoord crop (minimap.lua reserves the classic 0.08/0.92
-- icon-border trim for the Blizzard FALLBACK icon, which needs it; ours does not).
--
-- CLEAN-ROOM: every shape below is generated from the geometry in this file. No
-- addon's art is read, traced or copied. The pixels are ours.
--
-- Usage:  lua5.1 gen-core-glyphs.lua <outdir>      (outdir defaults to ".")
--         e.g.  lua5.1 dev/gen-core-glyphs.lua art

local W, H   = 64, 64
local CX, CY = W / 2, H / 2
local SS     = 6                 -- supersample grid per pixel (6x6 = 36 samples) for AA
local RIM    = 4.5               -- bronze keyline, PERPENDICULAR px in the 64px field

-- Rhombus radii in the L1 metric (|x| + |y|).
local R_OUT  = 30                                  -- vertices at +/-30 => 2px margin
local R_IN   = R_OUT - RIM * math.sqrt(2)          -- perpendicular rim of exactly RIM

local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

----------------------------------------------------------------------
-- palette (Field Ledger tokens, 0-255)
----------------------------------------------------------------------
local function rgb(r, g, b) return { r = r, g = g, b = b } end
local function mix(a, b, t)
    return rgb(a.r + (b.r - a.r) * t,
               a.g + (b.g - a.g) * t,
               a.b + (b.b - a.b) * t)
end

local BRONZE      = rgb(156, 122,  69)   -- #9C7A45  bronze      (keyline)
local BRAND       = rgb(192,  72,  60)   -- #C0483C  brand       (wax crimson)
local BRAND_LIGHT = rgb(232, 107,  90)   -- #E86B5A  brandBright (brighten target)

-- Facet strengths. The gradient is hinged at the mark's CENTRE, not lerped end to
-- end, so the middle band is exactly #C0483C: above centre the field walks toward
-- brandBright, below centre it walks toward black. A straight top-to-bottom lerp
-- would put some off-brand mixture in the middle (the brighten and the darken are
-- not symmetric in RGB), and the one colour a brandmark must actually hit is its
-- own. The facet is depth, never a recolour.
local FACET_UP   = 0.45   -- toward brandBright at the top vertex
local FACET_DOWN = 0.28   -- toward black at the bottom vertex
local BLACK      = rgb(0, 0, 0)

----------------------------------------------------------------------
-- the mark: returns nil (outside) or a colour for one sample
--   MATH coords: +x right, +y up, origin at centre
----------------------------------------------------------------------
local function markSample(x, y)
    local d = math.abs(x) + math.abs(y)
    if d > R_OUT then return nil end
    if d > R_IN  then return BRONZE end
    -- crimson field, shallow facet hinged at the centre line (t = -1 .. +1)
    local t = y / R_OUT
    if t >= 0 then return mix(BRAND, BRAND_LIGHT, clamp01(t) * FACET_UP) end
    return mix(BRAND, BLACK, clamp01(-t) * FACET_DOWN)
end

----------------------------------------------------------------------
-- rasteriser (same 18-byte type-2 BGRA writer as the Nexus / Bags / Raid-Prep
-- generators; this one accumulates COLOUR per sample instead of coverage alone,
-- so the rim/field seam antialiases as a colour blend, not as a hole)
----------------------------------------------------------------------
local function writeTGA(path, sample)
    local hdr = string.char(
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        W % 256, math.floor(W / 256),
        H % 256, math.floor(H / 256),
        32, 0x28)                              -- 32bpp, top-left origin
    local rows, step, total = {}, 1 / SS, SS * SS
    for yi = 0, H - 1 do                       -- top-left origin: first row is the TOP
        local cols = {}
        for xi = 0, W - 1 do
            local hits, sr, sg, sb = 0, 0, 0, 0
            for sy = 0, SS - 1 do
                for sx = 0, SS - 1 do
                    local px = (xi + (sx + 0.5) * step) - CX
                    -- flip to math coords (+y up) so the shape maths reads naturally
                    local py = CY - (yi + (sy + 0.5) * step)
                    local c = sample(px, py)
                    if c then
                        hits = hits + 1
                        sr, sg, sb = sr + c.r, sg + c.g, sb + c.b
                    end
                end
            end
            if hits == 0 then
                cols[#cols + 1] = string.char(0, 0, 0, 0)
            else
                local a = math.floor(clamp01(hits / total) * 255 + 0.5)
                local r = math.floor(clamp01(sr / hits / 255) * 255 + 0.5)
                local g = math.floor(clamp01(sg / hits / 255) * 255 + 0.5)
                local b = math.floor(clamp01(sb / hits / 255) * 255 + 0.5)
                cols[#cols + 1] = string.char(b, g, r, a)   -- B,G,R,A
            end
        end
        rows[#rows + 1] = table.concat(cols)
    end
    local body = table.concat(rows)
    assert(#hdr + #body == 18 + W * H * 4,
           "TGA size drift: expected " .. (18 + W * H * 4) .. " bytes")
    local f = assert(io.open(path, "wb"))
    f:write(hdr); f:write(body); f:close()
    print(("wrote %s (%d bytes)"):format(path, #hdr + #body))
end

local dir = (arg and arg[1]) or "."
writeTGA(dir .. "/maker-mark.tga", markSample)
