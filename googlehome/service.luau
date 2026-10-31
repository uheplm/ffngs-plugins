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
