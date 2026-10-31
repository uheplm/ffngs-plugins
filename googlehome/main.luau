--!nonstrict

local dataDir = nil
local connectedUuid = ""
local device = nil
local playerState = "UNKNOWN"
local trackTitle = "Nothing playing"
local trackArtist = ""
local albumName = ""
local seriesTitle = ""
local season = nil
local episode = nil
local coverUrl = ""
local coverPath = nil
local coverPending = false
local appName = ""
local appIconUrl = ""
local appIconAttemptedUrl = ""
local appIconPath = nil
local appIconPending = false
local currentTime = 0
local duration = 0
local volumePercent = 0
local volumeMuted = false
local busy = false
local message = ""
local panelOpen = false
local latestStatusPayload = ""
local run_control
local disconnect_device

local function media_image_url(metadata)
    if type(metadata) ~= "table" or type(metadata.images) ~= "table" then
        return ""
    end
    local bestUrl = ""
    local bestArea = 0
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
    return bestUrl
end

local function format_time(seconds)
    if type(seconds) ~= "number" or seconds < 0 then
        return "--:--"
    end
    local total = math.floor(seconds)
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function render()
    local cover = if coverPath ~= nil and noctalia.fileExists(coverPath)
        then ui.image({
            key = "player-cover",
            path = coverPath,
            width = 88,
            height = 88,
            fit = "cover",
            radius = 8,
        })
        else ui.column({
            key = "player-cover-placeholder",
            width = 88,
            height = 88,
            fill = "surface_container_high",
            radius = 8,
            align = "center",
            justify = "center",
        }, {
            ui.glyph({ key = "player-placeholder-glyph", name = "brand-google-home", size = 30 }),
        })

    local headerChildren = {}
    if appIconPath ~= nil and noctalia.fileExists(appIconPath) then
        table.insert(headerChildren, ui.image({
            key = "player-app-icon",
            path = appIconPath,
            width = 18,
            height = 18,
            fit = "contain",
        }))
    end
    table.insert(headerChildren, ui.button({
        key = "player-app-button",
        text = if appName ~= "" then appName else "Cast player",
        variant = "ghost",
        controlSize = "sm",
        tooltip = `Casting application: {if appName ~= "" then appName else "Cast player"}`,
    }))
    table.insert(headerChildren, ui.spacer({ key = "player-header-spacer", flexGrow = 1 }))
    if device ~= nil then
        table.insert(headerChildren, ui.glyph({
            key = "player-volume-glyph",
            name = if volumeMuted or volumePercent == 0 then "volume-x" else "volume",
            size = 18,
            color = "on_surface_variant",
        }))
        table.insert(headerChildren, ui.label({
            key = "player-volume",
            text = if volumeMuted then `{volumePercent}% muted` else `{volumePercent}%`,
            color = "on_surface_variant",
        }))
    end

    local videoDetails = ""
    if season ~= nil then
        videoDetails = `Season {tostring(season)}`
    end
    if episode ~= nil then
        videoDetails = if videoDetails ~= ""
            then `{videoDetails} • Episode {tostring(episode)}`
            else `Episode {tostring(episode)}`
    end

    local trackCard = ui.column({
        key = "player-track-card",
        gap = 8,
        padding = 10,
        fill = "surface_container_high",
        radius = 10,
    }, {
        ui.row({ key = "player-track", gap = 12, align = "center" }, {
            cover,
            ui.column({ key = "player-metadata", flexGrow = 1, gap = 4 }, {
                ui.label({
                    key = "player-title",
                    text = trackTitle,
                    fontSize = 16,
                    fontWeight = "bold",
                    maxLines = 2,
                }),
                ui.label({
                    key = "player-artist",
                    text = if seriesTitle ~= ""
                        then seriesTitle
                        else if trackArtist ~= "" then trackArtist else "Unknown artist",
                    color = "on_surface_variant",
                    maxLines = 1,
                }),
                ui.label({
                    key = "player-album",
                    text = if videoDetails ~= ""
                        then videoDetails
                        else if albumName ~= "" then albumName else " ",
                    color = "on_surface_variant",
                    maxLines = 1,
                }),
            }),
        }),
        ui.progress({
            key = "player-progress",
            progress = if duration > 0 then math.clamp(currentTime / duration, 0, 1) else 0,
            fill = "primary",
            track = "surface_variant",
            radius = 2,
            height = 4,
        }),
        ui.label({
            key = "player-time",
            text = if duration > 0
                then `{format_time(currentTime)} / {format_time(duration)} • {math.floor(math.clamp(currentTime / duration, 0, 1) * 100 + 0.5)}% • -{format_time(math.max(duration - currentTime, 0))}`
                else "--:-- / --:--",
            color = "on_surface_variant",
            textAlign = "end",
        }),
    })

    local children = {
        ui.row({ key = "player-header", align = "center", gap = 5 }, headerChildren),
        trackCard,
    }

    if device ~= nil then
        table.insert(children, ui.row({ key = "player-controls", gap = 6, align = "center" }, {
            ui.button({
                key = "player-previous",
                glyph = "player-track-prev",
                tooltip = "Previous track",
                enabled = not busy,
                onClick = function()
                    run_control("previous")
                end,
            }),
            ui.button({
                key = "player-toggle",
                glyph = if playerState == "PLAYING" then "player-pause" else "player-play",
                tooltip = if playerState == "PLAYING" then "Pause" else "Play",
                variant = "primary",
                enabled = not busy,
                onClick = function()
                    run_control(if playerState == "PLAYING" then "pause" else "play")
                end,
            }),
            ui.button({
                key = "player-next",
                glyph = "player-track-next",
                tooltip = "Next track",
                enabled = not busy,
                onClick = function()
                    run_control("next")
                end,
            }),
            ui.button({
                key = "player-stop",
                glyph = "player-stop",
                tooltip = "Stop and dismiss player",
                enabled = not busy,
                onClick = function()
                    run_control("stop")
                end,
            }),
            ui.spacer({ key = "player-control-spacer", flexGrow = 1 }),
            ui.button({
                key = "player-volume-down",
                glyph = "volume-2",
                tooltip = "Volume down",
                enabled = not busy,
                onClick = function()
                    run_control("volumedown")
                end,
            }),
            ui.button({
                key = "player-volume-up",
                glyph = "volume",
                tooltip = "Volume up",
                enabled = not busy,
                onClick = function()
                    run_control("volumeup")
                end,
            }),
            ui.button({
                key = "player-disconnect",
                glyph = "plug-off",
                tooltip = `Disconnect from {device.name}`,
                enabled = not busy,
                onClick = disconnect_device,
            }),
        }))
    else
        table.insert(children, ui.label({
            key = "player-disconnected",
            text = if message ~= "" then message else "Choose a speaker with /gh in the launcher.",
            color = "on_surface_variant",
            maxLines = 2,
        }))
    end

    panel.render(ui.column({
        key = "googlehome-mini-player",
        gap = 10,
        padding = 12,
    }, children))
end

local function load_device()
    device = nil
    if dataDir == nil or connectedUuid == "" then
        return
    end
    local contents, readError = noctalia.readFile(dataDir .. "/settings.json")
    if type(contents) ~= "string" then
        noctalia.log(`Could not read connected speaker details: {tostring(readError)}`)
        return
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" or settings.connected ~= true then
        return
    end
    if type(settings.devices) == "table" then
        for _, candidate in ipairs(settings.devices) do
            if type(candidate) == "table" and candidate.uuid == connectedUuid then
                device = candidate
                return
            end
        end
    end
    if settings.selectedUuid == connectedUuid then
        device = {
            uuid = connectedUuid,
            name = settings.name,
            host = settings.host,
            port = settings.port,
            model = settings.model,
        }
    end
end

local function load_cover(url)
    if url == coverUrl and (coverPath ~= nil or coverPending) then
        return
    end
    coverUrl = url
    coverPath = nil
    if url == "" or dataDir == nil then
        if panelOpen then
            render()
        end
        return
    end
    if coverPending then
        return
    end

    coverPending = true
    local requestedUrl = url
    local destination = dataDir .. "/panel-cover-art"
    local started = noctalia.download(requestedUrl, destination, function(ok)
        coverPending = false
        if requestedUrl ~= coverUrl then
            load_cover(coverUrl)
            return
        end
        if ok then
            coverPath = destination
        else
            noctalia.log(`Could not download Google Cast cover art: {requestedUrl}`)
        end
        if panelOpen then
            render()
        end
    end)
    if not started then
        coverPending = false
        noctalia.log(`Could not start Google Cast cover art download: {requestedUrl}`)
    end
end

local function load_app_icon(url)
    if url == appIconUrl
        and (appIconPath ~= nil or appIconPending or appIconAttemptedUrl == url)
    then
        return
    end
    appIconUrl = url
    appIconPath = nil
    if url == "" or dataDir == nil then
        return
    end
    if appIconPending then
        return
    end

    appIconPending = true
    appIconAttemptedUrl = url
    local requestedUrl = url
    local destination = dataDir .. "/casting-app-icon"
    local started = noctalia.download(requestedUrl, destination, function(ok)
        appIconPending = false
        if requestedUrl ~= appIconUrl then
            load_app_icon(appIconUrl)
            return
        end
        if ok then
            appIconPath = destination
        else
            noctalia.log(`Could not download Cast application icon: {requestedUrl}`)
        end
        if panelOpen then
            render()
        end
    end)
    if not started then
        appIconPending = false
        noctalia.log(`Could not start Cast application icon download: {requestedUrl}`)
    end
end

local function apply_status(payload)
    if type(payload) ~= "string" or payload == "" then
        playerState = "UNKNOWN"
        trackTitle = "Nothing playing"
        trackArtist = ""
        albumName = ""
        seriesTitle = ""
        season = nil
        episode = nil
        appName = ""
        currentTime = 0
        duration = 0
        volumePercent = 0
        volumeMuted = false
        load_cover("")
        load_app_icon("")
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
    volumeMuted = info.volume_muted == true
    appName = if type(info.display_name) == "string" then info.display_name else ""
    local metadata = if type(info.media_metadata) == "table" then info.media_metadata else {}
    trackTitle = if type(metadata.title) == "string" and metadata.title ~= ""
        then metadata.title
        else if type(info.status_text) == "string" and info.status_text ~= "" then info.status_text else "Nothing playing"
    trackArtist = if type(metadata.artist) == "string" then metadata.artist else ""
    albumName = if type(metadata.albumName) == "string" then metadata.albumName else ""
    seriesTitle = if type(metadata.seriesTitle) == "string" then metadata.seriesTitle else ""
    season = metadata.season
    episode = metadata.episode
    load_cover(media_image_url(metadata))
    load_app_icon(if type(info.icon_url) == "string" then info.icon_url else "")
end

run_control = function(action)
    if device == nil or busy then
        return
    end
    local command
    local timeout = 15000
    if action == "stop" or action == "play" or action == "pause" or action == "previous" or action == "next" then
        local pluginDir = noctalia.pluginDir()
        if type(pluginDir) ~= "string" or pluginDir == "" then
            noctalia.notifyError("Google Home", "Could not locate the Cast control helper.")
            return
        end
        command = {
            "python3",
            pluginDir .. "/cast-control.py",
            action,
            device.uuid,
            device.host,
            tostring(device.port),
            device.model,
        }
        timeout = if action == "stop" then 20000 else 35000
    else
        command = { "catt", "-d", device.name, action }
        if action == "volumeup" or action == "volumedown" then
            table.insert(command, "5")
        end
    end

    busy = true
    message = ""
    render()
    local started = noctalia.runAsync(command, function(result)
        busy = false
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.notifyError("Google Home", `Could not {action}: {detail}`)
        end
        render()
    end, timeout)
    if not started then
        busy = false
        noctalia.notifyError("Google Home", `Could not start the {action} command.`)
        render()
    end
end

disconnect_device = function()
    if dataDir == nil or device == nil then
        return
    end
    local path = dataDir .. "/settings.json"
    local contents, readError = noctalia.readFile(path)
    if type(contents) ~= "string" then
        noctalia.notifyError("Google Home", `Could not read saved speaker selection: {tostring(readError)}`)
        return
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" then
        noctalia.notifyError("Google Home", "Could not parse saved speaker selection.")
        return
    end
    settings.connected = false
    local encoded, encodeError = noctalia.json.encode(settings)
    if type(encoded) ~= "string" then
        noctalia.notifyError("Google Home", `Could not encode disconnect state: {tostring(encodeError)}`)
        return
    end
    local written, writeError = noctalia.writeFile(path, encoded)
    if not written then
        noctalia.notifyError("Google Home", `Could not save disconnect state: {tostring(writeError)}`)
        return
    end
    connectedUuid = ""
    device = nil
    message = "Disconnected."
    noctalia.state.set("googlehome.connectedUuid", "")
    noctalia.state.set("googlehome.status", "")
    apply_status("")
    render()
end

local function apply_connection(value)
    local nextUuid = if type(value) == "string" then value else ""
    local changed = nextUuid ~= connectedUuid
    connectedUuid = nextUuid
    message = ""
    load_device()
    if changed then
        playerState = "UNKNOWN"
        trackTitle = "Nothing playing"
        trackArtist = ""
        albumName = ""
        seriesTitle = ""
        season = nil
        episode = nil
        appName = ""
        currentTime = 0
        duration = 0
        volumePercent = 0
        volumeMuted = false
        load_cover("")
        load_app_icon("")
    end
    if connectedUuid == "" then
        device = nil
    end
    if panelOpen then
        render()
    end
end

local dataPath, dataError = noctalia.pluginDataDir()
if type(dataPath) == "string" and dataPath ~= "" then
    dataDir = dataPath
else
    noctalia.notifyError("Google Home", `Could not locate plugin data directory: {tostring(dataError)}`)
end

noctalia.state.watch("googlehome.connectedUuid", apply_connection)
noctalia.state.watch("googlehome.status", function(payload)
    latestStatusPayload = if type(payload) == "string" then payload else ""
    if panelOpen then
        apply_status(latestStatusPayload)
        render()
    end
end)

function onOpen(_context)
    panelOpen = true
    connectedUuid = noctalia.state.get("googlehome.connectedUuid") or ""
    load_device()
    latestStatusPayload = noctalia.state.get("googlehome.status") or ""
    apply_status(latestStatusPayload)
    render()
end

function onClose()
    panelOpen = false
end

function onKey(chord, pressed)
    if chord == "Escape" and pressed == "true" then
        panel.close()
    end
end
