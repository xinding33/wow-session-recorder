-- WoW Session Recorder Helper
--
-- WoW Session Recorder records your screen continuously and reads WoWCombatLog-*.txt to find
-- boss pulls, keys, arena matches and deaths. WoW turns combat logging off on every logout,
-- so this addon turns it back on whenever you enter an instance.
--
-- It also saves Mythic+ timers, affix names and spec names (the combat log only has IDs) so
-- the app can show timed/depleted results, and which of your spells are major cooldowns so the
-- app can mark them. WoW writes this to SavedVariables on logout/reload.
--
-- /srh             show status
-- /srh instances   log only inside dungeons, raids, delves and PvP (default)
-- /srh always      log everywhere
-- /srh off         never touch combat logging

local PREFIX = "|cff4f8ff7WoW Session Recorder|r: "

local defaults = { mode = "instances" }
local enabledByUs = false

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function wantLogging()
    local mode = SessionRecorderHelperDB.mode
    if mode == "always" then return true end
    if mode == "off" then return false end
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType ~= "none"
end

local function update()
    if SessionRecorderHelperDB.mode == "off" then return end
    local want, logging = wantLogging(), LoggingCombat()
    if want and not logging then
        -- LoggingCombat is rate limited (5 calls / 10s shared with /combatlog) and returns nil
        -- when throttled; the next zone event will retry.
        if LoggingCombat(true) then
            enabledByUs = true
            say("combat logging on.")
        end
    elseif not want and logging and enabledByUs then
        -- Only turn off logging we turned on, so we never fight other log tools.
        if LoggingCombat(false) == false then
            enabledByUs = false
            say("combat logging off.")
        end
    end
end

local function ensureAdvancedLogging()
    local ok, value = pcall(C_CVar.GetCVar, "advancedCombatLogging")
    if ok and value ~= "1" then
        if pcall(C_CVar.SetCVar, "advancedCombatLogging", "1") then
            say("enabled Advanced Combat Logging.")
        end
    end
end

-- Merged into what's already saved, so earlier seasons' timers stay available.
local function collectGameData()
    local data = SessionRecorderHelperDB.gameData or {}
    data.keystones = data.keystones or {}
    data.affixes = data.affixes or {}
    data.specs = data.specs or {}

    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        for _, mapID in ipairs(C_ChallengeMode.GetMapTable() or {}) do
            local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
            if name and timeLimit and timeLimit > 0 then
                data.keystones[mapID] = { name = name, timeLimit = timeLimit }
            end
        end
    end
    if C_ChallengeMode and C_ChallengeMode.GetAffixInfo then
        for affixID = 1, 400 do
            local name = C_ChallengeMode.GetAffixInfo(affixID)
            if name then data.affixes[affixID] = name end
        end
    end
    for classID = 1, GetNumClasses() do
        local className = GetClassInfo(classID)
        if className then
            for index = 1, GetNumSpecializationsForClassID(classID) do
                local specID, specName = GetSpecializationInfoForClassID(classID, index)
                if specID and specName then
                    data.specs[specID] = { spec = specName, class = className }
                end
            end
        end
    end

    SessionRecorderHelperDB.gameData = data
end

-- Spells with at least this base cooldown count as major cooldowns.
local MIN_COOLDOWN_SECONDS = 60

local function baseCooldownSeconds(spellID)
    if not GetSpellBaseCooldown then return nil end
    local ok, ms = pcall(GetSpellBaseCooldown, spellID)
    -- Midnight hides some values in combat as "secret"; they can't be compared.
    if not ok or type(ms) ~= "number" or (issecretvalue and issecretvalue(ms)) then return nil end
    return math.floor(ms / 1000)
end

-- Your class and spec spells (not General: mounts, professions) with a long cooldown. Merged
-- across characters; the app marks your casts of any of them.
local function collectCooldowns()
    if InCombatLockdown() or not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return end
    local data = SessionRecorderHelperDB.gameData or {}
    data.cooldowns = data.cooldowns or {}
    local bank = Enum.SpellBookSpellBank.Player
    for line = 2, C_SpellBook.GetNumSpellBookSkillLines() do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if info and not info.offSpecID and not info.shouldHide then
            for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                if item and item.itemType == Enum.SpellBookItemType.Spell and not item.isPassive then
                    -- spellID is the talent override if there is one; actionID is the base spell.
                    for _, spellID in ipairs({ item.actionID, item.spellID }) do
                        local seconds = spellID and baseCooldownSeconds(spellID)
                        if seconds and seconds >= MIN_COOLDOWN_SECONDS then
                            data.cooldowns[spellID] = seconds
                        end
                    end
                end
            end
        end
    end
    SessionRecorderHelperDB.gameData = data
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "SessionRecorderHelper" then return end
        SessionRecorderHelperDB = SessionRecorderHelperDB or {}
        for key, value in pairs(defaults) do
            if SessionRecorderHelperDB[key] == nil then SessionRecorderHelperDB[key] = value end
        end
        return
    end
    if event == "CHALLENGE_MODE_MAPS_UPDATE" then
        pcall(collectGameData)
        return
    end
    if event == "PLAYER_LOGOUT" then
        -- Also runs on /reload, right before WoW saves; picks up talent changes.
        pcall(collectCooldowns)
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        ensureAdvancedLogging()
        pcall(collectGameData)
        pcall(collectCooldowns)
        if C_MythicPlus and C_MythicPlus.RequestMapInfo then pcall(C_MythicPlus.RequestMapInfo) end
    end
    -- Instance info can lag the zone event slightly.
    C_Timer.After(1, update)
end)

SLASH_SESSIONRECORDERHELPER1 = "/srh"
SlashCmdList.SESSIONRECORDERHELPER = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "instances" or msg == "always" or msg == "off" then
        SessionRecorderHelperDB.mode = msg
        say("mode set to " .. msg .. ".")
        update()
    else
        say(("mode: %s, combat logging: %s. Options: /srh instances | always | off"):format(
            SessionRecorderHelperDB.mode, LoggingCombat() and "on" or "off"))
    end
end
