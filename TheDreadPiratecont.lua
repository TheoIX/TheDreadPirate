-- =============================
-- QuickTheoWarrior: /theo2hfury module (split-file safe)
-- Load this file AFTER your main addon file in the .toc
-- =============================

-- Compatibility shims when you split the addon into multiple .lua files:
local function Theo2H_PlayerInCombat()
  if type(PlayerInCombat) == "function" then
    return PlayerInCombat()
  end
  return UnitAffectingCombat("player")
end

local function Theo2H_UseCleave()
  if type(Theo_IsCleaveMode) == "function" then
    return Theo_IsCleaveMode()
  end
  -- fallback: if you made useCleave global
  return (type(useCleave) == "boolean" and useCleave) or false
end

local function Theo2H_UpdateSlamWindow()
  if type(TheoArms_UpdateSlamWindow) == "function" then
    TheoArms_UpdateSlamWindow()
  end
end

local function Theo2H_InSlamWindow()
  if type(Theo_InSlamWindow) == "function" then
    return Theo_InSlamWindow()
  end
  local now = GetTime()
  return (slamWindowExpires and slamWindowExpires > now) or false
end

-- ============================================================
-- /theo2hfury: 2H Fury Slam-weave rotation
-- ============================================================

local THEO_2H_EXEC_RAGE       = 70
local THEO_2H_EXEC_FINISH_PCT = 5
local THEO_2H_TRASH_EXEC_PCT  = 10


local THEO_2H_SLAM_CAST_S      = 1.70  -- observed Slam cast time (incl. batching/latency)
local THEO_2H_SLAM_PAD_S       = 0.15  -- safety pad; raise to 0.20 if you still clip swings

-- Extra safety: only Slam if the cast can "fit" before the next white swing according to st_timer.
-- If st_timer is unavailable/invalid, we do NOT block Slam (we still rely on SLAM_WINDOW to prevent clipping).
local function Theo2H_CanFitSlam()
  if type(st_timer) ~= "number" or st_timer <= 0 or st_timer > 10 then
    return true
  end
  return st_timer >= (THEO_2H_SLAM_CAST_S + THEO_2H_SLAM_PAD_S)
end

local function Theo2H_CanCastSlamNow(rage)
  if rage < COST_SLAM then return false end
  if not IsSpellReady("Slam") then return false end
  if not InTrueMeleeTarget() then return false end
  if not Theo2H_InSlamWindow() then return false end
  return Theo2H_CanFitSlam()
end

local function Theo2H_ShouldHoldForSlam(rage)
  if not GCDReady() then return false end
  if rage < COST_SLAM then return false end
  if not IsSpellReady("Slam") then return false end
  if type(st_timer) ~= "number" or st_timer <= 0 or st_timer > 10 then return false end
  return st_timer < (GCD_S - SLAM_WINDOW)
end

function QuickTheo2HFury()
  -- Hard dependency check (prevents silent nil errors)
  if type(StampIfRealGCD) ~= "function"
    or type(ValidEnemyTarget) ~= "function"
    or type(EnsureBerserkerStance) ~= "function"
    or type(GetRage) ~= "function"
    or type(IsSpellReady) ~= "function"
    or type(CDRemaining) ~= "function"
    or type(TargetHealthBelow) ~= "function"
    or type(InTrueMeleeTarget) ~= "function"
    or type(CastSlam) ~= "function"
    or type(CastBloodthirst) ~= "function"
    or type(CastWhirlwind) ~= "function"
    or type(CastExecute) ~= "function"
    or type(EarlySunderIfMissing) ~= "function"
  then
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff5555Theo2HFury: core helpers not found. Paste the exports block into your MAIN file and reload.|r")
    end
    return
  end

  StampIfRealGCD()

  if not Theo2H_PlayerInCombat() then
    earlySunderUsed = false
  end

  if not ValidEnemyTarget() then return end

  EnsureBerserkerStance()

  -- Update post-swing Slam window (if available from main file)
  Theo2H_UpdateSlamWindow()

  local rage = GetRage()
  local btReady, btStart, btDur = IsSpellReady("Bloodthirst")
  local wwReady, wwStart, wwDur = IsSpellReady("Whirlwind")
  local execReady = IsSpellReady("Execute")
  local btRem = CDRemaining(btStart, btDur)
  local wwRem = CDRemaining(wwStart, wwDur)
  local inExecute = TargetHealthBelow(EXECUTE_PHASE)

  -- SA = Early Sunder at start
  if EarlySunderIfMissing() then return end

  -- Trash mode (toggle /theocleave ON): WW > BT > Cleave
  if Theo2H_UseCleave() then
    if inExecute and execReady and rage >= EXEC_MIN and InTrueMeleeTarget() and GCDReady() then
      if ((not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S)
        or TargetHealthBelow(THEO_2H_TRASH_EXEC_PCT) then
        if CastExecute() then return end
      end
    end

    if wwReady and rage >= COST_WW and InTrueMeleeTarget() then
      if CastWhirlwind() then return end
    end

    rage = GetRage()
    if btReady and rage >= COST_BT and InTrueMeleeTarget() then
      if CastBloodthirst() then return end
    end

    -- Queue Cleave via your existing swing-timed weaver
    if type(TryWeaveSwing_FuryNoExec) == "function" then
      rage = GetRage()
      local _, btStart2, btDur2 = IsSpellReady("Bloodthirst")
      local _, wwStart2, wwDur2 = IsSpellReady("Whirlwind")
      btRem = CDRemaining(btStart2, btDur2)
      wwRem = CDRemaining(wwStart2, wwDur2)
      if TryWeaveSwing_FuryNoExec(rage, btRem, wwRem) then return end
    end

    return
  end

  -- Execute phase (boss / single-target)
  if inExecute and execReady and InTrueMeleeTarget() then
    local finish = TargetHealthBelow(THEO_2H_EXEC_FINISH_PCT)
    if (finish and rage >= EXEC_MIN) or (rage >= THEO_2H_EXEC_RAGE) then
      if CastExecute() then return end
    end
  end-- Slam is king: if we just swung and the SLAM_WINDOW is open, Slam wins
rage = GetRage()
if Theo2H_CanCastSlamNow(rage) then
  if CastSlam() then return end
end


  -- If the swing is about to happen and Slam is coming next, don't start BT/WW now.
  rage = GetRage()
  if Theo2H_ShouldHoldForSlam(rage) then
    -- IMPORTANT: don't return entirely (feels dead); just skip BT/WW this tick.
  else
    if btReady and rage >= (COST_BT + COST_SLAM) and InTrueMeleeTarget() then
      if CastBloodthirst() then return end
    end

    rage = GetRage()
    if wwReady and rage >= (COST_WW + COST_SLAM) and InTrueMeleeTarget() then
      if CastWhirlwind() then return end
    end
  end

  -- Optional BS + Sunder maint, only if those helpers are available
  if type(HasBattleShout) == "function"
    and type(CastBattleShout) == "function"
    and type(MaintainSundersMacro) == "function"
  then
    rage = GetRage()
    if Theo2H_PlayerInCombat() and rage >= COST_BS and not HasBattleShout() then
      -- local throttle just for this module
      if (not _G.THEO_2H_LAST_BS_AT) then _G.THEO_2H_LAST_BS_AT = 0 end
      if (GetTime() - _G.THEO_2H_LAST_BS_AT) > 0.7 then
        if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S and not Theo2H_ShouldHoldForSlam(rage) then
          if CastBattleShout() then _G.THEO_2H_LAST_BS_AT = GetTime(); return end
        end
      end
    end

    if not inExecute and not Theo2H_ShouldHoldForSlam(rage) and MaintainSundersMacro(btRem, wwRem) then
      return
    end
  end
end

function QuickTheoFarm()
  -- Confirm any pending Sunder macro actually triggered the GCD before proceeding
  StampIfRealGCD()

  if not PlayerInCombat() then
    earlySunderUsed = false
  end

  if not ValidEnemyTarget() then return end

  -- Always stay in Defensive Stance
  EnsureDefensiveStance()

  local rage = GetRage()

  -- 1) Shield Bash interrupt at TOP priority
  local isCasting = TargetIsCastingSpell()
  if isCasting then
    if CastShieldBash() then return end
  end

  -- 2) Keep HS/Cleave queued anytime over 35 rage (does not consume GCD)
if rage > 35 and ValidEnemyTarget() and InTrueMeleeTarget() and not IsSwingQueued() then
  local cleaveMode = (type(Theo_IsCleaveMode) == "function" and Theo_IsCleaveMode()) or false
  CastSpellByName(cleaveMode and "Cleave" or "Heroic Strike")
  -- do NOT return; allow GCD abilities on the same press
end


  -- 3) Revenge
  if CastRevenge() then return end

  -- 4) Thunder Clap
  rage = GetRage()
  if rage >= COST_TC then
    if CastThunderClap(true) then return end
  end

  -- 5) Battle Shout upkeep
  rage = GetRage()
  if rage >= COST_BS then
    if CastBattleShout() then return end
  end

  -- 6) Demoralizing Shout if missing
  rage = GetRage()
  if rage >= COST_DEMO then
    if CastDemoralizingShout() then return end
  end

  -- 7) Sunder Armor lowest priority (uses your ADF-aware macro plumbing)
  rage = GetRage()
  if rage >= 15 and GCDReady() and InTrueMeleeTarget() then
    if UseSunderMacro() then return end
  end

  -- 8) Regular HS/Cleave weaver at the very bottom
  rage = GetRage()
  if TryWeaveSwing_Protect(rage, 9999) then return end
end

SLASH_THEOFARM1 = "/theofarm"
SlashCmdList["THEOFARM"] = QuickTheoFarm

SLASH_THEO2HFURY1 = "/theo2hfury"
SlashCmdList["THEO2HFURY"] = QuickTheo2HFury
