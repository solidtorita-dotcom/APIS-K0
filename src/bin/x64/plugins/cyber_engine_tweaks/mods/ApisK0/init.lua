-- APIS-K0 - CET side.
-- Phase 1: debug hotkey and debug log output (bind the hotkey in CET > Bindings).
-- Phase 2: chat window (shown with the CET overlay) and the file bridge to the external AI process
-- (Apis-K0\bridge\apiko_bridge.py). Files live in this mod folder:
--   to_bridge.jsonl    appended here, one JSON object per line: what V says, game events, push-to-talk
--                      start/stop, with game state
--   from_bridge.txt    rewritten by the bridge: "id<TAB>kind<TAB>duration<TAB>text" lines;
--                      kind = say (subtitle) | heard (what the microphone understood) | status |
--                      face (the mood of the subtitle that follows, for the drone's screen) |
--                      react (the face at V's words, before the reply)
-- Phase 3: push-to-talk hotkey (hold it; the bridge records the microphone) with an on-screen indicator.
--   bridge_alive.txt   unix time written by the bridge every few seconds
--   audio_pose.txt     written here when it changes: where the drone is relative to the camera
--                      ("distance pan front", "car" or "none"); the bridge pans and attenuates the voice with it
-- Phase 4: world events ({type="world", event="action|kind|detail"}: V hacked or used a device, a camera spotted
--   V, V killed an enemy...) go to Apiko's diary in the bridge; the state carries the devices and enemies Apiko
--   perceives ("devices=", "enemies=", "quest=", "objective="). Story messages ({type="story", event=...}):
--   "heard|conv|speaker|text", "heard|news|speaker|text", "scene|start", "scene|end|<lines>".
-- Phase 3b: "APIKO Settings" window (settings_window.lua): providers, models and API keys, saved to
--   settings.json (catalog: providers.json); the bridge reloads it by itself.

local SettingsWindow = require("settings_window")
-- A development install (dev.lua present, see there): dev hotkeys, debug log and the Senses window.
local DEV = false
do
    local file = io.open("dev.lua", "r")
    if file then
        DEV = true
        file:close()
    end
end

local POLL_INTERVAL = 0.25
local POSE_INTERVAL = 0.1
local ALIVE_INTERVAL = 2.0
local ALIVE_TIMEOUT = 10
-- Apiko awake and no bridge for this long: one HUD warning (again only after the bridge came back and went away).
local OFFLINE_WARNING_SECONDS = 30
local OFFLINE_WARNING = "APIKO: bridge not running. See the Apiko window in the taskbar (it starts with the game)."
-- to_bridge.jsonl is truncated when bigger than this, on start and before a message during play (the bridge notices
-- and starts over; at worst it misses the messages of its last poll).
local MAX_OUT_FILE = 512 * 1024
local LOG_LINES = 40
local INPUT_MAX = 400

local TO_BRIDGE = "to_bridge.jsonl"
local FROM_BRIDGE = "from_bridge.txt"
local ALIVE_FILE = "bridge_alive.txt"
local POSE_FILE = "audio_pose.txt"
-- Memory per save: the bridge rewrites MEMORY_OUT after each memory change ("token<TAB>version<TAB>bytes", then the
-- memory JSON); it is stored in the game (and so in the next save) when the token is the one of the current load.
-- On every load the save's version and copy go to the bridge as {type="memory_load"}, which restores that memory.
local MEMORY_OUT = "memory_out.txt"
local MEMORY_INTERVAL = 1.0

local sincePose = 0
local lastPose = nil
local sinceDrain = 0
local sincePoll = 0
local sinceAlive = 0
local offlineFor = 0
local offlineWarned = false
local overlayOpen = false
local focusInput = false
local inputText = ""
local bridgeOnline = false
local lastReplyId = nil
local sentCount = 0
local chatLog = {}
local talking = false
local settingsOpen = false
-- "APIKO Senses" debug window: what Apiko perceives right now, refreshed every SENSES_INTERVAL seconds.
local SENSES_INTERVAL = 0.5
local WORLD_LOG_LINES = 15
local sensesOpen = false
local sinceSenses = 0
local sensesLines = {}
local enemyLines = {}
local sensesState = {}
local worldLog = {}
-- Set on every save load (and when the mod starts). Announced to the bridge only once the game is being played
-- and LOAD_SETTLE seconds have passed: announced at once, the save's state was not restored yet (Apiko looked
-- "not woken" and the bridge started a fresh memory over the real one).
local LOAD_SETTLE = 3.0
local loadPending = true
local loadSettle = 0
local loadToken = nil
local sinceMemory = 0
-- A save loaded and played (settled, as above): the time is written to GAME_LIVE_FILE every GAME_LIVE_INTERVAL
-- seconds, and the file is removed outside a session (main menu, loading, game closed). Without a fresh one the
-- bridge stays silent and cuts what Apiko is saying.
local GAME_LIVE_FILE = "game_live.txt"
local GAME_LIVE_INTERVAL = 1.0
local sinceGameLive = 0
local gameLive = nil

local function getSystem()
    return Game.GetScriptableSystemsContainer():Get("ApisK0.ApisK0System")
end

local function setGameLive(live)
    if live then
        local file = io.open(GAME_LIVE_FILE, "w")
        if file then
            file:write(tostring(os.time()))
            file:close()
        end
    elseif gameLive ~= false then
        os.remove(GAME_LIVE_FILE)
    end
    gameLive = live
end

local function updateGameLive(delta)
    sinceGameLive = sinceGameLive + delta
    if sinceGameLive < GAME_LIVE_INTERVAL then return end
    sinceGameLive = 0
    local system = getSystem()
    setGameLive(system ~= nil and system:IsInSession() and not loadPending and Game.GetPlayer() ~= nil
        and not Game.GetSystemRequestsHandler():IsPreGame())
end

------------------------------------------------------------------------------------------------------------
-- Minimal JSON encoder (strings, numbers, booleans, string-keyed tables and arrays).

local function encodeString(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        if c == '\n' then return '\\n' end
        if c == '\r' then return '\\r' end
        if c == '\t' then return '\\t' end
        return string.format('\\u%04x', c:byte())
    end)
    return '"' .. s .. '"'
end

local function encode(value)
    local t = type(value)
    if t == "string" then return encodeString(value) end
    if t == "number" or t == "boolean" then return tostring(value) end
    if t == "table" then
        local parts = {}
        if #value > 0 then
            for _, v in ipairs(value) do parts[#parts + 1] = encode(v) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, v in pairs(value) do parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. encode(v) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

------------------------------------------------------------------------------------------------------------
-- Bridge files

local function addLog(who, text)
    chatLog[#chatLog + 1] = { who = who, text = text }
    while #chatLog > LOG_LINES do table.remove(chatLog, 1) end
end

local function gameState(system)
    local state = {}
    for _, line in ipairs(system:GetChatState()) do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then state[key] = value end
    end
    return state
end

-- World events skip the state: they only feed the diary.
local function sendToBridge(message, withoutState)
    local system = getSystem()
    if not system then return end
    sentCount = sentCount + 1
    message.id = sentCount
    message.t = os.time()
    if not withoutState then message.state = gameState(system) end
    local file = io.open(TO_BRIDGE, "a")
    if file and file:seek("end") > MAX_OUT_FILE then
        file:close()
        file = io.open(TO_BRIDGE, "w")
    end
    if not file then
        addLog("!", "cannot write " .. TO_BRIDGE)
        return
    end
    file:write(encode(message) .. "\n")
    file:close()
end

local function readReplies()
    local file = io.open(FROM_BRIDGE, "r")
    if not file then return {} end
    local replies = {}
    for line in file:lines() do
        local id, kind, duration, text = line:match("^(%d+)\t(%a+)\t([%d%.]+)\t(.*)$")
        if id then
            replies[#replies + 1] = { id = tonumber(id), kind = kind, duration = tonumber(duration), text = text }
        end
    end
    file:close()
    return replies
end

local function pollReplies(system)
    for _, reply in ipairs(readReplies()) do
        if lastReplyId == nil or reply.id > lastReplyId then
            lastReplyId = reply.id
            if reply.kind == "say" then
                addLog("APIKO", reply.text)
                system:Say(reply.text, reply.duration)
            elseif reply.kind == "sayu" then
                -- The first contact before Apiko gives its name: an unknown speaker in the subtitles.
                addLog("???", reply.text)
                system:SayUnknown(reply.text, reply.duration)
            elseif reply.kind == "sayn" then
                -- NetWatch's recording on the beacon's call (the find).
                addLog("NETWATCH", reply.text)
                system:SayNetWatch(reply.text, reply.duration)
            elseif reply.kind == "face" then
                -- The mood of the subtitle that follows: its face on the drone's screen for as long.
                system:ShowFace(reply.text, reply.duration)
            elseif reply.kind == "react" then
                -- Apiko's face at V's words, while the reply is on its way.
                system:ShowReaction(reply.text, reply.duration)
            elseif reply.kind == "heard" then
                addLog("V", reply.text)
            elseif reply.kind == "test" then
                SettingsWindow.onTestResult(reply.text)
            elseif reply.kind == "cue" then
                -- The written first contact: Apiko finished speaking in V's head ("head_done").
                system:OnBridgeCue(reply.text)
            else
                addLog("!", reply.text)
            end
        end
    end
end

------------------------------------------------------------------------------------------------------------
-- Memory per save. The game only saves numbers, so the memory text travels as UTF-8 bytes packed four per Int32.

local function packBytes(text)
    local ints = {}
    for i = 1, #text, 4 do
        local b1, b2, b3, b4 = text:byte(i, i + 3)
        local value = (b1 or 0) + (b2 or 0) * 256 + (b3 or 0) * 65536 + (b4 or 0) * 16777216
        if value >= 2147483648 then value = value - 4294967296 end
        ints[#ints + 1] = value
    end
    return ints
end

local function unpackBytes(ints, length)
    local parts = {}
    for _, value in ipairs(ints) do
        if value < 0 then value = value + 4294967296 end
        parts[#parts + 1] = string.char(value % 256, math.floor(value / 256) % 256,
            math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
    end
    return table.concat(parts):sub(1, length)
end

-- The game's text language ("en-us", "es-es"...), or "" if it cannot be read.
local function gameLanguage()
    local ok, code = pcall(function()
        local value = Game.GetSettingsSystem():GetVar("/language", "OnScreen"):GetValue()
        local named, text = pcall(Game.NameToString, value)
        if named and type(text) == "string" and text ~= "" then return text end
        return value.value
    end)
    if ok and type(code) == "string" then return code end
    return ""
end

-- Tells the bridge which memory this save has (its version and its stored copy) and the game's language.
local function sendMemoryLoad(system)
    if not system or not loadToken then return end
    local version = system:GetMemoryVersion()
    local length = system:GetMemoryLength()
    local text = ""
    if version > 0 and length > 0 then text = unpackBytes(system:GetMemoryBlob(), length) end
    sendToBridge({ type = "memory_load", token = loadToken, version = version, unlocked = system:IsUnlocked(),
        memory = text, language = gameLanguage() }, true)
end

local function announceLoad(system)
    loadToken = string.format("%d-%d", os.time(), math.random(100000, 999999))
    sendMemoryLoad(system)
end

-- Copies a new memory version from the bridge into the game, if it is for this load.
local function syncMemory(system)
    if not loadToken then return end
    local file = io.open(MEMORY_OUT, "rb")
    if not file then return end
    local header = file:read("*l") or ""
    local token, version, length = header:match("^([^\t]*)\t(%d+)\t(%d+)")
    version, length = tonumber(version), tonumber(length)
    if token == loadToken and version and length and version ~= system:GetMemoryVersion() then
        local text = (file:read("*a") or ""):sub(1, length)
        if #text == length then system:SetMemory(version, packBytes(text), length) end
    end
    file:close()
end

local function checkAlive()
    local wasOnline = bridgeOnline
    local file = io.open(ALIVE_FILE, "r")
    if not file then
        bridgeOnline = false
        return
    end
    local stamp = tonumber(file:read("*l") or "")
    file:close()
    bridgeOnline = stamp ~= nil and os.time() - stamp <= ALIVE_TIMEOUT
    -- A bridge started (or restarted) mid-game learns which save is loaded.
    if bridgeOnline and not wasOnline then sendMemoryLoad(getSystem()) end
end

-- Only rewritten when it changes, so a still scene costs no disk writes.
local function writePose()
    local system = getSystem()
    if not system or not system:IsUnlocked() then return end
    local pose = system:GetAudioPose()
    if pose == lastPose then return end
    local file = io.open(POSE_FILE, "w")
    if not file then return end
    file:write(pose)
    file:close()
    lastPose = pose
end

local AWAY_NOTE = "Apiko is at your apartment (Megabuilding H10). Call APIKO, or go home and talk to it."

local function sendPlayerText()
    local text = inputText:gsub("^%s+", ""):gsub("%s+$", "")
    inputText = ""
    focusInput = true
    if text == "" then return end
    addLog("V", text)
    -- Sent away: nobody hears V until it is called back.
    local system = getSystem()
    if system and system:IsAway() then
        addLog("!", AWAY_NOTE)
        return
    end
    sendToBridge({ type = "say", text = text })
end

------------------------------------------------------------------------------------------------------------
-- Events

registerForEvent("onInit", function()
    -- Replies already in the file are from an earlier session: skip them.
    for _, reply in ipairs(readReplies()) do
        if lastReplyId == nil or reply.id > lastReplyId then lastReplyId = reply.id end
    end
    lastReplyId = lastReplyId or 0
    -- Every save load: the memory of that save must come back.
    Observe("PlayerPuppet", "OnGameAttached", function()
        loadPending = true
        loadSettle = 0
        -- Until the new load is announced, nothing from the bridge may reach the game: with the old token still
        -- valid, the previous session's newer memory version was copied into the save just loaded.
        loadToken = nil
    end)
    local file = io.open(TO_BRIDGE, "r")
    if file then
        local size = file:seek("end")
        file:close()
        if size > MAX_OUT_FILE then
            file = io.open(TO_BRIDGE, "w")
            if file then file:close() end
        end
    end
end)

-- Development hotkeys (dev.lua): only in a development install.
if DEV then require("dev")(getSystem, sendToBridge) end

-- Hold to talk. Fires with true on press and false on release.
registerInput("ApisK0_Talk", "Push to talk (Apiko)", function(down)
    local system = getSystem()
    if not system or not system:IsUnlocked() then
        talking = false
        return
    end
    if system:IsAway() then
        if down and not talking then system:ShowNotice(AWAY_NOTE, 4.0) end
        talking = down
        return
    end
    if down and not talking then
        talking = true
        sendToBridge({ type = "ptt_start" })
    elseif not down and talking then
        talking = false
        sendToBridge({ type = "ptt_stop" })
    end
end)

registerForEvent("onOverlayOpen", function()
    overlayOpen = true
    focusInput = true
end)

registerForEvent("onOverlayClose", function()
    overlayOpen = false
end)

registerForEvent("onShutdown", function()
    setGameLive(false)
end)

registerForEvent("onUpdate", function(delta)
    SettingsWindow.update(delta)
    updateGameLive(delta)
    sinceDrain = sinceDrain + delta
    sincePoll = sincePoll + delta
    sincePose = sincePose + delta
    if sincePose >= POSE_INTERVAL and bridgeOnline then
        sincePose = 0
        writePose()
    end
    sinceAlive = sinceAlive + delta
    if sinceAlive >= ALIVE_INTERVAL then
        sinceAlive = 0
        checkAlive()
        local system = getSystem()
        -- The find's upload waits for Apiko's voice only with the bridge running.
        if system then system:SetBridgeOnline(bridgeOnline) end
        if bridgeOnline then
            offlineFor, offlineWarned = 0, false
        elseif system and system:IsUnlocked() then
            offlineFor = offlineFor + ALIVE_INTERVAL
            if offlineFor >= OFFLINE_WARNING_SECONDS and not offlineWarned then
                offlineWarned = true
                system:ShowNotice(OFFLINE_WARNING, 10.0)
            end
        end
    end
    if sincePoll < POLL_INTERVAL then return end
    sincePoll = 0
    local system = getSystem()
    if not system then return end

    -- Debug lines queued by the redscript side (development install only): CET's scripting.log, and debug_log.txt in
    -- this folder, written at once (scripting.log loses its buffered lines when the game closes).
    system:SetDev(DEV)
    local lines = system:DebugDrain()
    if #lines > 0 then
        local file = io.open("debug_log.txt", "a")
        for _, line in ipairs(lines) do
            print("[ApisK0] " .. line)
            if file then file:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. line .. "\n") end
        end
        if file then file:close() end
    end
    -- Memory per save, also before the drone is woken (a new game starts a fresh Apiko).
    if loadPending and Game.GetPlayer() and not Game.GetSystemRequestsHandler():IsPreGame() then
        loadSettle = loadSettle + POLL_INTERVAL
        if loadSettle >= LOAD_SETTLE then
            loadPending = false
            announceLoad(system)
        end
    end
    sinceMemory = sinceMemory + POLL_INTERVAL
    if sinceMemory >= MEMORY_INTERVAL then
        sinceMemory = 0
        syncMemory(system)
    end
    -- The find needs the bridge before Apiko is awake (Apiko in V's head while the chip loads).
    if not system:IsUnlocked() and not system:NeedsBridge() then
        -- The settings window works before the drone is woken: only its test results are read.
        if settingsOpen then pollReplies(system) end
        return
    end
    for _, event in ipairs(system:DrainChatEvents()) do
        sendToBridge({ type = "event", event = event })
    end
    -- Sent away: only the phone call above reaches the bridge; the rest is dropped.
    local away = system:IsAway()
    for _, event in ipairs(system:DrainWorldEvents()) do
        if not away then sendToBridge({ type = "world", event = event }, true) end
        worldLog[#worldLog + 1] = os.date("%H:%M:%S ") .. event
        while #worldLog > WORLD_LOG_LINES do table.remove(worldLog, 1) end
    end
    -- Lines Apiko heard and conversation start/end. Only the end carries the state (Apiko may remark on it).
    for _, event in ipairs(system:DrainStoryMessages()) do
        if not away then sendToBridge({ type = "story", event = event }, not event:match("^scene|end")) end
    end
    if sensesOpen then
        sinceSenses = sinceSenses + POLL_INTERVAL
        if sinceSenses >= SENSES_INTERVAL then
            sinceSenses = 0
            sensesLines = system:GetSensesDebug()
            enemyLines = system:GetEnemiesDebug()
            sensesState = gameState(system)
        end
    end
    pollReplies(system)
end)

local function drawTalkIndicator()
    ImGui.SetNextWindowPos(20, 20, ImGuiCond.Always)
    local flags = ImGuiWindowFlags.NoDecoration + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoInputs
        + ImGuiWindowFlags.NoSavedSettings + ImGuiWindowFlags.NoFocusOnAppearing + ImGuiWindowFlags.NoNav
    if ImGui.Begin("##apiko_talk", flags) then
        if bridgeOnline then
            ImGui.TextColored(0.50, 0.91, 0.85, 1.0, "APIKO is listening...")
        else
            ImGui.TextColored(1.0, 0.45, 0.35, 1.0, "APIKO: bridge offline")
        end
    end
    ImGui.End()
end

-- Debug: sensors, the devices and enemies Apiko knows (how it learned of each, network, zone) and the latest world
-- events.
-- Only with the CET overlay open, like the chat window.
local function drawSenses()
    ImGui.SetNextWindowSize(760, 460, ImGuiCond.FirstUseEver)
    if ImGui.Begin("APIKO Senses") then
        ImGui.TextColored(0.50, 0.91, 0.85, 1.0, "Sensors")
        local keys = {}
        for key in pairs(sensesState) do
            if key ~= "devices" and key ~= "enemies" then keys[#keys + 1] = key end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            ImGui.Text(key .. " = " .. tostring(sensesState[key]))
        end
        ImGui.Separator()
        ImGui.TextColored(0.50, 0.91, 0.85, 1.0, "Devices")
        for i, line in ipairs(sensesLines) do
            if i == 1 then ImGui.TextDisabled(line) else ImGui.Text(line) end
        end
        ImGui.Separator()
        ImGui.TextColored(0.50, 0.91, 0.85, 1.0, "Enemies")
        for i, line in ipairs(enemyLines) do
            if i == 1 then ImGui.TextDisabled(line) else ImGui.Text(line) end
        end
        ImGui.Separator()
        ImGui.TextColored(0.50, 0.91, 0.85, 1.0, "World events (newest last)")
        for _, line in ipairs(worldLog) do
            ImGui.TextDisabled(line)
        end
    end
    ImGui.End()
end

registerForEvent("onDraw", function()
    if talking then drawTalkIndicator() end
    if not overlayOpen then return end
    ImGui.SetNextWindowSize(460, 320, ImGuiCond.FirstUseEver)
    if ImGui.Begin("APIKO") then
        local system = getSystem()
        local awake = system and system:IsUnlocked()
        if ImGui.Button(settingsOpen and "Close settings" or "Settings") then
            settingsOpen = not settingsOpen
            if settingsOpen then SettingsWindow.load() end
        end
        if DEV then
            ImGui.SameLine()
            if ImGui.Button(sensesOpen and "Close senses" or "Senses") then
                sensesOpen = not sensesOpen
                sinceSenses = SENSES_INTERVAL
            end
        end
        if not awake then
            ImGui.TextWrapped("APIS-K0 is offline.")
        else
            if bridgeOnline then
                ImGui.TextColored(0.50, 0.91, 0.85, 1.0, "Bridge online")
            else
                ImGui.TextColored(1.0, 0.45, 0.35, 1.0, "Bridge offline: it runs inside the game (red4ext\\plugins\\ApisK0). Is RED4ext installed? Log: %LOCALAPPDATA%\\Apiko\\data\\native.log")
            end
            ImGui.Separator()
            local footer = ImGui.GetFrameHeightWithSpacing() + 4
            ImGui.BeginChild("apiko_log", 0, -footer, false)
            for _, entry in ipairs(chatLog) do
                if entry.who == "APIKO" then
                    ImGui.TextColored(0.50, 0.91, 0.85, 1.0, "APIKO:")
                elseif entry.who == "V" then
                    ImGui.TextColored(0.95, 0.85, 0.35, 1.0, "V:")
                else
                    ImGui.TextColored(1.0, 0.45, 0.35, 1.0, "!")
                end
                ImGui.SameLine()
                ImGui.TextWrapped(entry.text)
            end
            if ImGui.GetScrollY() >= ImGui.GetScrollMaxY() - 4 then ImGui.SetScrollHereY(1.0) end
            ImGui.EndChild()
            if focusInput then
                ImGui.SetKeyboardFocusHere()
                focusInput = false
            end
            ImGui.PushItemWidth(-70)
            local entered
            inputText, entered = ImGui.InputText("##apiko_input", inputText, INPUT_MAX, ImGuiInputTextFlags.EnterReturnsTrue)
            ImGui.PopItemWidth()
            ImGui.SameLine()
            if ImGui.Button("Send") or entered then sendPlayerText() end
        end
    end
    ImGui.End()
    if settingsOpen then SettingsWindow.draw(bridgeOnline, sendToBridge) end
    if sensesOpen then drawSenses() end
end)
