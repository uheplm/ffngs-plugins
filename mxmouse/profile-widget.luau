--!nonstrict

local function config_path()
    local configHome = noctalia.getenv("XDG_CONFIG_HOME")
    if type(configHome) ~= "string" or configHome == "" or string.sub(configHome, 1, 1) ~= "/" then
        local home = noctalia.getenv("HOME")
        if type(home) ~= "string" or home == "" then
            return nil
        end
        configHome = home .. "/.config"
    end
    return configHome .. "/mxmouse/config.json"
end

local function status_path()
    local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
    if type(runtimeDir) ~= "string" or runtimeDir == "" then
        return nil
    end
    return runtimeDir .. "/mxmouse/status.json"
end

local function read_json(path, description)
    if path == nil then
        return nil, `{description} path is unavailable.`
    end
    if not noctalia.fileExists(path) then
        return nil, `{description} is unavailable.`
    end
    local contents, readError = noctalia.readFile(path)
    if type(contents) ~= "string" then
        return nil, `Could not read {description}: {tostring(readError)}`
    end
    local ok, decoded = pcall(noctalia.json.decode, contents)
    if not ok or type(decoded) ~= "table" then
        return nil, `Could not parse {description}.`
    end
    return decoded, nil
end

function update()
    noctalia.setUpdateInterval(500)

    local status, statusError = read_json(status_path(), "nnmxd status")
    local config, configError = read_json(config_path(), "MX Mouse configuration")
    local presets = if config ~= nil and type(config.presets) == "table" then config.presets else {}
    local presetId = if status ~= nil and type(status.presetId) == "string" and status.presetId ~= ""
        then status.presetId
        else if config ~= nil and type(config.defaultPresetId) == "string"
            then config.defaultPresetId else nil
    local selectedPreset = nil
    for _, preset in ipairs(presets) do
        if type(preset) == "table" and preset.id == presetId then
            selectedPreset = preset
            break
        end
    end
    if selectedPreset == nil and #presets > 0 and type(presets[1]) == "table" then
        selectedPreset = presets[1]
    end

    local glyph = if selectedPreset ~= nil
        and type(selectedPreset.glyph) == "string"
        and selectedPreset.glyph ~= ""
        then selectedPreset.glyph
        else "arrows-move"
    barWidget.setGlyph(glyph)
    barWidget.setVisible(true)
    if selectedPreset ~= nil then
        barWidget.setTooltip(selectedPreset.name or "Current MX Mouse profile")
    else
        barWidget.setTooltip(statusError or configError or "Current MX Mouse profile is unavailable.")
    end
end

update()
