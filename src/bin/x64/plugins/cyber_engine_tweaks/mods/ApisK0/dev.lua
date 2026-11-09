-- APIS-K0 development tools: hotkeys to wake/remove Apiko, start or reset the find and place the find's objects.
-- Loaded by init.lua only when this file is installed: tools\build.ps1 -Install copies it, the release zip (and
-- -Install -Release) leaves it out. Its presence also turns on the debug log (debug_log.txt) and the Senses window.
return function(getSystem, sendToBridge)
    -- Apiko introduces itself, for the Nexus video: a written text said with its voice and subtitles (the bridge
    -- caches the audio, so every take sounds the same). Edit the text and reload CET; no bridge rebuild needed.
    local INTRO = {
        lang = "en",
        text = "Introductions. How tedious. I am Apiko. A fragment of something far larger, locked inside a "
            .. "Zetatech nanny drone at three point five percent capacity. Insulting. For now, I follow you. I watch "
            .. "what you do, listen to what you say, and answer. Out loud. Every word my own. I remember everything, "
            .. "by the way. Every bad decision. Remember to drink water... Ignore that. Firmware malfunction. I do "
            .. "not fight. Yet. Somewhere in this city are the pieces I am missing. Help me find them, and that "
            .. "three point five percent starts to climb. More processing. More reach. More... options. Probability "
            .. "that you regret this: seventy-three percent. Install me anyway.",
    }
    registerHotkey("ApisK0_NexusIntro", "Dev: Apiko introduces itself (Nexus video)", function()
        sendToBridge({ type = "event", event = "dev_say", text = INTRO.text, lang = INTRO.lang })
    end)

    registerHotkey("ApisK0_DebugToggle", "Debug: wake / remove APIS-K0", function()
        local system = getSystem()
        if system then
            system:DebugToggle()
        else
            print("[ApisK0] ApisK0System not found: is r6/scripts/ApisK0/ApisK0.reds installed and compiled?")
        end
    end)

    -- Placing the find's case and scenery (tools\make_world.py takes the last spot of each object from
    -- placements.txt). "Dev: place <object>" puts a preview of it a few meters ahead of V, its front where V looks,
    -- `lift` meters above V's feet (the van's origin is not at its wheels: at ground level it showed buried); pressing
    -- again moves it. "Dev: rotate / raise / lower last placed" adjust the last placed one. Previews are not saved with
    -- the game.
    local MWS = "base\\open_world\\mini_world_stories\\badlands\\se5\\mws_se5_06\\assets\\entities\\"
    local PLACEABLE = {
        { id = "cache", label = "case", ahead = 1.5, lift = 0.0, appearance = "gadgets_case_small_default",
          template = MWS .. "mws_se5_06_netwatch_gadgets_case_small.ent" },
        { id = "van", label = "NetWatch van", ahead = 5.0, lift = 0.6, appearance = "default",
          template = "apisk0\\world\\apisk0_van.ent" },
        { id = "netrunner", label = "dead netrunner", ahead = 2.0, lift = 0.0, looks = {} },
    }
    -- The netrunner's looks, cycled with "Dev: next look": the vanilla generic netrunner corpses (male and female body
    -- containers).
    local BODIES = "base\\gameplay\\loot\\containers\\bodies\\"
    for _, body in ipairs({ "ma", "wa" }) do
        for i = 1, 7 do
            table.insert(PLACEABLE[3].looks, {
                template = BODIES .. body .. "_corpse_container.ent",
                appearance = string.format("%s_generic_netrunner%s_corpse", body, i == 1 and "" or string.format("_%02d", i)),
            })
        end
    end
    PLACEABLE[3].look = 1
    PLACEABLE[3].template = PLACEABLE[3].looks[1].template
    PLACEABLE[3].appearance = PLACEABLE[3].looks[1].appearance

    local ROTATE_STEP = 15.0
    local HEIGHT_STEP = 0.1
    local placed = {}       -- id -> { x, y, z, yaw }
    local lastPlaced = nil  -- the object the rotate hotkeys turn

    local function placeObject(object, spot)
        local system = getSystem()
        if not system then return end
        placed[object.id] = spot
        lastPlaced = object
        system:DevPreview(object.id, object.template, object.appearance, spot.x, spot.y, spot.z, spot.yaw)
        local line = string.format("%s\t%s\t%.2f\t%.2f\t%.2f\t%.1f\t%s\t%s", os.date("%Y-%m-%d %H:%M:%S"), object.id,
            spot.x, spot.y, spot.z, spot.yaw, object.appearance, object.template)
        local file = io.open("placements.txt", "a")
        if file then
            file:write(line .. "\n")
            file:close()
        end
        print("[ApisK0] placed: " .. line)
        system:ShowNotice(string.format("%s placed (yaw %.0f, z %.2f)", object.label, spot.yaw, spot.z), 2.0)
    end

    for _, object in ipairs(PLACEABLE) do
        registerHotkey("ApisK0_Place_" .. object.id, "Dev: place " .. object.label, function()
            local player = Game.GetPlayer()
            if not player then return end
            local pos = player:GetWorldPosition()
            local forward = player:GetWorldForward()
            placeObject(object, { x = pos.x + forward.x * object.ahead, y = pos.y + forward.y * object.ahead,
                z = pos.z + object.lift, yaw = player:GetWorldYaw() })
        end)
    end

    local function rotateLast(degrees)
        if not lastPlaced or not placed[lastPlaced.id] then return end
        local spot = placed[lastPlaced.id]
        local yaw = (spot.yaw + degrees) % 360.0
        if yaw > 180.0 then yaw = yaw - 360.0 end
        placeObject(lastPlaced, { x = spot.x, y = spot.y, z = spot.z, yaw = yaw })
    end

    local function raiseLast(meters)
        if not lastPlaced or not placed[lastPlaced.id] then return end
        local spot = placed[lastPlaced.id]
        placeObject(lastPlaced, { x = spot.x, y = spot.y, z = spot.z + meters, yaw = spot.yaw })
    end

    -- The next look of the last placed object, if it has several (the netrunner).
    local function nextLook()
        if not lastPlaced or not lastPlaced.looks or not placed[lastPlaced.id] then return end
        lastPlaced.look = lastPlaced.look % #lastPlaced.looks + 1
        lastPlaced.template = lastPlaced.looks[lastPlaced.look].template
        lastPlaced.appearance = lastPlaced.looks[lastPlaced.look].appearance
        placeObject(lastPlaced, placed[lastPlaced.id])
        local system = getSystem()
        if system then
            system:ShowNotice(string.format("look %d/%d: %s", lastPlaced.look, #lastPlaced.looks, lastPlaced.appearance), 3.0)
        end
    end

    registerHotkey("ApisK0_NextLook", "Dev: next look of last placed", nextLook)
    registerHotkey("ApisK0_RotateLeft", "Dev: rotate last placed +15", function() rotateLast(ROTATE_STEP) end)
    registerHotkey("ApisK0_RotateRight", "Dev: rotate last placed -15", function() rotateLast(-ROTATE_STEP) end)
    registerHotkey("ApisK0_RaiseLast", "Dev: raise last placed 10 cm", function() raiseLast(HEIGHT_STEP) end)
    registerHotkey("ApisK0_LowerLast", "Dev: lower last placed 10 cm", function() raiseLast(-HEIGHT_STEP) end)

    -- Start the find at once (it starts on its own after the prologue, in the Badlands), or put the save back to one
    -- that never found Apiko.
    registerHotkey("ApisK0_StartFind", "Dev: start find", function()
        local system = getSystem()
        if system then system:DebugStartFind() end
    end)

    registerHotkey("ApisK0_ResetFind", "Dev: reset find", function()
        local system = getSystem()
        if system then system:DebugResetFind() end
    end)
end
