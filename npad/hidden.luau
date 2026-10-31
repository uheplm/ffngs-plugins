--!nonstrict

local PANEL_ID = "ffngs/npad:manager"
local checking = false
local hideWhenZero = noctalia.getConfig("hide_when_zero") ~= false
local lastFocusedWorkspaceId = nil
local scratchWorkspace = noctalia.getConfig("scratch_workspace")
if type(scratchWorkspace) ~= "string" or scratchWorkspace == "" then
    scratchWorkspace = "scratch"
end

noctalia.setUpdateInterval(1000)

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

local function render(count, errorMessage, allWorkspaces)
    if not errorMessage and count == 0 and hideWhenZero then
        barWidget.setVisible(false)
        return
    end

    barWidget.setVisible(true)
    barWidget.setGlyph("eye")
    barWidget.setText(if errorMessage then "?" else tostring(count))
    local tooltip = if allWorkspaces
        then `{count} hidden scratchpad window(s) from all workspaces`
        else `{count} hidden scratchpad window(s) from this workspace`
    barWidget.setTooltip(errorMessage or tooltip)
end

local function show_error(message)
    render(nil, message)
end

local function count_hidden_windows()
    local path = state_path()
    if not noctalia.fileExists(path) then
        checking = false
        render(0)
        return
    end

    local content, readError = noctalia.readFile(path)
    if type(content) ~= "string" then
        checking = false
        show_error(`Could not read nscratch state: {tostring(readError)}`)
        return
    end

    local ok, state = pcall(noctalia.json.decode, content)
    if not ok or type(state) ~= "table" or type(state.windows) ~= "table" then
        checking = false
        show_error("Could not parse nscratch state.")
        return
    end

    local markedWorkspaces = {}
    for index, scratchpad in ipairs(state.windows) do
        if type(scratchpad) ~= "table"
            or type(scratchpad.id) ~= "number"
            or type(scratchpad.workspace) ~= "number"
        then
            checking = false
            show_error(`Invalid nscratch state at window {index}.`)
            return
        end
        markedWorkspaces[scratchpad.id] = scratchpad.workspace
    end

    if next(markedWorkspaces) == nil then
        checking = false
        render(0)
        return
    end

    local results = {}
    local pending = 2
    local failed = false

    local function on_result(name, result)
        if result.timedOut or result.exitCode ~= 0 then
            failed = true
            local detail = result.stderr ~= "" and result.stderr or `exit status {result.exitCode}`
            show_error(`Could not read Niri {name}: {detail}`)
        else
            local decodedOk, decoded = pcall(noctalia.json.decode, result.stdout)
            if not decodedOk or type(decoded) ~= "table" then
                failed = true
                show_error(`Could not parse Niri {name} response.`)
            else
                results[name] = decoded
            end
        end

        pending -= 1
        if pending == 0 then
            checking = false
            if failed then
                return
            end

            local workspaceNames = {}
            local focusedWorkspaceId = nil
            local activeWorkspaceIds = {}
            for _, workspace in ipairs(results.workspaces) do
                if type(workspace) == "table"
                    and type(workspace.id) == "number"
                then
                    if type(workspace.name) == "string" then
                        workspaceNames[workspace.id] = workspace.name
                    end
                    if workspace.is_focused == true then
                        focusedWorkspaceId = workspace.id
                    end
                    if workspace.is_active == true then
                        table.insert(activeWorkspaceIds, workspace.id)
                    end
                end
            end

            local windowsById = {}
            for _, window in ipairs(results.windows) do
                if type(window) == "table" and type(window.id) == "number" then
                    windowsById[window.id] = window
                end
            end

            if focusedWorkspaceId == nil then
                if lastFocusedWorkspaceId ~= nil then
                    for _, workspaceId in ipairs(activeWorkspaceIds) do
                        if workspaceId == lastFocusedWorkspaceId then
                            focusedWorkspaceId = lastFocusedWorkspaceId
                            break
                        end
                    end
                end

                focusedWorkspaceId = focusedWorkspaceId or activeWorkspaceIds[1]
            end
            if focusedWorkspaceId == nil then
                checking = false
                show_error("Niri did not report a focused workspace.")
                return
            end
            lastFocusedWorkspaceId = focusedWorkspaceId

            local focusedOnScratchWorkspace = workspaceNames[focusedWorkspaceId] == scratchWorkspace
            local hiddenCount = 0
            for windowId, originalWorkspaceId in pairs(markedWorkspaces) do
                local window = windowsById[windowId]
                if window
                    and (focusedOnScratchWorkspace or originalWorkspaceId == focusedWorkspaceId)
                    and type(window.workspace_id) == "number"
                    and workspaceNames[window.workspace_id] == scratchWorkspace
                then
                    hiddenCount += 1
                end
            end

            render(hiddenCount, nil, focusedOnScratchWorkspace)
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

function update()
    noctalia.setUpdateInterval(1000)
    if checking then
        return
    end

    checking = true
    count_hidden_windows()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

count_hidden_windows()
