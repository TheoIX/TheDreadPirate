-- QuickTheoWarrior.lua - Rage-based DPS Rotation Helper for Warriors (Turtle WoW 1.12)
-- Inspired by QuickTheoProt and TheoMode

local BOOKTYPE_SPELL = "spell"

-- =========================================
-- UTILITIES
-- =========================================
local function IsSpellReady(spellName)
  for i = 1, 300 do
    local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if spellName == name or (rank and spellName == name .. "(" .. rank .. ")") then
      local start, duration, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
      return enabled == 1 and (start == 0 or duration == 0)
    end
  end
  return false
end

local function GetRage()
  return UnitMana("player") or 0
end

local function InMeleeRange()
  return IsSpellInRange("Heroic Strike", "target") == 1
end

local function ValidEnemyTarget()
  return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDeadOrGhost("target")
end

-- =========================================
-- CAST HELPERS
-- =========================================
local function CastBloodthirst()
  if IsSpellReady("Bloodthirst") and ValidEnemyTarget() and InMeleeRange() then
    CastSpellByName("Bloodthirst")
    SpellTargetUnit("target")
    return true
  end
  return false
end

local function CastWhirlwind()
  if IsSpellReady("Whirlwind") and ValidEnemyTarget() and InMeleeRange() then
    CastSpellByName("Whirlwind")
    SpellTargetUnit("target")
    return true
  end
  return false
end

local function QueueHeroicStrike()
  if GetRage() >= 55 and ValidEnemyTarget() and InMeleeRange() then
    CastSpellByName("Heroic Strike")
    return true
  end
  return false
end

-- =========================================
-- MAIN ROTATION
-- =========================================
function QuickTheoWarrior()
  if not ValidEnemyTarget() then return end

  if CastBloodthirst() then return end
  if CastWhirlwind() then return end
  QueueHeroicStrike()
end

-- =========================================
-- SLASH COMMANDS
-- =========================================
SLASH_QHWARRIOR1 = "/qhtwarrior"
SlashCmdList["QHWARRIOR"] = QuickTheoWarrior

DEFAULT_CHAT_FRAME:AddMessage("QuickTheoWarrior loaded! Use /qhtwarrior to activate.", 0.5, 1, 0)
