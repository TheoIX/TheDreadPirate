-- QuickTheoWarrior.lua – Rage‑smart DPS (Classic/Turtle 1.12)
-- Execute gating so BT/WW never slip; precise HS/Cleave weaving using SP_SwingTimer.
-- HS/Cleave do NOT consume GCD, so we time them to main‑hand swing using st_timer.
local warthogMode = false -- /warthog toggles this
local weaponxPVP = false -- /weaponx PvP mode toggle
local useCleave = false
local useOverpower = false  -- /theoop toggles this
local lastStanceSwap = 0
local lastGCDAt = 0
local lastBSAt = 0 -- micro lockout after casting Battle Shout to avoid re-cast during aura scan delay
local lastDemoAt = 0 -- micro lockout after casting Demo Shout (debuff scan delay)

local TheoOPPending = false      -- we have committed to an OP sequence (next press = OP)
local TheoOPExpires = 0          -- safety timeout for that pending sequence
local THEO_OP_TIMEOUT = 5.0      -- seconds to keep a pending Overpower window alive
local TheoOPTries = 5            -- how many times we’ll try to fire OP in Battle before giving up

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
local COST_WW = 20
local COST_EXEC = 10           -- Improved Execute talented (5 rage base); still dumps remaining rage
local COST_CLEAVE = 20
local COST_HS = 7
local COST_BS = 10            -- Battle Shout
local COST_REVENGE = 5
-- Costs / thresholds
local COST_PUMMEL = 10  
local COST_MS = 20            -- Master Strike
local MS_MIN   = 70           -- need a big rage bank to press MS (adjust via /theoms)
local THEO_MS_ENABLE = 1      -- 1=enable, 0=disable (toggle via /theomsmode)
-- Weaving
local HS_BUFFER = 5          -- keep this much rage beyond the reserve floor when weaving
local IMMINENT_BT_WINDOW = 1.5  -- treat BT as imminent if ≤ this many seconds
local IMMINENT_WW_WINDOW = 1.5  -- treat WW as imminent if ≤ this many seconds
local SWING_QUEUE_WINDOW = 0.65 -- queue HS/Cleave if MH swing is due within this window (seconds)
local PANIC_RAGE = 60           -- anti‑cap: force weave even if conservative checks fail
local EXEC_PANIC_RAGE = 60      -- if rage >= this in execute, ignore BT/WW and just Execute
local WW_ONCD_BT_IMMINENT_BARRIER = 1.5 -- seconds: if BT is closer than this and rage < 30, briefly hold WW
local EXEC_MIN = 10            -- minimum rage to press Execute (Turtle: Execute dumps remaining rage)
local THEO_EXEC_WEAVE = 0      -- 0=disable HS/Cleave weaving during execute; 1=allow
local earlySunderUsed = false 
local COST_MORTAL_STRIKE = 30   -- Arms Mortal Strike cost / threshold gating
local COST_SLAM          = 15   -- Slam base cost
local SLAM_WINDOW        = 0.40 -- seconds after a white swing where we’re allowed to start a Slam
local COST_TC = 16            -- Thunder Clap
local COST_DEMO = 10  -- Demoralizing Shout

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
  {"Health II"},
  {"Elixir of the Mongoose"},
  {"Spirit of Zanza"},
  {"Rage of Ages", "Rage"},
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

local TheoDebuffTip = CreateFrame("GameTooltip", "TheoDebuffTip", UIParent, "GameTooltipTemplate")
TheoDebuffTip:SetOwner(UIParent, "ANCHOR_NONE")

local function Theo_PlayerHasDebuff(patterns)
  if type(patterns) == "string" then
    patterns = {patterns}
  end

  for i = 1, 16 do
    TheoDebuffTip:ClearLines()
    TheoDebuffTip:SetUnitDebuff("player", i)

    local t1 = _G["TheoDebuffTipTextLeft1"]
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

local function IsSpellUsableNow(spellName)
  if type(IsUsableSpell) ~= "function" then return true end
  local usable, notEnough = IsUsableSpell(spellName)
  if usable == nil then return true end
  if usable == 1 or usable == true then
    if notEnough == 1 or notEnough == true then return false end
    return true
  end
  return false
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

local function TargetHealthAbove(p)
  if not UnitExists("target") then return false end
  local hp = (UnitHealth("target") / math.max(1, UnitHealthMax("target"))) * 100
  return hp > p
end

local function TargetHealthBelow(p)
  if not UnitExists("target") then return false end
  local hp = (UnitHealth("target") / math.max(1, UnitHealthMax("target"))) * 100
  return hp <= p
end

local function GCDReady()
  return (GetTime() - lastGCDAt) >= GCD_S
end

-- Returns:
--   isCasting (bool),
--   spellName (string or nil),
--   kind ("cast" or "channel" or nil)
local function TargetIsCastingSpell()
  if not UnitExists("target") then
    return false, nil, nil
  end

  -- If Turtle/SuperWoW provides these (some clients do), use them first.
  if type(UnitCastingInfo) == "function" then
    local spellName = UnitCastingInfo("target")
    if spellName then
      return true, spellName, "cast"
    end
  end

  if type(UnitChannelInfo) == "function" then
    local spellName = UnitChannelInfo("target")
    if spellName then
      return true, spellName, "channel"
    end
  end

  -- Vanilla fallback: rely on the target cast bar being visible.
  local bar = TargetFrameSpellBar
  if bar and (bar:IsShown() or bar:IsVisible()) then
    local spellName = (bar.Text and bar.Text.GetText and bar.Text:GetText()) or nil
    local kind = bar.channeling and "channel" or "cast"
    return true, spellName, kind
  end

  return false, nil, nil
end

local function Theo_IsBossLikeTarget()
  if not UnitExists("target") then return false end

  local class = UnitClassification("target")
  if class == "worldboss" or class == "boss" then
    return true
  end

  -- Some 1.12/Turtle units may present boss mobs oddly; level -1 is still a good fallback.
  local lvl = UnitLevel("target")
  if lvl == -1 then
    return true
  end

  return false
end

local function CastBloodrage()
  local ready = IsSpellReady("Bloodrage")
  if not ready then return false end
  if not PlayerInCombat() then return false end
  if not ValidEnemyTarget() then return false end
  if not InTrueMeleeTarget() then return false end

  CastSpellByName("Bloodrage")
  return true
end

-- =============================
-- Dual/Shield swap macros (by aggro)
-- =============================
local THEO_DUAL_MACRO_NAME   = "Dual"
local THEO_SHIELD_MACRO_NAME = "Shield"

local THEO_DUAL_MACRO_SLOT, THEO_SHIELD_MACRO_SLOT = nil, nil
local THEO_SWAP_LAST_SCAN = 0
local THEO_SWAP_THROTTLE  = 0.25
local THEO_SWAP_LAST_AT   = 0
local THEO_LAST_SWAP_MODE = nil  -- "dual" or "shield"

local function RefreshSwapMacroSlots(force)
  local now = GetTime()
  if not force
     and (now - THEO_SWAP_LAST_SCAN) < 1.0
     and THEO_DUAL_MACRO_SLOT and THEO_SHIELD_MACRO_SLOT then
    return
  end

  THEO_SWAP_LAST_SCAN = now
  THEO_DUAL_MACRO_SLOT, THEO_SHIELD_MACRO_SLOT = nil, nil

  for slot = 1, 120 do
    local name = GetActionText(slot) -- macros return their macro name here
    if name == THEO_DUAL_MACRO_NAME then
      THEO_DUAL_MACRO_SLOT = slot
    elseif name == THEO_SHIELD_MACRO_NAME then
      THEO_SHIELD_MACRO_SLOT = slot
    end
    if THEO_DUAL_MACRO_SLOT and THEO_SHIELD_MACRO_SLOT then break end
  end
end

local function UseSwapMacro(mode)
  RefreshSwapMacroSlots(false)

  local slot = (mode == "shield") and THEO_SHIELD_MACRO_SLOT or THEO_DUAL_MACRO_SLOT
  if not slot or not HasAction(slot) then return false end

  local now = GetTime()
  if (now - THEO_SWAP_LAST_AT) < THEO_SWAP_THROTTLE then return false end

  UseAction(slot) -- fires your named macro from the action bar
  THEO_SWAP_LAST_AT = now
  return true
end

local function IHaveAggroOnTarget()
  return UnitExists("targettarget") and UnitIsUnit("targettarget", "player")
end

local function TheoSwapWeaponSetByAggro()
  -- Only do this in combat (per your request)
  if not PlayerInCombat() then
    THEO_LAST_SWAP_MODE = nil
    return false
  end
  if not ValidEnemyTarget() then return false end

  -- If target is attacking me (I have aggro) -> Shield macro, else -> Dual macro
  local desired = IHaveAggroOnTarget() and "shield" or "dual"
  if THEO_LAST_SWAP_MODE == desired then return false end

  if UseSwapMacro(desired) then
    THEO_LAST_SWAP_MODE = desired
    return true
  end

  return false
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
local function HasDefensiveStance()       return CurrentStance() == 2 end
local function HasBerserkerStance() return CurrentStance() == 3 end

local function EnsureBerserkerStance()
  if CurrentStance() ~= 3 and (GetTime() - lastStanceSwap) > 0.2 then
    CastSpellByName("Berserker Stance")
    lastStanceSwap = GetTime()
     lastGCDAt = lastStanceSwap
  end
end

local function EnsureDefensiveStance()
  if CurrentStance() ~= 2 and (GetTime() - lastStanceSwap) > 0.2 then
    CastSpellByName("Defensive Stance")
    lastStanceSwap = GetTime()
     lastGCDAt = lastStanceSwap
  end
end

local function EnsureBattleStance()
  if CurrentStance() ~= 1 and (GetTime() - lastStanceSwap) > 0.2 then
    CastSpellByName("Battle Stance")
    lastStanceSwap = GetTime()
     lastGCDAt = lastStanceSwap
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
  if ready and ValidEnemyTarget() and InTrueMeleeTarget() then
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

local function CastShieldBash()
  if not GCDReady() then return false end

  local rage = GetRage()
  if rage < 10 then return false end

  local ready = IsSpellReady("Shield Bash")
  if not ready then return false end
  if not IsSpellUsableNow("Shield Bash") then return false end

  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end

  CastSpellByName("Shield Bash")
  SpellTargetUnit("target")
  lastGCDAt = GetTime()
  return true
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

local function CastIntervene()
  local ready = IsSpellReady("Intervene")
  if ready
     and UnitExists("target")
     and UnitIsFriend("player", "target")
     and not UnitIsDead("target")
     and not UnitIsUnit("target", "player")
     and GCDReady() then

    CastSpellByName("Intervene")
    SpellTargetUnit("target")
    lastGCDAt = GetTime()
    return true
  end
  return false
end

-- Hamstring debuff check (icon only, 1.12-safe)
local function TargetHasHamstringDebuff()
  if not UnitExists("target") then return false end
  for i = 1, 40 do
    local tex = UnitDebuff("target", i)
    if not tex then break end
    if type(tex) == "string" then
      local t = string.lower(tex)
      -- Hamstring icon is commonly Ability_ShockWave in 1.12
      if string.find(t, "ability_shockwave") or string.find(t, "shockwave") then
        return true
      end
    end
  end
  return false
end

local function CastHamstring()
  local COST_HAMSTRING = 10
  local ready = IsSpellReady("Hamstring")
  if not ready then return false end
  if not IsSpellUsableNow("Hamstring") then return false end
  if not GCDReady() then return false end   -- <--- ADD THIS
  if GetRage() < COST_HAMSTRING then return false end
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end

  CastSpellByName("Hamstring")
  SpellTargetUnit("target")
  lastGCDAt = GetTime()
  return true
end

local function CastPerception()
  local ready = IsSpellReady("Perception")
  if not ready then return false end
  if not ValidEnemyTarget() then return false end

  CastSpellByName("Perception")
  return true
end

-- =============================
-- Revenge proc tracking (block/dodge/parry window)
-- =============================
local THEO_REVENGE_TIMEOUT = 5.0
local TheoRevengeWindowExpires = 0

local TheoRevengeFrame = CreateFrame("Frame")
TheoRevengeFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
TheoRevengeFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES")
TheoRevengeFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
TheoRevengeFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS")

TheoRevengeFrame:SetScript("OnEvent", function()
  local msg = arg1
  if not msg then return end
  msg = string.lower(msg)

  -- Enemy attack vs you resulted in: dodge/parry/block (wording varies slightly)
  if string.find(msg, "dodge") or string.find(msg, "dodged")
     or string.find(msg, "parry") or string.find(msg, "parries")
     or string.find(msg, "block") or string.find(msg, "blocked") then
    TheoRevengeWindowExpires = GetTime() + THEO_REVENGE_TIMEOUT
  end
end)

local function TheoHasRevengeProc()
  return GetTime() < TheoRevengeWindowExpires
end

local function CastRevenge()
  local rage = GetRage()
  local ready = IsSpellReady("Revenge")
  if not ready or rage < COST_REVENGE then return false end
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end

  -- only attempt when we've actually seen a block/dodge/parry recently
  if not TheoHasRevengeProc() then return false end

  -- caller (/theoprotect) already ensures Defensive; don't stance-dance here
  if not HasDefensiveStance() then return false end
  if not GCDReady() then return false end

  CastSpellByName("Revenge")
  SpellTargetUnit("target")
  TheoRevengeWindowExpires = 0 -- consume our local proc flag
  lastGCDAt = GetTime()
  return true
end

-- Thunder Clap debuff check (icon only)
local function TargetHasThunderClapDebuff()
  for i=1,40 do
    local tex = UnitDebuff("target", i)
    if not tex then break end
    if type(tex)=="string" and string.find(string.lower(tex), "thunderclap") then
      return true
    end
  end
  return false
end

local function CastThunderClap(ignoreDebuff)
  local ready = IsSpellReady("Thunder Clap")
  if not ready or not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end
  if not IsSpellUsableNow("Thunder Clap") then return false end
  if (not ignoreDebuff) and TargetHasThunderClapDebuff() then return false end
  if not GCDReady() then return false end

  CastSpellByName("Thunder Clap")
  SpellTargetUnit("target")
  lastGCDAt = GetTime()
  return true
end

local function HasDemoralizingShoutDebuff()
  if not UnitExists("target") then return false end
  for i = 1, 40 do
    local tex = UnitDebuff("target", i)
    if not tex then break end
    if type(tex) == "string" then
      local t = string.lower(tex)
      -- 1.12 Demo Shout icon is commonly Ability_Warrior_WarCry
      if string.find(t, "ability_warrior_warcry")
         or string.find(t, "warcry")
         or string.find(t, "demoral") then
        return true
      end
    end
  end
  return false
end

local function CastDemoralizingShout()
  if not GCDReady() then return false end

  local ready = IsSpellReady("Demoralizing Shout")
  if not ready then return false end
  if not IsSpellUsableNow("Demoralizing Shout") then return false end

  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end
  if HasDemoralizingShoutDebuff() then return false end

  CastSpellByName("Demoralizing Shout")
  lastDemoAt = GetTime()
  lastGCDAt  = GetTime()
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
local function TheoOverpower_Rotation(rage, btReady, btRem, inExecute)
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
    TheoOPTries = TheoOPTries - 0
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
  if rage >= 35 or rage < 5 then return false end
  if btReady then return false end
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
local PENDING_EARLY_SUNDER = false

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

-- If aDF (Armor Debuff Finder) is installed, use it to read exact Sunder stacks.
-- Returns: number (0..5+) OR nil if aDF isn't available.
local function GetSunderStacksFromADF()
  if not aDF or type(aDF.GetDebuff) ~= "function" then return nil end
  if not aDFSpells or not aDFSpells["Sunder Armor"] then return nil end

  -- aDF:GetDebuff(unit, spellTextOrList, wantStacks)
  local stacks = aDF:GetDebuff("target", aDFSpells["Sunder Armor"], 1)
  if type(stacks) == "number" then return stacks end
  return nil
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
  -- HARD STOP: if aDF detects 5+ stacks, do not press the Sunder macro at all.
  local adfStacks = GetSunderStacksFromADF()
  if adfStacks and adfStacks >= 5 then
    return false
  end
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

  -- Only once per combat (but don't burn it until we confirm a real cast)
  if earlySunderUsed then return false end

  -- Don't overlap with macro sunder or another pending early sunder
  if PENDING_GCD_FROM_SUNDER or PENDING_EARLY_SUNDER then return false end

  if not ValidEnemyTarget() or not InTrueMeleeTarget() or not GCDReady() then return false end
  if GetRage() < 5 then return false end
 
   local adfStacks = GetSunderStacksFromADF()
  if adfStacks and adfStacks >= 5 then
    return false
  end

  -- Attempt cast; confirm next press via StampIfRealGCD()
  PENDING_RAGE = GetRage()
  CastSpellByName("Sunder Armor")
  PENDING_GCD_FROM_SUNDER, PENDING_AT = true, GetTime()
  PENDING_EARLY_SUNDER = true
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

local function Theo_FindBagItemByName(itemName)
  local needle = string.lower(itemName or "")
  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link and string.find(string.lower(link), needle, 1, true) then
        return bag, slot
      end
    end
  end
  return nil, nil
end

local function Theo_CanUseBagItemByName(itemName)
  local bag, slot = Theo_FindBagItemByName(itemName)
  if not bag then return false end

  local start, duration, enable = GetContainerItemCooldown(bag, slot)
  if enable ~= 1 then return false end
  if start and duration and start > 0 and duration > 0 then return false end

  return bag, slot
end

local function Theo_UseBagItemByName(itemName)
  local bag, slot = Theo_CanUseBagItemByName(itemName)
  if not bag then return false end

  UseContainerItem(bag, slot)
  return true
end

local function Theo_UseWarthogQuicknessPotion()
  if not warthogMode then return false end
  if not PlayerInCombat() then return false end
  if not ValidEnemyTarget() then return false end
  if not InTrueMeleeTarget() then return false end
  if not Theo_IsBossLikeTarget() then return false end

  -- Use tooltip-name buff detection, since this file already supports that well.
  if not Theo_PlayerHasDebuff("Death Wish") then return false end
  -- Optional anti-waste: don't try again if the haste potion buff is already active.
  if Theo_PlayerHasBuff({"Potion of Quickness", "Quickness"}) then return false end

  return Theo_UseBagItemByName("Potion of Quickness")
end

local function Theo_UseWarthogJujuFlurry()
  if not warthogMode then return false end
  if not PlayerInCombat() then return false end
  if not ValidEnemyTarget() then return false end
  if not InTrueMeleeTarget() then return false end
  if not Theo_IsBossLikeTarget() then return false end

  -- No Death Wish requirement for Juju Flurry.
  -- Optional anti-waste: don't re-use if buff already active.
  if Theo_PlayerHasBuff({"Juju Flurry", "Flurry"}) then return false end

  return Theo_UseBagItemByName("Juju Flurry")
end

local function Theo_HasDeathWishBuff()
  for i = 1, 40 do
    local tex = UnitBuff("player", i)
    if not tex then break end
    if type(tex) == "string" then
      local t = string.lower(tex)
      if string.find(t, "deathwish")
         or string.find(t, "ability_whirlwind")
         or string.find(t, "spell_shadow_deathpact") then
        return true
      end
    end
  end
  return false
end

local function Theo_SlotHasWarthogTrinket(slot)
  local link = GetInventoryItemLink("player", slot)
  if not link then return false end

  local s = string.lower(link)
  return string.find(s, "earthstrike", 1, true)
      or string.find(s, "molten emberstone", 1, true)
end

local function Theo_CanUseWarthogTrinket(slot)
  if not Theo_SlotHasWarthogTrinket(slot) then return false end

  local start, duration, enable = GetInventoryItemCooldown("player", slot)
  if enable ~= 1 then return false end
  if start and duration and start > 0 and duration > 0 then return false end

  return true
end

local function Theo_UseWarthogTrinkets()
  if not warthogMode then return false end
  if not PlayerInCombat() then return false end
  if not ValidEnemyTarget() then return false end
  if not InTrueMeleeTarget() then return false end

  local bossLike = Theo_IsBossLikeTarget()
  local hasDW = Theo_PlayerHasDebuff("Death Wish")

  for slot = 13, 14 do
    if Theo_CanUseWarthogTrinket(slot) then
      if not bossLike then
        UseInventoryItem(slot)
        return true
      end

      if hasDW then
        UseInventoryItem(slot)
        return true
      end
    end
  end

  return false
end

local function Theo_UseWarthog()
  if not warthogMode then return false end
  if not ValidEnemyTarget() then return false end

  local inMelee = InTrueMeleeTarget()

  -- =========================================================
  -- 1) Perception
  -- =========================================================
  local percReady = IsSpellReady("Perception")
  if percReady then
    if not inMelee then
      return CastPerception()
    end

    local btReady = IsSpellReady("Bloodthirst")
    local wwReady = IsSpellReady("Whirlwind")

    if inMelee and (not btReady) and (not wwReady) and TargetHealthAbove(20) then
      return CastPerception()
    end
  end

  -- =========================================================
  -- 2) Bloodrage
  -- =========================================================
  if inMelee and PlayerInCombat() then
    local bossLike = Theo_IsBossLikeTarget()

    if not bossLike then
      if CastBloodrage() then
        return true
      end
    else
      if TargetHealthBelow(20) then
        if CastBloodrage() then
          return true
        end
      end
    end
  end

  -- =========================================================
  -- 3) Warthog trinkets
  -- =========================================================
  if Theo_UseWarthogTrinkets() then
    return true
  end

  -- =========================================================
  -- 4) Boss quickness potion
  -- =========================================================
  if Theo_UseWarthogQuicknessPotion() then
    return true
  end

  -- =========================================================
  -- 5) Boss juju flurry
  -- =========================================================
  if Theo_UseWarthogJujuFlurry() then
    return true
  end

  return false
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

  local function Confirm(stampTime)
    lastGCDAt = stampTime
    PENDING_GCD_FROM_SUNDER = false
    if PENDING_EARLY_SUNDER then
      earlySunderUsed = true
      PENDING_EARLY_SUNDER = false
    end
  end

  local now = GetTime()

  -- Probe shared GCD on nominal 0-CD spells
  local probes = {"Hamstring","Rend","Battle Shout"}
  for _, sp in ipairs(probes) do
    local _, start, dur = IsSpellReady(sp)
    if start and dur and start > 0 and dur >= 1.0 then
      Confirm(start)
      return
    end
  end

  -- Backup: rage delta consistent with Sunder cost
  if (PENDING_RAGE - GetRage()) >= 10 then
    Confirm(now)
    return
  end

  -- If nothing observed within a short window, treat as no-op (do NOT burn earlySunderUsed)
  if (now - PENDING_AT) > 0.8 then
    PENDING_GCD_FROM_SUNDER = false
    PENDING_EARLY_SUNDER = false
  end
end

-- Prot variant: HS/Cleave queueing that only reserves rage for BT (ignores WW + execute weave rules)
local function TryWeaveSwing_Protect(rage, btRem)
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end
  if type(st_timer) ~= "number" or st_timer <= 0 then return false end

  local nextMH = st_timer
  if nextMH <= 0 or nextMH > 10 then return false end

  -- Only queue inside the pre-swing window (unless we're panic-capping rage)
  if nextMH > SWING_QUEUE_WINDOW and rage < PANIC_RAGE then return false end

  local spellName = useCleave and "Cleave" or "Heroic Strike"
  local cost      = useCleave and COST_CLEAVE or COST_HS

  -- If BT is imminent (before/around the swing), ensure we can afford BT + queued cost + buffer
  if btRem <= (nextMH + IMMINENT_BT_WINDOW) then
    if rage < (COST_BT + cost + HS_BUFFER) then return false end
  else
    -- Otherwise, just don't dump below buffer (unless panic rage)
    if (rage - cost) < HS_BUFFER and rage < PANIC_RAGE then return false end
  end

  if IsSwingQueued() then return false end
  CastSpellByName(spellName)
  return true
end

-- Fury weave helper with NO Whirlwind logic (for /theofury no-AOE mode)
local function RageFloor_NoWW(btRem)
  if btRem <= IMMINENT_BT_WINDOW then return COST_BT end
  return 0
end

local function TryWeaveSwing_FuryNoWW(rage, btRem)
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end
  if type(st_timer) ~= "number" or st_timer <= 0 then return false end

  local nextMH = st_timer
  if nextMH <= 0 or nextMH > 10 then return false end

  if nextMH > SWING_QUEUE_WINDOW and rage < PANIC_RAGE then return false end

  local floor = RageFloor_NoWW(btRem)
  local spellName = useCleave and "Cleave" or "Heroic Strike"
  local cost = useCleave and COST_CLEAVE or COST_HS

  if btRem <= (nextMH + IMMINENT_BT_WINDOW) then
    if rage < (COST_BT + cost + HS_BUFFER) then return false end
  else
    if (rage - cost) < (floor + HS_BUFFER) and rage < PANIC_RAGE then return false end
  end

  if IsSwingQueued() then return false end
  CastSpellByName(spellName)
  return true
end

-- ============================================================
-- /theofury: Fury DW rotation WITHOUT Execute and WITHOUT Overpower
-- Goal: conservative trash rotation (no Execute dumping), otherwise identical feel.
-- Paste this block:
--   1) Put the helper TryWeaveSwing_FuryNoExec near your other weaving helpers (after TryWeaveSwing).
--   2) Put QuickTheoFury() near QuickTheoWarrior() (after it is fine).
--   3) Add the slash command at the bottom with your other SlashCmdList registrations.
-- ============================================================

-- 1) Weave helper that DOES NOT disable weaving below 20% (because this rotation never Executes)
--    This is a copy of TryWeaveSwing() with the execute-phase weaving lock removed.
local function TryWeaveSwing_FuryNoExec(rage, btRem, wwRem)
  if not ValidEnemyTarget() or not InTrueMeleeTarget() then return false end
  if type(st_timer) ~= "number" or st_timer <= 0 then return false end

  local nextMH = st_timer -- seconds until MH swing (from SP_SwingTimer)
  if nextMH <= 0 or nextMH > 10 then return false end

  -- Only queue inside a narrow pre-swing window (unless we're panic-capping rage)
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

  -- If we're already queued, do nothing
  if IsSwingQueued() then return false end

  -- Queue HS/Cleave
  CastSpellByName(spellName)
  return true
end

-- 2) Fury rotation (no Execute, no Overpower)
function QuickTheoFury()
  -- Confirm any pending Sunder macro actually triggered the GCD before proceeding
  StampIfRealGCD()

  if not PlayerInCombat() then
    earlySunderUsed = false
  end

  if not ValidEnemyTarget() then return end

  local rage = GetRage()
  local btReady, btStart, btDur = IsSpellReady("Bloodthirst")
  local btRem = CDRemaining(btStart, btDur)

  -- If this returns true, we either stance-swapped or cast Overpower; skip the rest.
   if TheoOverpower_Rotation(rage, btReady, btRem, wwReady, wwRem, inExecute) then
    return
  end

  -- Always Berserker stance for this DPS rotation
  EnsureBerserkerStance()

  -- 0.x) High-rage HS/Cleave: queue on every press above threshold
  -- Does NOT return so BT/WW can still fire the same press.
  if rage >= 50
     and InTrueMeleeTarget()
     and not IsSwingQueued() then
    local spellName = useCleave and "Cleave" or "Heroic Strike"
    CastSpellByName(spellName)
  end

  -- 1) One early Sunder per combat (your existing helper)
  if EarlySunderIfMissing() then return end

  -- 2) Bloodthirst on cooldown
  if btReady and rage >= COST_BT and InTrueMeleeTarget() then
    if CastBloodthirst() then return end
  end


  -- 4) Battle Shout upkeep – safe window (BT & WW both on cooldown and not imminent)
  if PlayerInCombat() and rage >= COST_BS and not HasBattleShout() and (GetTime() - lastBSAt) > 0.7 then
    if (not btReady) and btRem > GCD_S then
      if CastBattleShout() then return end
    end
  end

  -- 5) Maintain Sunders with macro in safe windows (macro auto-stops at 5)
  if MaintainSundersMacro(btRem, 9999) then return end

  -- 6) Master Strike (rage sink) — only when BT/WW are safely on cooldown and rage is high
  if THEO_MS_ENABLE == 1 then
    if (not btReady) and btRem > GCD_S then
      if rage >= MS_MIN then
        if CastMasterStrike() then return end
      end
    end
  end

  -- 7) Pummel (interrupt) — same safe GCD window as Master Strike
  if THEO_MS_ENABLE == 1 then
    if (not btReady) and btRem > GCD_S then
      if rage >= MS_MIN then
        if CastPummel() then return end
      end
    end
  end

  -- 8) Precise HS/Cleave weaving tied to SP_SwingTimer main-hand swing timing
  rage = GetRage()
local _, btStart2, btDur2 = IsSpellReady("Bloodthirst")
btRem = CDRemaining(btStart2, btDur2)

  if TryWeaveSwing_FuryNoWW(rage, btRem) then return end
end

-- ============================================================
-- /theotrash: Trash DW rotation with /theocleave-dependent prio
--  /theocleave OFF:
--    - HS queued any time rage >= 42
--    - BT priority
--    - WW only if rage >= 60 AND BT is on cooldown (not ready / not imminent)
--  /theocleave ON:
--    - Cleave queued any time rage >= 45
--    - WW priority
--    - BT locked behind 60 rage (and don't steal a GCD if WW is imminent)
-- ============================================================
function quicktheotrash()
  -- Confirm any pending Sunder macro actually triggered the GCD before proceeding
  StampIfRealGCD()

  if not PlayerInCombat() then
    earlySunderUsed = false
  end

  if not ValidEnemyTarget() then return end

  local rage = GetRage()
  local btReady, btStart, btDur = IsSpellReady("Bloodthirst")
  local wwReady, wwStart, wwDur = IsSpellReady("Whirlwind")
  local btRem = CDRemaining(btStart, btDur)
  local wwRem = CDRemaining(wwStart, wwDur)

  if Theo_UseWarthog() then
    return
  end

  -- Always Berserker stance for this DPS rotation
  EnsureBerserkerStance()

  -- 0.x) Keep HS/Cleave queued based on /theocleave toggle
  -- Does NOT return so BT/WW can still fire the same press.
  if InTrueMeleeTarget() and not IsSwingQueued() then
    if useCleave then
      if rage >= 40 then
        CastSpellByName("Cleave")
      end
    else
      if rage >= 40 then
        CastSpellByName("Heroic Strike")
      end
    end
  end

  -- 1) One early Sunder per combat (your existing helper)
  if EarlySunderIfMissing() then return end

  -- 2–3) BT/WW priority changes based on /theocleave
  if useCleave then
    -- /theocleave ON: WW prio
    if wwReady and rage >= COST_WW and InTrueMeleeTarget() then
      if CastWhirlwind() then return end
    end

    -- BT locked behind 60 rage; also don't steal a GCD if WW is about to come up
    if btReady and rage >= 45 and InTrueMeleeTarget() then
      local wwImminent = (wwRem <= GCD_S)
      if not wwImminent then
        if CastBloodthirst() then return end
      end
    end
  else
    -- /theocleave OFF: BT prio
    if btReady and rage >= COST_BT and InTrueMeleeTarget() then
      if CastBloodthirst() then return end
    end

    -- WW locked behind 60 rage AND only if BT is on cooldown (not ready / not imminent)
    if wwReady and rage >= 45 and InTrueMeleeTarget() then
      local btImminent = (btRem <= GCD_S)
      if (not btReady) and (not btImminent) then
        if CastWhirlwind() then return end
      end
    end
  end

  -- 4) Battle Shout upkeep – safe window (BT & WW both on cooldown and not imminent)
  if PlayerInCombat() and rage >= COST_BS and not HasBattleShout() and (GetTime() - lastBSAt) > 0.7 then
    if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if CastBattleShout() then return end
    end
  end

  -- 5) Maintain Sunders with macro in safe windows (macro auto-stops at 5)
  if MaintainSundersMacro(btRem, wwRem) then return end

  -- 6) Master Strike (rage sink) — only when BT/WW are safely on cooldown and rage is high
  if THEO_MS_ENABLE == 1 then
    if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if rage >= MS_MIN then
        if CastMasterStrike() then return end
      end
    end
  end

  -- 7) Pummel (interrupt) — same safe GCD window as Master Strike
  if THEO_MS_ENABLE == 1 then
    if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if rage >= MS_MIN then
        if CastPummel() then return end
      end
    end
  end

  -- 8) Precise HS/Cleave weaving tied to SP_SwingTimer main-hand swing timing
  rage = GetRage()
  local _, btStart2, btDur2 = IsSpellReady("Bloodthirst")
  local _, wwStart2, wwDur2 = IsSpellReady("Whirlwind")
  btRem = CDRemaining(btStart2, btDur2)
  wwRem = CDRemaining(wwStart2, wwDur2)

  if TryWeaveSwing_FuryNoExec(rage, btRem, wwRem) then return end
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

-- 1.1) One early Sunder if the target has no Sunder yet (no restrictions)
  if EarlySunderIfMissing() then return end

if Theo_UseWarthog() then
    return
  end

  -- Normal rotation continues in Berserker stance
  EnsureBerserkerStance()

 -- NEW 0.x) High-rage HS/Cleave: queue on every press above 90 rage (non-execute)
  -- This does NOT return, so BT/WW/Execute can still be cast in the same press.
  if not inExecute
     and rage >= 55
     and ValidEnemyTarget()
     and InTrueMeleeTarget()
     and not IsSwingQueued() then

    local spellName = useCleave and "Cleave" or "Heroic Strike"
    CastSpellByName(spellName)
    -- no return here: we still fall through to Sunder/BT/WW logic
  end

  -- 1–3) Core rotation with execute-phase BT/WW rules
  if inExecute then
    -- Rage bands for execute-phase behavior
    local inExecLow  = (rage >= EXEC_MIN and rage < 99)  -- 10–30
    local inExecMid  = (rage >= 30 and rage <= 60)       -- 30–60 window
    local inExecHigh = (rage > 1)                       -- 60–100+

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
    if wwReady and rage >= COST_WW and InTrueMeleeTarget() then
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

  -- 3.9) Hamstring — same safe GCD window as Master Strike/Pummel
  -- Only applied if the target doesn't already have the Hamstring debuff.
  if THEO_MS_ENABLE == 1 and not inExecute then
    if (not btReady and not wwReady) and btRem > GCD_S and wwRem > GCD_S then
      if rage >= MS_MIN then
        if CastHamstring() then return end
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
-- Prot rotation (NO Execute logic)
-- Always Defensive Stance: BT > Revenge > Sunder maintain > HS/Cleave weave > Battle Shout
-- =============================
function QuickTheoProtect()
  -- Confirm any pending Sunder macro actually triggered the GCD before proceeding
  StampIfRealGCD()

  if not PlayerInCombat() then
    earlySunderUsed = false
  end

  if not ValidEnemyTarget() then return end

  -- Always stay in Defensive Stance (no execute-phase stance swap)
  EnsureDefensiveStance()

  local rage = GetRage()
  local btReady, btStart, btDur = IsSpellReady("Bloodthirst")
  local btRem = CDRemaining(btStart, btDur)

  -- Auto swap Dual/Shield macros based on (approx) aggro
  -- TheoSwapWeaponSetByAggro()

  -- 0.x) High-rage HS/Cleave: queue on every press above 90 rage
  -- Does NOT return so BT/Revenge can still fire this press.
  if rage >= 50
     and ValidEnemyTarget()
     and InTrueMeleeTarget()
     and not IsSwingQueued() then
    local spellName = useCleave and "Cleave" or "Heroic Strike"
    CastSpellByName(spellName)
  end

  -- 1) Bloodthirst (normal)
  if btReady and rage >= COST_BT and InTrueMeleeTarget() and GCDReady() then
    if CastBloodthirst() then return end
  end

  -- 2) Revenge (proc) — protect an imminent/affordable BT
  do
    local rageNow = GetRage()
    local _, btStartR, btDurR = IsSpellReady("Bloodthirst")
    local btRemR = CDRemaining(btStartR, btDurR)

    local btImminentAndAffordable = (btRemR <= GCD_S) and (rageNow >= COST_BT)

    if not btImminentAndAffordable then
      if CastRevenge() then return end
    end
  end

  -- 3) Precise swing-timed HS/Cleave weave attempt (does NOT return)
  TryWeaveSwing_Protect(rage, btRem)

  -- 4) Maintain Sunders (Prot: ignore WW gate by passing a huge wwRem)
  do
    local _, btStartS, btDurS = IsSpellReady("Bloodthirst")
    local btRemS = CDRemaining(btStartS, btDurS)

    -- IMPORTANT: /theoprotect doesn't WW, so wwRem must NOT be "0/ready" here.
    if MaintainSundersMacro(btRemS, 9999) then return end
  end

  -- 5) Battle Shout upkeep (don’t delay BT if it’s ready AND you can afford it)
  rage = GetRage()
  local _, btStart2, btDur2 = IsSpellReady("Bloodthirst")
  btRem = CDRemaining(btStart2, btDur2)

  if PlayerInCombat()
     and rage >= COST_BS
     and not HasBattleShout()
     and (GetTime() - lastBSAt) > 0.7
     and ( (not btReady) or (rage < COST_BT) )
     and btRem > GCD_S then
    if CastBattleShout() then return end
  end

  -- 6) Demoralizing Shout (AoE mode only: /theocleave) — protect BT
  if useCleave and PlayerInCombat() and (GetTime() - lastDemoAt) > 0.8 then
    rage = GetRage()
    local _, btStartD, btDurD = IsSpellReady("Bloodthirst")
    local btRemNow = CDRemaining(btStartD, btDurD)

    local btImminentAndAffordable = (btRemNow <= GCD_S) and (rage >= COST_BT)

    if rage >= COST_DEMO and (not btImminentAndAffordable) and btRemNow > GCD_S then
      if CastDemoralizingShout() then return end
    end
  end

  -- 7) Thunder Clap (AoE mode only: /theocleave) — protect BT
  if useCleave then
    rage = GetRage()
    local _, btStartTC, btDurTC = IsSpellReady("Bloodthirst")
    local btRemTC = CDRemaining(btStartTC, btDurTC)

    local btImminentAndAffordableTC = (btRemTC <= GCD_S) and (rage >= COST_BT)

    if not btImminentAndAffordableTC then
      if CastThunderClap() then return end
    end
  end
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

  -- Friendly target: Defensive Stance -> Intervene
  if UnitIsFriend("player", "target") and not UnitIsDead("target") and not UnitCanAttack("player", "target") then
    if not HasDefensiveStance() then
      EnsureDefensiveStance()
      return
    end
    CastIntervene()
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
if ready then
  CastSpellByName("Intercept")
  lastGCDAt = GetTime()
end
return
  else
    -- Out of combat

    -- If we're already in Berserker Stance and floating a lot of rage,
    -- just Intercept instead of stance dancing back to Battle for Charge.
    if HasBerserkerStance() and GetRage() >= 35 then
      local ready = IsSpellReady("Intercept")
      if ready then
        CastSpellByName("Intercept")
          lastGCDAt = GetTime()
        return
      end
      -- if Intercept isn't ready, fall through to normal Charge logic
    end

    -- Default: make sure we're in Battle Stance, then Charge
    if not HasBattleStance() then
      CastSpellByName("Battle Stance")
      lastGCDAt = GetTime()
      return
    end

    -- We’re in the correct stance; just try Charge (no range gate here)
local ready = IsSpellReady("Charge")
if ready then
  CastSpellByName("Charge")
  lastGCDAt = GetTime()
end
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

-- =========================================================
-- Exports for TheoWarriorIcons.lua (reads local toggle state)
-- =========================================================
function Theo_GetUseCleave()
  return useCleave and true or false
end

function Theo_GetSunderMaintain()
  return (THEO_SUNDER_MAINTAIN == 1) and 1 or 0
end

-- NEW: Cleave toggle – /theocleave flips between Cleave (20 rage) and HS (12 rage)
SLASH_THEOCLEAVE1 = "/theocleave"
SlashCmdList["THEOCLEAVE"] = function()
  useCleave = not useCleave
  DEFAULT_CHAT_FRAME:AddMessage(
    "Theo: Cleave mode "..(useCleave and "ENABLED (using Cleave, cost 20)." or "DISABLED (using Heroic Strike, cost 12)."),
    0.8, 1, 0.6
  )
  if TheoUI_UpdateIcons then TheoUI_UpdateIcons() end
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

-- Toggle ONLY the Sunder maintenance (macro) on/off
SLASH_THEOSUNDERMAINT1 = "/theosundermaint"
SlashCmdList["THEOSUNDERMAINT"] = function()
  THEO_SUNDER_MAINTAIN = (THEO_SUNDER_MAINTAIN == 1) and 0 or 1
  DEFAULT_CHAT_FRAME:AddMessage(
    "Theo: Sunder maintenance " .. ((THEO_SUNDER_MAINTAIN == 1) and "ON" or "OFF"),
    0.8, 1, 0.6
  )
  if TheoUI_UpdateIcons then TheoUI_UpdateIcons() end
end

SLASH_WARTHOG1 = "/warthog"
SlashCmdList["WARTHOG"] = function()
  warthogMode = not warthogMode
  DEFAULT_CHAT_FRAME:AddMessage(
    "Theo: Warthog mode " .. (warthogMode and "ON" or "OFF"),
    0.8, 1, 0.6
  )
end

-- 3) Slash command registration (add near your other SlashCmdList lines)
SLASH_THEOFURY1 = "/theofury"
SlashCmdList["THEOFURY"] = QuickTheoFury

SLASH_QHWARRIOR1 = "/qhtwarrior"
SlashCmdList["QHWARRIOR"] = QuickTheoWarrior

SLASH_THEOPROTECT1 = "/theoprotect"
SlashCmdList["THEOPROTECT"] = QuickTheoProtect

-- Slash: stance first, then driver
SLASH_THEOSTANCE1 = "/theostance"
SlashCmdList["THEOSTANCE"] = TheoCharge_EnsureStance

-- TheoCharge macro
SLASH_THEOCHARGE1 = "/theocharge"
SlashCmdList["THEOCHARGE"] = TheoCharge

SLASH_THEOARMS1 = "/theoarms"
SlashCmdList["THEOARMS"] = QuickTheoArms

SLASH_THEOTRASH1 = "/theotrash"
SlashCmdList["THEOTRASH"] = quicktheotrash
 
-- =============================
-- /weaponx: PvP mode toggle
-- =============================
SLASH_WEAPONX1 = "/weaponx"
SlashCmdList["WEAPONX"] = function()
  weaponxPVP = not weaponxPVP
  DEFAULT_CHAT_FRAME:AddMessage("Theo: PvP mode " .. (weaponxPVP and "ON" or "OFF"), 0.8, 1, 0.6)
end

DEFAULT_CHAT_FRAME:AddMessage("QuickTheoWarrior loaded! /qhtwarrior, /theoprotect, /theoexec <n>, /theoexecweave 0|1, /theosundermacro <name>, /theocleave, /theostance, /theocharge.", 0.5, 1, 0)

-- =============================
-- Exports for split modules (theo2hfury.lua)
-- Paste near bottom of your MAIN file
-- =============================

_G.PlayerInCombat         = PlayerInCombat
_G.ValidEnemyTarget       = ValidEnemyTarget
_G.EnsureBerserkerStance  = EnsureBerserkerStance
_G.GetRage                = GetRage
_G.IsSpellReady           = IsSpellReady
_G.CDRemaining            = CDRemaining
_G.TargetHealthBelow      = TargetHealthBelow
_G.InTrueMeleeTarget      = InTrueMeleeTarget
_G.GCDReady               = GCDReady

_G.CastSlam               = CastSlam
_G.CastBloodthirst        = CastBloodthirst
_G.CastWhirlwind          = CastWhirlwind
_G.CastExecute            = CastExecute

_G.EarlySunderIfMissing   = EarlySunderIfMissing

_G.TryWeaveSwing_FuryNoExec = TryWeaveSwing_FuryNoExec
_G.HasBattleShout           = HasBattleShout
_G.CastBattleShout          = CastBattleShout
_G.MaintainSundersMacro      = MaintainSundersMacro

_G.TheoArms_UpdateSlamWindow = TheoArms_UpdateSlamWindow

-- constants used by theo2hfury
_G.COST_BT        = COST_BT
_G.COST_WW        = COST_WW
_G.COST_SLAM      = COST_SLAM
_G.COST_BS        = COST_BS
_G.EXEC_MIN       = EXEC_MIN
_G.EXECUTE_PHASE  = EXECUTE_PHASE
_G.GCD_S          = GCD_S
_G.SLAM_WINDOW    = SLAM_WINDOW
_G.EnsureDefensiveStance  = EnsureDefensiveStance
_G.TargetIsCastingSpell   = TargetIsCastingSpell
_G.CastRevenge            = CastRevenge
_G.CastThunderClap        = CastThunderClap
_G.CastDemoralizingShout  = CastDemoralizingShout
_G.UseSunderMacro         = UseSunderMacro
_G.TryWeaveSwing_Protect  = TryWeaveSwing_Protect
_G.IsSwingQueued          = IsSwingQueued
_G.IsSpellUsableNow       = IsSpellUsableNow
_G.CastShieldBash = CastShieldBash
_G.COST_TC   = COST_TC
_G.COST_DEMO = COST_DEMO

-- wrappers for local state used by modules
function Theo_IsCleaveMode()
  return useCleave
end

function Theo_InSlamWindow()
  local now = GetTime()
  return slamWindowExpires and slamWindowExpires > now
end
