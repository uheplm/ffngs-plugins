--!nonstrict

local dataDir = nil
local selectedName = nil
local selectedUuid = nil
local playerState = "UNKNOWN"
local trackTitle = "Nothing playing"
local trackArtist = ""
local albumName = ""
local appName = ""
local volume = 0
local volumeMuted = false
local currentTime = 0
local duration = 0
local streamType = ""
local coverUrl = ""
local coverPath = nil
local infoInFlight = false
local controlInFlight = false
local artworkInFlight = false
local control
local refresh

local function poll_interval_ms()
    local configured = tonumber(noctalia.getConfig("poll_interval"))
    local seconds = if configured ~= nil then math.clamp(math.floor(configured), 1, 60) else 5
    return seconds * 1000
end

local function format_time(seconds)
    local total = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function render()
    local children = {}
    if coverPath ~= nil and noctalia.fileExists(coverPath) then
        table.insert(children, ui.image({
            path = coverPath,
            width = 24,
            height = 24,
            fit = "cover",
            radius = 4,
        }))
    else
        table.insert(children, ui.glyph({ name = "brand-google-home", size = 16 }))
    end

    table.insert(children, ui.label({
        text = trackTitle,
        maxWidth = 110,
        maxLines = 1,
    }))
    table.insert(children, ui.button({
        key = "widget-play-toggle",
        glyph = if playerState == "PLAYING" then "player-pause" else "player-play",
        tooltip = if playerState == "PLAYING" then "Pause" else "Play",
        enabled = selectedName ~= nil and not controlInFlight,
        variant = "ghost",
        onClick = function()
            control("play_toggle")
        end,
    }))
    table.insert(children, ui.button({
        key = "widget-skip",
        glyph = "player-track-next",
        tooltip = "Skip track",
        enabled = selectedName ~= nil and not controlInFlight,
        variant = "ghost",
        onClick = function()
            control("skip")
        end,
    }))
    table.insert(children, ui.button({
        key = "widget-volume-down",
        glyph = "volume-2",
        tooltip = `Volume down · {volume}%`,
        enabled = selectedName ~= nil and not controlInFlight,
        variant = "ghost",
        onClick = function()
            control("volumedown", "5")
        end,
    }))
    table.insert(children, ui.button({
        key = "widget-volume-up",
        glyph = "volume",
        tooltip = `Volume up · {volume}%`,
        enabled = selectedName ~= nil and not controlInFlight,
        variant = "ghost",
        onClick = function()
            control("volumeup", "5")
        end,
    }))
    table.insert(children, ui.button({
        key = "widget-volume-mute",
        glyph = if volumeMuted then "volume-off" else "volume",
        tooltip = if volumeMuted then "Unmute speaker" else "Mute speaker",
        enabled = selectedName ~= nil and not controlInFlight,
        variant = "ghost",
        onClick = function()
            control("volumemute", tostring(not volumeMuted))
        end,
    }))

    barWidget.render((barWidget.isVertical() and ui.column or ui.row)({
        align = "center",
        gap = 4,
    }, children))
    local tooltipParts = { selectedName or "No speaker selected", trackTitle }
    if trackArtist ~= "" then
        table.insert(tooltipParts, trackArtist)
    end
    if albumName ~= "" then
        table.insert(tooltipParts, albumName)
    end
    if appName ~= "" then
        table.insert(tooltipParts, appName)
    end
    table.insert(tooltipParts, playerState)
    table.insert(tooltipParts, if volumeMuted then "Muted" else `{volume}%`)
    if duration > 0 then
        table.insert(tooltipParts, if streamType == "LIVE" then "LIVE" else `{format_time(currentTime)} / {format_time(duration)}`)
    end
    barWidget.setTooltip(table.concat(tooltipParts, " · "))
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

local function load_artwork(url)
    if type(url) ~= "string" or url == "" then
        coverUrl = ""
        coverPath = nil
        render()
        return
    end
    if url == coverUrl and (coverPath ~= nil or artworkInFlight) then
        return
    end
    coverUrl = url
    coverPath = nil
    if artworkInFlight or dataDir == nil then
        render()
        return
    end

    artworkInFlight = true
    local requestedUrl = url
    local destination = dataDir .. "/bar-cover-art"
    local started = noctalia.download(requestedUrl, destination, function(ok)
        artworkInFlight = false
        if coverUrl ~= requestedUrl then
            load_artwork(coverUrl)
            return
        end
        if ok then
            coverPath = destination
        else
            noctalia.log(`Could not download Google Cast bar artwork: {requestedUrl}`)
        end
        render()
    end)
    if not started then
        artworkInFlight = false
        noctalia.log(`Could not start Google Cast bar artwork download: {requestedUrl}`)
    end
end

local function read_selection()
    local contents, readError = noctalia.readFile(dataDir .. "/settings.json")
    if type(contents) ~= "string" then
        if noctalia.fileExists(dataDir .. "/settings.json") then
            noctalia.log(`Could not read Google Home speaker selection: {tostring(readError)}`)
        end
        selectedName = nil
        return
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" then
        noctalia.log("Could not parse Google Home speaker selection.")
        selectedName = nil
        return
    end
    local nextName = if type(settings.name) == "string" and settings.name ~= "" then settings.name else nil
    local nextUuid = if type(settings.selectedUuid) == "string" and settings.selectedUuid ~= "" then settings.selectedUuid else nil
    if nextName ~= selectedName or nextUuid ~= selectedUuid then
        selectedName = nextName
        selectedUuid = nextUuid
        playerState = "UNKNOWN"
        trackTitle = "Nothing playing"
        trackArtist = ""
        albumName = ""
        appName = ""
        volume = 0
        volumeMuted = false
        currentTime = 0
        duration = 0
        streamType = ""
        coverUrl = ""
        coverPath = nil
    end
end

control = function(action, argument)
    if selectedName == nil or controlInFlight then
        return
    end
    local command = { "catt", "-d", selectedName, action }
    if argument ~= nil then
        table.insert(command, argument)
    end
    controlInFlight = true
    render()
    local started = noctalia.runAsync(command, function(result)
        controlInFlight = false
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.log(`Google Home {action} failed: {detail}`)
        end
        render()
        refresh()
    end, 15000)
    if not started then
        controlInFlight = false
        noctalia.log(`Could not start catt {action} from the Google Home widget.`)
        render()
    end
end

refresh = function()
    if dataDir == nil then
        local dir, dirError = noctalia.pluginDataDir()
        if type(dir) ~= "string" or dir == "" then
            noctalia.log(`Could not locate Google Home widget data directory: {tostring(dirError)}`)
            render()
            return
        end
        dataDir = dir
    end
    read_selection()
    if selectedName == nil or infoInFlight then
        render()
        return
    end

    infoInFlight = true
    local requestedName = selectedName
    local started = noctalia.runAsync({ "catt", "-d", requestedName, "info", "--json-output" }, function(result)
        infoInFlight = false
        if selectedName ~= requestedName then
            refresh()
            return
        end
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.log(`Could not read {requestedName} status: {detail}`)
            render()
            return
        end
        local ok, info = pcall(noctalia.json.decode, result.stdout)
        if not ok or type(info) ~= "table" then
            noctalia.log("Could not parse Google Home widget status.")
            render()
            return
        end
        playerState = if type(info.player_state) == "string" then info.player_state else "UNKNOWN"
        volume = if type(info.volume_level) == "number" then math.floor(info.volume_level * 100 + 0.5) else volume
        volumeMuted = info.volume_muted == true
        currentTime = if type(info.current_time) == "number" then info.current_time else 0
        duration = if type(info.duration) == "number" then info.duration else 0
        streamType = if type(info.stream_type) == "string" then info.stream_type else ""
        appName = if type(info.display_name) == "string" and info.display_name ~= ""
            then info.display_name
            else if type(info.status_text) == "string" then info.status_text else ""
        local metadata = if type(info.media_metadata) == "table" then info.media_metadata else {}
        trackTitle = if type(metadata.title) == "string" and metadata.title ~= ""
            then metadata.title
            else if type(info.status_text) == "string" and info.status_text ~= "" then info.status_text else "Nothing playing"
        trackArtist = if type(metadata.artist) == "string" then metadata.artist else ""
        albumName = if type(metadata.albumName) == "string" then metadata.albumName else ""
        load_artwork(media_image_url(metadata))
        render()
    end, 10000)
    if not started then
        infoInFlight = false
        noctalia.log("Could not start catt to refresh Google Home widget status.")
        render()
    end
end

function onClick()
    noctalia.togglePanel("ffngs/googlehome:remote")
end

function update()
    noctalia.setUpdateInterval(poll_interval_ms())
    refresh()
end

noctalia.setUpdateInterval(poll_interval_ms())
refresh()
