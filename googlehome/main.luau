--!nonstrict

local DATA_PATH = nil
local devices = {}
local selectedUuid = ""
local activeTab = "playback"
local volume = 0
local volumeMuted = false
local playerState = "Unknown"
local trackTitle = "Nothing playing"
local trackArtist = ""
local albumName = ""
local appName = ""
local streamType = ""
local contentType = ""
local playbackRate = 1
local volumeControlType = ""
local currentTime = 0
local duration = 0
local pollInterval = 5
local displayElapsedMs = 0
local cover = { url = "", path = nil, pending = false }
local appIcon = { url = "", path = nil, pending = false }
local volumeDragging = false
local seekDragging = false
local busy = false
local scanning = false
local refreshing = false
local refreshPending = false
local pendingPreserveMessage = false
local message = ""
local castUrl = ""
local castTitle = ""
local render
local refresh_status

local function selected_device()
    for _, device in ipairs(devices) do
        if device.uuid == selectedUuid then
            return device
        end
    end
    return nil
end

local function persist_selection()
    if DATA_PATH == nil or selectedUuid == "" then
        message = "Could not save speaker selection because the plugin data path is unavailable."
        return false
    end
    local device = selected_device()
    if device == nil then
        message = "Could not save speaker selection because the selected speaker is unavailable."
        return false
    end
    local encoded, encodeError = noctalia.json.encode({
        selectedUuid = selectedUuid,
        name = device.name,
        host = device.host,
        model = device.model,
    })
    if type(encoded) ~= "string" then
        message = `Could not encode speaker selection: {tostring(encodeError)}`
        return false
    end
    local written, writeError = noctalia.writeFile(DATA_PATH, encoded)
    if not written then
        message = `Could not save speaker selection: {tostring(writeError)}`
        return false
    end
    return true
end

local function load_image_asset(asset, url, filename)
    if type(url) ~= "string" or url == "" then
        asset.url = ""
        asset.path = nil
        return
    end
    if url == asset.url and (asset.path ~= nil or asset.pending) then
        return
    end
    asset.url = url
    asset.path = nil
    if asset.pending then
        return
    end

    local dataDir, dirError = noctalia.pluginDataDir()
    if type(dataDir) ~= "string" or dataDir == "" then
        message = `Could not locate artwork cache directory: {tostring(dirError)}`
        return
    end
    local destination = dataDir .. "/" .. filename
    asset.pending = true
    local requestedUrl = url
    local started = noctalia.download(requestedUrl, destination, function(ok)
        asset.pending = false
        if asset.url ~= requestedUrl then
            load_image_asset(asset, asset.url, filename)
            return
        end
        if ok then
            asset.path = destination
        else
            noctalia.log(`Could not download Google Cast image: {requestedUrl}`)
        end
        render()
    end)
    if not started then
        asset.pending = false
        noctalia.log(`Could not start Google Cast image download: {requestedUrl}`)
    end
end

local function format_time(seconds)
    local total = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local remainder = total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, remainder)
    end
    return string.format("%d:%02d", minutes, remainder)
end

local function load_poll_interval()
    local configured = tonumber(noctalia.getConfig("poll_interval"))
    if configured ~= nil then
        pollInterval = math.clamp(math.floor(configured), 1, 60)
    else
        pollInterval = 5
    end
    noctalia.setUpdateInterval(pollInterval * 1000)
end

local function media_image_url(metadata)
    if type(metadata.images) ~= "table" then
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

local function load_selection()
    local dataDir, dirError = noctalia.pluginDataDir()
    if type(dataDir) ~= "string" or dataDir == "" then
        message = `Could not locate plugin data directory: {tostring(dirError)}`
        return
    end
    DATA_PATH = dataDir .. "/settings.json"
    if not noctalia.fileExists(DATA_PATH) then
        return
    end
    local contents, readError = noctalia.readFile(DATA_PATH)
    if type(contents) ~= "string" then
        message = `Could not read speaker selection: {tostring(readError)}`
        return
    end
    local ok, decoded = pcall(noctalia.json.decode, contents)
    if not ok or type(decoded) ~= "table" or type(decoded.selectedUuid) ~= "string" then
        message = "Could not parse saved speaker selection."
        return
    end
    selectedUuid = decoded.selectedUuid
end

local function run_device_command(action, arguments, successMessage)
    local device = selected_device()
    if device == nil then
        message = "Select a Google Home speaker or Cast group first."
        render()
        return
    end
    if busy then
        return
    end

    busy = true
    message = `Running {action} on {device.name}…`
    render()
    local command = { "catt", "-d", device.name, action }
    for _, argument in ipairs(arguments or {}) do
        table.insert(command, argument)
    end
    local started = noctalia.runAsync(command, function(result)
        busy = false
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            message = `Could not {action}: {detail}`
            render()
            refresh_status(true)
            return
        end
        message = successMessage
        render()
        refresh_status()
    end, 30000)
    if not started then
        busy = false
        message = `Could not start catt {action}.`
        render()
        refresh_status(true)
    end
end

refresh_status = function(preserveMessage)
    local device = selected_device()
    if device == nil then
        return
    end
    if refreshing then
        refreshPending = true
        pendingPreserveMessage = pendingPreserveMessage or preserveMessage == true
        return
    end

    local preserveCurrentMessage = preserveMessage == true
    local requestedUuid = device.uuid
    refreshing = true
    local function finish_refresh()
        refreshing = false
        if refreshPending then
            local keepMessage = pendingPreserveMessage
            refreshPending = false
            pendingPreserveMessage = false
            refresh_status(keepMessage)
        end
    end

    local started = noctalia.runAsync({ "catt", "-d", device.name, "info", "--json-output" }, function(result)
        if selectedUuid ~= requestedUuid then
            finish_refresh()
            if not refreshing then
                refresh_status()
            end
            return
        end
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            message = `Could not read {device.name} status: {detail}`
            finish_refresh()
            render()
            return
        end

        local ok, info = pcall(noctalia.json.decode, result.stdout)
        if not ok or type(info) ~= "table" then
            message = "Could not parse speaker status from catt."
            finish_refresh()
            render()
            return
        end
        playerState = if type(info.player_state) == "string" then info.player_state else "Unknown"
        if not volumeDragging and type(info.volume_level) == "number" then
            volume = math.floor(info.volume_level * 100 + 0.5)
        end
        volumeMuted = info.volume_muted == true
        if not seekDragging then
            currentTime = if type(info.current_time) == "number" then info.current_time else 0
            displayElapsedMs = 0
        end
        duration = if type(info.duration) == "number" then info.duration else 0
        streamType = if type(info.stream_type) == "string" then info.stream_type else ""
        contentType = if type(info.content_type) == "string" then info.content_type else ""
        playbackRate = if type(info.playback_rate) == "number" then info.playback_rate else 1
        volumeControlType = if type(info.volume_control_type) == "string" then info.volume_control_type else ""
        appName = if type(info.display_name) == "string" and info.display_name ~= ""
            then info.display_name
            else if type(info.status_text) == "string" then info.status_text else ""
        local metadata = if type(info.media_metadata) == "table" then info.media_metadata else {}
        trackTitle = if type(metadata.title) == "string" and metadata.title ~= ""
            then metadata.title
            else if type(info.status_text) == "string" and info.status_text ~= "" then info.status_text else "Nothing playing"
        trackArtist = if type(metadata.artist) == "string" and metadata.artist ~= ""
            then metadata.artist
            else ""
        albumName = if type(metadata.albumName) == "string" then metadata.albumName else ""
        load_image_asset(cover, media_image_url(metadata), "cover-art")
        load_image_asset(appIcon, info.icon_url, "cast-app-icon")
        if not preserveCurrentMessage and not pendingPreserveMessage then
            message = ""
        end
        finish_refresh()
        render()
    end, 10000)
    if not started then
        message = "Could not start catt to read speaker status."
        finish_refresh()
        render()
    end
end

local function scan_devices()
    if scanning then
        return
    end
    scanning = true
    message = "Searching the local network for Google Home speakers and Cast groups…"
    render()
    local started = noctalia.runAsync({ "catt", "scan", "--json-output" }, function(result)
        scanning = false
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            message = `Could not discover Cast devices: {detail}`
            render()
            return
        end

        local ok, discovered = pcall(noctalia.json.decode, result.stdout)
        if not ok or type(discovered) ~= "table" then
            message = "Could not parse Cast device discovery results."
            render()
            return
        end

        devices = {}
        for name, info in pairs(discovered) do
            if type(info) == "table"
                and type(info.model_name) == "string"
                and (
                    string.find(info.model_name, "Google Home Mini", 1, true) ~= nil
                    or string.find(info.model_name, "Google Cast Group", 1, true) ~= nil
                )
                and type(info.uuid) == "string"
                and type(info.host) == "string"
            then
                table.insert(devices, {
                    name = if type(info.friendly_name) == "string" and info.friendly_name ~= "" then info.friendly_name else name,
                    uuid = info.uuid,
                    host = info.host,
                    model = info.model_name,
                })
            end
        end
        table.sort(devices, function(left, right)
            return left.name < right.name
        end)

        local changedSelection = selected_device() == nil
        if changedSelection then
            selectedUuid = if #devices > 0 then devices[1].uuid else ""
        end

        if #devices == 0 then
            message = "No Google Home speakers or Cast groups found. Check that catt and the devices are on the same local network."
            render()
            return
        end
        if changedSelection then
            playerState = "Unknown"
            trackTitle = "Nothing playing"
            trackArtist = ""
            albumName = ""
            appName = ""
            streamType = ""
            contentType = ""
            playbackRate = 1
            volumeControlType = ""
            currentTime = 0
            duration = 0
            volume = 0
            volumeMuted = false
            cover.url = ""
            cover.path = nil
            appIcon.url = ""
            appIcon.path = nil
        end
        if not persist_selection() then
            render()
            return
        end
        message = `Found {#devices} Google Home speaker(s) and Cast group(s).`
        render()
        refresh_status()
    end, 20000)
    if not started then
        scanning = false
        message = "Could not start catt device discovery."
        render()
    end
end

local function select_device(value)
    local optionIndex = tonumber(value)
    if optionIndex == nil or optionIndex < 0 or optionIndex >= #devices then
        return
    end
    local index = optionIndex + 1
    local previousUuid = selectedUuid
    selectedUuid = devices[index].uuid
    if previousUuid ~= selectedUuid then
        playerState = "Unknown"
        trackTitle = "Nothing playing"
        trackArtist = ""
        albumName = ""
        appName = ""
        currentTime = 0
        duration = 0
        volume = 0
        volumeMuted = false
        streamType = ""
        contentType = ""
        playbackRate = 1
        volumeControlType = ""
        cover.url = ""
        cover.path = nil
        appIcon.url = ""
        appIcon.path = nil
    end
    if not persist_selection() then
        render()
        return
    end
    message = `Selected {devices[index].name}.`
    render()
    refresh_status()
end

local function set_volume()
    run_device_command("volume", { tostring(volume) }, `Volume set to {volume}%.`)
end

local function set_mute()
    local nextMuted = not volumeMuted
    run_device_command("volumemute", { tostring(nextMuted) }, if nextMuted then "Muted speaker." else "Unmuted speaker.")
end

local function seek_media()
    if duration <= 0 then
        return
    end
    currentTime = math.clamp(math.floor(currentTime + 0.5), 0, math.floor(duration))
    displayElapsedMs = 0
    run_device_command("seek", { tostring(currentTime) }, `Seeking to {format_time(currentTime)}.`)
end

local function cast_media()
    local url = string.gsub(castUrl, "^%s*(.-)%s*$", "%1")
    if not string.match(url, "^https?://[^%s]+$") then
        message = "Enter a valid HTTP or HTTPS media URL."
        render()
        return
    end
    local arguments = {}
    local title = string.gsub(castTitle, "^%s*(.-)%s*$", "%1")
    if title ~= "" then
        table.insert(arguments, "-l")
        table.insert(arguments, title)
    end
    table.insert(arguments, url)
    run_device_command("cast", arguments, "Casting media to the selected speaker.")
end

render = function()
    local device = selected_device()
    local pluginPath = noctalia.pluginDir()
    local deviceIconName = if device ~= nil and device.model == "Google Cast Group"
        then "chromecast.svg"
        else "nest-mini.svg"
    local deviceIconPath = if type(pluginPath) == "string" and pluginPath ~= ""
        then pluginPath .. "/" .. deviceIconName
        else nil
    local deviceOptions = {}
    local selectedIndex = 0
    for index, item in ipairs(devices) do
        table.insert(deviceOptions, `{item.name} · {item.model} · {item.host}`)
        if item.uuid == selectedUuid then
            selectedIndex = index - 1
        end
    end

    local tabs = {
        ui.button({
            text = "Playback",
            glyph = "player-play",
            selected = activeTab == "playback",
            onClick = function()
                activeTab = "playback"
                render()
            end,
        }),
        ui.button({
            text = "Cast",
            glyph = "cast",
            selected = activeTab == "cast",
            onClick = function()
                activeTab = "cast"
                render()
            end,
        }),
    }
    local playbackGlyph = if playerState == "PLAYING" then "player-pause" else "player-play"
    local statusGlyph = if playerState == "PLAYING" then "player-play"
        else if playerState == "PAUSED" then "player-pause"
        else "player-stop"
    local artwork = if cover.path ~= nil and noctalia.fileExists(cover.path) then ui.image({
        path = cover.path,
        width = 192,
        height = 192,
        fit = "cover",
        radius = 20,
    }) else ui.column({ width = 192, height = 192, align = "center", justify = "center", fill = "surface_container_high", radius = 20 }, {
        ui.glyph({ name = "brand-google-home", size = 64, color = "on_surface_variant" }),
    })
    local appBadgeChildren = {}
    if appIcon.path ~= nil and noctalia.fileExists(appIcon.path) then
        table.insert(appBadgeChildren, ui.image({
            path = appIcon.path,
            width = 18,
            height = 18,
            fit = "contain",
        }))
    end
    if appName ~= "" then
        table.insert(appBadgeChildren, ui.label({ text = appName, color = "on_surface_variant", maxLines = 1 }))
    end
    if streamType == "LIVE" then
        table.insert(appBadgeChildren, ui.label({ text = "LIVE", fontSize = 10, color = "primary", fontWeight = "bold" }))
    elseif contentType ~= "" and #appBadgeChildren == 0 then
        table.insert(appBadgeChildren, ui.label({ text = contentType, color = "on_surface_variant", maxLines = 1 }))
    end

    local content = {
        ui.row({ align = "center", gap = 16 }, {
            if deviceIconPath ~= nil and noctalia.fileExists(deviceIconPath) then ui.image({
                path = deviceIconPath,
                width = 40,
                height = 40,
                fit = "contain",
            }) else ui.glyph({ name = "brand-google-home", size = 32, color = "primary" }),
            ui.column({ flexGrow = 1, gap = 1 }, {
                ui.label({ text = "Google Home", fontSize = 22, fontWeight = "bold" }),
                ui.label({
                    text = if device ~= nil then `Connected to {device.name}` else "Discover a speaker to get started",
                    color = "on_surface_variant",
                    maxLines = 1,
                }),
            }),
            ui.row({ gap = 8 }, tabs),
        }),
        ui.row({ align = "center", gap = 12 }, {
            ui.select({
                key = "speaker-select",
                options = deviceOptions,
                selectedIndex = selectedIndex,
                placeholder = if scanning then "Searching…" else "Select a speaker",
                enabled = #devices > 0 and not busy,
                flexGrow = 1,
                onChange = select_device,
            }),
            ui.button({
                text = if scanning then "Scanning…" else "Refresh",
                glyph = "refresh",
                enabled = not scanning,
                onClick = scan_devices,
            }),
        }),
    }

    if activeTab == "playback" then
        table.insert(content, ui.column({ gap = 20, padding = 24, fill = "surface_container", radius = 18 }, {
            ui.row({ align = "center", gap = 24 }, {
                artwork,
                ui.column({
                    flexGrow = 1,
                    minWidth = 340,
                    gap = 12,
                    padding = 18,
                    fill = "surface_container_high",
                    radius = 18,
                    align = "center",
                    justify = "center",
                }, {
                    ui.row({ align = "center", gap = 6 }, {
                        ui.glyph({ name = statusGlyph, size = 16, color = "primary" }),
                        ui.label({ text = if refreshing then "Updating…" else "Playback", color = "on_surface_variant" }),
                        if playbackRate ~= 1 then ui.label({ text = `{playbackRate}×`, color = "on_surface_variant" }) else nil,
                    }),
                    ui.label({ text = trackTitle, fontSize = 20, fontWeight = "bold", maxLines = 2, textAlign = "center" }),
                    ui.label({
                        text = if trackArtist ~= "" then trackArtist else if albumName ~= "" then albumName else (if device ~= nil then device.name else "No speaker selected"),
                        color = "on_surface_variant",
                        maxLines = 2,
                        textAlign = "center",
                    }),
                    if albumName ~= "" and trackArtist ~= "" then ui.label({
                        text = albumName,
                        color = "on_surface_variant",
                        maxLines = 1,
                        textAlign = "center",
                    }) else nil,
                    ui.row({ align = "center", gap = 5 }, appBadgeChildren),
                }),
            }),
            ui.row({ align = "center", justify = "space_between", paddingH = 4 }, {
                ui.label({ text = format_time(currentTime), color = "on_surface_variant" }),
                ui.label({
                    text = if streamType == "LIVE" then "LIVE" else format_time(duration),
                    color = "on_surface_variant",
                }),
            }),
            ui.slider({
                key = "position-slider",
                min = 0,
                max = math.max(1, math.floor(duration)),
                step = 1,
                value = math.clamp(currentTime, 0, math.max(1, duration)),
                enabled = device ~= nil and duration > 0 and not busy,
                onChange = function(value)
                    local updated = tonumber(value)
                    if updated ~= nil then
                        seekDragging = true
                        currentTime = math.clamp(updated, 0, duration)
                        render()
                    end
                end,
                onDragEnd = function()
                    seekDragging = false
                    seek_media()
                end,
            }),
            ui.label({
                text = if device ~= nil
                    then `Speaker volume · {volume}%{if volumeControlType ~= "" then ` · {volumeControlType}` else ""}`
                    else "Speaker volume",
                color = "on_surface_variant",
            }),
            ui.slider({
                key = "volume-slider",
                min = 0,
                max = 100,
                step = 1,
                value = volume,
                enabled = device ~= nil and not busy,
                onChange = function(value)
                    local updated = tonumber(value)
                    if updated ~= nil then
                        volumeDragging = true
                        volume = math.clamp(math.floor(updated + 0.5), 0, 100)
                        render()
                    end
                end,
                onDragEnd = function()
                    volumeDragging = false
                    set_volume()
                end,
            }),
            ui.row({ justify = "center", gap = 14, paddingV = 4 }, {
                ui.button({
                    glyph = "player-skip-back",
                    tooltip = "Rewind 10 seconds",
                    enabled = device ~= nil and not busy,
                    onClick = function()
                        run_device_command("rewind", { "10" }, "Rewound 10 seconds.")
                    end,
                }),
                ui.button({
                    glyph = playbackGlyph,
                    tooltip = if playerState == "PLAYING" then "Pause" else "Play",
                    variant = "primary",
                    enabled = device ~= nil and not busy,
                    onClick = function()
                        run_device_command("play_toggle", {}, "Toggled playback.")
                    end,
                }),
                ui.button({
                    glyph = if volumeMuted then "volume-off" else "volume",
                    tooltip = if volumeMuted then "Unmute" else "Mute",
                    enabled = device ~= nil and not busy,
                    onClick = set_mute,
                }),
                ui.button({
                    glyph = "player-track-next",
                    tooltip = "Skip to next track",
                    enabled = device ~= nil and not busy,
                    onClick = function()
                        run_device_command("skip", {}, "Skipped current media.")
                    end,
                }),
                ui.button({
                    glyph = "player-skip-forward",
                    tooltip = "Forward 10 seconds",
                    enabled = device ~= nil and not busy,
                    onClick = function()
                        run_device_command("ffwd", { "10" }, "Forwarded 10 seconds.")
                    end,
                }),
            }),
        }))
    else
        table.insert(content, ui.column({ gap = 12, padding = 16, fill = "surface_container", radius = 14 }, {
            ui.column({ gap = 3 }, {
                ui.label({ text = "Cast a media URL", fontSize = 18, fontWeight = "bold" }),
                ui.label({
                    text = "Send a supported video or audio URL to the selected speaker.",
                    color = "on_surface_variant",
                }),
            }),
            ui.column({ gap = 4 }, {
                ui.label({ text = "Media URL", fontWeight = "medium" }),
                ui.input({
                    key = "cast-url",
                    value = castUrl,
                    placeholder = "https://example.com/media.mp3",
                    onChange = function(value)
                        castUrl = value
                    end,
                }),
            }),
            ui.column({ gap = 4 }, {
                ui.label({ text = "Title (optional)", fontWeight = "medium" }),
                ui.input({
                    key = "cast-title",
                    value = castTitle,
                    placeholder = "What to show on the speaker",
                    onChange = function(value)
                        castTitle = value
                    end,
                }),
            }),
            ui.button({
                text = if busy then "Working…" else "Cast to speaker",
                glyph = "cast",
                variant = "primary",
                enabled = device ~= nil and not busy,
                onClick = cast_media,
            }),
        }))
    end

    table.insert(content, ui.label({
        text = if message ~= "" then message else "Choose a speaker and control it over your local network.",
        color = if string.find(message, "Could not") or string.find(message, "No Google") or string.find(message, "valid") then "error" else "on_surface_variant",
        maxLines = 3,
    }))
    panel.render(ui.column({ flexGrow = 1, gap = 18, padding = 24 }, content))
end

function onOpen(_context)
    message = ""
    load_poll_interval()
    displayElapsedMs = 0
    panel.setNeedsFrameTick(true)
    panel.setWantsSecondTicks(true)
    load_selection()
    render()
    scan_devices()
end

function update()
    if not volumeDragging and not seekDragging and not busy then
        refresh_status()
    end
end

function onFrameTick(deltaMs)
    local elapsedMs = tonumber(deltaMs)
    if elapsedMs == nil or elapsedMs <= 0 or playerState ~= "PLAYING" or seekDragging or duration <= 0 then
        return
    end

    displayElapsedMs += elapsedMs
    if displayElapsedMs >= 1000 then
        local elapsedSeconds = math.floor(displayElapsedMs / 1000)
        displayElapsedMs %= 1000
        currentTime = math.min(currentTime + elapsedSeconds * playbackRate, duration)
        render()
    end
end

function onClose()
    panel.setNeedsFrameTick(false)
    panel.setWantsSecondTicks(false)
end

function onKey(chord, pressed)
    if chord == "Escape" and pressed == "true" then
        panel.close()
    end
end
