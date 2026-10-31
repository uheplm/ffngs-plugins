--!nonstrict

local PANEL_ID = "ffngs/npad:manager"
local scratchpads = {}
local windowStates = {}
local workspaceWindows = {}
local unmarkedScratchWindows = {}
local workspaceNames = {}
local workspaceIndexes = {}
local workspaceOutputs = {}
local focusedWorkspaceId = nil
local scratchWorkspaceIndex = nil
local scratchRestoreWorkspaceIndex = nil
local showAllHidden = false
local panelOpen = false
local refreshInProgress = false
local refreshPending = false
local listenerScript = nil
local listenerStarting = false
local listenerActive = false
local stopListenerWhenStarted = false
local status = "Loading scratchpads..."
local scratchWorkspace = noctalia.getConfig("scratch_workspace")
if type(scratchWorkspace) ~= "string" or scratchWorkspace == "" then
    scratchWorkspace = "scratch"
end
local preventSelectingScratch = noctalia.getConfig("prevent_selecting_scratch") == true

local function state_path()
    local cacheHome = noctalia.getenv("XDG_CACHE_HOME")
    if type(cacheHome) == "string" and cacheHome ~= "" and string.sub(cacheHome, 1, 1) == "/" then
        return cacheHome .. "/nscratch/state.json"
    end

    local home = noctalia.getenv("HOME")
    if type(home) == "string" and home ~= "" then
        return home .. "/.cache/nscratch/state.json"
    end

    return "/tmp/nscratch/state.json"
end

local function window_row(windowId, appId, title, actionLabel, actionGlyph, action, extraAction, stateLabel, actionEnabled, muted, workspaceName, isFloating, floatingAction)
    local iconPath = noctalia.appIconPath(appId, 32)
    local iconImage = if type(iconPath) == "string" then
        ui.image({
            path = iconPath,
            width = 32,
            height = 32,
            fit = "contain",
            opacity = if muted then 0.45 else 1,
        })
    else
        ui.glyph({
            name = "window",
            size = 28,
            color = if muted then "on_surface_variant" else "primary",
            opacity = if muted then 0.5 else 1,
        })

    local children = {
        iconImage,
        ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({
                text = if workspaceName then `{workspaceName} - {appId}` else appId,
                fontWeight = "medium",
                maxLines = 1,
                color = if muted then "on_surface_variant" else "on_surface",
            }),
            ui.label({
                text = title,
                color = "on_surface_variant",
                maxLines = 1,
                opacity = if muted then 0.65 else 1,
            }),
        }),
    }

    if stateLabel then
        table.insert(children, ui.label({ text = stateLabel, color = "on_surface_variant" }))
    end

    table.insert(children, ui.button({
        text = actionLabel,
        glyph = actionGlyph,
        enabled = actionEnabled ~= false,
        onClick = function()
            action()
        end,
    }))
    if floatingAction then
        table.insert(children, ui.button({
            text = if isFloating then "Tile" else "Float",
            glyph = if isFloating then "layout" else "picture-in-picture",
            tooltip = if isFloating then "Move window to tiling layout" else "Move window to floating layout",
            onClick = function()
                floatingAction()
            end,
        }))
    end
    if extraAction then
        table.insert(children, ui.button({
            glyph = "trash",
            color = "error",
            onClick = function()
                extraAction()
            end,
        }))
    end

    return ui.row({
        key = `window-{windowId}`,
        align = "center",
        gap = 10,
        paddingH = 8,
        paddingV = 6,
        fill = if muted then "surface" else "surface_container",
        radius = 10,
    }, children)
end

local function render()
    local markedRows = {}
    local workspaceRows = {}
    local unmarkedScratchRows = {}
    local focusedOnScratchWorkspace = focusedWorkspaceId ~= nil
        and workspaceNames[focusedWorkspaceId] == scratchWorkspace

    for index, scratchpad in ipairs(scratchpads) do
        local scratchIndex = index
        local windowId = scratchpad.id
        local appId = type(scratchpad.app_id) == "string" and scratchpad.app_id or "Unknown app"
        local title = type(scratchpad.title) == "string" and scratchpad.title or "Untitled window"
        local liveState = windowStates[windowId]
        local isHidden = liveState ~= nil and liveState.hidden
        local isFromFocusedWorkspace = focusedWorkspaceId ~= nil
            and scratchpad.workspace == focusedWorkspaceId
        local includeInMarked = if showAllHidden then isHidden else isFromFocusedWorkspace

        if includeInMarked then
            local stateLabel = if liveState == nil then "Unavailable" else nil
            local actionLabel = if isHidden then "Restore" else "Hide"
            local actionGlyph = if isHidden then "eye" else "eye-off"
            local originWorkspaceName = if showAllHidden then
                workspaceNames[scratchpad.workspace] or `Workspace {scratchpad.workspace}`
            else nil

            table.insert(markedRows, window_row(
                windowId,
                appId,
                title,
                actionLabel,
                actionGlyph,
                function()
                    if liveState == nil then
                        status = `Could not find {appId} in Niri's live window list. Refresh and try again.`
                        render()
                    elseif isHidden then
                        if focusedOnScratchWorkspace then
                            restore_scratchpad(windowId, scratchpad.workspace)
                        else
                            run_nscratch({ "--index", tostring(scratchIndex) }, "Scratchpad restored.")
                        end
                    else
                        hide_scratchpad(windowId)
                    end
                end,
                function()
                    run_nscratch({ "--remove", tostring(scratchIndex) }, "Scratchpad removed.")
                end,
                stateLabel,
                true,
                isHidden,
                originWorkspaceName,
                liveState ~= nil and liveState.floating == true,
                if isHidden then function()
                    toggle_window_floating(windowId)
                end else nil
            ))
        end
    end

    for _, window in ipairs(workspaceWindows) do
        local appId = type(window.app_id) == "string" and window.app_id or ""
        table.insert(workspaceRows, window_row(
            window.id,
            appId ~= "" and appId or "Unknown app",
            type(window.title) == "string" and window.title or "Untitled window",
            "Mark",
            "bookmark-plus",
            function()
                mark_workspace_window(window.id)
            end,
            nil,
            nil,
            true,
            false
        ))
    end

    for _, window in ipairs(unmarkedScratchWindows) do
        local appId = type(window.app_id) == "string" and window.app_id or ""
        table.insert(unmarkedScratchRows, window_row(
            window.id,
            appId ~= "" and appId or "Unknown app",
            type(window.title) == "string" and window.title or "Untitled window",
            "Restore",
            "eye",
            function()
                restore_unmarked_window(window.id)
            end,
            nil,
            "Unmarked",
            scratchRestoreWorkspaceIndex ~= nil,
            false,
            nil,
            window.is_floating == true,
            function()
                toggle_window_floating(window.id)
            end
        ))
    end

    local content = {}
    if status ~= "" then
        table.insert(content, ui.label({ text = status, color = "on_surface_variant" }))
    end

    table.insert(content, ui.label({
        text = if showAllHidden then "Hidden - All workspaces"
            elseif focusedWorkspaceId ~= nil then `Marked - {workspaceNames[focusedWorkspaceId] or "Current workspace"}`
            else "Marked",
        fontSize = 16,
        fontWeight = "semibold",
    }))
    if #markedRows == 0 then
        table.insert(content, ui.label({
            text = if showAllHidden then "No hidden marked windows."
                else "No marked windows in this workspace.",
            color = "on_surface_variant",
        }))
    else
        for _, row in ipairs(markedRows) do
            table.insert(content, row)
        end
    end

    if focusedOnScratchWorkspace then
        table.insert(content, ui.label({ text = "Unmarked", fontSize = 16, fontWeight = "semibold" }))
        if #unmarkedScratchRows == 0 then
            table.insert(content, ui.label({
                text = "No unmarked windows on the scratchpad workspace.",
                color = "on_surface_variant",
            }))
        else
            for _, row in ipairs(unmarkedScratchRows) do
                table.insert(content, row)
            end
        end
    else
        table.insert(content, ui.label({ text = "Workspace", fontSize = 16, fontWeight = "semibold" }))
        if #workspaceRows == 0 then
            table.insert(content, ui.label({
                text = "No unmarked windows in the focused workspace.",
                color = "on_surface_variant",
            }))
        else
            for _, row in ipairs(workspaceRows) do
                table.insert(content, row)
            end
        end
    end

    local headerChildren = {
        ui.label({ text = "npad", fontSize = 22, fontWeight = "bold", flexGrow = 1 }),
    }
    if not focusedOnScratchWorkspace then
        table.insert(headerChildren, ui.button({
            text = if showAllHidden then "Current workspace" else "Show all hidden",
            glyph = if showAllHidden then "eye-off" else "eye",
            onClick = function()
                showAllHidden = not showAllHidden
                render()
            end,
        }))
        if preventSelectingScratch then
            table.insert(headerChildren, ui.button({
                text = "Open Scratch",
                glyph = "wallpaper",
                enabled = scratchWorkspaceIndex ~= nil,
                onClick = function()
                    if scratchWorkspaceIndex == nil then
                        status = `Could not find the "{scratchWorkspace}" workspace on this output.`
                        render()
                        return
                    end

                    local started = noctalia.runAsync({
                        "niri",
                        "msg",
                        "action",
                        "focus-workspace",
                        tostring(scratchWorkspaceIndex),
                    }, function(result)
                        if result.timedOut or result.exitCode ~= 0 then
                            local detail = result.stderr ~= "" and result.stderr
                                or `exit status {result.exitCode}`
                            status = `Could not open the scratch workspace: {detail}`
                            noctalia.notifyError("npad", status)
                            render()
                            return
                        end

                        refresh_scratchpads()
                    end, 10000)

                    if not started then
                        status = "Could not start niri. Check that it is installed and available on PATH."
                        noctalia.notifyError("npad", status)
                        render()
                    end
                end,
            }))
        end
    end

    panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, headerChildren),
        ui.scroll({ flexGrow = 1, gap = 6 }, content),
    }))
end

local function reopen_panel_after_delay()
    local started = noctalia.runAsync({ "sleep", "0.25" }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            noctalia.notifyError("npad", "Could not wait before reopening the panel.")
        end
        noctalia.togglePanel(PANEL_ID)
    end, 2000)

    if not started then
        noctalia.notifyError("npad", "Could not start the panel reopen delay.")
        noctalia.togglePanel(PANEL_ID)
    end
end

local function focus_and_mark_window(windowId)
    local focusStarted = noctalia.runAsync({
        "niri",
        "msg",
        "action",
        "focus-window",
        "--id",
        tostring(windowId),
    }, function(focusResult)
        if focusResult.timedOut or focusResult.exitCode ~= 0 then
            local detail = focusResult.stderr ~= "" and focusResult.stderr or `exit status {focusResult.exitCode}`
            noctalia.notifyError("npad", `Could not focus the selected window: {detail}`)
            reopen_panel_after_delay()
            return
        end

        local started = noctalia.runAsync({ "sleep", "0.1" }, function(delayResult)
            if delayResult.timedOut or delayResult.exitCode ~= 0 then
                noctalia.notifyError("npad", "Could not wait for Niri to focus the selected window.")
                reopen_panel_after_delay()
                return
            end

            run_nscratch({ "--mark" }, "Window marked as a dynamic scratchpad.", reopen_panel_after_delay)
        end, 2000)

        if not started then
            noctalia.notifyError("npad", "Could not start the focus settling delay.")
            reopen_panel_after_delay()
        end
    end, 5000)

    if not focusStarted then
        noctalia.notifyError("npad", "Could not start niri to focus the selected window.")
        reopen_panel_after_delay()
    end
end

function mark_workspace_window(windowId)
    panel.close()

    local started = noctalia.runAsync({ "sleep", "0.25" }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            noctalia.notifyError("npad", "Could not wait for the panel to close.")
            reopen_panel_after_delay()
            return
        end

        focus_and_mark_window(windowId)
    end, 2000)

    if not started then
        noctalia.notifyError("npad", "Could not start the panel close delay.")
        noctalia.togglePanel(PANEL_ID)
    end
end

local function finish_refresh()
    refreshInProgress = false
    if panelOpen and refreshPending then
        refreshPending = false
        refresh_scratchpads()
    end
end

function refresh_scratchpads()
    if refreshInProgress then
        refreshPending = true
        return
    end

    refreshInProgress = true
    local path = state_path()
    status = ""
    if not noctalia.fileExists(path) then
        scratchpads = {}
        windowStates = {}
        update_window_states()
        return
    end

    local content, readError = noctalia.readFile(path)
    if type(content) ~= "string" then
        scratchpads = {}
        windowStates = {}
        status = `Could not read nscratch state at {path}: {tostring(readError)}`
        finish_refresh()
        render()
        return
    end

    local ok, state = pcall(noctalia.json.decode, content)
    if not ok then
        scratchpads = {}
        windowStates = {}
        status = `Could not parse nscratch state: {tostring(state)}`
        finish_refresh()
        render()
        return
    end

    if type(state) ~= "table" or type(state.windows) ~= "table" then
        scratchpads = {}
        windowStates = {}
        status = "Invalid nscratch state: expected a windows list."
        finish_refresh()
        render()
        return
    end

    for index, scratchpad in ipairs(state.windows) do
        if type(scratchpad) ~= "table"
            or type(scratchpad.id) ~= "number"
            or type(scratchpad.title) ~= "string"
            or type(scratchpad.app_id) ~= "string"
            or type(scratchpad.workspace) ~= "number"
        then
            scratchpads = {}
            windowStates = {}
            status = `Invalid nscratch state: malformed window at index {index}.`
            finish_refresh()
            render()
            return
        end
    end

    scratchpads = state.windows
    update_window_states()
end

function update_window_states()
    local results = {}
    local pending = 2
    local failed = false

    local function on_result(name, result)
        if result.timedOut or result.exitCode ~= 0 then
            failed = true
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            status = `Could not read Niri {name}: {detail}`
        else
            local ok, decoded = pcall(noctalia.json.decode, result.stdout)
            if not ok or type(decoded) ~= "table" then
                failed = true
                status = `Could not parse Niri {name} response.`
            else
                results[name] = decoded
            end
        end

        pending -= 1
        if pending == 0 then
            if failed then
                windowStates = {}
                workspaceWindows = {}
                unmarkedScratchWindows = {}
                workspaceNames = {}
                workspaceIndexes = {}
                workspaceOutputs = {}
                scratchWorkspaceIndex = nil
                scratchRestoreWorkspaceIndex = nil
                focusedWorkspaceId = nil
            else
                local previousFocusedWorkspaceId = focusedWorkspaceId
                workspaceNames = {}
                workspaceIndexes = {}
                workspaceOutputs = {}
                focusedWorkspaceId = nil
                local activeWorkspaceIds = {}
                for _, workspace in ipairs(results.workspaces) do
                    if type(workspace) == "table" and type(workspace.id) == "number" then
                        if type(workspace.name) == "string" then
                            workspaceNames[workspace.id] = workspace.name
                        end
                        if type(workspace.idx) == "number" then
                            workspaceIndexes[workspace.id] = workspace.idx
                        end
                        if type(workspace.output) == "string" then
                            workspaceOutputs[workspace.id] = workspace.output
                        end
                        if workspace.is_focused == true then
                            focusedWorkspaceId = workspace.id
                        end
                        if workspace.is_active == true then
                            table.insert(activeWorkspaceIds, workspace.id)
                        end
                    end
                end

                if focusedWorkspaceId == nil and #activeWorkspaceIds > 0 then
                    for _, workspaceId in ipairs(activeWorkspaceIds) do
                        if workspaceId == previousFocusedWorkspaceId then
                            focusedWorkspaceId = previousFocusedWorkspaceId
                            break
                        end
                    end
                    focusedWorkspaceId = focusedWorkspaceId or activeWorkspaceIds[1]
                end

                local windowsById = {}
                for _, window in ipairs(results.windows) do
                    if type(window) == "table" and type(window.id) == "number" then
                        windowsById[window.id] = window
                        if window.is_focused == true and type(window.workspace_id) == "number" then
                            focusedWorkspaceId = window.workspace_id
                        end
                    end
                end

                scratchWorkspaceIndex = nil
                local focusedOutput = workspaceOutputs[focusedWorkspaceId]
                for _, workspace in ipairs(results.workspaces) do
                    if type(workspace) == "table"
                        and type(workspace.id) == "number"
                        and workspaceNames[workspace.id] == scratchWorkspace
                        and type(workspaceIndexes[workspace.id]) == "number"
                        and (focusedOutput == nil or workspaceOutputs[workspace.id] == focusedOutput)
                    then
                        scratchWorkspaceIndex = workspaceIndexes[workspace.id]
                        break
                    end
                end

                local markedIds = {}
                windowStates = {}
                for _, scratchpad in ipairs(scratchpads) do
                    markedIds[scratchpad.id] = true
                    local window = windowsById[scratchpad.id]
                    if window then
                        windowStates[scratchpad.id] = {
                            hidden = type(window.workspace_id) == "number"
                                and workspaceNames[window.workspace_id] == scratchWorkspace,
                            floating = window.is_floating == true,
                        }
                    end
                end

                showAllHidden = focusedWorkspaceId ~= nil
                    and workspaceNames[focusedWorkspaceId] == scratchWorkspace
                local focusedOnScratchWorkspace = showAllHidden

                workspaceWindows = {}
                unmarkedScratchWindows = {}
                scratchRestoreWorkspaceIndex = nil
                if focusedOnScratchWorkspace then
                    local scratchIndex = workspaceIndexes[focusedWorkspaceId]
                    local scratchOutput = workspaceOutputs[focusedWorkspaceId]
                    local nextIndex = nil
                    local previousIndex = nil
                    if type(scratchIndex) == "number" then
                        for workspaceId, workspaceIndex in pairs(workspaceIndexes) do
                            if workspaceOutputs[workspaceId] == scratchOutput then
                                if workspaceIndex > scratchIndex
                                    and (nextIndex == nil or workspaceIndex < nextIndex)
                                then
                                    nextIndex = workspaceIndex
                                elseif workspaceIndex < scratchIndex
                                    and (previousIndex == nil or workspaceIndex > previousIndex)
                                then
                                    previousIndex = workspaceIndex
                                end
                            end
                        end
                    end
                    scratchRestoreWorkspaceIndex = nextIndex or previousIndex
                end

                if focusedWorkspaceId ~= nil then
                    for _, window in ipairs(results.windows) do
                        if type(window) == "table" and type(window.id) == "number" then
                            if focusedOnScratchWorkspace
                                and window.workspace_id == focusedWorkspaceId
                                and not markedIds[window.id]
                            then
                                table.insert(unmarkedScratchWindows, window)
                            elseif window.workspace_id == focusedWorkspaceId
                                and not markedIds[window.id]
                            then
                                table.insert(workspaceWindows, window)
                            end
                        end
                    end
                    status = ""
                else
                    status = "Could not determine Niri's focused workspace."
                end
            end
            render()
            finish_refresh()
        end
    end

    for _, name in ipairs({ "windows", "workspaces" }) do
        local started = noctalia.runAsync({ "niri", "msg", "--json", name }, function(result)
            on_result(name, result)
        end, 5000)
        if not started then
            on_result(name, {
                timedOut = false,
                exitCode = 1,
                stderr = "Could not start niri. Check that it is installed and available on PATH.",
                stdout = "",
            })
        end
    end
end

function hide_scratchpad(windowId)
    local started = noctalia.runAsync({
        "niri",
        "msg",
        "action",
        "move-window-to-workspace",
        "--window-id",
        tostring(windowId),
        scratchWorkspace,
        "--focus=false",
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            status = `Could not hide scratchpad: {detail}`
            noctalia.notifyError("npad", status)
            render()
            return
        end

        status = "Scratchpad hidden."
        refresh_scratchpads()
    end, 10000)

    if not started then
        status = "Could not start niri. Check that it is installed and available on PATH."
        noctalia.notifyError("npad", status)
        render()
    end
end

function restore_scratchpad(windowId, originWorkspaceId)
    local workspaceIndex = workspaceIndexes[originWorkspaceId]
    if type(workspaceIndex) ~= "number" then
        status = "Could not determine the original workspace for this scratchpad."
        noctalia.notifyError("npad", status)
        render()
        return
    end

    local started = noctalia.runAsync({
        "niri",
        "msg",
        "action",
        "move-window-to-workspace",
        "--window-id",
        tostring(windowId),
        tostring(workspaceIndex),
        "--focus=true",
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            status = `Could not restore scratchpad: {detail}`
            noctalia.notifyError("npad", status)
            render()
            return
        end

        status = "Scratchpad restored to its original workspace."
        refresh_scratchpads()
    end, 10000)

    if not started then
        status = "Could not start niri. Check that it is installed and available on PATH."
        noctalia.notifyError("npad", status)
        render()
    end
end

function restore_unmarked_window(windowId)
    if type(scratchRestoreWorkspaceIndex) ~= "number" then
        status = "Could not find another workspace to restore this window to."
        noctalia.notifyError("npad", status)
        render()
        return
    end

    local started = noctalia.runAsync({
        "niri",
        "msg",
        "action",
        "move-window-to-workspace",
        "--window-id",
        tostring(windowId),
        tostring(scratchRestoreWorkspaceIndex),
        "--focus=true",
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            status = `Could not restore unmarked window: {detail}`
            noctalia.notifyError("npad", status)
            render()
            return
        end

        status = "Unmarked window restored to the next workspace."
        refresh_scratchpads()
    end, 10000)

    if not started then
        status = "Could not start niri. Check that it is installed and available on PATH."
        noctalia.notifyError("npad", status)
        render()
    end
end

function toggle_window_floating(windowId)
    local started = noctalia.runAsync({
        "niri",
        "msg",
        "action",
        "toggle-window-floating",
        "--id",
        tostring(windowId),
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            status = `Could not toggle floating layout: {detail}`
            noctalia.notifyError("npad", status)
            render()
            return
        end

        status = "Window layout toggled."
        refresh_scratchpads()
    end, 10000)

    if not started then
        status = "Could not start niri. Check that it is installed and available on PATH."
        noctalia.notifyError("npad", status)
        render()
    end
end

function run_nscratch(arguments, successMessage, onComplete)
    local command = { "nscratch" }
    for _, argument in ipairs(arguments) do
        table.insert(command, argument)
    end

    local started = noctalia.runAsync(command, function(result)
        local output = {}
        local stdout = type(result.stdout) == "string" and result.stdout:gsub("^%s+", ""):gsub("%s+$", "") or ""
        local stderr = type(result.stderr) == "string" and result.stderr:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if stdout ~= "" then
            table.insert(output, `stdout: {stdout}`)
        end
        if stderr ~= "" then
            table.insert(output, `stderr: {stderr}`)
        end
        local detail = #output > 0 and table.concat(output, "\n") or `exit status {result.exitCode}`

        if result.timedOut then
            status = `nscratch timed out: {detail}`
            noctalia.notifyError("npad", status)
        elseif result.exitCode ~= 0 then
            status = `nscratch failed: {detail}`
            if result.exitCode == 1 then
                if arguments[1] == "--index" or arguments[1] == "--remove" then
                    status ..= "\nThe scratchpad entry may be stale. The panel will reload automatically."
                end
            end
            noctalia.notifyError("npad", status)
        else
            status = successMessage
            refresh_scratchpads()
            if onComplete then
                onComplete()
            end
            return
        end
        render()
        if onComplete then
            onComplete()
        end
    end, 10000)

    if not started then
        status = "Could not start nscratch. Check that it is installed and on PATH."
        noctalia.notifyError("npad", status)
        render()
        if onComplete then
            onComplete()
        end
    end
end

function onOpen(_context)
    panelOpen = true
    if listenerScript == nil then
        local script, readError = noctalia.readFile("niri-event-listener.sh")
        if type(script) ~= "string" then
            status = `Could not read Niri event listener script: {tostring(readError)}`
            render()
        else
            listenerScript = script
        end
    end

    if listenerScript and not listenerStarting and not listenerActive then
        listenerStarting = true
        local started = noctalia.runAsync({
            "bash",
            "-c",
            listenerScript,
            "npad-niri-event-listener",
            "start",
            listenerScript,
        }, function(result)
            listenerStarting = false
            if result.timedOut or result.exitCode ~= 0 then
                stopListenerWhenStarted = false
                local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
                status = `Could not start Niri event listener: {detail}`
                noctalia.notifyError("npad", status)
                render()
                return
            end

            listenerActive = true
            if stopListenerWhenStarted or not panelOpen then
                stopListenerWhenStarted = false
                stop_niri_event_listener()
            end
        end, 5000)
        if not started then
            listenerStarting = false
            status = "Could not start Niri event listener process."
            noctalia.notifyError("npad", status)
            render()
        end
    end

    refresh_scratchpads()
end

function onClose()
    panelOpen = false
    refreshPending = false
    if listenerStarting then
        stopListenerWhenStarted = true
    elseif listenerActive then
        stop_niri_event_listener()
    end
end

function onKey(chord, pressed)
    if chord == "Escape" and pressed == "true" then
        panel.close()
    end
end

function stop_niri_event_listener()
    if not listenerActive or listenerScript == nil then
        return
    end

    listenerActive = false
    local started = noctalia.runAsync({
        "bash",
        "-c",
        listenerScript,
        "npad-niri-event-listener",
        "stop",
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            noctalia.notifyError("npad", `Could not stop Niri event listener: {detail}`)
        end
    end, 5000)

    if not started then
        noctalia.notifyError("npad", "Could not start the Niri event listener stop command.")
    end
end

function onIpc(event, payload)
    if event == "niri-event" and panelOpen then
        refresh_scratchpads()
    elseif event == "niri-listener-error" and panelOpen then
        status = "Niri event stream stopped unexpectedly. Close and reopen the panel to reconnect."
        noctalia.notifyError("npad", status)
        render()
    elseif event == "prevent-scratch-error" then
        local detail = type(payload) == "string" and payload or "Workspace navigation helper failed."
        status = detail
        noctalia.notifyError("npad", detail)
        if panelOpen then
            render()
        end
    end
end

function onExit()
    if listenerScript then
        noctalia.runAsync({
            "bash",
            "-c",
            listenerScript,
            "npad-niri-event-listener",
            "stop",
        })
    end
end
