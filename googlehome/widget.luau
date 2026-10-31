--!nonstrict

local connectedUuid = ""
local trackTitle = "Nothing playing"
local playerState = "UNKNOWN"
local currentTime = 0
local duration = 0
local volumePercent = 0
local coverUrl = ""
local coverPath = nil
local coverPending = false
local dataDir = nil
local pluginDir = noctalia.pluginDir()
local connectedDevice = nil
local controlInFlight = false
local control

local function format_time(seconds)
    if type(seconds) ~= "number" or seconds < 0 then
        return "--:--"
    end
    local total = math.floor(seconds)
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function device_icon_path(model)
    if type(pluginDir) ~= "string" or pluginDir == "" or type(model) ~= "string" then
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

local function render()
    barWidget.setVisible(connectedUuid ~= "")
    if connectedUuid == "" then
        return
    end

    local children = {}
    if coverPath ~= nil and noctalia.fileExists(coverPath) then
        table.insert(children, ui.image({
            key = "googlehome-widget-cover",
            path = coverPath,
            width = 24,
            height = 24,
            fit = "cover",
            radius = 4,
            tooltip = if playerState == "PLAYING" then "Playing • click to pause" else "Not playing • click to play",
            onClick = function()
                control(if playerState == "PLAYING" then "pause" else "play")
            end,
        }))
    else
        table.insert(children, ui.button({
            key = "googlehome-widget-placeholder",
            glyph = if playerState == "PLAYING" then "player-pause" else "player-play",
            width = 24,
            height = 24,
            tooltip = if playerState == "PLAYING" then "Playing • click to pause" else "Not playing • click to play",
            enabled = not controlInFlight,
            onClick = function()
                control(if playerState == "PLAYING" then "pause" else "play")
            end,
        }))
    end
    table.insert(children, ui.label({
        key = "googlehome-widget-title",
        text = trackTitle,
        maxWidth = 140,
        maxLines = 1,
        tooltip = `{format_time(currentTime)} / {format_time(duration)}`,
    }))
    local iconPath = if connectedDevice ~= nil then device_icon_path(connectedDevice.model) else nil
    if iconPath ~= nil and noctalia.fileExists(iconPath) then
        table.insert(children, ui.image({
            key = "googlehome-widget-device-icon",
            path = iconPath,
            width = 18,
            height = 18,
            fit = "contain",
            tooltip = `{connectedDevice.name} • {volumePercent}%`,
        }))
    end
    barWidget.render((barWidget.isVertical() and ui.column or ui.row)({
        key = "googlehome-widget",
        align = "center",
        gap = 5,
    }, children))
end

local function read_connected_device()
    connectedDevice = nil
    if dataDir == nil or connectedUuid == "" then
        return
    end
    local contents, readError = noctalia.readFile(dataDir .. "/settings.json")
    if type(contents) ~= "string" then
        noctalia.log(`Could not read connected Cast device details: {tostring(readError)}`)
        return
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" or settings.connected ~= true then
        return
    end
    if type(settings.devices) == "table" then
        for _, candidate in ipairs(settings.devices) do
            if type(candidate) == "table" and candidate.uuid == connectedUuid then
                connectedDevice = candidate
                return
            end
        end
    end
end

local function load_cover(url)
    if url == coverUrl and (coverPath ~= nil or coverPending) then
        return
    end
    coverUrl = url
    coverPath = nil
    if url == "" or dataDir == nil then
        render()
        return
    end
    if coverPending then
        return
    end

    coverPending = true
    local requestedUrl = url
    local destination = dataDir .. "/widget-cover-art"
    local started = noctalia.download(requestedUrl, destination, function(ok)
        coverPending = false
        if requestedUrl ~= coverUrl then
            load_cover(coverUrl)
            return
        end
        if ok then
            coverPath = destination
        else
            noctalia.log(`Could not download Google Cast widget cover art: {requestedUrl}`)
        end
        render()
    end)
    if not started then
        coverPending = false
        noctalia.log(`Could not start Google Cast widget cover art download: {requestedUrl}`)
    end
end

local function apply_connection(value)
    local nextUuid = if type(value) == "string" then value else ""
    if nextUuid ~= connectedUuid then
        connectedUuid = nextUuid
        playerState = "UNKNOWN"
        trackTitle = "Nothing playing"
        currentTime = 0
        duration = 0
        volumePercent = 0
        load_cover("")
    end
    read_connected_device()
    render()
end

local function apply_status(payload)
    if connectedUuid == "" or type(payload) ~= "string" or payload == "" then
        return
    end
    local ok, info = pcall(noctalia.json.decode, payload)
    if not ok or type(info) ~= "table" or info.selected_uuid ~= connectedUuid then
        return
    end
    playerState = if type(info.player_state) == "string" then info.player_state else "UNKNOWN"
    currentTime = if type(info.current_time) == "number" then info.current_time else 0
    duration = if type(info.duration) == "number" then info.duration else 0
    volumePercent = if type(info.volume_level) == "number"
        then math.clamp(math.floor(info.volume_level * 100 + 0.5), 0, 100)
        else volumePercent
    local metadata = if type(info.media_metadata) == "table" then info.media_metadata else {}
    trackTitle = if type(metadata.title) == "string" and metadata.title ~= ""
        then metadata.title
        else if type(info.status_text) == "string" and info.status_text ~= "" then info.status_text else "Nothing playing"
    local bestUrl = ""
    local bestArea = 0
    if type(metadata.images) == "table" then
        for _, image in ipairs(metadata.images) do
            if type(image) == "table" and type(image.url) == "string" and image.url ~= "" then
                local width = if type(image.width) == "number" then image.width else 0
                local height = if type(image.height) == "number" then image.height else 0
                local area = width * height
                if bestUrl == "" or area > bestArea then
                    bestUrl = image.url
                    bestArea = area
                end
            end
        end
    end
    load_cover(bestUrl)
    render()
end

control = function(action)
    if connectedDevice == nil or controlInFlight then
        return
    end
    local command
    local timeout = 15000
    if action == "play" or action == "pause" or action == "next" then
        if type(pluginDir) ~= "string" or pluginDir == "" then
            noctalia.notifyError("Google Home", "Could not locate the Cast control helper.")
            return
        end
        command = {
            "python3",
            pluginDir .. "/cast-control.py",
            "next",
            connectedDevice.uuid,
            connectedDevice.host,
            tostring(connectedDevice.port),
            connectedDevice.model,
        }
        timeout = 35000
    else
        command = { "catt", "-d", connectedDevice.name, action }
    end
    controlInFlight = true
    render()
    local started = noctalia.runAsync(command, function(result)
        controlInFlight = false
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.notifyError("Google Home", `Could not {action}: {detail}`)
        end
        render()
    end, timeout)
    if not started then
        controlInFlight = false
        noctalia.notifyError("Google Home", `Could not start the {action} command.`)
        render()
    end
end

local dataPath, dataError = noctalia.pluginDataDir()
if type(dataPath) == "string" and dataPath ~= "" then
    dataDir = dataPath
else
    noctalia.log(`Could not locate Google Home widget data directory: {tostring(dataError)}`)
end

noctalia.state.watch("googlehome.connectedUuid", apply_connection)
noctalia.state.watch("googlehome.status", apply_status)

function onClick()
    if connectedUuid ~= "" then
        noctalia.togglePanel("ffngs/googlehome:remote")
    end
end

function onRightClick()
    control("next")
end

apply_connection(noctalia.state.get("googlehome.connectedUuid") or "")
apply_status(noctalia.state.get("googlehome.status") or "")
