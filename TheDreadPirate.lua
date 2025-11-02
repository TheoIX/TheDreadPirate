-- QuickTheoWarrior.lua – Rage‑smart DPS (Classic/Turtle 1.12)
-- Execute gating so BT/WW never slip; precise HS/Cleave weaving using SP_SwingTimer.
-- HS/Cleave do NOT consume GCD, so we time them to main‑hand swing using st_timer.

local BOOKTYPE_SPELL = "spell"
local useCleave = false
local lastStanceSwap = 0
local lastGCDAt = 0
local lastBSAt = 0 -- micro lockout after casting Battle Shout to avoid re-cast during aura scan delay

-- TheoCharge state
local theocharge_phase = 0   -- 0=idle, 1=charging, 2=charged(wait bloodrage), 3=done(wait reset)
local lastChargeStart = 0

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
local HS_BUFFER = 5             -- keep this much rage beyond the reserve floor when weaving
local IMMINENT_BT_WINDOW = 1.2  -- treat BT as imminent if ≤ this many seconds
local IMMINENT_WW_WINDOW = 1.0  -- treat WW as imminent if ≤ this many seconds
local SWING_QUEUE_WINDOW = 0.35 -- queue HS/Cleave if MH swing is due within this window (seconds)
local PANIC_RAGE = 95           -- anti‑cap: force weave even if conservative checks fail
local WW_ONCD_BT_IMMINENT_BARRIER = 0.5 -- seconds: if BT is closer than this and rage < 30, briefly hold WW

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

local function InMeleeRange()
  if type(SP_ST_InRange) == "function" then
    return SP_ST_InRange()
  end
  return IsSpellInRange("Heroic Strike", "target") == 1
end

local function InChargeRange()
  local r = IsSpellInRange("Charge", "target")
  return r == 1
end

local function InInterceptRange()
  local r = IsSpellInRange("Intercept", "target")
  return r == 1
end

local function ValidEnemyTarget()
  return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDeadOrGhost("target")
end

local function TargetHealthBelow(percent)
  if not UnitExists("target") then return false end
  local hp = (UnitHealth("target") / UnitHealthMax("target")) * 100
  return hp < percent
end

local function GCDReady()
  return (GetTime() - lastGCDAt) >= GCD_S
end

local function PlayerInCombat()
  return UnitAffectingCombat("player") == 1
end

-- =============================
-- Buff checks
-- =============================
local function HasBerserkerStance()
  for i = 1, 40 do
    local tex = UnitBuff("player", i)
    if not tex then break end
    if string.find(tex, "Berserker Stance") then return true end
  end
  return false
end

local function HasBattleStance()
  for i = 1, 40 do
    local tex = UnitBuff("player", i)
    if not tex then break end
    if string.find(tex, "Battle Stance") then return true end
  end
  return false
end

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
-- Stance helpers (non‑blocking)
-- =============================
local function EnsureBerserkerStance()
  if not HasBerserkerStance() and GetTime() - lastStanceSwap > 1.0 then
    CastSpellByName("Berserker Stance")
    lastStanceSwap = GetTime()
  end
end

local function EnsureBattleStance()
  if not HasBattleStance() and GetTime() - lastStanceSwap > 1.0 then
    CastSpellByName("Battle Stance")
    lastStanceSwap = GetTime()
  end
end

-- =============================
-- Cast helpers (mark GCD where relevant)
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
  if not ready then return false end
  CastSpellByName("Battle Shout")
  lastGCDAt = GetTime()
  lastBSAt = lastGCDAt
  return true
end

local function CastSunder()
  if not GCDReady() then return false end
  CastSpellByName("Sunder Armor")
  SpellTargetUnit("target")
  lastGCDAt = GetTime()
  return true
end

-- =============================
-- Action‑slot scanner to detect queued HS/Cleave (avoids accidental toggles)
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
    if tex == "Interface\Icons\Ability_Rogue_Ambush" or tex == "Interface\Icons\Ability_Warrior_Cleave" then
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
-- Rage floor & weaving using SP_SwingTimer (main‑hand swing timing)
-- =============================
local function RageFloor(btRem, wwRem)
  if btRem <= IMMINENT_BT_WINDOW then return COST_BT end
  if wwRem <= IMMINENT_WW_WINDOW then return COST_WW end
  return 0
end

-- Decide if we can safely queue HS/Cleave to land on the **next main‑hand** swing
local function TryWeaveSwing(rage, btRem, wwRem)
  if not ValidEnemyTarget() or not InMeleeRange() then return false end
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

  -- If WW also aligns tightly after the swing, add a mild guard
  if wwRem <= (nextMH + 0.6) and (rage - cost) < (COST_WW + HS_BUFFER) and rage < PANIC_RAGE then
    return false
  end

  -- Don’t double‑press if already queued (prevents unqueue)
  if IsSwingQueued() then return false end

  local ready = IsSpellReady(spellName)
  if ready then
    CastSpellByName(spellName) -- queues on next MH swing (no GCD)
    return true
  end
  return false
end

-- =============================
-- Optional: maintain Sunder if neither BT nor WW is imminent
-- =============================
local function MaintainSunders()
  local rage = GetRage()
  if rage < 10 or not ValidEnemyTarget() or not InMeleeRange() then return false end
  local btReady, btStart, btDur = IsSpellReady("Bloodthirst")
  local wwReady, wwStart, wwDur = IsSpellReady("Whirlwind")
  local btRem = CDRemaining(btStart, btDur)
  local wwRem = CDRemaining(wwStart, wwDur)
  if not btReady and not wwReady and btRem > GCD_S and wwRem > GCD_S then
    return CastSunder()
  end
  return false
end

-- =============================
-- TheoCharge: Out‑of‑combat Charge path (stance handled OUTSIDE) / In‑combat Intercept
-- =============================
local function TheoCharge()
  if not ValidEnemyTarget() then return end

  -- hard reset when combat ends (safety; also wired via event below)
  if not PlayerInCombat() and theocharge_phase == 3 then
    theocharge_phase = 0
  end

  if PlayerInCombat() then
    -- In combat: assume stance handled externally; just Intercept
    local ready = IsSpellReady("Intercept")
    if ready and InInterceptRange() then
      CastSpellByName("Intercept"); SpellTargetUnit("target")
    end
    return
  end

  -- Out of combat: assume /theostance handled the stance; now do Charge → Bloodrage across presses
  local chargeReady, cStart, cDur = IsSpellReady("Charge")

  -- Detect if Charge went on cooldown (used successfully)
  if cDur > 0 and cStart ~= lastChargeStart then
    theocharge_phase = 2
    lastChargeStart = cStart
  end

  if theocharge_phase == 0 or theocharge_phase == 1 then
    -- Try to Charge until it actually goes on cooldown
    if chargeReady and InChargeRange() then
      CastSpellByName("Charge"); SpellTargetUnit("target")
      theocharge_phase = 1
      return
    else
      -- keep pressing until in range/ready; stance is managed by /theostance
      return
    end
  end

  if theocharge_phase == 2 then
    -- Next press: Bloodrage
    local brReady = IsSpellReady("Bloodrage")
    if brReady then
      CastSpellByName("Bloodrage")
      theocharge_phase = 3
    end
    return
  end
  -- phase 3: path completed; will reset on combat drop or explicit event
end

-- =============================
-- Main rotation with Execute gating + swing‑timed weaving + Battle Shout upkeep
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
    if btRem <= GCD_S and rage < COST_BT then
      -- hold to secure BT
    elseif wwRem <= GCD_S and btRem > GCD_S and rage < COST_WW then
      -- hold to secure WW
    elseif rage >= COST_EXEC then
      if CastExecute() then return end
    end
  end

  -- 3.5) Battle Shout upkeep – safe spot: both BT and WW are on cooldown and not imminent
  if PlayerInCombat() and rage >= COST_BS and not HasBattleShout() and (GetTime() - lastBSAt) > 0.7 then
    if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if CastBattleShout() then return end
    end
  end

  -- 4) Precise HS/Cleave weaving tied to SP_SwingTimer main‑hand swing (no GCD)
  if TryWeaveSwing(rage, btRem, wwRem) then return end

  -- 5) Optional: maintain Sunder stacks if nothing else to do
  if MaintainSunders() then return end
end

-- =============================
-- Slash commands
-- =============================
SLASH_QHWARRIOR1 = "/qhtwarrior"
SlashCmdList["QHWARRIOR"] = QuickTheoWarrior

SLASH_THEOCLEAVE1 = "/theocleave"
SlashCmdList["THEOCLEAVE"] = function()
  useCleave = not useCleave
  if useCleave then
    DEFAULT_CHAT_FRAME:AddMessage("Cleave mode ENABLED.", 1, 1, 0)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Cleave mode DISABLED.", 1, 0.5, 0.5)
  end
end

SLASH_THEOSAFE1 = "/theosafe"       -- adjust rage buffer for weaving
SlashCmdList["THEOSAFE"] = function(msg)
  local n = tonumber(msg)
  if n then
    HS_BUFFER = math.max(0, math.floor(n))
    DEFAULT_CHAT_FRAME:AddMessage("HS/Cleave safety buffer set to "..HS_BUFFER.." rage.", 0.5, 1, 0.8)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Usage: /theosafe <rageBuffer>", 1, 0.6, 0.6)
  end
end

SLASH_THEOWINDOW1 = "/theowindow"   -- adjust swing queue window
SlashCmdList["THEOWINDOW"] = function(msg)
  local n = tonumber(msg)
  if n then
    SWING_QUEUE_WINDOW = math.max(0.05, math.min(0.8, n))
    DEFAULT_CHAT_FRAME:AddMessage("Swing queue window set to "..string.format("%.2f", SWING_QUEUE_WINDOW).."s.", 0.5, 1, 0.8)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Usage: /theowindow <seconds e.g. 0.35>", 1, 0.6, 0.6)
  end
end

-- Stance ensure kept **outside** TheoCharge to avoid blocking the sequence
local function TheoCharge_EnsureStance()
  if PlayerInCombat() then
    if not HasBerserkerStance() and (GetTime() - lastStanceSwap) > 1.0 then
      CastSpellByName("Berserker Stance")
      lastStanceSwap = GetTime()
    end
  else
    if not HasBattleStance() and (GetTime() - lastStanceSwap) > 1.0 then
      CastSpellByName("Battle Stance")
      lastStanceSwap = GetTime()
    end
  end
end

-- Events: reset theocharge state when leaving combat
local TheoChargeEvt = CreateFrame("Frame")
TheoChargeEvt:RegisterEvent("PLAYER_REGEN_ENABLED")
TheoChargeEvt:SetScript("OnEvent", function()
  theocharge_phase = 0
end)

-- Slash: stance first, then driver
SLASH_THEOSTANCE1 = "/theostance"
SlashCmdList["THEOSTANCE"] = TheoCharge_EnsureStance

-- New: TheoCharge macro
SLASH_THEOCHARGE1 = "/theocharge"
SlashCmdList["THEOCHARGE"] = TheoCharge

DEFAULT_CHAT_FRAME:AddMessage("QuickTheoWarrior loaded! /qhtwarrior, /theocleave, /theosafe <n>, /theowindow <sec>, /theostance, /theocharge.", 0.5, 1, 0)

