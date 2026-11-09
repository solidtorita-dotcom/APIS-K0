-- APIS-K0 - "APIKO Settings" window (CET overlay): the player picks who powers Apiko and pastes their API keys.
-- Reads the catalog providers.json (providers, models, recommendations, notes) and reads/writes settings.json,
-- which the bridge reloads on its own. Apiko's voice itself is fixed per provider: only the provider is chosen.
-- "Test" buttons send {type = "test", what = "llm" | "stt" | "tts"} to the bridge, which answers with a "test"
-- reply "<what>|ok|<text>" or "<what>|error|<text>" (see onTestResult).

local Settings = {}

local CATALOG_FILE = "providers.json"
local SETTINGS_FILE = "settings.json"
local SAVE_DELAY = 0.8 -- seconds after the last edit
local KEY_MAX = 300
local URL_MAX = 300
local MODEL_MAX = 200

local SECTIONS = {
    { kind = "llm", title = "Reply model", hint = "The AI that writes what Apiko says." },
    { kind = "stt", title = "Speech recognition", hint = "Turns your voice into text (push to talk)." },
    { kind = "tts", title = "Voice", hint = "Renders Apiko's voice. The voice itself is always Apiko's." },
}

local catalog = nil
local settings = nil
local loadError = nil
local dirty = false
local sinceEdit = 0
local customModel = {} -- kind -> true while typing a model id not in the presets
local customRegion = {} -- kind .. provider -> true while typing a region not in the list
local testStatus = {}  -- kind -> { ok = bool, text = string } or { pending = true }

local function readJson(path)
    local file = io.open(path, "r")
    if not file then return nil, path .. " not found" end
    local text = file:read("*a")
    file:close()
    local ok, value = pcall(json.decode, text)
    if not ok or type(value) ~= "table" then return nil, path .. " is not valid JSON" end
    return value
end

-- json.decode turns {} into an empty list; make sure every table we index is there.
local function tableAt(parent, key)
    if type(parent[key]) ~= "table" then parent[key] = {} end
    return parent[key]
end

function Settings.load()
    local err
    catalog, err = readJson(CATALOG_FILE)
    if not catalog then
        loadError = err
        return
    end
    settings = readJson(SETTINGS_FILE) or { version = 1 }
    for _, section in ipairs(SECTIONS) do
        local mine = tableAt(settings, section.kind)
        tableAt(mine, "models")
        tableAt(mine, "urls")
    end
    tableAt(settings, "keys")
    loadError = nil
end

local function save()
    local file = io.open(SETTINGS_FILE, "w")
    if not file then
        loadError = "cannot write " .. SETTINGS_FILE
        return
    end
    file:write(json.encode(settings))
    file:close()
    dirty = false
end

local function changed()
    dirty = true
    sinceEdit = 0
end

-- Called from onUpdate: writes settings.json shortly after the last edit (not on every key press).
function Settings.update(delta)
    if not dirty then return end
    sinceEdit = sinceEdit + delta
    if sinceEdit >= SAVE_DELAY then save() end
end

-- Bridge reply of kind "test".
function Settings.onTestResult(text)
    local kind, status, message = text:match("^(%a+)|(%a+)|(.*)$")
    if kind then testStatus[kind] = { ok = status == "ok", text = message } end
end

------------------------------------------------------------------------------------------------------------
-- Helpers

local function providerId(kind)
    local section = catalog[kind]
    local id = settings[kind].provider
    if not section.providers[id] then id = section.default end
    return id
end

local function recommendedModel(entry)
    local models = entry.models or {}
    for _, model in ipairs(models) do
        if model.badge == "Recommended" then return model.id end
    end
    return models[1] and models[1].id or ""
end

local function currentModel(kind, id, entry)
    local model = settings[kind].models[id]
    if type(model) ~= "string" or model == "" then model = recommendedModel(entry) end
    return model
end

local function findPreset(entry, modelId)
    for _, model in ipairs(entry.models or {}) do
        if model.id == modelId then return model end
    end
    return nil
end

local function withBadge(label, badge)
    if badge and badge ~= "" then return label .. " (" .. badge .. ")" end
    return label
end

-- CET's ImGui.Selectable(label, selected) returns the item's new selected state, not "clicked": the selected
-- item returns true every frame. Only an unselected item turning selected is a real pick.
local function picked(label, selected)
    return ImGui.Selectable(label, selected) and not selected
end

-- Space above every option (each control with its label and note), so they do not run into each other.
local OPTION_GAP = 16

local function gap()
    ImGui.Dummy(0, OPTION_GAP)
end

local function note(text)
    if text and text ~= "" then
        ImGui.PushStyleColor(ImGuiCol.Text, 0.70, 0.70, 0.70, 1.0)
        ImGui.TextWrapped(text)
        ImGui.PopStyleColor()
    end
end

------------------------------------------------------------------------------------------------------------
-- Drawing

local function drawProvider(kind)
    local section = catalog[kind]
    local id = providerId(kind)
    local entry = section.providers[id]
    ImGui.PushItemWidth(-1)
    if ImGui.BeginCombo("##provider_" .. kind, withBadge(entry.label, entry.badge)) then
        for _, optionId in ipairs(section.order) do
            local option = section.providers[optionId]
            if option and picked(withBadge(option.label, option.badge), optionId == id) then
                settings[kind].provider = optionId
                testStatus[kind] = nil
                changed()
            end
        end
        ImGui.EndCombo()
    end
    ImGui.PopItemWidth()
    note(entry.note)
    return providerId(kind), section.providers[providerId(kind)]
end

local function drawModel(kind, id, entry)
    local models = entry.models or {}
    local model = currentModel(kind, id, entry)
    local preset = findPreset(entry, model)
    local custom = customModel[kind .. id] or (preset == nil)
    gap()
    ImGui.Text("Model")
    ImGui.PushItemWidth(-1)
    if #models > 0 then
        local preview = custom and "Custom model..." or withBadge(model, preset and preset.badge)
        if ImGui.BeginCombo("##model_" .. kind, preview) then
            for _, option in ipairs(models) do
                if picked(withBadge(option.id, option.badge), not custom and option.id == model) then
                    settings[kind].models[id] = option.id
                    customModel[kind .. id] = nil
                    changed()
                end
            end
            if picked("Custom model...", custom) then
                customModel[kind .. id] = true
            end
            ImGui.EndCombo()
        end
    end
    if custom or #models == 0 then
        local typed = settings[kind].models[id]
        if type(typed) ~= "string" then typed = "" end
        local text, edited = ImGui.InputTextWithHint("##custom_model_" .. kind, "model id, e.g. provider/model-name",
            typed, MODEL_MAX)
        if edited then
            settings[kind].models[id] = text
            changed()
        end
    end
    ImGui.PopItemWidth()
    if not custom and preset then note(preset.note) end
end

-- Providers with a fixed list of regions (Azure): a dropdown, plus "Other..." to type one that is not listed.
local function drawRegion(kind, id, entry, url)
    local current
    for _, region in ipairs(entry.regions) do
        if region.id == url then current = region end
    end
    local other = customRegion[kind .. id] or current == nil
    ImGui.Text(entry.url_label or "Region")
    ImGui.PushItemWidth(-1)
    if ImGui.BeginCombo("##region_" .. kind, other and "Other..." or current.label) then
        for _, region in ipairs(entry.regions) do
            if picked(region.label, not other and region.id == url) then
                settings[kind].urls[id] = region.id
                customRegion[kind .. id] = nil
                changed()
            end
        end
        if picked("Other...", other) then
            customRegion[kind .. id] = true
        end
        ImGui.EndCombo()
    end
    if other then
        local text, edited = ImGui.InputTextWithHint("##region_custom_" .. kind, "region name, e.g. uaenorth", url,
            URL_MAX)
        if edited then
            settings[kind].urls[id] = text
            changed()
        end
    end
    ImGui.PopItemWidth()
    if entry.url_note then note(entry.url_note) end
end

local function drawUrl(kind, id, entry)
    if not entry.url_editable then return end
    gap()
    local url = settings[kind].urls[id]
    if type(url) ~= "string" or url == "" then url = entry.base_url or "" end
    if entry.regions then
        drawRegion(kind, id, entry, url)
        return
    end
    ImGui.Text(entry.url_label or "Base URL")
    ImGui.PushItemWidth(-1)
    local text, edited = ImGui.InputText("##url_" .. kind, url, URL_MAX)
    ImGui.PopItemWidth()
    if edited then
        settings[kind].urls[id] = text
        changed()
    end
end

local function drawKey(kind, entry)
    if not entry.key then return end
    gap()
    local key = settings.keys[entry.key]
    if type(key) ~= "string" then key = "" end
    ImGui.Text("API key (" .. entry.label .. ")")
    ImGui.PushItemWidth(-1)
    local text, edited = ImGui.InputTextWithHint("##key_" .. kind, key == "" and "paste your key here" or "",
        key, KEY_MAX, ImGuiInputTextFlags.Password)
    ImGui.PopItemWidth()
    if edited then
        settings.keys[entry.key] = text:gsub("^%s+", ""):gsub("%s+$", "")
        changed()
    end
    if entry.key_url then
        ImGui.TextDisabled("Get a key (select and Ctrl+C):")
        ImGui.PushItemWidth(-1)
        ImGui.InputText("##key_url_" .. kind, entry.key_url, URL_MAX, ImGuiInputTextFlags.ReadOnly)
        ImGui.PopItemWidth()
    end
end

-- Reply model only: when the chosen model cannot answer, the bridge tries the next best one with a key.
local function drawFallback()
    gap()
    local enabled = settings.llm.fallback ~= false
    local value, pressed = ImGui.Checkbox("If it fails, use the next best model you have a key for", enabled)
    if pressed then
        settings.llm.fallback = value
        changed()
    end
    note("Order (best first): Claude Haiku, GPT-5.4 mini, Gemini 3.5 Flash, ... Groq, Ollama, free models. "
        .. "Only models whose provider has a key here are used.")
end

-- Reply model only: let it reason before answering (off by default: slower and dearer, little gain for Apiko).
local function drawThink(entry)
    gap()
    local enabled = settings.llm.think == true
    local value, pressed = ImGui.Checkbox("Think before answering", enabled)
    if pressed then
        settings.llm.think = value
        changed()
    end
    if entry.reasoning then
        note("Follows Apiko's rules a bit better, but answers about 2 s later and costs about twice as much. "
            .. "Recommended: off.")
    else
        note("This provider's models do not think: no effect here.")
    end
end

-- Reply model only: how often Apiko's remarks on events come from the model instead of its written lines.
local function drawImprovise()
    gap()
    local percent = math.floor((tonumber(settings.llm.improvise) or 0.1) * 100 + 0.5)
    ImGui.PushItemWidth(200)
    local value, used = ImGui.SliderInt("Improvised remarks", percent, 0, 50, "%d%%")
    ImGui.PopItemWidth()
    if used and value ~= percent then
        settings.llm.improvise = value / 100
        changed()
    end
    note("Apiko reacts to events (combat, alarms, districts...) with written lines: instant and free. This is how "
        .. "often the model makes one up instead (fresher, but it costs tokens and comes a bit later). 0% = only "
        .. "when you talk to it.")
end

local function drawTest(kind, bridgeOnline, sendToBridge)
    gap()
    if not bridgeOnline then
        ImGui.TextDisabled("Test: start the bridge first.")
        return
    end
    if ImGui.Button("Test##" .. kind) then
        if dirty then save() end
        testStatus[kind] = { pending = true }
        sendToBridge({ type = "test", what = kind })
    end
    local status = testStatus[kind]
    if status then
        ImGui.SameLine()
        if status.pending then
            ImGui.TextDisabled("testing...")
        elseif status.ok then
            ImGui.TextColored(0.50, 0.91, 0.85, 1.0, status.text)
        else
            ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.45, 0.35, 1.0)
            ImGui.TextWrapped(status.text)
            ImGui.PopStyleColor()
        end
    end
end

function Settings.draw(bridgeOnline, sendToBridge)
    ImGui.SetNextWindowSize(520, 640, ImGuiCond.FirstUseEver)
    if ImGui.Begin("APIKO Settings") then
        if not catalog or not settings then Settings.load() end
        if loadError then
            ImGui.TextColored(1.0, 0.45, 0.35, 1.0, loadError)
            if ImGui.Button("Retry") then Settings.load() end
        else
            note("Pick who powers Apiko and paste your own API keys. Changes apply on their own in a second.")
            ImGui.PushStyleColor(ImGuiCol.Text, 0.95, 0.75, 0.35, 1.0)
            ImGui.TextWrapped("Keys are saved as plain text in this mod's folder (settings.json). Never share that file.")
            ImGui.PopStyleColor()
            for _, section in ipairs(SECTIONS) do
                ImGui.Spacing()
                if ImGui.CollapsingHeader(section.title, ImGuiTreeNodeFlags.DefaultOpen) then
                    note(section.hint)
                    local id, entry = drawProvider(section.kind)
                    if section.kind ~= "tts" and (#(entry.models or {}) > 0 or entry.url_editable) then
                        drawModel(section.kind, id, entry)
                    end
                    drawUrl(section.kind, id, entry)
                    drawKey(section.kind, entry)
                    if section.kind == "llm" then
                        drawThink(entry)
                        drawImprovise()
                        drawFallback()
                    end
                    drawTest(section.kind, bridgeOnline, sendToBridge)
                end
            end
            ImGui.Spacing()
            ImGui.Separator()
            if dirty then ImGui.TextDisabled("Saving...") else ImGui.TextDisabled("Saved.") end
        end
    end
    ImGui.End()
end

return Settings
