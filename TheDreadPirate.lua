-- QuickTheoFury.lua : Dual‑Wield Fury Warrior one‑button helper (Turtle WoW 1.12)
-- Installation:
-- 1) Place this file at Interface/AddOns/QuickTheoFury/QuickTheoFury.lua
-- 2) Create Interface/AddOns/QuickTheoFury/QuickTheoFury.toc with:
--    ## Interface: 11302
--    ## Title: QuickTheoFury
--    ## Notes: Fury Warrior helper (BT>WW, rage aware, auto-stance)
--    QuickTheoFury.lua
-- 3) Bind or macro: /qtfury

local BOOKTYPE_SPELL = "spell"

-- Rage costs (Classic/Turtle 1.12)
local COST_BT = 30  -- Bloodthirst
local COST_WW = 25  -- Whirlwind
local COST_SU = 10  -- Sunder Armor (baseline; talents may reduce)
local COST_HS = 12  -- Heroic Strike (reference only; queue at >=60 rage as dump)

local function HasRage(cost)
  local r = QuickTheoFury_LastRage > 0 and QuickTheoFury_LastRage or UnitMana("player") or 0
  return r >= cost
end

-- =========================
-- Small utilities (Vanilla)
-- =========================
-- Tooltip for debuff name/stack scans
local QTF_Tooltip = CreateFrame("GameTooltip", "QTF_Tooltip", UIParent, "GameTooltipTemplate")
QTF_Tooltip:SetOwner(UIParent, "ANCHOR_NONE")
local function GetDebuffStacks(unit, matchName)
  if not UnitExists(unit) then return 0 end
  local lname = string.lower(matchName)
  for i=1,16 do
    local tex, stacks = UnitDebuff(unit, i)
    if not tex then break end
    QTF_Tooltip:ClearLines()
    QTF_Tooltip:SetUnitDebuff(unit, i)
    local tname = _G.QTF_TooltipTextLeft1 and _G.QTF_TooltipTextLeft1:GetText() or nil
    if tname and string.lower(tname) == lname then
      if type(stacks) == "number" and stacks > 0 then return stacks else return 1 end
    end
  end
  return 0
end
-- CombatRangeChecker integration (accepts GREEN or TEAL as "in range"), with graceful fallback
QuickTheoFury_UseCRF = true
local function CRF_MeleeState()
  if not QuickTheoFury_UseCRF then return nil end
  -- Try common exported APIs from CombatRangeChecker/CombatRangeFinder
  if type(CombatRangeChecker_GetArrowColor) == "function" then
    local c = CombatRangeChecker_GetArrowColor()
    if c then
      c = string.lower(tostring(c))
      if c == "green" or c == "teal" then return true end
      if c == "red" then return false end
    end
  end
  if type(CombatRangeChecker_IsMeleeInRange) == "function" then
    local ok = CombatRangeChecker_IsMeleeInRange()
    if ok ~= nil then return ok and true or false end
  end
  if type(CRF_IsMeleeInRange) == "function" then
    local ok = CRF_IsMeleeInRange()
    if ok ~= nil then return ok and true or false end
  end
  if type(CombatRange_IsMeleeInRange) == "function" then
    local ok = CombatRange_IsMeleeInRange()
    if ok ~= nil then return ok and true or false end
  end
  return nil -- unknown; fall back to spell/range APIs
end

local function GetRage()
  -- In 1.12, warrior rage is returned by UnitMana("player")
  local r = UnitMana("player") or 0
  return r
end

local function IsSpellReady(spellName)
  -- Scan spellbook for cooldown == 0 (same pattern we use in other QuickTheo addons)
  for i = 1, 300 do
    local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == spellName then
      local start, dur, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
      if enabled == 1 and (dur == 0 or (start + dur) <= GetTime()) then
        return true
      else
        return false
      end
    end
  end
  return false
end

local function EnsureBerserkerStance()
  -- 1=Battle, 2=Defensive, 3=Berserker in 1.12
  local form = GetShapeshiftForm()
  if form ~= 3 then
    CastSpellByName("Berserker Stance")
    return true  -- consumed the press to switch stance
  end
  return false
end

-- Track rage continuously (future rules depend on it)
QuickTheoFury_LastRage = 0
local rageWatch = CreateFrame("Frame")
local accum = 0
rageWatch:SetScript("OnUpdate", function(_, e)
  accum = accum + e
  if accum > 0.20 then  -- light throttle
    accum = 0
    QuickTheoFury_LastRage = GetRage()
  end
end)

-- =========================
-- Core casts we care about
-- =========================
local function EnsureAutoAttack()
  if CanAttackTarget() then
    if SpellIsTargeting() then SpellStopTargeting() end
    -- Explicitly try the macro path first if supported on this client
    if RunMacroText then RunMacroText("/startattack") end
    -- Also directly trigger Attack for robustness
    CastSpellByName("Attack")
    AttackTarget()
  end
end


local function CanAttackTarget()
  return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDeadOrGhost("target")
end

local function InMeleeFor(spellName)
  -- Prefer CombatRangeChecker's color when available (GREEN/TEAL = in range)
  local cr = CRF_MeleeState()
  if cr == false then return false end -- out of range
  -- If cr == true, we still sanity-check spell range so we don't fire into nil target states
  local ok = IsSpellInRange(spellName, "target")
  if cr == true then
    return ok == 1 or ok == nil or CheckInteractDistance("target", 3) == 1
  end
  -- Fallback behavior when CRF not available
  return (ok == 1) or (ok == nil and CheckInteractDistance("target", 3) == 1)
end

local function TryBloodthirst()
  if not CanAttackTarget() then return false end
  if IsSpellReady("Bloodthirst") and HasRage(COST_BT) and InMeleeFor("Bloodthirst") then
    CastSpellByName("Bloodthirst")
    return true
  end
  return false
end

-- Mark WW as melee distance required via CRF too
local function TryWhirlwind(btWasReady)
  -- Only WW if BT is NOT available (explicitly gate WW behind BT's cooldown)
  if btWasReady then return false end
  if IsSpellReady("Whirlwind") and HasRage(COST_WW) and InMeleeFor("Whirlwind") then
    CastSpellByName("Whirlwind")
    return true
  end
  return false
end

-- Sunder Armor logic (opening and maintenance)
local function TrySunder(opening)
  if not CanAttackTarget() then return false end
  local stacks = GetDebuffStacks("target", "Sunder Armor")
  if stacks >= 5 then return false end
  if not InMeleeFor("Sunder Armor") then return false end
  if opening then
    if HasRage(COST_SU) then
      CastSpellByName("Sunder Armor")
      return true
    else
      return false
    end
  else
    if (not IsSpellReady("Bloodthirst")) and (not IsSpellReady("Whirlwind")) and (GetRage() >= 40) then
      CastSpellByName("Sunder Armor")
      return true
    end
  end
  return false
end

-- Heroic Strike: queue when BT and WW are both on cooldown and rage is high (>=60)
local function TryHeroicStrike()
  if not CanAttackTarget() then return false end
  if IsSpellReady("Bloodthirst") or IsSpellReady("Whirlwind") then return false end
  if GetRage() < 60 then return false end
  -- HS is a next-melee, so rely on CRF/auto-attack being active; sanity range via Bloodthirst check
  if not InMeleeFor("Bloodthirst") then return false end
  CastSpellByName("Heroic Strike")
  return true
end

-- =========================
-- Main one-button entrypoint
-- =========================
function QuickTheoFury()
  -- 0) Cache current rage for any external readers/macros
  QuickTheoFury_LastRage = GetRage()

  -- 0.5) Always ensure auto-attack is running before anything else
  EnsureAutoAttack()

  -- 1) Ensure we are in Berserker ("fury") stance; if we had to swap, stop here this press
  if EnsureBerserkerStance() then return end

  -- 1.5) Opening: on brand-new combat, push Sunder to 5 stacks
  if QuickTheoFury_OpeningSunder then
    if TrySunder(true) then QuickTheoFury_OpeningSunder = false; return end
    QuickTheoFury_OpeningSunder = false
  end

  -- 2) Priority: Bloodthirst > Whirlwind (only WW once BT is on cooldown)
  local btReady = IsSpellReady("Bloodthirst")
  if btReady and TryBloodthirst() then return end
  if TryWhirlwind(btReady) then return end

  -- Maintenance Sunder (don’t starve BT/WW): both on CD, rage >= 40, stacks < 5
  if TrySunder(false) then return end

  -- 4) High-rage dump: queue Heroic Strike when BT & WW are both on CD and rage >= 60
  if TryHeroicStrike() then return end

  -- (Nothing else yet; we will add rage-dependent rules and HS/Cleave, cooldowns, and execute later.)
end

-- =========================
-- Simple event + slash
-- =========================
local msgPrefix = "|cff00ccff[QuickTheoFury]|r "
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_REGEN_DISABLED")
loader:RegisterEvent("PLAYER_REGEN_ENABLED")
QuickTheoFury_OpeningSunder = false
loader:SetScript("OnEvent", function(_, ev)
  if ev == "PLAYER_LOGIN" then
    DEFAULT_CHAT_FRAME:AddMessage(msgPrefix .. "loaded. Use /qtfury to pump.")
  elseif ev == "PLAYER_REGEN_DISABLED" then
    QuickTheoFury_OpeningSunder = true
  elseif ev == "PLAYER_REGEN_ENABLED" then
    QuickTheoFury_OpeningSunder = false
  end
end)

SLASH_QUICKTHEOFURY1 = "/quicktheofury"
SLASH_QUICKTHEOFURY2 = "/qtfury"
SlashCmdList["QUICKTHEOFURY"] = QuickTheoFury
