--!nonstrict

local function namesFromSetting(values)
    local names = {}
    local seen = {}
    if type(values) == "table" then
        for _, name in ipairs(values) do
            if type(name) == "string" then
                name = noctalia.string.trim(name)
                if name ~= "" and not seen[name] then
                    table.insert(names, name)
                    seen[name] = true
                end
            end
        end
    end
    return names
end

local function availableBarNames()
    local configured = noctalia.getSetting("bar.order")
    if type(configured) ~= "table" then
        return nil
    end
    local names = namesFromSetting(configured)
    local available = {}
    for _, name in ipairs(names) do
        available[name] = true
    end
    return names, available
end

local function configuredBarNames()
    local names = namesFromSetting(noctalia.getConfig("bar_names"))
    if #names == 0 then
        names = availableBarNames() or {}
    end
    return names
end

local barNames = configuredBarNames()
local dataPath = nil
local pluginDir = nil
local zenWindows = {}
local barModes = {}
local transitioning = {}
local transitionRefreshPending = {}
local outputGenerations = {}
local knownOutputs = nil
local barGenerations = {}
local knownBars = nil
local nextTransitionToken = 0
local refreshing = false
local refreshPending = false
local queuedActions = {}
local listenerScript = nil
local configFallbackReported = false

local function reportError(message)
    noctalia.notifyError("Zen Mode", message)
end

local function saveState()
    if dataPath == nil then
        reportError("Could not locate Zen Mode plugin data.")
        return false
    end

    local windowIds = {}
    for windowId in pairs(zenWindows) do
        table.insert(windowIds, windowId)
    end
    table.sort(windowIds)

    local bars = {}
    for barName, outputs in pairs(barModes) do
        for output, state in pairs(outputs) do
            table.insert(bars, {
                bar = barName,
                output = output,
                zen = state.zen == true,
                reserveSpace = state.reserveSpace == true,
                normalReserveSpace = state.normalReserveSpace == true,
            })
        end
    end
    table.sort(bars, function(left, right)
        if left.bar == right.bar then
            return left.output < right.output
        end
        return left.bar < right.bar
    end)

    local encoded, encodeError = noctalia.json.encode({
        windows = windowIds,
        bars = bars,
    }, true)
    if type(encoded) ~= "string" then
        reportError(`Could not encode Zen Mode state: {tostring(encodeError)}`)
        return false
    end

    local written, writeError = noctalia.writeFile(dataPath, encoded)
    if not written then
        reportError(`Could not save Zen Mode state: {tostring(writeError)}`)
        return false
    end
    return true
end

local function connectedOutputs()
    local outputs = noctalia.outputs()
    local connected = {}
    for _, output in ipairs(outputs) do
        if type(output.name) == "string" and output.name ~= "" then
            connected[output.name] = true
        end
    end
    return outputs, connected
end

local function clearBarTransitions(barName)
    local prefix = barName .. "\0"
    for key in pairs(transitioning) do
        if string.sub(key, 1, #prefix) == prefix then
            transitioning[key] = nil
            transitionRefreshPending[key] = nil
        end
    end
end

local function dropUnavailableBars(available)
    if available == nil then
        local _, current = availableBarNames()
        available = current
    end
    if available == nil then
        return nil
    end

    local removed = {}
    if knownBars ~= nil then
        for barName in pairs(knownBars) do
            if not available[barName] then
                removed[barName] = true
            end
        end
    end
    knownBars = available

    local changed = false
    for barName, outputs in pairs(barModes) do
        if not available[barName] then
            removed[barName] = true
            barModes[barName] = nil
            changed = true
        end
    end
    for barName in pairs(removed) do
        barGenerations[barName] = (barGenerations[barName] or 0) + 1
        clearBarTransitions(barName)
    end
    if changed then
        saveState()
    end
    return available
end

local function dropDisconnectedOutputs(outputs, connected)
    if outputs == nil or connected == nil then
        outputs, connected = connectedOutputs()
    end
    if knownOutputs == nil then
        knownOutputs = connected
    else
        for output in pairs(knownOutputs) do
            if not connected[output] then
                outputGenerations[output] = (outputGenerations[output] or 0) + 1
                noctalia.state.set("zenmode.output." .. output, false)
            end
        end
        knownOutputs = connected
    end

    local changed = false
    for barName, barOutputs in pairs(barModes) do
        for output in pairs(barOutputs) do
            if not connected[output] then
                barOutputs[output] = nil
                local transitionKey = barName .. "\0" .. output
                transitioning[transitionKey] = nil
                transitionRefreshPending[transitionKey] = nil
                changed = true
            end
        end
        if next(barOutputs) == nil then
            barModes[barName] = nil
        end
    end
    if changed then
        saveState()
    end
    return outputs, connected
end

local function loadState()
    if not noctalia.fileExists(dataPath) then
        local legacyWindows = noctalia.readFile("/tmp/noctalia_zen_windows.txt")
        if type(legacyWindows) == "string" then
            for line in string.gmatch(legacyWindows, "[^\r\n]+") do
                local windowId = tonumber(noctalia.string.trim(line))
                if windowId ~= nil then
                    zenWindows[windowId] = true
                end
            end
        end

        for _, output in ipairs(noctalia.outputs()) do
            if type(output.name) == "string" and output.name ~= "" then
                local safeOutput = string.gsub(output.name, "-", "_")
                local legacyBarState = noctalia.readFile(
                    "/tmp/noctalia_bar_state_" .. safeOutput .. ".txt"
                )
                if type(legacyBarState) == "string" then
                    local state = noctalia.string.trim(legacyBarState)
                    if state == "zen" then
                        barModes.TopBar = barModes.TopBar or {}
                        barModes.TopBar[output.name] = {
                            zen = true,
                            reserveSpace = false,
                            normalReserveSpace = true,
                        }
                    elseif state == "normal" then
                        barModes.TopBar = barModes.TopBar or {}
                        barModes.TopBar[output.name] = {
                            zen = false,
                            reserveSpace = true,
                            normalReserveSpace = true,
                        }
                    end
                end
            end
        end
        saveState()
        return
    end

    local contents = noctalia.readFile(dataPath)
    if type(contents) ~= "string" then
        reportError("Could not read saved Zen Mode state.")
        return
    end

    local ok, state = pcall(noctalia.json.decode, contents)
    if not ok or type(state) ~= "table" then
        reportError("Could not parse saved Zen Mode state; starting with an empty state.")
        return
    end

    if type(state.windows) == "table" then
        for _, windowId in ipairs(state.windows) do
            if type(windowId) == "number" then
                zenWindows[windowId] = true
            end
        end
    end
    if type(state.bars) == "table" then
        for _, bar in ipairs(state.bars) do
            if type(bar) == "table"
                and type(bar.output) == "string"
                and type(bar.zen) == "boolean"
            then
                local barName = if type(bar.bar) == "string" and bar.bar ~= ""
                    then bar.bar
                    else "TopBar"
                local normalReserveSpace = bar.normalReserveSpace
                if type(normalReserveSpace) ~= "boolean" then
                    normalReserveSpace = true
                end
                local reserveSpace = bar.reserveSpace
                if type(reserveSpace) ~= "boolean" then
                    reserveSpace = normalReserveSpace ~= (bar.reserveToggled == true)
                end
                barModes[barName] = barModes[barName] or {}
                barModes[barName][bar.output] = {
                    zen = bar.zen,
                    reserveSpace = reserveSpace,
                    normalReserveSpace = normalReserveSpace,
                }
            end
        end
    end
end

local function runCommand(arguments, callback)
    local started = noctalia.runAsync(arguments, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            callback(false, detail)
            return
        end
        callback(true, "")
    end, 10000)

    if not started then
        callback(false, "Could not start the command.")
    end
end

local function runCommands(commands, index, callback)
    if index > #commands then
        callback(true, "")
        return
    end

    runCommand(commands[index], function(ok, detail)
        if not ok then
            callback(false, detail)
            return
        end
        runCommands(commands, index + 1, callback)
    end)
end

local function configuredBarDefaults(output)
    local home = noctalia.getenv("HOME")
    local configHome = noctalia.getenv("XDG_CONFIG_HOME")
    if type(configHome) ~= "string" or configHome == "" or string.sub(configHome, 1, 1) ~= "/" then
        configHome = if type(home) == "string" and home ~= "" then home .. "/.config" else nil
    end

    local settingsPath = if configHome then configHome .. "/noctalia/settings.json" else nil
    local contents = nil
    local readError = nil
    if settingsPath then
        contents, readError = noctalia.readFile(settingsPath)
    else
        readError = "HOME is not set"
    end
    local settings = nil
    if type(contents) == "string" then
        local ok, decoded = pcall(noctalia.json.decode, contents)
        if ok and type(decoded) == "table" then
            settings = decoded
        elseif not configFallbackReported then
            configFallbackReported = true
            reportError("Could not parse Noctalia settings.json; using visible, space-reserving defaults.")
        end
    elseif not configFallbackReported then
        configFallbackReported = true
        reportError(`Could not read Noctalia settings.json: {tostring(readError)}. Using visible, space-reserving defaults.`)
    end

    local bar = if type(settings) == "table" and type(settings.bar) == "table" then settings.bar else {}
    local displayMode = bar.displayMode
    if type(bar.screenOverrides) == "table" then
        for _, override in ipairs(bar.screenOverrides) do
            if type(override) == "table"
                and override.enabled == true
                and override.name == output
                and type(override.displayMode) == "string"
            then
                displayMode = override.displayMode
                break
            end
        end
    end

    return {
        autoHide = type(displayMode) == "string" and displayMode ~= "always_visible",
        reserveSpace = true,
    }
end

local function barCommands(barName, output, zen, toggleReserve, defaults)
    defaults = defaults or configuredBarDefaults(output)
    local commands = {
        {
            "noctalia", "msg", "bar-auto-hide-set",
            if zen then "on" else if defaults.autoHide then "on" else "off",
            barName, output,
        },
        {
            "noctalia", "msg", "bar-layer-set",
            if zen then "overlay" else "top",
            barName, output,
        },
    }

    if toggleReserve then
        table.insert(commands, {
            "noctalia", "msg", "bar-reserve-toggle", barName, output,
        })
    end
    return commands
end

local function applyBarMode(barName, output, shouldBeZen, defaults)
    local _, available = availableBarNames()
    if available ~= nil and not available[barName] then
        dropUnavailableBars(available)
        return
    end

    local transitionKey = barName .. "\0" .. output
    if transitioning[transitionKey] then
        transitionRefreshPending[transitionKey] = true
        return
    end

    local barState = barModes[barName]
    local previous = if barState then barState[output] else nil
    if previous == nil and not shouldBeZen then
        return
    end

    local normalReserveSpace = if previous == nil or not previous.zen
        then defaults.reserveSpace
        else previous.normalReserveSpace
    local currentReserveSpace = if previous == nil
        then normalReserveSpace
        else previous.reserveSpace
    local desiredReserveSpace = if shouldBeZen then false else normalReserveSpace
    local toggleReserve = currentReserveSpace ~= desiredReserveSpace
    local stateChanged = previous == nil
        or previous.zen ~= shouldBeZen
        or previous.reserveSpace ~= desiredReserveSpace
        or previous.normalReserveSpace ~= normalReserveSpace
    local commands = barCommands(barName, output, shouldBeZen, toggleReserve, defaults)
    nextTransitionToken += 1
    local transitionToken = nextTransitionToken
    local outputGeneration = outputGenerations[output] or 0
    local barGeneration = barGenerations[barName] or 0
    transitioning[transitionKey] = transitionToken
    runCommands(commands, 1, function(ok, detail)
        local outputs, connected = connectedOutputs()
        dropDisconnectedOutputs(outputs, connected)
        local _, available = availableBarNames()
        dropUnavailableBars(available)
        if (outputGenerations[output] or 0) ~= outputGeneration
            or not connected[output]
            or (barGenerations[barName] or 0) ~= barGeneration
            or (available ~= nil and not available[barName])
        then
            if transitioning[transitionKey] == transitionToken then
                transitioning[transitionKey] = nil
                transitionRefreshPending[transitionKey] = nil
            end
            return
        end
        if transitioning[transitionKey] == transitionToken then
            transitioning[transitionKey] = nil
        end
        if not ok then
            reportError(`Could not update bar "{barName}" on {output}: {detail}`)
        else
            barModes[barName] = barModes[barName] or {}
            barModes[barName][output] = {
                zen = shouldBeZen,
                reserveSpace = desiredReserveSpace,
                normalReserveSpace = normalReserveSpace,
            }
            if stateChanged then
                saveState()
            end
        end

        if transitioning[transitionKey] == nil and transitionRefreshPending[transitionKey] then
            transitionRefreshPending[transitionKey] = nil
            requestRefresh()
        end
    end)
end

local function updateFromNiri(windows, workspaces)
    local activeWindowByOutput = {}
    local workspaceOutputById = {}
    for _, workspace in ipairs(workspaces) do
        if type(workspace) == "table"
            and type(workspace.id) == "number"
            and type(workspace.output) == "string"
        then
            workspaceOutputById[workspace.id] = workspace.output
            if workspace.is_active == true
                and type(workspace.active_window_id) == "number"
            then
                activeWindowByOutput[workspace.output] = workspace.active_window_id
            end
        end
    end

    local focusedWindowId = nil
    local liveWindows = {}
    for _, window in ipairs(windows) do
        if type(window) == "table" and type(window.id) == "number" then
            liveWindows[window.id] = true
            if window.is_focused == true then
                focusedWindowId = window.id
                local output = if type(window.workspace_id) == "number"
                    then workspaceOutputById[window.workspace_id] else nil
                if output then
                    activeWindowByOutput[output] = window.id
                end
            end
        end
    end

    local removedStaleWindow = false
    for windowId in pairs(zenWindows) do
        if not liveWindows[windowId] then
            zenWindows[windowId] = nil
            removedStaleWindow = true
        end
    end
    if removedStaleWindow then
        saveState()
    end

    local availableBars = dropUnavailableBars()
    local outputs, connected = connectedOutputs()
    outputs = dropDisconnectedOutputs(outputs, connected)
    for _, output in ipairs(outputs) do
        if type(output.name) == "string" and output.name ~= "" then
            local activeWindowId = activeWindowByOutput[output.name]
            local isZen = activeWindowId ~= nil and zenWindows[activeWindowId] == true
            noctalia.state.set("zenmode.output." .. output.name, isZen)
            local defaults = configuredBarDefaults(output.name)
            for _, barName in ipairs(barNames) do
                if availableBars == nil or availableBars[barName] then
                    applyBarMode(barName, output.name, isZen, defaults)
                end
            end
        end
    end

    if focusedWindowId == nil then
        local focusedOutput = noctalia.focusedOutputName()
        if type(focusedOutput) == "string" then
            focusedWindowId = activeWindowByOutput[focusedOutput]
        end
    end
    return focusedWindowId, activeWindowByOutput
end

local function queryNiri(callback)
    local results = {}
    local remaining = 2
    local failed = false

    local function onResult(name, result)
        if result.timedOut or result.exitCode ~= 0 then
            failed = true
            local detail = result.stderr ~= "" and result.stderr
                or `exit status {result.exitCode}`
            reportError(`Could not read Niri {name}: {detail}`)
        else
            local ok, decoded = pcall(noctalia.json.decode, result.stdout)
            if not ok or type(decoded) ~= "table" then
                failed = true
                reportError(`Could not parse Niri {name} response.`)
            else
                results[name] = decoded
            end
        end

        remaining -= 1
        if remaining == 0 then
            if failed then
                callback(nil)
            else
                callback(results)
            end
        end
    end

    for _, name in ipairs({ "windows", "workspaces" }) do
        local started = noctalia.runAsync({ "niri", "msg", "--json", name }, function(result)
            onResult(name, result)
        end, 5000)
        if not started then
            onResult(name, {
                timedOut = false,
                exitCode = 1,
                stderr = "Could not start niri.",
                stdout = "",
            })
        end
    end
end

function requestRefresh(action, output)
    if action == "toggle" or action == "exit" then
        table.insert(queuedActions, {
            action = action,
            output = if type(output) == "string" and output ~= "" then output else nil,
        })
    end
    if refreshing then
        refreshPending = true
        return
    end

    refreshing = true
    local actions = queuedActions
    queuedActions = {}
    queryNiri(function(results)
        if results ~= nil then
            local focusedWindowId, activeWindowByOutput =
                updateFromNiri(results.windows, results.workspaces)
            local changedWindowIds = {}
            if #actions > 0 then
                for _, queuedAction in ipairs(actions) do
                    local targetOutput = queuedAction.output or noctalia.focusedOutputName()
                    local targetWindowId = if type(targetOutput) == "string"
                        then activeWindowByOutput[targetOutput] else nil
                    if queuedAction.output == nil then
                        targetWindowId = targetWindowId or focusedWindowId
                    end
                    if targetWindowId == nil then
                        reportError("Cannot change Zen Mode without a focused window.")
                    else
                        local currentlyZen = zenWindows[targetWindowId] == true
                        if queuedAction.action == "toggle" then
                            zenWindows[targetWindowId] = if currentlyZen then nil else true
                            changedWindowIds[targetWindowId] = true
                        elseif queuedAction.action == "exit" and currentlyZen then
                            zenWindows[targetWindowId] = nil
                            changedWindowIds[targetWindowId] = true
                        end
                    end
                end

                for windowId in pairs(changedWindowIds) do
                    local maximizeStarted = noctalia.runAsync({
                        "niri",
                        "msg",
                        "action",
                        "maximize-window-to-edges",
                        "--id",
                        tostring(windowId),
                    }, function(result)
                        if result.timedOut or result.exitCode ~= 0 then
                            local detail = result.stderr ~= "" and result.stderr
                                or `exit status {result.exitCode}`
                            reportError(`Could not maximize window {windowId}: {detail}`)
                        end
                    end, 5000)
                    if not maximizeStarted then
                        reportError(`Could not start Niri to maximize window {windowId}.`)
                    end
                end

                if next(changedWindowIds) ~= nil then
                    saveState()
                    updateFromNiri(results.windows, results.workspaces)
                end
            end
        end
        refreshing = false
        if refreshPending or #queuedActions > 0 then
            refreshPending = false
            requestRefresh()
        end
    end)
end

local function startListener()
    pluginDir = noctalia.pluginDir()
    if type(pluginDir) ~= "string" or pluginDir == "" then
        reportError("Could not locate the Zen Mode plugin directory.")
        return
    end

    listenerScript = pluginDir .. "/niri-event-listener.sh"
    local started = noctalia.runAsync({ "bash", listenerScript, "start" }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or `exit status {result.exitCode}`
            reportError(`Could not start the Niri event listener: {detail}`)
        end
    end, 5000)
    if not started then
        reportError("Could not start the Niri event listener.")
    end
end

local function restoreAllBars()
    dropUnavailableBars()
    dropDisconnectedOutputs()
    for barName, outputs in pairs(barModes) do
        for output, state in pairs(outputs) do
            if state.zen then
                local _, connected = connectedOutputs()
                local _, available = availableBarNames()
                if not connected[output] or (available ~= nil and not available[barName]) then
                    continue
                end
                local commands = barCommands(
                    barName,
                    output,
                    false,
                    state.reserveSpace ~= state.normalReserveSpace,
                    nil
                )
                runCommands(commands, 1, function(ok, detail)
                    local _, stillConnected = connectedOutputs()
                    local _, stillAvailable = availableBarNames()
                    if not stillConnected[output]
                        or (stillAvailable ~= nil and not stillAvailable[barName])
                    then
                        return
                    elseif not ok then
                        reportError(`Could not restore bar "{barName}" on {output}: {detail}`)
                    else
                        barModes[barName][output] = {
                            zen = false,
                            reserveSpace = state.normalReserveSpace,
                            normalReserveSpace = state.normalReserveSpace,
                        }
                        saveState()
                    end
                end)
            end
        end
    end
end

local function restoreUnconfiguredBars()
    dropDisconnectedOutputs()
    dropUnavailableBars()
    local selected = {}
    for _, barName in ipairs(barNames) do
        selected[barName] = true
    end

    for barName, outputs in pairs(barModes) do
        if not selected[barName] then
            for output, state in pairs(outputs) do
                local commands = barCommands(
                    barName,
                    output,
                    false,
                    state.reserveSpace ~= state.normalReserveSpace,
                    nil
                )
                runCommands(commands, 1, function(ok, detail)
                    local _, connected = connectedOutputs()
                    local _, available = availableBarNames()
                    if not connected[output] or (available ~= nil and not available[barName]) then
                        return
                    elseif not ok then
                        reportError(`Could not restore unselected bar "{barName}" on {output}: {detail}`)
                    else
                        barModes[barName][output] = nil
                        if next(barModes[barName]) == nil then
                            barModes[barName] = nil
                        end
                        saveState()
                    end
                end)
            end
        end
    end
end

local stateDir, stateError = noctalia.pluginDataDir()
if type(stateDir) == "string" and stateDir ~= "" then
    local made, makeError = noctalia.mkdirAll(stateDir)
    if made then
        dataPath = stateDir .. "/state.json"
        loadState()
    else
        reportError(`Could not create Zen Mode state directory: {tostring(makeError)}`)
    end
else
    reportError(`Could not locate Zen Mode plugin data: {tostring(stateError)}`)
end

restoreUnconfiguredBars()
startListener()
requestRefresh()

function onOutputsChanged()
    dropDisconnectedOutputs()
    dropUnavailableBars()
    requestRefresh()
end

function onIpc(event, _payload)
    if event == "toggle" then
        requestRefresh("toggle", _payload)
    elseif event == "exit" then
        requestRefresh("exit", _payload)
    elseif event == "reconcile" then
        requestRefresh()
    elseif event == "reserve-enabled" or event == "reserve-disabled" then
        if type(_payload) ~= "string" or _payload == "" then
            reportError("Reservation recovery requires an output name as its payload.")
            return
        end

        local barName, output = string.match(_payload, "^([^|]+)|(.+)$")
        local targetBars = {}
        if barName ~= nil and output ~= nil then
            table.insert(targetBars, barName)
        else
            output = _payload
            targetBars = barNames
        end
        if output == "" then
            reportError("Reservation recovery requires a non-empty output name.")
            return
        end
        local _, connected = connectedOutputs()
        if not connected[output] then
            reportError(`Cannot update reserve-space state for disconnected output {output}.`)
            return
        end
        local _, available = availableBarNames()
        if barName ~= nil and available ~= nil and not available[barName] then
            reportError(`Cannot update reserve-space state for unknown bar {barName}.`)
            return
        end

        for _, targetBar in ipairs(targetBars) do
            local outputs = barModes[targetBar]
            local previous = if outputs then outputs[output] else nil
            local zen = if previous ~= nil
                then previous.zen
                else noctalia.state.get("zenmode.output." .. output) == true
            local normalReserveSpace = if previous ~= nil
                then previous.normalReserveSpace
                else configuredBarDefaults(output).reserveSpace
            barModes[targetBar] = barModes[targetBar] or {}
            barModes[targetBar][output] = {
                zen = zen,
                reserveSpace = event == "reserve-enabled",
                normalReserveSpace = normalReserveSpace,
            }
        end
        saveState()
        requestRefresh()
    elseif event == "listener-error" then
        reportError("The Niri event listener stopped unexpectedly.")
    end
end

function onConfigChanged()
    dropDisconnectedOutputs()
    dropUnavailableBars()
    local previousNames = barNames
    barNames = configuredBarNames()
    local currentNames = {}
    for _, name in ipairs(barNames) do
        currentNames[name] = true
    end

    for _, name in ipairs(previousNames) do
        if not currentNames[name] and barModes[name] ~= nil then
            local outputs = barModes[name]
            for output, state in pairs(outputs) do
                local commands = barCommands(
                    name,
                    output,
                    false,
                    state.reserveSpace ~= state.normalReserveSpace,
                    nil
                )
                runCommands(commands, 1, function(ok, detail)
                    local _, connected = connectedOutputs()
                    local _, available = availableBarNames()
                    if not connected[output] or (available ~= nil and not available[name]) then
                        return
                    elseif not ok then
                        reportError(`Could not restore removed bar "{name}" on {output}: {detail}`)
                    else
                        barModes[name][output] = nil
                        if next(barModes[name]) == nil then
                            barModes[name] = nil
                        end
                        saveState()
                    end
                end)
            end
        end
    end
    requestRefresh()
end

function onExit()
    dropDisconnectedOutputs()
    if pluginDir ~= nil then
        noctalia.runAsync({ "bash", pluginDir .. "/niri-event-listener.sh", "stop" })
    end
    zenWindows = {}
    saveState()
    restoreAllBars()
end
