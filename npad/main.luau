--!nonstrict

local PANEL_ID = "ffngs/npad:manager"
local scratchpads = {}
local windowStates = {}
local workspaceWindows = {}
local status = "Loading scratchpads..."

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

local function window_row(windowId, appId, title, actionLabel, actionGlyph, action, extraAction, stateLabel, actionEnabled, muted)
    local iconPath = noctalia.appIconPath(appId, 32)
    local icon = if muted then
        ui.glyph({ name = "window", size = 28, color = "on_surface_variant", opacity = 0.5 })
    elseif type(iconPath) == "string" then
        ui.image({ path = iconPath, width = 32, height = 32, fit = "contain" })
    else
        ui.glyph({ name = "window", size = 28, color = "primary" })

    local children = {
        icon,
        ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({
                text = appId,
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
    if extraAction then
        table.insert(children, ui.button({
            text = "Remove",
            glyph = "trash",
            variant = "outline",
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

    for index, scratchpad in ipairs(scratchpads) do
        local scratchIndex = index
        local windowId = scratchpad.id
        local appId = type(scratchpad.app_id) == "string" and scratchpad.app_id or "Unknown app"
        local title = type(scratchpad.title) == "string" and scratchpad.title or "Untitled window"
        local liveState = windowStates[windowId]
        local isHidden = liveState ~= nil and liveState.hidden
        local stateLabel = if liveState == nil then "Unavailable" elseif isHidden then nil else "Marked"
        local actionLabel = if isHidden then "Restore" else "Hide"
        local actionGlyph = if isHidden then "eye" else "eye-off"

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
                    run_nscratch({ "--index", tostring(scratchIndex) }, "Scratchpad restored.")
                else
                    hide_scratchpad(windowId)
                end
            end,
            function()
                run_nscratch({ "--remove", tostring(scratchIndex) }, "Scratchpad removed.")
            end,
            stateLabel,
            true,
            isHidden
        ))
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

    local content = {}
    if status ~= "" then
        table.insert(content, ui.label({ text = status, color = "on_surface_variant" }))
    end

    table.insert(content, ui.label({ text = "Marked", fontSize = 16, fontWeight = "semibold" }))
    if #markedRows == 0 then
        table.insert(content, ui.label({
            text = "No marked windows.",
            color = "on_surface_variant",
        }))
    else
        for _, row in ipairs(markedRows) do
            table.insert(content, row)
        end
    end

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

    panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.label({ text = "Npad", fontSize = 22, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ text = "Refresh", glyph = "refresh-cw", onClick = refresh_scratchpads }),
        }),
        ui.scroll({ flexGrow = 1, gap = 6 }, content),
    }))
end

local function reopen_panel_after_delay()
    local started = noctalia.runAsync({ "sleep", "0.25" }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            noctalia.notifyError("Npad", "Could not wait before reopening the panel.")
        end
        noctalia.togglePanel(PANEL_ID)
    end, 2000)

    if not started then
        noctalia.notifyError("Npad", "Could not start the panel reopen delay.")
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
            noctalia.notifyError("Npad", `Could not focus the selected window: {detail}`)
            reopen_panel_after_delay()
            return
        end

        local started = noctalia.runAsync({ "sleep", "0.1" }, function(delayResult)
            if delayResult.timedOut or delayResult.exitCode ~= 0 then
                noctalia.notifyError("Npad", "Could not wait for Niri to focus the selected window.")
                reopen_panel_after_delay()
                return
            end

            run_nscratch({ "--mark" }, "Window marked as a dynamic scratchpad.", reopen_panel_after_delay)
        end, 2000)

        if not started then
            noctalia.notifyError("Npad", "Could not start the focus settling delay.")
            reopen_panel_after_delay()
        end
    end, 5000)

    if not focusStarted then
        noctalia.notifyError("Npad", "Could not start niri to focus the selected window.")
        reopen_panel_after_delay()
    end
end

function mark_workspace_window(windowId)
    panel.close()

    local started = noctalia.runAsync({ "sleep", "0.25" }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            noctalia.notifyError("Npad", "Could not wait for the panel to close.")
            reopen_panel_after_delay()
            return
        end

        focus_and_mark_window(windowId)
    end, 2000)

    if not started then
        noctalia.notifyError("Npad", "Could not start the panel close delay.")
        noctalia.togglePanel(PANEL_ID)
    end
end

function refresh_scratchpads()
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
        render()
        return
    end

    local ok, state = pcall(noctalia.json.decode, content)
    if not ok then
        scratchpads = {}
        windowStates = {}
        status = `Could not parse nscratch state: {tostring(state)}`
        render()
        return
    end

    if type(state) ~= "table" or type(state.windows) ~= "table" then
        scratchpads = {}
        windowStates = {}
        status = "Invalid nscratch state: expected a windows list."
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
            render()
            return
        end
    end

    scratchpads = state.windows
    update_window_states()
end

function update_window_states()
    status = "Checking window states..."
    render()

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
            else
                local workspaceNames = {}
                local focusedWorkspaceId = nil
                for _, workspace in ipairs(results.workspaces) do
                    if type(workspace) == "table" and type(workspace.id) == "number" then
                        workspaceNames[workspace.id] = workspace.name
                        if workspace.is_focused == true then
                            focusedWorkspaceId = workspace.id
                        end
                    end
                end

                local windowsById = {}
                for _, window in ipairs(results.windows) do
                    if type(window) == "table" and type(window.id) == "number" then
                        windowsById[window.id] = window
                    end
                end

                local scratchWorkspace = noctalia.getenv("NS_WORKSPACE") or "scratch"
                local markedIds = {}
                windowStates = {}
                for _, scratchpad in ipairs(scratchpads) do
                    markedIds[scratchpad.id] = true
                    local window = windowsById[scratchpad.id]
                    if window then
                        windowStates[scratchpad.id] = {
                            hidden = type(window.workspace_id) == "number"
                                and workspaceNames[window.workspace_id] == scratchWorkspace,
                        }
                    end
                end

                workspaceWindows = {}
                if focusedWorkspaceId ~= nil then
                    for _, window in ipairs(results.windows) do
                        if type(window) == "table"
                            and type(window.id) == "number"
                            and window.workspace_id == focusedWorkspaceId
                            and not markedIds[window.id]
                        then
                            table.insert(workspaceWindows, window)
                        end
                    end
                    status = ""
                else
                    status = "Could not determine Niri's focused workspace."
                end
            end
            render()
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
    local scratchWorkspace = noctalia.getenv("NS_WORKSPACE") or "scratch"
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
            noctalia.notifyError("Npad", status)
            render()
            return
        end

        status = "Scratchpad hidden."
        refresh_scratchpads()
    end, 10000)

    if not started then
        status = "Could not start niri. Check that it is installed and available on PATH."
        noctalia.notifyError("Npad", status)
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
            noctalia.notifyError("Npad", status)
        elseif result.exitCode ~= 0 then
            status = `nscratch failed: {detail}`
            if result.exitCode == 1 then
                if arguments[1] == "--index" or arguments[1] == "--remove" then
                    status ..= "\nThe scratchpad entry may be stale. Refresh the list and try again."
                end
            end
            noctalia.notifyError("Npad", status)
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
        noctalia.notifyError("Npad", status)
        render()
        if onComplete then
            onComplete()
        end
    end
end

function onOpen(_context)
    refresh_scratchpads()
end
