--!nonstrict

local dataDir, dataError = noctalia.pluginDataDir()
local pluginDir = noctalia.pluginDir()

if type(dataDir) ~= "string" or dataDir == "" then
    noctalia.notifyError("Google Home", `Could not locate plugin data directory: {tostring(dataError)}`)
    return
end
if type(pluginDir) ~= "string" or pluginDir == "" then
    noctalia.notifyError("Google Home", "Could not locate plugin directory.")
    return
end

local settingsPath = dataDir .. "/settings.json"
local statusPath = dataDir .. "/cast-status.json"
local helper = pluginDir .. "/cast-status.py"
local activeUuid = ""
local lastStatus = ""
local lastNotifiedStatusError = ""
local lastObservedUuid = ""
local lastObservedVolume = nil
local lastObservedMute = nil
local lastObservedTrack = nil

local function osd_is_suppressed(stateKey)
    local untilTime = noctalia.state.get(stateKey)
    return type(untilTime) == "number" and untilTime > os.time()
end

local function show_osd(icon, text)
    local args = { "noctalia", "msg", "osd-show", icon }
    if text ~= "" then
        table.insert(args, text)
    end
    local started = noctalia.runAsync(args, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.log(`Could not show Google Home OSD: {detail}`)
        end
    end, 5000)
    if not started then
        noctalia.log("Could not start the Google Home OSD command.")
    end
end

local function connected_device_details(uuid)
    if not noctalia.fileExists(settingsPath) then
        return "", "cast"
    end
    local contents, readError = noctalia.readFile(settingsPath)
    if type(contents) ~= "string" then
        noctalia.log(`Could not read connected device details for OSD: {tostring(readError)}`)
        return "", "cast"
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" then
        noctalia.log("Could not parse connected device details for OSD.")
        return "", "cast"
    end

    local name = if settings.selectedUuid == uuid and type(settings.name) == "string"
        then settings.name
        else ""
    local model = if settings.selectedUuid == uuid and type(settings.model) == "string"
        then settings.model
        else ""
    if type(settings.devices) == "table" then
        for _, candidate in ipairs(settings.devices) do
            if type(candidate) == "table" and candidate.uuid == uuid then
                if name == "" and type(candidate.name) == "string" then
                    name = candidate.name
                end
                if model == "" and type(candidate.model) == "string" then
                    model = candidate.model
                end
                break
            end
        end
    end

    local normalizedModel = string.lower(model)
    local icon = if string.find(normalizedModel, "group", 1, true) then "speaker-multiple"
        else if string.find(normalizedModel, "speaker", 1, true)
            or string.find(normalizedModel, "audio", 1, true)
            or string.find(normalizedModel, "mini", 1, true)
            then "speaker"
            else "cast"
    return name, icon
end

local function track_signature(status)
    local metadata = if type(status.media_metadata) == "table" then status.media_metadata else {}
    local fallbackText = if type(metadata.title) ~= "string" or metadata.title == ""
        then if type(status.status_text) == "string"
            and not string.find(status.status_text, "Could not", 1, true)
            and not string.find(status.status_text, "PyChromecast", 1, true)
            then status.status_text
            else ""
        else ""
    return table.concat({
        if type(metadata.title) == "string" then metadata.title else "",
        if type(metadata.artist) == "string" then metadata.artist else "",
        if type(metadata.albumName) == "string" then metadata.albumName else "",
        if type(metadata.seriesTitle) == "string" then metadata.seriesTitle else "",
        if type(metadata.season) == "number" then tostring(metadata.season) else "",
        if type(metadata.episode) == "number" then tostring(metadata.episode) else "",
        if type(status.display_name) == "string" then status.display_name else "",
        if type(status.stream_type) == "string" then status.stream_type else "",
        if status.player_state == "PLAYING" or status.player_state == "PAUSED"
            then status.player_state
            else "",
        fallbackText,
    }, "\31")
end

local function track_osd_text(status)
    local metadata = if type(status.media_metadata) == "table" then status.media_metadata else {}
    local title = if type(metadata.title) == "string" then metadata.title else ""
    local artist = if type(metadata.artist) == "string" then metadata.artist else ""
    local displayName = if type(status.display_name) == "string" then status.display_name else ""
    local trackText = if title ~= "" and artist ~= ""
        then `{title} — {artist}`
        else if title ~= "" then title
        else if displayName ~= "" then displayName
        else if type(status.status_text) == "string" and status.status_text ~= ""
            then status.status_text
            else "Nothing playing"
    local stateText = if status.player_state == "PLAYING" then "Playing"
        else if status.player_state == "PAUSED" then "Paused"
        else ""
    local text = if stateText ~= "" and trackText ~= "Nothing playing"
        then `{stateText} · {trackText}`
        else if stateText ~= "" then stateText
        else trackText
    return string.sub(text, 1, 120)
end

local function report_external_changes(status)
    local uuid = status.selected_uuid
    local volume = if type(status.volume_level) == "number"
        then math.clamp(math.floor(status.volume_level * 100 + 0.5), 0, 100)
        else nil
    local muted = status.volume_muted == true
    local track = track_signature(status)
    if uuid ~= lastObservedUuid then
        lastObservedUuid = uuid
        lastObservedVolume = volume
        lastObservedMute = muted
        lastObservedTrack = track
        return
    end
    local volumeChanged = volume ~= nil and lastObservedVolume ~= nil
        and (volume ~= lastObservedVolume or muted ~= lastObservedMute)
    local trackChanged = track ~= lastObservedTrack
    local showVolumeOsd = status.player_state ~= "IDLE"
        and volumeChanged
        and noctalia.getConfig("volume_osd") ~= false
        and not osd_is_suppressed("googlehome.suppressVolumeOsdUntil")
    local showTrackOsd = status.player_state ~= "IDLE"
        and trackChanged
        and noctalia.getConfig("track_osd") ~= false
        and not osd_is_suppressed("googlehome.suppressTrackOsdUntil")
    if showVolumeOsd or showTrackOsd then
        local deviceName = connected_device_details(uuid)
        if deviceName == "" and type(status.device_name) == "string"
            and status.device_name ~= "" and string.lower(status.device_name) ~= "google home"
        then
            deviceName = status.device_name
        end
        if deviceName == "" then
            deviceName = "Google Home"
        end
        if showVolumeOsd then
            local volumeText = if muted then `{deviceName} · {volume}% muted`
                else `{deviceName} · {volume}%`
            show_osd(if muted or volume == 0 then "volume-x" else "volume-2", volumeText)
        end
        if showTrackOsd then
            show_osd(
                if status.player_state == "PLAYING" then "player-play"
                    else if status.player_state == "PAUSED" then "player-pause"
                    else "music",
                track_osd_text(status)
            )
        end
    end

    lastObservedVolume = volume
    lastObservedMute = muted
    lastObservedTrack = track
end

local function persist_poll_interval()
    local configured = tonumber(noctalia.getConfig("poll_interval"))
    if configured == nil then
        noctalia.notifyError("Google Home", "Could not read the playback polling interval.")
        return
    end
    local settings = {}
    if noctalia.fileExists(settingsPath) then
        local contents, readError = noctalia.readFile(settingsPath)
        if type(contents) ~= "string" then
            noctalia.notifyError("Google Home", `Could not read speaker cache: {tostring(readError)}`)
            return
        end
        local ok, decoded = pcall(noctalia.json.decode, contents)
        if not ok or type(decoded) ~= "table" then
            noctalia.notifyError("Google Home", "Could not parse speaker cache to update the polling interval.")
            return
        end
        settings = decoded
    end
    local interval = math.clamp(math.floor(configured), 1, 60)
    if settings.pollInterval == interval then
        return
    end
    settings.pollInterval = interval
    local encoded, encodeError = noctalia.json.encode(settings)
    if type(encoded) ~= "string" then
        noctalia.notifyError("Google Home", `Could not encode polling interval: {tostring(encodeError)}`)
        return
    end
    local written, writeError = noctalia.writeFile(settingsPath, encoded)
    if not written then
        noctalia.notifyError("Google Home", `Could not save polling interval: {tostring(writeError)}`)
    end
end

local function connected_uuid_from_settings()
    if not noctalia.fileExists(settingsPath) then
        return ""
    end
    local contents, readError = noctalia.readFile(settingsPath)
    if type(contents) ~= "string" then
        noctalia.log(`Could not read connected speaker settings: {tostring(readError)}`)
        return ""
    end
    local ok, settings = pcall(noctalia.json.decode, contents)
    if not ok or type(settings) ~= "table" then
        noctalia.log("Could not parse connected speaker settings.")
        return ""
    end
    if settings.connected == true and type(settings.selectedUuid) == "string" then
        return settings.selectedUuid
    end
    return ""
end

local function start_helper()
    local started = noctalia.runAsync({ "python3", helper, dataDir })
    if not started then
        noctalia.notifyError("Google Home", "Could not start the live Cast status listener.")
    end
end

local function stop_helper()
    local stopScript = [[
import os
from pathlib import Path
import signal
import sys

data_dir, helper = sys.argv[1:3]
pid_path = Path(data_dir) / "cast-status.pid"
try:
    pid = int(pid_path.read_text(encoding="ascii"))
    command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
except (OSError, ValueError):
    raise SystemExit(0)
if helper.encode() not in command:
    raise SystemExit(0)
try:
    os.kill(pid, signal.SIGTERM)
except ProcessLookupError:
    pass
]]
    local started = noctalia.runAsync({
        "python3",
        "-c",
        stopScript,
        dataDir,
        helper,
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.log(`Could not stop the live Cast status listener: {detail}`)
        end
    end, 5000)
    if not started then
        noctalia.notifyError("Google Home", "Could not start the Cast listener shutdown command.")
    end
end

local function set_connection(uuid)
    local nextUuid = if type(uuid) == "string" then uuid else ""
    if nextUuid == activeUuid then
        if noctalia.state.get("googlehome.connectedUuid") ~= nextUuid then
            noctalia.state.set("googlehome.connectedUuid", nextUuid)
        end
        return
    end
    local wasConnected = activeUuid ~= ""
    activeUuid = nextUuid
    lastStatus = ""
    lastNotifiedStatusError = ""
    lastObservedUuid = ""
    lastObservedVolume = nil
    lastObservedMute = nil
    lastObservedTrack = nil
    noctalia.state.set("googlehome.status", "")
    if noctalia.state.get("googlehome.connectedUuid") ~= activeUuid then
        noctalia.state.set("googlehome.connectedUuid", activeUuid)
    end
    if activeUuid == "" then
        if wasConnected then
            stop_helper()
        end
    elseif not wasConnected then
        start_helper()
    end
end

noctalia.state.watch("googlehome.connectedUuid", set_connection)
local savedUuid = connected_uuid_from_settings()
set_connection(savedUuid)
if savedUuid == "" then
    stop_helper()
end
persist_poll_interval()

function update()
    noctalia.setUpdateInterval(if activeUuid == "" then 1000 else 250)
    if activeUuid == "" or not noctalia.fileExists(statusPath) then
        return
    end
    local contents, readError = noctalia.readFile(statusPath)
    if type(contents) ~= "string" then
        noctalia.log(`Could not read live Cast status: {tostring(readError)}`)
        return
    end
    if contents == lastStatus then
        return
    end
    lastStatus = contents
    local ok, status = pcall(noctalia.json.decode, contents)
    if ok and type(status) == "table" and status.selected_uuid == activeUuid then
        report_external_changes(status)
        local statusText = if type(status.status_text) == "string" then status.status_text else ""
        local isStatusError = string.find(statusText, "Could not", 1, true) ~= nil
            or string.find(statusText, "PyChromecast", 1, true) ~= nil
        if isStatusError and statusText ~= lastNotifiedStatusError then
            lastNotifiedStatusError = statusText
            noctalia.notifyError("Google Home", statusText)
        elseif not isStatusError then
            lastNotifiedStatusError = ""
        end
    end
    noctalia.state.set("googlehome.status", contents)
end

function onConfigChanged()
    persist_poll_interval()
end

function onExit(_signal, reason)
    if reason == "disable" or reason == "uninstall" or reason == "shutdown" then
        stop_helper()
    end
end
