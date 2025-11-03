-- QuickTheoWarrior.lua – Rage‑smart DPS (Classic/Turtle 1.12)
-- Execute gating so BT/WW never slip; precise HS/Cleave weaving using SP_SwingTimer.
-- HS/Cleave do NOT consume GCD, so we time them to main‑hand swing using st_timer.

local BOOKTYPE_SPELL = "spell"
local useCleave = false
local lastStanceSwap = 0
local lastGCDAt = 0
local lastBSAt = 0 -- micro lockout after casting Battle Shout to avoid re-cast during aura scan delay

-- =============================
-- Tuning
-- =============================
local GCD_S = 1.5            -- global cooldown seconds
local EXECUTE_PHASE = 20     -- sub‑20% HP
local COST_BT = 30
local COST_WW = 25
local COST_EXEC = 10          -- Turtle value (consumes all remaining rage)
local COST_CLEAVE = 20
local COST_HS = 12
local COST_BS = 10            -- Battle Shout

-- Weaving
local HS_BUFFER = 5          -- keep this much rage beyond the reserve floor when weaving
local IMMINENT_BT_WINDOW = 1.2  -- treat BT as imminent if ≤ this many seconds
local IMMINENT_WW_WINDOW = 1.0  -- treat WW as imminent if ≤ this many seconds
local SWING_QUEUE_WINDOW = 0.35 -- queue HS/Cleave if MH swing is due within this window (seconds)
local PANIC_RAGE = 95           -- anti‑cap: force weave even if conservative checks fail
local WW_ONCD_BT_IMMINENT_BARRIER = 0.7 -- seconds: if BT is closer than this and rage < 30, briefly hold WW
local EXEC_MIN = 35            -- minimum rage to press Execute (Turtle: Execute dumps remaining rage)
local THEO_EXEC_WEAVE = 0      -- 0=disable HS/Cleave weaving during execute; 1=allow

-- =============================
-- Utilities
-- =============================
-- Match Theomode‑style signature: (ready, start, duration)
local function IsSpellReady(spellName)
  for i = 1, 300 do
    local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if spellName == name or (rank and spellName == name .. "(" .. rank .. ")") then
      local start, duration, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
      return enabled == 1 and (start == 0 or duration == 0), start or 0, duration or 0
    end
  end
  return false, 0, 0
end

local function CDRemaining(start, duration)
  if start == 0 or duration == 0 then return 0 end
  local rem = start + duration - GetTime()
  if rem < 0 then rem = 0 end
  return rem
end

local function GetRage()
  return UnitMana("player") or 0
end

local function PlayerInCombat()
  return UnitAffectingCombat("player")
end

local function ValidEnemyTarget()
  return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")
end

local function InMeleeRange()
  -- any reliable 5 yard check; hard fallback
  return CheckInteractDistance("target", 3)
end

local function TargetHealthBelow(p)
  if not UnitExists("target") then return false end
  local hp = (UnitHealth("target") / math.max(1, UnitHealthMax("target"))) * 100
  return hp <= p
end

local function GCDReady()
  return (GetTime() - lastGCDAt) >= GCD_S
end

-- =============================
-- Stances (1.12‑safe via shapeshift API)
-- =============================
local function CurrentStance()
  local n = GetNumShapeshiftForms() or 0
  for i = 1, n do
    local _, _, active = GetShapeshiftFormInfo(i)  -- icon, name, active[, castable]
    if active then return i end
  end
  return 0
end

local function HasBattleStance()    return CurrentStance() == 1 end  -- Warrior order is fixed in 1.12
local function HasBerserkerStance() return CurrentStance() == 3 end

local lastStanceSwap = 0
local function EnsureBerserkerStance()
  if CurrentStance() ~= 3 and (GetTime() - lastStanceSwap) > 0.2 then
    CastSpellByName("Berserker Stance")
    lastStanceSwap = GetTime()
  end
end

-- =============================
-- Basic buff check
-- =============================
local function HasBattleShout()
  -- Vanilla/Turtle 1.12: UnitBuff returns a TEXTURE path, not the localized name.
  -- Battle Shout icon path contains "Ability_Warrior_BattleShout"; match robustly.
  for i = 1, 40 do
    local tex = UnitBuff("player", i)
    if not tex then break end
    if string.find(tex, "Ability_Warrior_BattleShout") or string.find(tex, "BattleShout") then
      return true
    end
  end
  return false
end

-- =============================
-- Casting helpers
-- =============================
local function CastBloodthirst()
  local ready = IsSpellReady("Bloodthirst")
  if ready and ValidEnemyTarget() and InMeleeRange() and GCDReady() then
    CastSpellByName("Bloodthirst")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastWhirlwind()
  local ready = IsSpellReady("Whirlwind")
  if ready and ValidEnemyTarget() and InMeleeRange() and GCDReady() then
    CastSpellByName("Whirlwind")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastExecute()
  local ready = IsSpellReady("Execute")
  if ready and ValidEnemyTarget() and InMeleeRange() and GCDReady() then
    CastSpellByName("Execute")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastBattleShout()
  if not GCDReady() then return false end
  local ready = IsSpellReady("Battle Shout")
  if not ready or HasBattleShout() then return false end
  CastSpellByName("Battle Shout")
  lastBSAt = GetTime()
  lastGCDAt = GetTime()
  return true
end

-- (legacy placeholder kept; unused after we switch to macro maintainer)
local function MaintainSunders()
  return false
end

-- =============================
-- HS/Cleave swing queue detection (action bar scan + SP_SwingTimer)
-- =============================
local TheoSwingSlots = {}
local lastSwingSlotScan = 0

local function ScanSwingSlots(force)
  local now = GetTime()
  if not force and (now - lastSwingSlotScan) < 1.0 and next(TheoSwingSlots) then return end
  TheoSwingSlots = {}
  for slot = 1, 120 do
    local txt = GetActionText(slot)
    local tex = GetActionTexture(slot)
    if type(tex)=="string" and (string.find(tex, "Ability_Rogue_Ambush") or string.find(tex, "Ability_Warrior_Cleave")) then
      table.insert(TheoSwingSlots, slot)
    elseif txt then
      local t = string.lower(txt)
      if t == "heroic strike" or t == "heroicstrike" or t == "hs" or t == "cleave" then
        table.insert(TheoSwingSlots, slot)
      end
    end
  end
  lastSwingSlotScan = now
end

local function IsSwingQueued()
  ScanSwingSlots(false)
  for _,slot in ipairs(TheoSwingSlots) do
    if IsCurrentAction(slot) then return true end
  end
  return false
end

-- =============================
-- Early Sunder + Macro Maintenance (SuperCleveroid)
-- =============================
local THEO_EARLY_SUNDER = 1         -- 1 = use one immediate Sunder if target has none
local THEO_SUNDER_MAINTAIN = 1      -- 1 = maintain with macro in safe windows
local THEO_SUNDER_MACRO_NAME = "Sunder5"  -- name of your SuperCleveroid macro

local THEO_SUNDER_MACRO_SLOT, THEO_LAST_MACRO_SCAN = nil, 0

-- Simple check for presence of any Sunder debuff (icon only)
local function HasSunderDebuff()
  for i=1,40 do
    local tex = UnitDebuff("target", i)
    if not tex then break end
    if type(tex)=="string" and string.find(string.lower(tex), "ability_warrior_sunder") then
      return true
    end
  end
  return false
end

-- Find/cached macro slot by name
local function RefreshSunderMacroSlot(force)
  local now = GetTime()
  if not force and THEO_SUNDER_MACRO_SLOT and (now - THEO_LAST_MACRO_SCAN) < 1.0 then return THEO_SUNDER_MACRO_SLOT end
  THEO_LAST_MACRO_SCAN = now
  THEO_SUNDER_MACRO_SLOT = nil
  for slot=1,120 do
    local name = GetActionText(slot) -- for macros, this returns the macro's name
    if name and name == THEO_SUNDER_MACRO_NAME then
      THEO_SUNDER_MACRO_SLOT = slot
      break
    end
  end
  return THEO_SUNDER_MACRO_SLOT
end

local function UseSunderMacro()
  local slot = RefreshSunderMacroSlot(false)
  if not slot or not HasAction(slot) then return false end
  UseAction(slot)          -- fires: /cast [debuff:"Sunder Armor"<#5] Sunder Armor
  lastGCDAt = GetTime()    -- stamp GCD for rotation bookkeeping
  return true
end

-- Fire ONE early Sunder on targets that have no Sunder yet (no BT/WW gating)
local function EarlySunderIfMissing()
  if THEO_EARLY_SUNDER ~= 1 then return false end
  if not ValidEnemyTarget() or not InMeleeRange() or not GCDReady() then return false end
  if HasSunderDebuff() then return false end
  if GetRage() < 15 then return false end -- keep a small floor so we don't zero out on pull
  CastSpellByName("Sunder Armor"); SpellTargetUnit("target")
  lastGCDAt = GetTime()
  return true
end

-- Maintain via macro in safe BT/WW windows (macro self-stops at 5)
local function MaintainSundersMacro(btRem, wwRem)
  if THEO_SUNDER_MAINTAIN ~= 1 then return false end
  if not ValidEnemyTarget() or not InMeleeRange() or not GCDReady() then return false end
  if btRem <= 0.4 then return false end
  if wwRem <= 0.2 then return false end
  return UseSunderMacro()
end

-- Optional slash to set the macro name at runtime
SLASH_THEOSUNDERMAC1 = "/theosundermacro"
SlashCmdList["THEOSUNDERMAC"] = function(msg)
  if msg and msg ~= "" then
    THEO_SUNDER_MACRO_NAME = msg
    THEO_SUNDER_MACRO_SLOT = nil
    DEFAULT_CHAT_FRAME:AddMessage("Theo: Sunder macro set to '"..msg.."'. Place it on any bar.", 0.8,1,0.6)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Usage: /theosundermacro <MacroName>", 1,0.6,0.6)
  end
end

-- =============================
-- Rage floor & weaving using SP_SwingTimer (main‑hand swing timing)
-- =============================
-- Expect st_timer to be provided by SP_SwingTimer.
-- If unavailable, TryWeaveSwing() becomes a no‑op.
local function RageFloor(btRem, wwRem)
  -- Base is 0; add reserves if big buttons imminent
  if btRem <= IMMINENT_BT_WINDOW then return COST_BT end
  if wwRem <= IMMINENT_WW_WINDOW then return COST_WW end
  return 0
end

-- Decide if we can safely queue HS/Cleave to land on the **next main‑hand** swing
local function TryWeaveSwing(rage, btRem, wwRem)
  if not ValidEnemyTarget() or not InMeleeRange() then return false end
  -- Disable weaving during execute unless explicitly enabled
  if TargetHealthBelow and TargetHealthBelow(EXECUTE_PHASE) and THEO_EXEC_WEAVE ~= 1 then return false end
  if type(st_timer) ~= "number" or st_timer <= 0 then return false end

  local nextMH = st_timer -- seconds until main‑hand swing (from SP_SwingTimer)
  if nextMH <= 0 or nextMH > 10 then return false end

  -- Only queue inside a narrow pre‑swing window (user‑tunable via /theowindow)
  if nextMH > SWING_QUEUE_WINDOW and rage < PANIC_RAGE then return false end

  -- If WW is ready now or extremely soon, don't weave unless we can still afford WW after HS/Cleave
  local wwNow = IsSpellReady("Whirlwind")
  if wwNow or wwRem <= 0.2 then
    local pendingCost = useCleave and COST_CLEAVE or COST_HS
    if (rage - pendingCost) < (COST_WW + HS_BUFFER) then return false end
  end

  local floor = RageFloor(btRem, wwRem)
  local spellName = useCleave and "Cleave" or "Heroic Strike"
  local cost = useCleave and COST_CLEAVE or COST_HS

  -- If BT will be ready before or right after the swing, be conservative: ensure BT+cost+buffer now
  if btRem <= (nextMH + IMMINENT_BT_WINDOW) then
    if rage < (COST_BT + cost + HS_BUFFER) then return false end
  else
    -- Otherwise respect floor+buffer after paying cost at swing time
    if (rage - cost) < (floor + HS_BUFFER) and rage < PANIC_RAGE then return false end
  end

  -- If we're already queued, do nothing (avoid cancel‑weaving on Turtle)
  if IsSwingQueued() then return false end

  -- Finally, queue it
  CastSpellByName(spellName)
  return true
end

-- =============================
-- Main rotation with Execute gating + swing‑timed weaving + Battle Shout + Sunder
-- =============================
function QuickTheoWarrior()
  if not ValidEnemyTarget() then return end
  EnsureBerserkerStance()

  local rage = GetRage()
  local btReady, btStart, btDur = IsSpellReady("Bloodthirst")
  local wwReady, wwStart, wwDur = IsSpellReady("Whirlwind")
  local execReady = IsSpellReady("Execute")
  local btRem = CDRemaining(btStart, btDur)
  local wwRem = CDRemaining(wwStart, wwDur)
  local inExecute = TargetHealthBelow(EXECUTE_PHASE)

  -- 1) Keep BT on cooldown (never starve it)
  if btReady and rage >= COST_BT and InMeleeRange() then
    if CastBloodthirst() then return end
  end

  -- 1.1) One early Sunder if the target has no Sunder yet (no restrictions)
  if EarlySunderIfMissing() then return end

  -- 2) Keep WW on cooldown when it won't jeopardize BT
  if wwReady and InMeleeRange() then
    local btImminent = (btRem <= WW_ONCD_BT_IMMINENT_BARRIER)
    -- Fire WW essentially on cooldown: only hold if BT is very close AND we don't have 30 rage banked
    if (not btImminent) or (rage >= COST_BT) then
      if rage >= COST_WW then
        if CastWhirlwind() then return end
      end
    end
  end

  -- 3) Execute as filler/dump between BT/WW windows (don’t starve them)
  if inExecute and execReady and InMeleeRange() then
    -- Never dump right before BT; it will zero rage and delay BT
    if btRem <= 1.2 then
      -- hold Execute to preserve BT on-time
    -- If WW is about to come up and BT isn't, prefer WW first
    elseif wwRem <= 0.8 and btRem > 1.2 then
      -- hold Execute so WW stays on-time
    -- Otherwise, only Execute if it's a "fat" dump, or you're about to cap
    elseif rage >= EXEC_MIN or rage >= (PANIC_RAGE - 5) then
      if CastExecute() then return end
    end
  end

  -- 3.5) Battle Shout upkeep – safe spot: both BT and WW are on cooldown and not imminent
  if PlayerInCombat() and rage >= COST_BS and not HasBattleShout() and (GetTime() - lastBSAt) > 0.7 then
    if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if CastBattleShout() then return end
    end
  end

  -- 3.6) Maintain Sunders with macro in safe windows (macro auto-stops at 5)
  if MaintainSundersMacro(btRem, wwRem) then return end

  -- 4) Precise HS/Cleave weaving tied to SP_SwingTimer main‑hand swing (no GCD)
  if TryWeaveSwing(rage, btRem, wwRem) then return end

  -- 5) (legacy) optional maintainer (disabled by default)
  if MaintainSunders() then return end
end

-- =============================
-- TheoCharge helper (two-press opener: OOC Battle Stance → Charge; IC Berserker Stance → Intercept)
-- =============================
local function TheoCharge_EnsureStance()
  if not HasBattleStance() then
    CastSpellByName("Battle Stance")
  end
end

local function TheoCharge()
  if not UnitExists("target") then
    -- Optional: still prep stance with no target
    if not UnitAffectingCombat("player") and not HasBattleStance() then
      CastSpellByName("Battle Stance")
    elseif UnitAffectingCombat("player") and not HasBerserkerStance() then
      CastSpellByName("Berserker Stance")
    end
    return
  end

  if UnitAffectingCombat("player") then
    -- In combat: ensure Berserker Stance; next press will Intercept
    if not HasBerserkerStance() then
      CastSpellByName("Berserker Stance")
      return
    end
    -- We’re in the correct stance; just try Intercept (no range gate here)
    local ready = IsSpellReady("Intercept")
    if ready then CastSpellByName("Intercept") end
    return
  else
    -- Out of combat: ensure Battle Stance; next press will Charge
    if not HasBattleStance() then
      CastSpellByName("Battle Stance")
      return
    end
    -- We’re in the correct stance; just try Charge (no range gate here)
    local ready = IsSpellReady("Charge")
    if ready then CastSpellByName("Charge") end
    return
  end
end

-- =============================
-- Slash commands
-- =============================

-- Execute threshold: /theoexec <minRage>
SLASH_THEOEXEC1 = "/theoexec"
SlashCmdList["THEOEXEC"] = function(msg)
  local n = tonumber(msg)
  if n then
    EXEC_MIN = math.max(10, math.floor(n))
    DEFAULT_CHAT_FRAME:AddMessage("Execute minimum set to "..EXEC_MIN.." rage.", 0.8, 1, 0.6)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Usage: /theoexec <minRage>", 1, 0.6, 0.6)
  end
end

-- Execute weaving toggle: /theoexecweave 0|1
SLASH_THEOEXECWEAVE1 = "/theoexecweave"
SlashCmdList["THEOEXECWEAVE"] = function(msg)
  local n = tonumber(msg)
  if n == 1 or n == 0 then
    THEO_EXEC_WEAVE = n
    DEFAULT_CHAT_FRAME:AddMessage("Execute-phase weaving: "..(THEO_EXEC_WEAVE==1 and "ENABLED" or "DISABLED"), 0.8, 1, 0.6)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Usage: /theoexecweave 0|1", 1, 0.6, 0.6)
  end
end

SLASH_QHWARRIOR1 = "/qhtwarrior"
SlashCmdList["QHWARRIOR"] = QuickTheoWarrior

-- Slash: stance first, then driver
SLASH_THEOSTANCE1 = "/theostance"
SlashCmdList["THEOSTANCE"] = TheoCharge_EnsureStance

-- New: TheoCharge macro
SLASH_THEOCHARGE1 = "/theocharge"
SlashCmdList["THEOCHARGE"] = TheoCharge

DEFAULT_CHAT_FRAME:AddMessage("QuickTheoWarrior loaded! /qhtwarrior, /theoexec <n>, /theoexecweave 0|1, /theosundermacro <name>, /theostance, /theocharge.", 0.5, 1, 0)
