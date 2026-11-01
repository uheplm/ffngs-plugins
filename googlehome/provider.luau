--!nonstrict

local dataDir = nil
local pluginDir = noctalia.pluginDir()
local devices = {}
local currentQuery = ""
local scanStarted = false
local scanInFlight = false
local notifyWhenScanCompletes = false
local connectedUuid = ""
local connectedName = ""
local latestStatusPayload = ""

local function glyph_for_model(model)
    local normalized = string.lower(model)
    if string.find(normalized, "group", 1, true) then
        return "speaker-multiple"
    elseif string.find(normalized, "speaker", 1, true)
        or string.find(normalized, "audio", 1, true)
        or string.find(normalized, "home mini", 1, true)
    then
        return "speaker"
    end
    return "cast"
end

local function icon_path_for_model(model)
    if type(pluginDir) ~= "string" or pluginDir == "" then
        return nil
    end
    local normalized = string.lower(model)
    if string.find(normalized, "group", 1, true) then
        return pluginDir .. "/speaker-group.svg"
    elseif string.find(normalized, "mini", 1, true) then
        return pluginDir .. "/nest-mini.svg"
    end
    return pluginDir .. "/chromecast.svg"
end

local function status_for_device(uuid)
    if uuid ~= connectedUuid or latestStatusPayload == "" then
        return if uuid == connectedUuid then "Connected" else "Available"
    end
    local ok, status = pcall(noctalia.json.decode, latestStatusPayload)
    if not ok or type(status) ~= "table" or status.selected_uuid ~= uuid then
        return "Connected"
    end
    if status.player_state == "PLAYING" then
        return "Playing"
    elseif status.player_state == "PAUSED" then
        return "Paused"
    elseif status.player_state == "IDLE" then
        return "Idle"
    end
    return "Connected"
end

local function load_saved_devices()
    local path = dataDir .. "/settings.json"
    if not noctalia.fileExists(path) then
        return
    end
    local contents, readError = noctalia.readFile(path)
    if type(contents) ~= "string" then
        noctalia.log(`Could not read cached Cast devices: {tostring(readError)}`)
        return
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" or type(settings.devices) ~= "table" then
        noctalia.log("Could not parse cached Cast devices.")
        return
    end
    devices = settings.devices
    connectedUuid = if settings.connected == true and type(settings.selectedUuid) == "string"
        then settings.selectedUuid
        else ""
    connectedName = if connectedUuid ~= "" and type(settings.name) == "string" then settings.name else ""
end

local function save_devices()
    local path = dataDir .. "/settings.json"
    local settings = {}
    if noctalia.fileExists(path) then
        local contents, readError = noctalia.readFile(path)
        if type(contents) ~= "string" then
            noctalia.notifyError("Google Home", `Could not read speaker cache: {tostring(readError)}`)
            return false
        end
        local ok, decoded = pcall(noctalia.json.decode, contents)
        if not ok or type(decoded) ~= "table" then
            noctalia.notifyError("Google Home", "Could not parse speaker cache.")
            return false
        end
        settings = decoded
    end
    settings.devices = devices
    local encoded, encodeError = noctalia.json.encode(settings)
    if type(encoded) ~= "string" then
        noctalia.notifyError("Google Home", `Could not encode speaker cache: {tostring(encodeError)}`)
        return false
    end
    local written, writeError = noctalia.writeFile(path, encoded)
    if not written then
        noctalia.notifyError("Google Home", `Could not save speaker cache: {tostring(writeError)}`)
        return false
    end
    return true
end

local function filtered_results(query)
    local needle = string.lower(noctalia.string.trim(query))
    local results = {}
    if connectedUuid ~= "" then
        table.insert(results, {
            id = "disconnect",
            title = "Disconnect",
            subtitle = `Disconnect from {connectedName}`,
            glyph = "plug-connected",
            score = 100,
        })
    end
    table.insert(results, {
        id = "refresh",
        title = if scanInFlight then "Refreshing devices…" else "Refresh devices",
        subtitle = if scanInFlight then "Scanning the local network with catt" else "Scan the local network for Cast devices",
        glyph = "refresh",
        score = 99,
    })
    for _, device in ipairs(devices) do
        local searchable = string.lower(device.name .. " " .. device.model)
        if needle == "" or string.find(searchable, needle, 1, true) ~= nil then
            table.insert(results, {
                id = device.uuid,
                title = device.name,
                subtitle = `{device.host} • {device.model} • {status_for_device(device.uuid)}`,
                glyph = glyph_for_model(device.model),
                icon = icon_path_for_model(device.model),
            })
        end
    end
    if #results == 0 then
        table.insert(results, {
            id = "",
            title = if scanInFlight then "Searching for Cast devices…" else "No matching Cast devices",
            subtitle = if scanInFlight then "Scanning the local network with catt" else "Try another query or check the network",
            glyph = "cast",
        })
    end
    return results
end

local function publish_results(query)
    launcher.setResults(query, filtered_results(query))
end

local function notify_scan_complete(deviceCount)
    local deviceLabel = if deviceCount == 1 then "device" else "devices"
    local body = `Found {deviceCount} Cast {deviceLabel}.`
    local started = noctalia.runAsync({
        "noctalia",
        "msg",
        "notification-show",
        "Google Home",
        body,
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.notifyError("Google Home", `Could not show refresh notification: {detail}`)
        end
    end, 5000)
    if not started then
        noctalia.notifyError("Google Home", "Could not start the refresh notification.")
    end
end

local function begin_scan(force)
    if dataDir == nil then
        return
    end
    if scanInFlight then
        notifyWhenScanCompletes = notifyWhenScanCompletes or force
        return
    end
    if scanStarted and not force then
        return
    end
    scanStarted = true
    scanInFlight = true
    notifyWhenScanCompletes = force
    local started = noctalia.runAsync({ "catt", "scan", "--json-output" }, function(result)
        scanInFlight = false
        if result.timedOut or result.exitCode ~= 0 then
            notifyWhenScanCompletes = false
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.notifyError("Google Home", `Could not discover Cast devices: {detail}`)
            publish_results(currentQuery)
            return
        end

        local ok, discovered = pcall(noctalia.json.decode, result.stdout)
        if not ok or type(discovered) ~= "table" then
            notifyWhenScanCompletes = false
            noctalia.notifyError("Google Home", "Could not parse catt device discovery results.")
            publish_results(currentQuery)
            return
        end

        local nextDevices = {}
        for fallbackName, info in pairs(discovered) do
            if type(info) == "table"
                and type(info.model_name) == "string"
                and info.model_name ~= ""
                and type(info.uuid) == "string"
                and info.uuid ~= ""
                and type(info.host) == "string"
                and info.host ~= ""
            then
                local name = if type(info.friendly_name) == "string" and info.friendly_name ~= ""
                    then info.friendly_name
                    else fallbackName
                local port = tonumber(info.port)
                if port == nil then
                    port = if string.find(string.lower(info.model_name), "group", 1, true) ~= nil
                        then 32000
                        else 8009
                end
                table.insert(nextDevices, {
                    name = name,
                    uuid = info.uuid,
                    host = info.host,
                    port = port,
                    model = info.model_name,
                })
            end
        end
        table.sort(nextDevices, function(left, right)
            return left.name < right.name
        end)
        devices = nextDevices
        if not save_devices() then
            notifyWhenScanCompletes = false
            publish_results(currentQuery)
            return
        end
        publish_results(currentQuery)
        if notifyWhenScanCompletes then
            notifyWhenScanCompletes = false
            notify_scan_complete(#devices)
        end
    end, 20000)
    if not started then
        scanInFlight = false
        notifyWhenScanCompletes = false
        noctalia.notifyError("Google Home", "Could not start catt device discovery.")
        publish_results(currentQuery)
    end
end

local function disconnect()
    local path = dataDir .. "/settings.json"
    local contents, readError = noctalia.readFile(path)
    if type(contents) ~= "string" then
        noctalia.notifyError("Google Home", `Could not read saved speaker selection: {tostring(readError)}`)
        return false
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" then
        noctalia.notifyError("Google Home", "Could not parse saved speaker selection.")
        return false
    end
    settings.connected = false
    local encoded, encodeError = noctalia.json.encode(settings)
    if type(encoded) ~= "string" then
        noctalia.notifyError("Google Home", `Could not encode disconnect state: {tostring(encodeError)}`)
        return false
    end
    local written, writeError = noctalia.writeFile(path, encoded)
    if not written then
        noctalia.notifyError("Google Home", `Could not save disconnect state: {tostring(writeError)}`)
        return false
    end
    connectedUuid = ""
    connectedName = ""
    noctalia.state.set("googlehome.status", "")
    noctalia.state.set("googlehome.deviceModel", "")
    noctalia.state.set("googlehome.connectedUuid", "")
    publish_results(currentQuery)
    return true
end

local function persist_connection(selected)
    local path = dataDir .. "/settings.json"
    local contents, readError = noctalia.readFile(path)
    if type(contents) ~= "string" then
        noctalia.notifyError("Google Home", `Could not read speaker cache: {tostring(readError)}`)
        return false
    end

    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" then
        noctalia.notifyError("Google Home", "Could not parse speaker cache.")
        return false
    end
    settings.selectedUuid = selected.uuid
    settings.connected = true
    settings.name = selected.name
    settings.host = selected.host
    settings.port = selected.port
    settings.model = selected.model
    local encoded, encodeError = noctalia.json.encode(settings)
    if type(encoded) ~= "string" then
        noctalia.notifyError("Google Home", `Could not encode speaker selection: {tostring(encodeError)}`)
        return false
    end
    local written, writeError = noctalia.writeFile(path, encoded)
    if not written then
        noctalia.notifyError("Google Home", `Could not save speaker selection: {tostring(writeError)}`)
        return false
    end
    return true
end

local dataPath, dataError = noctalia.pluginDataDir()
if type(dataPath) == "string" and dataPath ~= "" then
    dataDir = dataPath
    load_saved_devices()
else
    noctalia.notifyError("Google Home", `Could not locate plugin data directory: {tostring(dataError)}`)
end

function onQuery(query)
    currentQuery = query
    publish_results(query)
    begin_scan(false)
end

function onActivate(id)
    if id == "disconnect" then
        disconnect()
        return
    end
    if id == "refresh" then
        begin_scan(true)
        publish_results(currentQuery)
        return
    end

    if type(id) ~= "string" or id == "" or dataDir == nil then
        return
    end
    local selected = nil
    for _, candidate in ipairs(devices) do
        if candidate.uuid == id then
            selected = candidate
            break
        end
    end
    if selected == nil then
        noctalia.notifyError("Google Home", "That Cast device is no longer in the discovery results. Search again.")
        return
    end
    if not persist_connection(selected) then
        return
    end
    connectedUuid = selected.uuid
    connectedName = selected.name
    noctalia.state.set("googlehome.status", "")
    noctalia.state.set("googlehome.deviceModel", selected.model)
    noctalia.state.set("googlehome.connectedUuid", selected.uuid)
    noctalia.togglePanel("ffngs/googlehome:remote")
end

noctalia.state.watch("googlehome.status", function(payload)
    latestStatusPayload = if type(payload) == "string" then payload else ""
    publish_results(currentQuery)
end)
latestStatusPayload = noctalia.state.get("googlehome.status") or ""
