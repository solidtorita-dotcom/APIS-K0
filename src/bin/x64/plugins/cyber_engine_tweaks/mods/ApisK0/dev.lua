-- APIS-K0 development tools: hotkeys to wake/remove Apiko, start or reset the find, place the find's objects and
-- the antenna mission's site (objects, agents, the hostile zone's corners).
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

    -- Apiko's faces (ApisK0Face.reds), one per press, each for a few seconds; then the resting face.
    local FACES = { "happy", "laughing", "bored", "angry", "sad", "confused", "surprised", "glitching", "curious" }
    local faceIndex = 0
    registerHotkey("ApisK0_DevNextFace", "Dev: next face on the drone's screen", function()
        local system = getSystem()
        if system then
            faceIndex = faceIndex % #FACES + 1
            system:ShowFace(FACES[faceIndex], 4.0)
            system:ShowNotice("face: " .. FACES[faceIndex], 2.0)
        end
    end)

    -- The antenna mission (ApisK0Antenna.reds): start it now, or reset it when it had started.
    registerHotkey("ApisK0_DevToggleAntenna", "Dev: start / reset the antenna mission", function()
        local system = getSystem()
        if system then system:DevToggleAntenna() end
    end)

    -- Apiko's ping (ApisK0System.ApikoPing): only with its antenna mounted, at most one per minute.
    registerHotkey("ApisK0_DevPing", "Dev: Apiko ping", function()
        local system = getSystem()
        if not system then return end
        if not system:IsAntennaMounted() then
            system:ShowNotice("no antenna yet: finish Echo first", 2.0)
            return
        end
        system:ApikoPing(true)
    end)

    -- The glass over the screen: cracked / repaired (the repair mission's result, saved with the game).
    registerHotkey("ApisK0_DevToggleGlass", "Dev: crack / repair the drone's glass", function()
        local system = getSystem()
        if system then
            system:SetGlassRepaired(not system:IsGlassRepaired())
            system:ShowNotice(system:IsGlassRepaired() and "glass: repaired" or "glass: cracked", 2.0)
        end
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

    -- The antenna mission's NetWatch site in Pacifica (DISENO.md, "Misión: antena y cara"): the
    -- evidence crate with the antenna, the burnt server Apiko remembers, the technician who carries the log, and the
    -- agents of the clean-up team (`many`: each press places one more, "Dev: remove last agent" takes the last one
    -- back). The agents are the vanilla NetWatch agents of the van's mini world story (neutral here, hostile copies in
    -- the mission). Every object cycles its looks with "Dev: next look of last placed".
    local CONTAINERS = "base\\gameplay\\loot\\containers\\"
    -- First, the picks without their Arasaka logos (our copies, tools\make_world.py: EVIDENCE_ENT, SERVER_ENT).
    local EVIDENCE_LOOKS = {
        { template = "apisk0\\world\\apisk0_evidence.ent", appearance = "equipment_case_medium_default" },
    }
    for _, kind in ipairs({ "equipment_cases\\equipment_case_medium", "valuable_crates\\valuable_crate_small",
                            "weapon_cases\\weapon_case_medium", "crates\\crate_small" }) do
        local name = kind:match("[^\\]+$")
        for _, style in ipairs({ "default", "neomilitary_a", "entropy_a" }) do
            local look = name .. "_" .. style
            if name == "valuable_crate_small" and style == "entropy_a" then look = name .. "_neokitsch_a" end
            table.insert(EVIDENCE_LOOKS, { template = CONTAINERS .. kind .. ".ent", appearance = look })
        end
    end
    local SERVERS = "base\\gameplay\\devices\\explosives\\appearances\\explosive_server\\"
    local STREET = "base\\open_world\\street_stories\\"
    local SERVER_LOOKS = {
        { template = "apisk0\\world\\apisk0_server.ent", appearance = "default" },
        { template = SERVERS .. "explosive_server_arasaka_a_destroyed.ent", appearance = "default" },
        { template = SERVERS .. "explosvie_server_neomilitarism_destroyed.ent", appearance = "default" },
        { template = SERVERS .. "explosive_server_nemilitarism_small_destroyed.ent", appearance = "default" },
        { template = STREET .. "santo_domingo\\arroyo\\sts_std_arr_06\\entities\\sts_std_arr_06_server.ent", appearance = "default" },
        { template = STREET .. "santo_domingo\\rancho_corronado\\sts_std_rcr_04\\entities\\rcr_04_server.ent", appearance = "default" },
        { template = STREET .. "heywood\\vista_del_rey\\sts_hey_rey_09\\entities\\sts_hey_rey_09_server.ent", appearance = "default" },
        { template = STREET .. "watson\\northside_industrial_district\\sts_wat_nid_12\\entities\\sts_wat_nid_12_security_server.ent", appearance = "default" },
        { template = STREET .. "city_center\\downtown\\sts_cct_dtn_03\\entities\\server_infectable.ent", appearance = "default" },
    }
    local AGENT_LOOKS = {}
    for _, record in ipairs({ "rifle_ma", "rifle_wa", "handgun_ma", "handgun_wa", "shotgun_ma" }) do
        table.insert(AGENT_LOOKS, { record = "Character.mws_se5_06_netwatch_" .. record })
    end
    table.insert(PLACEABLE, { id = "evidence", label = "evidence crate", ahead = 1.5, lift = 0.0, looks = EVIDENCE_LOOKS, look = 1 })
    table.insert(PLACEABLE, { id = "server", label = "burnt server", ahead = 1.5, lift = 0.0, looks = SERVER_LOOKS, look = 1 })
    table.insert(PLACEABLE, { id = "technician", label = "NetWatch technician", ahead = 2.0, lift = 0.0, looks = AGENT_LOOKS, look = 3 })
    table.insert(PLACEABLE, { id = "agent", label = "NetWatch agent", ahead = 2.0, lift = 0.0, looks = AGENT_LOOKS, look = 1,
                              many = true, instances = {} })
    -- What NetWatch seized, around the crate (decoration; `many`, as the agents): laptops, a cyberdeck, shard boxes,
    -- evidence, a badge, a tablet, a body bag, small cases.
    local Q110 = "base\\quest\\main_quests\\part1\\q110\\devices\\"
    local ELECTRONICS = "base\\items\\interactive\\electronics\\"
    local DECOR_LOOKS = {
        { template = Q110 .. "q110_netwatch_agents_laptop.ent", appearance = "default" },
        { template = Q110 .. "q110_netrunners_den_laptop.ent", appearance = "default" },
        { template = "base\\gameplay\\devices\\masters\\computers\\laptop_1.ent", appearance = "laptop_laptop_1" },
        { template = "base\\gameplay\\devices\\masters\\computers\\laptop_1.ent", appearance = "laptop_laptop_3" },
        { template = "base\\gameplay\\devices\\masters\\computers\\computer_movable.ent", appearance = "default" },
        { template = "base\\items\\quest\\q108__cyberdeck_a.ent", appearance = "default" },
        { template = ELECTRONICS .. "int_electronics_001__shard_box_a.ent", appearance = "default" },
        { template = ELECTRONICS .. "int_electronics_001__shard_box_a_neomilitary\\int_electronics_001__shard_box_a_neomilitary_part.ent", appearance = "default" },
        { template = STREET .. "heywood\\glenn\\sts_hey_gle_04\\entities\\sts_hey_gle_04_evidence.ent", appearance = "default" },
        { template = MWS .. "mws_se5_06_netwatch_badge.ent", appearance = "default" },
        { template = MWS .. "mws_se5_06_netwatch_gadgets_case_small.ent", appearance = "gadgets_case_small_default" },
        { template = "base\\items\\light_crowd_items\\tablet_c_neo_military.ent", appearance = "default" },
        { template = "base\\items\\quest\\q003_intro__body_bag.ent", appearance = "default" },
        { template = CONTAINERS .. "weapon_cases\\weapon_case_small.ent", appearance = "weapon_case_small_neomilitary_a" },
        { template = CONTAINERS .. "ammo_cases\\ammo_case_small.ent", appearance = "ammo_case_small_neomilitary_a" },
    }
    table.insert(PLACEABLE, { id = "decor", label = "seized item", ahead = 1.2, lift = 0.0, looks = DECOR_LOOKS, look = 1,
                              many = true, instances = {} })
    local function findPlaceable(id)
        for _, object in ipairs(PLACEABLE) do
            if object.id == id then return object end
        end
    end

    -- An object takes its current look (template and appearance, or an NPC record).
    local function applyLook(object)
        if not object.looks then return end
        local look = object.looks[object.look]
        object.template = look.template
        object.appearance = look.appearance
        object.record = look.record
    end
    for _, object in ipairs(PLACEABLE) do applyLook(object) end

    local ROTATE_STEP = 15.0
    local HEIGHT_STEP = 0.1
    local placed = {}       -- id -> { x, y, z, yaw }
    local lastPlaced = nil  -- the object the rotate hotkeys turn

    local function writePlacement(line)
        local file = io.open("placements.txt", "a")
        if file then
            file:write(line .. "\n")
            file:close()
        end
        print("[ApisK0] placed: " .. line)
    end

    local function placeObject(object, spot)
        local system = getSystem()
        if not system then return end
        placed[object.id] = spot
        lastPlaced = object
        if object.record then
            system:DevPreviewRecord(object.id, object.record, spot.x, spot.y, spot.z, spot.yaw)
        else
            system:DevPreview(object.id, object.template, object.appearance, spot.x, spot.y, spot.z, spot.yaw)
        end
        writePlacement(string.format("%s\t%s\t%.2f\t%.2f\t%.2f\t%.1f\t%s\t%s", os.date("%Y-%m-%d %H:%M:%S"), object.id,
            spot.x, spot.y, spot.z, spot.yaw, object.appearance or "", object.record or object.template))
        system:ShowNotice(string.format("%s placed (yaw %.0f, z %.2f)", object.label, spot.yaw, spot.z), 2.0)
    end

    -- A spot a few meters ahead of V, facing where V looks.
    local function spotAhead(object)
        local player = Game.GetPlayer()
        if not player then return nil end
        local pos = player:GetWorldPosition()
        local forward = player:GetWorldForward()
        return { x = pos.x + forward.x * object.ahead, y = pos.y + forward.y * object.ahead, z = pos.z + object.lift,
                 yaw = player:GetWorldYaw() }
    end

    for _, object in ipairs(PLACEABLE) do
        registerHotkey("ApisK0_Place_" .. object.id, "Dev: place " .. object.label, function()
            local spot = spotAhead(object)
            if not spot then return end
            if object.many then
                -- One more: its own id (agent_1, agent_2...), starting with the look of the last one.
                local n = #object.instances + 1
                local previous = object.instances[n - 1]
                local instance = { id = object.id .. "_" .. n, label = object.label .. " " .. n, ahead = object.ahead,
                                   lift = object.lift, looks = object.looks, look = previous and previous.look or object.look }
                applyLook(instance)
                table.insert(object.instances, instance)
                placeObject(instance, spot)
            else
                placeObject(object, spot)
            end
        end)
    end

    -- Takes back the last one placed of a `many` object.
    local function removeLast(id)
        local system = getSystem()
        local instances = findPlaceable(id).instances
        if not system or #instances == 0 then return end
        local last = table.remove(instances)
        system:DevRemovePreview(last.id)
        placed[last.id] = nil
        if lastPlaced == last then lastPlaced = nil end
        writePlacement(string.format("%s\t%s\tremoved", os.date("%Y-%m-%d %H:%M:%S"), last.id))
        system:ShowNotice(last.label .. " removed", 2.0)
    end
    registerHotkey("ApisK0_RemoveAgent", "Dev: remove last agent", function() removeLast("agent") end)
    registerHotkey("ApisK0_RemoveDecor", "Dev: remove last seized item", function() removeLast("decor") end)

    -- Ghost mode: NPCs, turrets and cameras near V treat V as neutral (to place things in a hostile area). Turn it on
    -- before they see V.
    registerHotkey("ApisK0_DevGhost", "Dev: ghost mode (enemies ignore V)", function()
        local system = getSystem()
        if system then system:DevToggleGhost() end
    end)

    -- The NPC V looks at, as it is: its record, appearance and spot (a vanilla event's agents, to spawn the same
    -- ones there when the event is gone).
    registerHotkey("ApisK0_DevRecordNPC", "Dev: record NPC in sight", function()
        local system = getSystem()
        local player = Game.GetPlayer()
        if not system or not player then return end
        local target = Game.GetTargetingSystem():GetLookAtObject(player, false, false)
        if not target or not target:IsNPC() then
            system:ShowNotice("no NPC in sight", 2.0)
            return
        end
        local record = TDBID.ToStringDEBUG(target:GetRecordID())
        local appearance = target:GetCurrentAppearanceName().value
        local pos = target:GetWorldPosition()
        writePlacement(string.format("%s\tnpc\t%.2f\t%.2f\t%.2f\t%.1f\t%s\t%s", os.date("%Y-%m-%d %H:%M:%S"), pos.x, pos.y,
            pos.z, target:GetWorldYaw(), appearance, record))
        system:ShowNotice("recorded: " .. record, 3.0)
    end)

    -- The hostile zone's outline: corners at V's feet, in order around it (a small crate marks each). The zone is
    -- the polygon they make; "Dev: clear zone corners" starts it again.
    local corners = 0
    registerHotkey("ApisK0_ZoneCorner", "Dev: add zone corner", function()
        local system = getSystem()
        local player = Game.GetPlayer()
        if not system or not player then return end
        local pos = player:GetWorldPosition()
        corners = corners + 1
        local id = "zone_corner_" .. corners
        system:DevPreview(id, CONTAINERS .. "crates\\crate_small.ent", "crate_small_default", pos.x, pos.y, pos.z, 0.0)
        writePlacement(string.format("%s\t%s\t%.2f\t%.2f\t%.2f", os.date("%Y-%m-%d %H:%M:%S"), id, pos.x, pos.y, pos.z))
        system:ShowNotice(string.format("zone corner %d", corners), 2.0)
    end)
    registerHotkey("ApisK0_ZoneClear", "Dev: clear zone corners", function()
        local system = getSystem()
        if not system then return end
        for i = 1, corners do system:DevRemovePreview("zone_corner_" .. i) end
        corners = 0
        writePlacement(string.format("%s\tzone_clear", os.date("%Y-%m-%d %H:%M:%S")))
        system:ShowNotice("zone corners cleared", 2.0)
    end)

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

    -- The next look of the last placed object, if it has several.
    local function nextLook()
        if not lastPlaced or not lastPlaced.looks or not placed[lastPlaced.id] then return end
        lastPlaced.look = lastPlaced.look % #lastPlaced.looks + 1
        applyLook(lastPlaced)
        placeObject(lastPlaced, placed[lastPlaced.id])
        local system = getSystem()
        if system then
            local name = lastPlaced.record or (lastPlaced.template:match("[^\\]+$") .. " / " .. lastPlaced.appearance)
            system:ShowNotice(string.format("look %d/%d: %s", lastPlaced.look, #lastPlaced.looks, name), 3.0)
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
