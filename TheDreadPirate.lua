-- QuickTheoWarrior.lua – Rage‑smart DPS (Classic/Turtle 1.12)
-- Execute gating so BT/WW never slip; precise HS/Cleave weaving using SP_SwingTimer.
-- HS/Cleave do NOT consume GCD, so we time them to main‑hand swing using st_timer.

local useCleave = false
local useOverpower = true  -- /theoop toggles this
local lastStanceSwap = 0
local lastGCDAt = 0
local lastBSAt = 0 -- micro lockout after casting Battle Shout to avoid re-cast during aura scan delay

local TheoOPPending = false      -- we have committed to an OP sequence (next press = OP)
local TheoOPExpires = 0          -- safety timeout for that pending sequence
local THEO_OP_TIMEOUT = 5.0      -- seconds to keep a pending Overpower window alive
local TheoOPTries = 0            -- how many times we’ll try to fire OP in Battle before giving up

local THEO_OP_ICD = 7.0          -- internal cooldown between successful Overpowers (seconds)
local TheoLastOPAt = 0           -- last time we successfully cast Overpower
local slamWindowExpires = 0
local lastMHTimeLeft    = nil

-- Tiny frame watching:
--   • CHAT_MSG_COMBAT_SELF_MISSES for "Your attack was dodged."
--   • COMBAT_TEXT_UPDATE SPELL_ACTIVE "Overpower" (the <Overpower> floating text)
local TheoOPFrame = CreateFrame("Frame")
TheoOPFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
TheoOPFrame:RegisterEvent("COMBAT_TEXT_UPDATE")

TheoOPFrame:SetScript("OnEvent", function()
  local now = GetTime()

  -- 1) Classic combat log: "Your attack was dodged." / "Your %s was dodged."
  if event == "CHAT_MSG_COMBAT_SELF_MISSES" then
    local msg = arg1
    if not msg then return end
    if string.find(msg, "dodge") or string.find(msg, "dodged") then
      TheoHasOPWindow = true
      TheoOPWindowExpires = now + THEO_OP_TIMEOUT
    end
    return
  end

  -- 2) Floating combat text "spell active" proc: <Overpower>
  if event == "COMBAT_TEXT_UPDATE" then
    local updateType = arg1
    local spellName  = arg2
    -- Default Blizzard FCT sends SPELL_ACTIVE + spell name here.
    if updateType == "SPELL_ACTIVE" and spellName and string.find(spellName, "Overpower") then
      TheoHasOPWindow = true
      TheoOPWindowExpires = now + THEO_OP_TIMEOUT
    end
    return
  end
end)

-- =============================
-- Tuning
-- =============================
local GCD_S = 1.5            -- global cooldown seconds
local GCD_SLAM = 1.0         -- Slam triggers only a 1.0s GCD with talent
local EXECUTE_PHASE = 20     -- sub‑20% HP
local COST_BT = 30
local COST_WW = 25
local COST_EXEC = 10           -- Improved Execute talented (5 rage base); still dumps remaining rage
local COST_CLEAVE = 20
local COST_HS = 12
local COST_BS = 10            -- Battle Shout
-- Costs / thresholds
local COST_PUMMEL = 10  
local COST_MS = 20            -- Master Strike
local MS_MIN   = 70           -- need a big rage bank to press MS (adjust via /theoms)
local THEO_MS_ENABLE = 1      -- 1=enable, 0=disable (toggle via /theomsmode)
-- Weaving
local HS_BUFFER = 0          -- keep this much rage beyond the reserve floor when weaving
local IMMINENT_BT_WINDOW = 1.5  -- treat BT as imminent if ≤ this many seconds
local IMMINENT_WW_WINDOW = 1.5  -- treat WW as imminent if ≤ this many seconds
local SWING_QUEUE_WINDOW = 0.45 -- queue HS/Cleave if MH swing is due within this window (seconds)
local PANIC_RAGE = 85           -- anti‑cap: force weave even if conservative checks fail
local EXEC_PANIC_RAGE = 60      -- if rage >= this in execute, ignore BT/WW and just Execute
local WW_ONCD_BT_IMMINENT_BARRIER = 1.5 -- seconds: if BT is closer than this and rage < 30, briefly hold WW
local EXEC_MIN = 10            -- minimum rage to press Execute (Turtle: Execute dumps remaining rage)
local THEO_EXEC_WEAVE = 0      -- 0=disable HS/Cleave weaving during execute; 1=allow
local earlySunderUsed = false 
local COST_MORTAL_STRIKE = 30   -- Arms Mortal Strike cost / threshold gating
local COST_SLAM          = 15   -- Slam base cost
local SLAM_WINDOW        = 0.40 -- seconds after a white swing where we’re allowed to start a Slam

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
  return CheckInteractDistance("target", 2)
end

-- Prefer CRF (Combat Range Finder) for true melee verification; fall back to spell range.
local function InTrueMeleeTarget()
  if UnitExists("target") and type(CRF) == "table" and type(CRF.IsTargetMeleeGreenOrTeal) == "function" then
    -- GREEN or TEAL arrow from CombatRangeFinder counts as in-range & facing OK
    return CRF:IsTargetMeleeGreenOrTeal()
  end
  -- Fallbacks when CRF isn't loaded: probe with melee-range abilities or interact distance
  local r1 = IsSpellInRange and IsSpellInRange("Hamstring", "target")
  local r2 = IsSpellInRange and IsSpellInRange("Sunder Armor", "target")
  local r3 = IsSpellInRange and IsSpellInRange("Rend", "target")
  if r1 == 1 or r2 == 1 or r3 == 1 then return true end
  return CheckInteractDistance("target", 2)
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

local function TheoArms_CanSlam(rage, inExecute)
  local now = GetTime()

  -- Only right after a white swing
  if slamWindowExpires <= now then return false end
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end
  if not GCDReady() then return false end
  if type(st_timer) ~= "number" or st_timer <= 0 or st_timer > 10 then return false end
  if rage < COST_SLAM then return false end

  -- During execute, if we’re in the high-rage "panic execute" band, let Execute handle it.
  if inExecute and rage >= EXEC_PANIC_RAGE then
    return false
  end

  return true
end


-- =============================
-- Casting helpers
-- =============================
local function CastBloodthirst()
  local ready = IsSpellReady("Bloodthirst")
  if ready and ValidEnemyTarget() and InTrueMeleeTarget() then
    CastSpellByName("Bloodthirst")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastWhirlwind()
  local ready = IsSpellReady("Whirlwind")
  if ready and ValidEnemyTarget() and InMeleeRange() then
    CastSpellByName("Whirlwind")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastExecute()
  local ready = IsSpellReady("Execute")
  if ready and ValidEnemyTarget() and InTrueMeleeTarget() and GCDReady() then
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

local function CastMasterStrike()
  local ready = IsSpellReady("Master Strike")
  if ready and ValidEnemyTarget() and InTrueMeleeTarget() and GCDReady() then
    CastSpellByName("Master Strike")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastPummel()
  local ready = IsSpellReady("Pummel")
  if ready and ValidEnemyTarget() and InTrueMeleeTarget() and GCDReady() then
    CastSpellByName("Pummel")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastMortalStrike()
  local ready = IsSpellReady("Mortal Strike")
  if ready and ValidEnemyTarget() and InTrueMeleeTarget() then
    CastSpellByName("Mortal Strike")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

local function CastSlam()
  local ready = IsSpellReady("Slam")
  if not ready then return false end
  if not GCDReady() then return false end
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end

  CastSpellByName("Slam")
  SpellTargetUnit("target")

  -- Backdate GCD so the script only waits GCD_SLAM seconds after Slam
  local now = GetTime()
  lastGCDAt = now - (GCD_S - GCD_SLAM)

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
-- Slam swing tracking (Arms mode)
-- =============================
-- slamWindowExpires / lastMHTimeLeft are declared near the top of the file
-- so TheoArms_CanSlam and TheoArms_UpdateSlamWindow share the same state.

-- Called every /theoarms press. Uses st_timer (seconds until next MH swing)
-- from SP_SwingTimer to detect when a white hit just landed.
local function TheoArms_UpdateSlamWindow()
  if type(st_timer) ~= "number" or st_timer <= 0 or st_timer > 10 then
    return
  end

  local now = GetTime()

  if lastMHTimeLeft then
    -- st_timer counts DOWN to 0, then jumps UP when a swing fires.
    -- If it jumps up by a bit, treat that as "we just got a white hit".
    if st_timer > (lastMHTimeLeft + 0.2) then
      slamWindowExpires = now + SLAM_WINDOW
    end
  end

  lastMHTimeLeft = st_timer
end


-- =============================
-- Baked-in Overpower handler (stance-dance inside main rotation)
-- Uses real dodge-based window + no Overpower in Execute phase.
-- Once Battle Stance is triggered for OP, it’s OP-or-nothing for a few presses.
-- =============================
local function TheoOverpower_Rotation(rage, btReady, btRem, wwReady, wwRem, inExecute)
  -- If the toggle is OFF, clear stale state and bail
  if not useOverpower then
    TheoOPPending = false
    TheoOPTries   = 0
    TheoOPExpires = 0
    return false
  end

  -- Do not use Overpower at all in Execute phase
  if inExecute then
    TheoOPPending = false
    TheoOPTries   = 0
    TheoOPExpires = 0
    return false
  end

  local now = GetTime()

  -- Expire the Overpower window from dodge
  if TheoHasOPWindow and now > TheoOPWindowExpires then
    TheoHasOPWindow = false
  end

  -- Expire any old pending "next press = Overpower" state
  if TheoOPPending and now > TheoOPExpires then
    TheoOPPending = false
    TheoOPTries   = 0
  end

  -- =========================
  -- Phase 1: we already committed to an OP sequence
  -- =========================
  if TheoOPPending then
    -- If we have no window or no tries left, drop sequence and resume normal rotation
    if not TheoHasOPWindow or TheoOPTries <= 0 then
      TheoOPPending = false
      TheoOPTries   = 0
      TheoOPExpires = 0
      return false
    end

    -- While pending, NOTHING else in the rotation should fire.

    -- First, make sure we actually are in Battle Stance.
    if not HasBattleStance() then
      if (now - lastStanceSwap) > 0.2 then
        CastSpellByName("Battle Stance")
        lastStanceSwap = now
        -- NOTE: do NOT touch lastGCDAt here; stance swap does not use GCD
      end
      -- Still in Overpower mode; completely block BT/WW/HS/etc this press.
      return true
    end

    -- We are in Battle Stance now. Wait for any existing GCD
    -- from BT/WW/Sunder/Master Strike to finish.
    if not GCDReady() then
      return true
    end

    -- Try to cast Overpower if window is still really there
    if TheoHasOPWindow and ValidEnemyTarget() and InTrueMeleeTarget() then
      CastSpellByName("Overpower")
      SpellTargetUnit("target")
      lastGCDAt    = now             -- Overpower DOES use the GCD
      TheoLastOPAt = now

      -- Consume the opportunity
      TheoHasOPWindow     = false
      TheoOPWindowExpires = 0
      TheoOPPending       = false
      TheoOPTries         = 0
      TheoOPExpires       = 0
      return true
    end

    -- We got here: in Battle Stance, window flag set, but something blocked cast
    -- (range/facing/window ended between checks). Try again next press.
    TheoOPTries = TheoOPTries - 1
    if TheoOPTries <= 0 then
      TheoOPPending = false
      TheoOPTries   = 0
      TheoOPExpires = 0
      return false   -- give up and let normal rotation resume next press
    end

    -- Still in OP mode, nothing else should happen this press.
    return true
  end

  -- =========================
  -- Phase 2: decide whether to *start* an OP sequence
  -- =========================

  -- No real Overpower proc? Then we don't do anything.
  if not TheoHasOPWindow then
    return false
  end

  -- Internal cooldown: don't start a fresh OP sequence if we just used Overpower
  if TheoLastOPAt > 0 and (now - TheoLastOPAt) < THEO_OP_ICD then
    return false
  end

  -- Start conditions (only checked BEFORE we commit):
  -- • Rage between 5 and 24
  -- • BT + WW both NOT ready
  if rage >= 30 or rage < 5 then return false end
  if btReady or wwReady then return false end
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end

  -- If we're already in Battle Stance, just slam Overpower (after respecting GCD) and be done.
  if HasBattleStance() then
    if not GCDReady() then
      -- Hold rotation until the GCD is free, then try again next press
      return true
    end
    CastSpellByName("Overpower")
    SpellTargetUnit("target")
    lastGCDAt      = now
    TheoLastOPAt   = now
    TheoHasOPWindow     = false
    TheoOPWindowExpires = 0
    TheoOPPending       = false
    TheoOPTries         = 0
    TheoOPExpires       = 0
    return true
  end

  -- Normal flow: Berserker → Battle Stance, then next several presses = Overpower attempts
  if (now - lastStanceSwap) > 0.2 then
    CastSpellByName("Battle Stance")
    lastStanceSwap = now
    -- NOTE: do NOT touch lastGCDAt here; previous BT/WW/Sunder GCD is still the real one.
    TheoOPPending  = true
    TheoOPTries    = 5         -- TRY Overpower up to 5 times before giving up
    TheoOPExpires  = now + THEO_OP_TIMEOUT  -- safety timeout in case you stop spamming
  end

  -- While we’re in this path, rotation is “owned” by Overpower logic.
  return true
end

-- =============================
-- Early Sunder + Macro Maintenance (SuperCleveroid)
-- =============================
local THEO_EARLY_SUNDER = 1         -- 1 = use one immediate Sunder if target has none
local THEO_SUNDER_MAINTAIN = 1      -- 1 = maintain with macro in safe windows
local THEO_SUNDER_MACRO_NAME = "Sunder5"  -- name of your SuperCleveroid macro

local THEO_SUNDER_MACRO_SLOT, THEO_LAST_MACRO_SCAN = nil, 0
-- Throttle and pending-GCD confirmation for Sunder macro
local THEO_SUNDER_MACRO_THROTTLE = 1.0 -- seconds between macro attempts
local THEO_LAST_SUNDER_MACRO = 0
local PENDING_GCD_FROM_SUNDER, PENDING_AT, PENDING_RAGE = false, 0, 0

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
  local now = GetTime()
  -- Do not spam the macro and do not overlap while awaiting confirmation
  if (now - THEO_LAST_SUNDER_MACRO) < THEO_SUNDER_MACRO_THROTTLE or PENDING_GCD_FROM_SUNDER then
    return false
  end
  PENDING_RAGE = GetRage()
  UseAction(slot)                 -- fires the SuperCleveroid conditional macro
  -- Do NOT stamp lastGCDAt yet; confirm a real GCD or rage spend first
  PENDING_GCD_FROM_SUNDER, PENDING_AT = true, now
  THEO_LAST_SUNDER_MACRO = now
  return true
end

local function EarlySunderIfMissing()
  if THEO_EARLY_SUNDER ~= 1 then return false end

  -- Only once per combat
  if earlySunderUsed then return false end

  -- Only bother once we’ve actually entered combat
  if not PlayerInCombat() then return false end

  if not ValidEnemyTarget() or not InTrueMeleeTarget() or not GCDReady() then return false end

  -- NOTE: removed this so we always add ONE sunder, even if some are already up:
  -- if HasSunderDebuff() then return false end

  if GetRage() < 10 then return false end -- keep a small floor so we don't zero out on pull

  CastSpellByName("Sunder Armor")
  SpellTargetUnit("target")
  lastGCDAt = GetTime()
  earlySunderUsed = true
  return true
end


-- Maintain via macro in safe BT/WW windows (macro self-stops at 5)
local function MaintainSundersMacro(btRem, wwRem)
  if THEO_SUNDER_MAINTAIN ~= 1 then return false end
  if not ValidEnemyTarget() or not InTrueMeleeTarget() or not GCDReady() then return false end
    if btRem <= GCD_S then return false end
       if wwRem <= GCD_S then return false end
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
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end
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

function StampIfRealGCD()
  if not PENDING_GCD_FROM_SUNDER then return end
  local now = GetTime()
  -- Probe shared GCD on nominal 0-CD spells
  local probes = {"Hamstring","Rend","Battle Shout"}
  for _, sp in ipairs(probes) do
    local _, start, dur = IsSpellReady(sp)
    if start and dur and start > 0 and dur >= 1.0 then
      lastGCDAt = start
      PENDING_GCD_FROM_SUNDER = false
      return
    end
  end
  -- Backup: rage delta consistent with Sunder cost
  if (PENDING_RAGE - GetRage()) >= 10 then
    lastGCDAt = now
    PENDING_GCD_FROM_SUNDER = false
    return
  end
  -- If nothing observed within a short window, treat as no-op
  if (now - PENDING_AT) > 0.35 then
    PENDING_GCD_FROM_SUNDER = false
  end
end

-- =============================
-- Main rotation with Execute gating + swing‑timed weaving + Battle Shout + Sunder
-- =============================
function QuickTheoWarrior()
  -- Confirm any pending Sunder macro actually triggered the GCD before proceeding
  StampIfRealGCD()

if not PlayerInCombat() then
    earlySunderUsed = false
  end

  if not ValidEnemyTarget() then return end

  local rage = GetRage()
  local btReady, btStart, btDur = IsSpellReady("Bloodthirst")
  local wwReady, wwStart, wwDur = IsSpellReady("Whirlwind")
  local execReady = IsSpellReady("Execute")
  local btRem = CDRemaining(btStart, btDur)
  local wwRem = CDRemaining(wwStart, wwDur)
  local inExecute = TargetHealthBelow(EXECUTE_PHASE)

  -- NEW: baked-in Overpower handler.
  -- If this returns true, we either stance-swapped or cast Overpower; skip the rest.
   if TheoOverpower_Rotation(rage, btReady, btRem, wwReady, wwRem, inExecute) then
    return
  end

  -- Normal rotation continues in Berserker stance
  EnsureBerserkerStance()
 
 -- NEW 0.x) High-rage HS/Cleave: queue on every press above 90 rage (non-execute)
  -- This does NOT return, so BT/WW/Execute can still be cast in the same press.
  if not inExecute
     and rage >= 90
     and ValidEnemyTarget()
     and InTrueMeleeTarget()
     and not IsSwingQueued() then

    local spellName = useCleave and "Cleave" or "Heroic Strike"
    CastSpellByName(spellName)
    -- no return here: we still fall through to Sunder/BT/WW logic
  end

  -- 1.1) One early Sunder if the target has no Sunder yet (no restrictions)
  if EarlySunderIfMissing() then return end

  -- 1–3) Core rotation with execute-phase BT/WW rules
  if inExecute then
    -- Rage bands for execute-phase behavior
    local inExecLow  = (rage >= EXEC_MIN and rage < 30)  -- 10–30
    local inExecMid  = (rage >= 30 and rage <= 60)       -- 30–60 window
    local inExecHigh = (rage > 60)                       -- 60–100+

    -- A) 10–30 and 60–100 rage: Execute has top priority
    if (inExecLow or inExecHigh) and execReady and InTrueMeleeTarget() then
      if CastExecute() then return end
    end

    -- B) 30–60 rage: behavior depends on HS vs Cleave mode
    if inExecMid then
      if not useCleave then
        -- HS mode: 30–60 window = BT if ready, otherwise Execute
        if btReady and rage >= COST_BT and InTrueMeleeTarget() then
          if CastBloodthirst() then return end
        elseif execReady and rage >= EXEC_MIN and InTrueMeleeTarget() then
          if CastExecute() then return end
        end
      else
        -- Cleave mode: BT or WW if ready, otherwise Execute
        if btReady and rage >= COST_BT and InTrueMeleeTarget() then
          if CastBloodthirst() then return end
        elseif wwReady and rage >= COST_WW and InTrueMeleeTarget() then
          -- Don’t start a WW GCD if BT will be ready during it
          local btImminent = (btRem <= GCD_S)
          if not btImminent then
            if CastWhirlwind() then return end
          end
        elseif execReady and rage >= EXEC_MIN and InTrueMeleeTarget() then
          if CastExecute() then return end
        end
      end
    end

    -- C) Fallback inside execute if nothing has fired yet: BT > WW > Execute
    if btReady and rage >= COST_BT and InTrueMeleeTarget() then
      if CastBloodthirst() then return end
    end

    -- Only allow Whirlwind as a fallback in execute if Cleave mode is ON
    if useCleave and wwReady and rage >= COST_WW and InTrueMeleeTarget() then
      local btImminent = (btRem <= GCD_S)
      if not btImminent then
        if CastWhirlwind() then return end
      end
    end

    if execReady and rage >= EXEC_MIN and InTrueMeleeTarget() then
      if CastExecute() then return end
    end

  else
    -- Non-execute phase: standard BT -> WW priority

    -- 1) Bloodthirst on cooldown
    if btReady and rage >= COST_BT and InTrueMeleeTarget() then
      if CastBloodthirst() then return end
    end

    -- 2) Whirlwind when it won't jeopardize BT
    if wwReady and rage >= COST_WW and InMeleeRange() then
      local btImminent = (btRem <= GCD_S)
      if not btImminent then
        if CastWhirlwind() then return end
      end
    end
  end

  -- 3.5) Battle Shout upkeep – safe spot: both BT and WW are on cooldown and not imminent
  if PlayerInCombat() and rage >= COST_BS and not HasBattleShout() and (GetTime() - lastBSAt) > 0.7 then
      if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if CastBattleShout() then return end
    end
  end

  -- 3.6) Maintain Sunders with macro in safe windows (macro auto-stops at 5)
    if not inExecute and MaintainSundersMacro(btRem, wwRem) then return end

      -- 3.7) Master Strike (rage sink) — only when BT/WW are safely on cooldown and rage is high
    if THEO_MS_ENABLE == 1 and not inExecute then
     -- Both BT and WW must be on cooldown and not about to come up (safe GCD window)
       if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if rage >= MS_MIN then
        if CastMasterStrike() then return end
      end
    end
  end
 
  -- 3.8) Pummel (interrupt) — same safe GCD window as Master Strike
  -- Only when BT/WW are both on cooldown and not about to come up, and not in execute.
  if THEO_MS_ENABLE == 1 and not inExecute then
      if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
     if rage >= MS_MIN then
      if CastPummel() then return end
    end
  end
end

  -- 4) Precise HS/Cleave weaving tied to SP_SwingTimer main‑hand swing (no GCD)
     rage = GetRage()
  local _, btStart2, btDur2 = IsSpellReady("Bloodthirst")
  local _, wwStart2, wwDur2 = IsSpellReady("Whirlwind")
  btRem = CDRemaining(btStart2, btDur2)
  wwRem = CDRemaining(wwStart2, wwDur2)

  if TryWeaveSwing(rage, btRem, wwRem) then return end
end

function QuickTheoArms()
  -- Confirm any pending Sunder macro actually triggered the GCD before proceeding
  StampIfRealGCD()

  if not PlayerInCombat() then
    earlySunderUsed = false
  end

  if not ValidEnemyTarget() then return end

  -- Track swings for Slam weaving
  TheoArms_UpdateSlamWindow()

  local rage = GetRage()
  local msReady, msStart, msDur = IsSpellReady("Mortal Strike")
  local wwReady, wwStart, wwDur = IsSpellReady("Whirlwind")
  local execReady = IsSpellReady("Execute")

  local msRem = CDRemaining(msStart, msDur)
  local wwRem = CDRemaining(wwStart, wwDur)
  local inExecute = TargetHealthBelow(EXECUTE_PHASE)

  -- Overpower handler – treat Mortal Strike as the "big button" for gating
  if TheoOverpower_Rotation(rage, msReady, msRem, wwReady, wwRem, inExecute) then
    return
  end

  -- Arms baseline: still live in Berserker for damage; OP logic stance-dances as needed.
  EnsureBerserkerStance()

  -- One early Sunder per combat (same as Fury)
  if EarlySunderIfMissing() then return end

  -- Execute phase: if we’re about to cap rage, dump first.
  if inExecute and execReady and rage >= EXEC_PANIC_RAGE and InTrueMeleeTarget() and GCDReady() then
    if CastExecute() then return end
  end

  -- 1) Slam — bread and butter, charged immediately after every auto
  rage = GetRage()
  if TheoArms_CanSlam(rage, inExecute) then
    if CastSlam() then return end
  end

  -- 2) Mortal Strike only when we have "extra" rage above Slam fuel
  --    (pay for MS and still keep at least COST_SLAM rage in the bank)
  rage = GetRage()
  if msReady and InTrueMeleeTarget() and rage >= (COST_MORTAL_STRIKE + COST_SLAM) then
    if CastMortalStrike() then return end
  end

  -- 3) Whirlwind – same idea: don't steal Slam rage
  rage = GetRage()
  if wwReady and InMeleeRange() and rage >= (COST_WW + COST_SLAM) then
    if CastWhirlwind() then return end
  end

  -- 4) Battle Shout upkeep – safe spot when MS & WW are both truly on cooldown
  if PlayerInCombat() and rage >= COST_BS and not HasBattleShout() and (GetTime() - lastBSAt) > 0.7 then
    if (not msReady and not wwReady) and msRem > GCD_S and wwRem > GCD_S then
      if CastBattleShout() then return end
    end
  end

  -- 5) Maintain Sunders with macro in safe windows (use MS cooldown as the "BT" reference)
  if not inExecute and MaintainSundersMacro(msRem, wwRem) then return end

  -- 6) Execute as a fallback in execute phase (prio is still MS/WW + Slam below 60 rage)
  if inExecute and execReady and rage >= EXEC_MIN and InTrueMeleeTarget() and GCDReady() then
    if CastExecute() then return end
  end

  -- NOTE: No HS/Cleave weaving in Arms for now; Slam is the primary swing-synced filler.
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
    -- Out of combat

    -- If we're already in Berserker Stance and floating a lot of rage,
    -- just Intercept instead of stance dancing back to Battle for Charge.
    if HasBerserkerStance() and GetRage() >= 50 then
      local ready = IsSpellReady("Intercept")
      if ready then
        CastSpellByName("Intercept")
        return
      end
      -- if Intercept isn't ready, fall through to normal Charge logic
    end

    -- Default: make sure we're in Battle Stance, then Charge
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
-- Raid buff checker (/theobuffs)
-- =============================
local TheoBuffTip = CreateFrame("GameTooltip", "TheoBuffTip", UIParent, "GameTooltipTemplate")
TheoBuffTip:SetOwner(UIParent, "ANCHOR_NONE")

local function Theo_PlayerHasBuff(patterns)
  if type(patterns) == "string" then patterns = {patterns} end

  for i = 1, 40 do
    TheoBuffTip:ClearLines()
    TheoBuffTip:SetUnitBuff("player", i)

    local t1 = _G["TheoBuffTipTextLeft1"]
    local name = t1 and t1:GetText()
    if not name then break end

    local nl = string.lower(name)
    for _, p in ipairs(patterns) do
      if p and p ~= "" and string.find(nl, string.lower(p), 1, true) then
        return true
      end
    end
  end

  return false
end

local THEO_RAID_BUFFS = {
  {"Winterfall Firewater"},
  {"Juju Power"},
  {"Medivh's Merlot", "Merlot"},
  {"Well Fed"},
  {"Elixir of Fortitude"},
  {"Elixir of the Mongoose"},
  {"Spirit of Zanza"},
  {"Elemental Sharpening Stone", "Sharpening Stone"},
  {"R.O.I.D.S.", "R.O.I.D.S", "ROIDS"},
}

SLASH_THEOBUFFS1 = "/theobuffs"
SlashCmdList["THEOBUFFS"] = function()
  local missing = {}

  for _, entry in ipairs(THEO_RAID_BUFFS) do
    local label = entry[1]
    if not Theo_PlayerHasBuff(entry) then
      table.insert(missing, label)
    end
  end

  if table.getn(missing) == 0 then
    DEFAULT_CHAT_FRAME:AddMessage("Theo: Buff check OK (all listed raid buffs found).", 0.5, 1, 0.5)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Theo: Missing buffs -> " .. table.concat(missing, ", "), 1, 0.5, 0.5)
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

-- NEW: Cleave toggle – /theocleave flips between Cleave (20 rage) and HS (12 rage)
SLASH_THEOCLEAVE1 = "/theocleave"
SlashCmdList["THEOCLEAVE"] = function()
  useCleave = not useCleave
  DEFAULT_CHAT_FRAME:AddMessage(
    "Theo: Cleave mode "..(useCleave and "ENABLED (using Cleave, cost 20)." or "DISABLED (using Heroic Strike, cost 12)."),
    0.8, 1, 0.6
  )
end

-- Master Strike + Pummel toggle – /theomsmode flips both on/off
SLASH_THEOMSMODE1 = "/theomsmode"
SlashCmdList["THEOMSMODE"] = function()
  if THEO_MS_ENABLE == 1 then
    THEO_MS_ENABLE = 0
    DEFAULT_CHAT_FRAME:AddMessage(
      "Theo: Master Strike + Pummel DISABLED.",
      1, 0.5, 0.5
    )
  else
    THEO_MS_ENABLE = 1
    DEFAULT_CHAT_FRAME:AddMessage(
      "Theo: Master Strike + Pummel ENABLED.",
      0.5, 1, 0.5
    )
  end
end

-- Overpower toggle – /theoop will enable/disable baked-in Overpower usage
SLASH_THEOOP1 = "/theoop"
SlashCmdList["THEOOP"] = function()
  useOverpower = not useOverpower
  -- Clear any old pending state when switching modes
  TheoOPPending = false
  TheoOPExpires = 0

  DEFAULT_CHAT_FRAME:AddMessage(
    "Theo: Overpower usage "..(useOverpower and "ENABLED (stance-dancing for Overpower when safe)." or "DISABLED."),
    0.8, 1, 0.6
  )
end

SLASH_QHWARRIOR1 = "/qhtwarrior"
SlashCmdList["QHWARRIOR"] = QuickTheoWarrior

-- Slash: stance first, then driver
SLASH_THEOSTANCE1 = "/theostance"
SlashCmdList["THEOSTANCE"] = TheoCharge_EnsureStance

-- TheoCharge macro
SLASH_THEOCHARGE1 = "/theocharge"
SlashCmdList["THEOCHARGE"] = TheoCharge

SLASH_THEOARMS1 = "/theoarms"
SlashCmdList["THEOARMS"] = QuickTheoArms

DEFAULT_CHAT_FRAME:AddMessage("QuickTheoWarrior loaded! /qhtwarrior, /theoexec <n>, /theoexecweave 0|1, /theosundermacro <name>, /theocleave, /theostance, /theocharge.", 0.5, 1, 0)
