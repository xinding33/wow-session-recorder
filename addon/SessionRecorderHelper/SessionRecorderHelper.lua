-- WoW Session Recorder Helper
--
-- WoW Session Recorder records your screen continuously and reads WoWCombatLog-*.txt to find
-- boss pulls, keys, arena matches and deaths. WoW turns combat logging off on every logout,
-- so this addon turns it back on whenever you enter an instance.
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

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "SessionRecorderHelper" then return end
        SessionRecorderHelperDB = SessionRecorderHelperDB or {}
        for key, value in pairs(defaults) do
            if SessionRecorderHelperDB[key] == nil then SessionRecorderHelperDB[key] = value end
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        ensureAdvancedLogging()
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
