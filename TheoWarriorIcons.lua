-- TheoWarriorIcons.lua
-- HS/Cleave + Sunder toggle indicator icons (Vanilla/Turtle 1.12)

TheoWarriorIconDB = TheoWarriorIconDB or {
  enabled = 1,
  x = 0,
  y = -140,
  size = 36,
  spacing = 6,
  scale = 1,
  _texCache = {},
}

local function Theo_GetSpellIcon(spellName)
  if not spellName or spellName == "" then return nil end

  local cache = TheoWarriorIconDB._texCache
  if cache and cache[spellName] then return cache[spellName] end

  local tabs = GetNumSpellTabs() or 0
  for tab = 1, tabs do
    local _, _, offset, numSlots = GetSpellTabInfo(tab)
    if numSlots and numSlots > 0 then
      for i = 1, numSlots do
        local idx = offset + i
        local name = GetSpellName(idx, BOOKTYPE_SPELL)
        if not name then break end
        if name == spellName then
          local tex = GetSpellTexture(idx, BOOKTYPE_SPELL)
          if tex then
            cache[spellName] = tex
            return tex
          end
        end
      end
    end
  end

  return nil
end

local TheoUI_Anchor, TheoUI_HS, TheoUI_Sunder

local function TheoUI_CreateIcon(parent, frameName)
  local f = CreateFrame("Frame", frameName, parent)
  f:SetWidth(TheoWarriorIconDB.size)
  f:SetHeight(TheoWarriorIconDB.size)

  f.icon = f:CreateTexture(nil, "BACKGROUND")
  f.icon:SetAllPoints(f)
  f.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

  f.border = f:CreateTexture(nil, "ARTWORK")
  f.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  f.border:SetPoint("TOPLEFT", f, "TOPLEFT", -7, 7)
  f.border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 7, -7)

  return f
end

local function TheoUI_ApplyLayout()
  if not TheoUI_Anchor then return end

  TheoUI_Anchor:SetScale(TheoWarriorIconDB.scale or 1)

  local size = TheoWarriorIconDB.size or 36
  local spacing = TheoWarriorIconDB.spacing or 6

  TheoUI_HS:SetWidth(size); TheoUI_HS:SetHeight(size)
  TheoUI_Sunder:SetWidth(size); TheoUI_Sunder:SetHeight(size)

  TheoUI_HS:ClearAllPoints()
  TheoUI_Sunder:ClearAllPoints()

  TheoUI_HS:SetPoint("LEFT", TheoUI_Anchor, "LEFT", 0, 0)
  TheoUI_Sunder:SetPoint("LEFT", TheoUI_HS, "RIGHT", spacing, 0)

  TheoUI_Anchor:SetWidth(size * 2 + spacing)
  TheoUI_Anchor:SetHeight(size)
end

function TheoUI_UpdateIcons()
  if not TheoUI_Anchor then return end

  if TheoWarriorIconDB.enabled ~= 1 then
    TheoUI_Anchor:Hide()
    return
  end
  TheoUI_Anchor:Show()

  -- pull toggle state from main file via getters (preferred)
  local cleaveOn = false
  if Theo_GetUseCleave then cleaveOn = Theo_GetUseCleave() end

  local sunderOn = 0
  if Theo_GetSunderMaintain then sunderOn = Theo_GetSunderMaintain() end

  local hsName = cleaveOn and "Cleave" or "Heroic Strike"
  TheoUI_HS.icon:SetTexture(Theo_GetSpellIcon(hsName) or "Interface\\Icons\\INV_Misc_QuestionMark")

  TheoUI_Sunder.icon:SetTexture(Theo_GetSpellIcon("Sunder Armor") or "Interface\\Icons\\INV_Misc_QuestionMark")
  TheoUI_Sunder:SetAlpha((sunderOn == 1) and 1 or 0.25)
end

local function TheoUI_Init()
  if TheoUI_Anchor then return end

  TheoUI_Anchor = CreateFrame("Frame", "TheoWarriorIconAnchor", UIParent)
  TheoUI_Anchor:SetFrameStrata("HIGH")
  TheoUI_Anchor:SetClampedToScreen(true)
  TheoUI_Anchor:SetMovable(true)
  TheoUI_Anchor:EnableMouse(true)
  TheoUI_Anchor:RegisterForDrag("LeftButton")

  TheoUI_Anchor:SetScript("OnDragStart", function() this:StartMoving() end)
  TheoUI_Anchor:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    local cx, cy = this:GetCenter()
    TheoWarriorIconDB.x = cx - (UIParent:GetWidth() / 2)
    TheoWarriorIconDB.y = cy - (UIParent:GetHeight() / 2)
  end)

  TheoUI_HS     = TheoUI_CreateIcon(TheoUI_Anchor, "TheoWarriorIcon_HS")
  TheoUI_Sunder = TheoUI_CreateIcon(TheoUI_Anchor, "TheoWarriorIcon_Sunder")

  TheoUI_Anchor:ClearAllPoints()
  TheoUI_Anchor:SetPoint("CENTER", UIParent, "CENTER", TheoWarriorIconDB.x or 0, TheoWarriorIconDB.y or -140)

  TheoUI_ApplyLayout()
  TheoUI_UpdateIcons()
end

-- boot after login
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  TheoUI_Init()
  boot:UnregisterEvent("PLAYER_LOGIN")
end)

-- optional commands
SLASH_THEOICONS1 = "/theoicons"
SlashCmdList["THEOICONS"] = function(msg)
  msg = string.lower(msg or "")
  if msg == "on" then TheoWarriorIconDB.enabled = 1 end
  if msg == "off" then TheoWarriorIconDB.enabled = 0 end
  if msg == "" or msg == "toggle" then
    TheoWarriorIconDB.enabled = (TheoWarriorIconDB.enabled == 1) and 0 or 1
  end
  TheoUI_UpdateIcons()
end

SLASH_THEOICONSIZE1 = "/theoiconsize"
SlashCmdList["THEOICONSIZE"] = function(msg)
  local n = tonumber(msg)
  if n and n >= 16 and n <= 96 then
    TheoWarriorIconDB.size = n
    TheoUI_ApplyLayout()
    TheoUI_UpdateIcons()
  else
    DEFAULT_CHAT_FRAME:AddMessage("Usage: /theoiconsize 16-96", 1, 0.6, 0.6)
  end
end

SLASH_THEOICONSCALE1 = "/theoiconscale"
SlashCmdList["THEOICONSCALE"] = function(msg)
  local n = tonumber(msg)
  if n and n >= 0.5 and n <= 3 then
    TheoWarriorIconDB.scale = n
    TheoUI_ApplyLayout()
    TheoUI_UpdateIcons()
  else
    DEFAULT_CHAT_FRAME:AddMessage("Usage: /theoiconscale 0.5-3", 1, 0.6, 0.6)
  end
end
