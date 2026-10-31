--!nonstrict

local syncing = false
local pendingRequest = nil

local function sync_configuration(forceDisabled, allowConcurrent)
    if syncing and not allowConcurrent then
        pendingRequest = if forceDisabled then "disable" else "settings"
        return
    end

    local pluginDir = noctalia.pluginDir()
    local stateDir, stateError = noctalia.pluginDataDir()
    if type(pluginDir) ~= "string" or pluginDir == "" then
        noctalia.notifyError("npad", "Could not locate the npad plugin directory.")
        return
    end
    if type(stateDir) ~= "string" or stateDir == "" then
        noctalia.notifyError("npad", `Could not locate npad plugin data: {tostring(stateError)}`)
        return
    end

    local configPath = noctalia.getConfig("niri_config_path")
    if type(configPath) ~= "string" then
        configPath = ""
    end
    local scratchWorkspace = noctalia.getConfig("scratch_workspace")
    if type(scratchWorkspace) ~= "string" or scratchWorkspace == "" then
        scratchWorkspace = "scratch"
    end
    local enabled = not forceDisabled
        and noctalia.getConfig("prevent_selecting_scratch") == true

    if not allowConcurrent then
        syncing = true
    end
    local started = noctalia.runAsync({
        "python3",
        pluginDir .. "/prevent-scratch.py",
        "configure",
        configPath,
        stateDir,
        pluginDir,
        scratchWorkspace,
        if enabled then "true" else "false",
    }, function(result)
        if not allowConcurrent then
            syncing = false
        end
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            noctalia.notifyError("npad", `Could not manage Niri workspace bindings: {detail}`)
        end

        if not allowConcurrent and pendingRequest ~= nil then
            local request = pendingRequest
            pendingRequest = nil
            sync_configuration(request == "disable")
        end
    end, 20000)

    if not started then
        if not allowConcurrent then
            syncing = false
        end
        noctalia.notifyError("npad", "Could not start Python 3 to manage Niri workspace bindings.")
    end
end

sync_configuration(false)

function onConfigChanged()
    sync_configuration(false)
end

function onExit(_signal, reason)
    if reason == "disable" or reason == "uninstall" then
        sync_configuration(true, true)
    end
end
