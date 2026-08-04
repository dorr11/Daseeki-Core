--[[
    Daseeki Core — minimap button.
    Left-click opens the combined options hub.

    Uses LibDBIcon-1.0 + LibDataBroker-1.1 when another loaded addon provides them
    (so minimap-button collectors treat it as a first-class button), and falls back
    to a self-contained draggable button otherwise. Position is saved in
    DaseekiCoreDB (LibDBIcon manages its own `_minimapDB` sub-table).

    ── The button's face is the SUITE MAKER'S MARK ────────────────────────────
    art/maker-mark.tga — the crimson-on-bronze brand diamond, authored by
    dev/gen-core-glyphs.lua (64x64 BGRA type-2 TGA; read that file for the geometry
    and why the colours are baked rather than themed). It is the same brandmark
    UI.MakerMark draws on the hub titlebar and the Nexus shell header, restated bold
    enough to survive the ~18px a minimap button gets.

    It replaces art/nightblade.jpg, which never rendered at all: the WoW client reads
    only .blp and .tga, so the icon silently fell through to INV_Misc_Gear_01 and the
    suite's button wore Blizzard's cog.

    NO SetTexCoord CROP on the mark. The classic 0.08/0.92 trim exists to shave the
    baked border off Interface/Icons art; the mark carries its own 2px margin inside
    the 64px field and a crop would clip its vertices. The trim is applied to the
    FALLBACK icon only, which is Blizzard icon art and does need it.
--]]

local _, Core = ...

local CUSTOM_ICON   = "Interface/AddOns/Daseeki-Core/art/maker-mark"
local FALLBACK_ICON = "Interface/Icons/INV_Misc_Gear_01"

local function addTooltip(tip)
    tip:AddLine('Daseeki Core', 1, 1, 1)
    tip:AddLine('Left-Click to open config window.', 0.8, 0.8, 0.8, true)
end

-- ── Position math for the fallback button (matches LibDBIcon-1.0) ──────────────
local MINIMAP_SHAPES = {
    ['ROUND']                = {true,  true,  true,  true },
    ['SQUARE']               = {false, false, false, false},
    ['CORNER-TOPLEFT']       = {false, false, false, true },
    ['CORNER-TOPRIGHT']      = {false, false, true,  false},
    ['CORNER-BOTTOMLEFT']    = {false, true,  false, false},
    ['CORNER-BOTTOMRIGHT']   = {true,  false, false, false},
    ['SIDE-LEFT']            = {false, true,  false, true },
    ['SIDE-RIGHT']           = {true,  false, true,  false},
    ['SIDE-TOP']             = {false, false, true,  true },
    ['SIDE-BOTTOM']          = {true,  true,  false, false},
    ['TRICORNER-TOPLEFT']    = {false, true,  true,  true },
    ['TRICORNER-TOPRIGHT']   = {true,  false, true,  true },
    ['TRICORNER-BOTTOMLEFT'] = {true,  true,  false, true },
    ['TRICORNER-BOTTOMRIGHT']= {true,  true,  true,  false},
}
local MINIMAP_RADIUS = 5

local function updatePosition(btn, angle)
    angle = (angle or 220) % 360
    local rad  = math.rad(angle)
    local cosA, sinA = math.cos(rad), math.sin(rad)

    local q = 1
    if cosA < 0 then q = q + 1 end
    if sinA > 0 then q = q + 2 end

    local shape = MINIMAP_SHAPES[GetMinimapShape and GetMinimapShape() or 'ROUND']
    local w = (Minimap:GetWidth()  / 2) + MINIMAP_RADIUS
    local h = (Minimap:GetHeight() / 2) + MINIMAP_RADIUS
    local x, y

    if not shape or shape[q] then
        x, y = cosA * w, sinA * h
    else
        local dw = math.sqrt(2 * w * w) - 10
        local dh = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(cosA * dw, w))
        y = math.max(-h, math.min(sinA * dh, h))
    end

    btn:ClearAllPoints()
    btn:SetPoint('CENTER', Minimap, 'CENTER', x, y)
end

-- ── Button creation ───────────────────────────────────────────────────────────
function Core:CreateMinimapButton()
    if self._minimapBtn then return self._minimapBtn end
    local db = self.db or {}

    -- ── Preferred: LibDBIcon path (no "custom button" warning from collectors) ──
    local LibDBIcon     = LibStub and LibStub('LibDBIcon-1.0',     true)
    local LibDataBroker = LibStub and LibStub('LibDataBroker-1.1', true)

    if LibDBIcon and LibDataBroker then
        if not db._minimapDB then
            db._minimapDB = {
                hide       = db.minimapHide and true or false,
                minimapPos = db.minimapAngle or 220,
            }
        end

        if not LibDBIcon:IsRegistered('DaseekiCore') then
            local dataObj = LibDataBroker:NewDataObject('DaseekiCore', {
                type  = 'launcher',
                label = 'Daseeki Core',
                icon  = CUSTOM_ICON,
                OnClick = function(_, button)
                    if button == 'LeftButton' then Core:Toggle() end
                end,
                OnTooltipShow = addTooltip,
            })
            LibDBIcon:Register('DaseekiCore', dataObj, db._minimapDB)
        end

        self._libDBIcon  = LibDBIcon
        self._minimapBtn = LibDBIcon:GetMinimapButton('DaseekiCore')
        -- If the mark is missing, fall back to a built-in icon — and only THEN take
        -- the border trim, which is Blizzard-icon housekeeping the mark does not want.
        local ico = self._minimapBtn and self._minimapBtn.icon
        if ico and not ico:GetTexture() then
            ico:SetTexture(FALLBACK_ICON)
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        return self._minimapBtn
    end

    -- ── Fallback: self-contained draggable button ──────────────────────────────
    local btn = CreateFrame('Button', 'DaseekiCoreMinimapBtn', Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata('MEDIUM')
    btn:SetFixedFrameStrata(true)
    btn:SetFrameLevel(8)
    btn:SetFixedFrameLevel(true)
    btn:SetClampedToScreen(false)
    btn:RegisterForDrag('LeftButton')
    btn:RegisterForClicks('AnyUp')

    local bg = btn:CreateTexture(nil, 'BACKGROUND')
    bg:SetTexture(136467); bg:SetSize(20, 20); bg:SetPoint('TOPLEFT', 7, -5)

    local ico = btn:CreateTexture(nil, 'ARTWORK')
    ico:SetSize(18, 18); ico:SetPoint('TOPLEFT', 7, -6)
    ico:SetTexture(CUSTOM_ICON)
    -- Border trim on the FALLBACK only (see the file header): the mark ships its own
    -- margin and a crop would take its points off.
    if not ico:GetTexture() then
        ico:SetTexture(FALLBACK_ICON)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    btn.icon = ico

    local border = btn:CreateTexture(nil, 'OVERLAY')
    border:SetTexture(136430); border:SetSize(53, 53); border:SetPoint('TOPLEFT', 0, 0)

    btn:SetHighlightTexture(136477)

    btn:SetScript('OnClick', function(_, button)
        if button == 'LeftButton' then Core:Toggle() end
    end)
    btn:SetScript('OnEnter', function(self)
        GameTooltip:SetOwner(self, 'ANCHOR_LEFT')
        addTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    btn:SetScript('OnLeave', function() GameTooltip:Hide() end)

    btn:SetScript('OnDragStart', function(self)
        self:LockHighlight()
        self:SetScript('OnUpdate', function(self)
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale  = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            if mx then
                local angle = math.deg(math.atan2(py - my, px - mx)) % 360
                Core.db.minimapAngle = angle
                updatePosition(self, angle)
            end
        end)
    end)
    btn:SetScript('OnDragStop', function(self)
        self:SetScript('OnUpdate', nil)
        self:UnlockHighlight()
    end)

    updatePosition(btn, db.minimapAngle or 220)
    self._minimapBtn = btn
    return btn
end

function Core:ShowMinimapButton()
    if not self._minimapBtn then self:CreateMinimapButton() end
    if self.db then self.db.minimapHide = false end
    if self._libDBIcon then
        self._libDBIcon:Show('DaseekiCore')
        if self.db and self.db._minimapDB then self.db._minimapDB.hide = false end
    elseif self._minimapBtn then
        self._minimapBtn:Show()
    end
end

function Core:HideMinimapButton()
    if self.db then self.db.minimapHide = true end
    if self._libDBIcon then
        self._libDBIcon:Hide('DaseekiCore')
        if self.db and self.db._minimapDB then self.db._minimapDB.hide = true end
    elseif self._minimapBtn then
        self._minimapBtn:Hide()
    end
end

function Core:ToggleMinimapButton()
    if self.db and self.db.minimapHide then
        self:ShowMinimapButton()
    else
        self:HideMinimapButton()
    end
end

-- Create the button after login (DaseekiCoreDB and other addons' libs are ready).
local loader = CreateFrame('Frame')
loader:RegisterEvent('PLAYER_LOGIN')
loader:SetScript('OnEvent', function()
    if not (Core.db and Core.db.minimapHide) then
        Core:CreateMinimapButton()
    end
end)
