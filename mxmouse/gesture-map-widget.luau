--!nonstrict

local AXIS = noctalia.getConfig("axis") == "y" and "y" or "x"
local STATUS_PATH = nil
local serviceStatus = {}
local windows = {}
local workspaces = {}
local outputName = barWidget.outputName() or noctalia.focusedOutputName()
local layoutRequestInFlight = false
local layoutRevision = 0
local lastLayoutUpdateAt = 0
local LAYOUT_REFRESH_INTERVAL_MS = 100
local lastTriggerCount = nil
local errorMessage = nil
local suppressGestureProgress = false
local triggerCompletion = nil
local PROGRESS_STEP = 0.01
local PROGRESS_EASE_MS = 64
local PROGRESS_VISIBILITY_EASE_MS = 96
local WARNING_COLOR = "#f97316"
local widgetLayout = if AXIS == "y" then "vertical" else "horizontal"
local showProgressWhenInactive = true
local dominantAxisProgress = false
local dynamicProgressOpacity = false
local shrinkInactiveWorkspacePills = false
local animateWorkspacePillResizing = true
local workspacePillResizeDuration = 280
local openLauncherOnEmptyWorkspace = false
local openLauncherOnFocus = false
local closeLauncherLeavingEmptyWorkspace = false
local openLauncherAtWorkspaceEdge = false
local launcherWorkspaceEdge = "end"
local launcherGlyph = "apps"
local hideEmptyWorkspaces = false
local focusedWorkspaceState = nil
local edgeLauncherFocus = nil
local widgetWidth = 190
local targetMinWidthPercent = 10
local workspacePillWidth = 28
local workspacePillHeight = 40
local pillRadius = 6
local workspaceBadgeRadius = 6
local iconSizePercent = 70
local horizontalPillPadding = 2
local verticalPillPadding = 2
local progressThicknessPercent = 40
local iconProgressGap = 3
local workspaceGlyphs = {}
local pillProgressStates = { x = {}, y = {} }
local workspacePillSizeStates = {}
local progressAnimation = {
    x = { value = 0, direction = "", sourceKey = nil, updatedAt = noctalia.nowMs() },
    y = { value = 0, direction = "", sourceKey = nil, updatedAt = noctalia.nowMs() },
}

local arrange = ui.column

local function setting(name, fallback, minimum, maximum)
    local value = tonumber(noctalia.getConfig(name))
    if value == nil then
        return fallback
    end
    return math.clamp(value, minimum, maximum)
end

local function read_widget_settings()
    local configuredLayout = noctalia.getConfig("layout")
    widgetLayout = if configuredLayout == "vertical" or configuredLayout == "horizontal"
        then configuredLayout else if AXIS == "y" then "vertical" else "horizontal"
    arrange = if widgetLayout == "horizontal" then ui.row else ui.column
    showProgressWhenInactive = noctalia.getConfig("show_progress_when_inactive") ~= false
    dominantAxisProgress = noctalia.getConfig("dominant_axis_progress") == true
    dynamicProgressOpacity = noctalia.getConfig("dynamic_progress_opacity") == true
    shrinkInactiveWorkspacePills = AXIS == "y"
        and noctalia.getConfig("shrink_inactive_workspace_pills") == true
    animateWorkspacePillResizing = noctalia.getConfig("animate_workspace_pill_resizing") ~= false
    workspacePillResizeDuration = setting("workspace_pill_resize_duration", 280, 100, 1000)
    openLauncherOnEmptyWorkspace = AXIS == "x"
        and noctalia.getConfig("open_launcher_on_empty_workspace") == true
    openLauncherOnFocus = AXIS == "x" and noctalia.getConfig("open_launcher_on_focus") == true
    closeLauncherLeavingEmptyWorkspace = AXIS == "x"
        and noctalia.getConfig("close_launcher_leaving_empty_workspace") == true
    openLauncherAtWorkspaceEdge = AXIS == "x"
        and noctalia.getConfig("open_launcher_at_workspace_edge") == true
    local configuredLauncherEdge = noctalia.getConfig("launcher_workspace_edge")
    launcherWorkspaceEdge = if configuredLauncherEdge == "start" then "start" else "end"
    local configuredLauncherGlyph = noctalia.getConfig("launcher_glyph")
    launcherGlyph = if type(configuredLauncherGlyph) == "string" and configuredLauncherGlyph ~= ""
        then configuredLauncherGlyph else "apps"
    hideEmptyWorkspaces = noctalia.getConfig("hide_empty_workspaces") == true
    widgetWidth = setting("widget_width", 190, 60, 600)
    targetMinWidthPercent = setting("target_min_width_percent", 10, 1, 50)
    workspacePillWidth = setting("workspace_pill_width", 28, 16, 200)
    workspacePillHeight = setting("workspace_pill_height", 40, 16, 200)
    pillRadius = setting("pill_radius", 6, 0, 24)
    workspaceBadgeRadius = setting("workspace_badge_radius", 6, 0, 24)
    iconSizePercent = setting("icon_size_percent", 70, 25, 150)
    horizontalPillPadding = setting("horizontal_pill_padding", 2, 0, 16)
    verticalPillPadding = setting("vertical_pill_padding", 2, 0, 16)
    progressThicknessPercent = setting("progress_thickness_percent", 40, 10, 100)
    iconProgressGap = setting("icon_progress_gap", 3, 0, 24)
    workspaceGlyphs = {}
    local mappings = noctalia.getConfig("workspace_glyphs")
    if type(mappings) == "string" then
        for mapping in string.gmatch(mappings, "[^,]+") do
            local separator = string.find(mapping, "=", 1, true)
            if separator ~= nil then
                local name = string.match(string.sub(mapping, 1, separator - 1), "^%s*(.-)%s*$")
                local glyph = string.match(string.sub(mapping, separator + 1), "^%s*(.-)%s*$")
                if name ~= nil and name ~= "" and glyph ~= nil and glyph ~= "" then
                    workspaceGlyphs[name] = glyph
                end
            end
        end
    end
end

local function status_path()
    local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
    if type(runtimeDir) ~= "string" or runtimeDir == "" then
        return nil
    end
    return runtimeDir .. "/mxmouse/status.json"
end

local function report_action_error(action, result)
    if result.timedOut or result.exitCode ~= 0 then
        local detail = result.stderr ~= "" and result.stderr
            or result.stdout ~= "" and result.stdout
            or `exit status {result.exitCode}`
        noctalia.notifyError("MX Mouse", `Could not {action}: {detail}`)
    end
end

local function run_action(action, args)
    local command = { "niri", "msg", "action" }
    for _, arg in ipairs(args) do
        table.insert(command, tostring(arg))
    end
    local started = noctalia.runAsync(command, function(result)
        report_action_error(action, result)
    end, 5000)
    if not started then
        noctalia.notifyError("MX Mouse", `Could not start Niri to {action}.`)
    end
end

local function run_launcher_opening_command()
    local command = noctalia.getConfig("launcher_opening_command")
    if type(command) ~= "string" or string.match(command, "^%s*$") ~= nil then
        noctalia.notifyError("MX Mouse", "Launcher opening command is empty.")
        return false
    end
    local started = noctalia.runAsync({ "sh", "-c", command }, function(result)
        report_action_error("open the launcher", result)
    end, 5000)
    if not started then
        noctalia.notifyError("MX Mouse", "Could not start the launcher opening command.")
    end
    return started
end

local function close_launcher()
    local started = noctalia.runAsync({ "noctalia", "msg", "panel-close", "launcher" }, function(result)
        report_action_error("close the launcher", result)
    end, 5000)
    if not started then
        noctalia.notifyError("MX Mouse", "Could not start Noctalia to close the launcher.")
    end
end

local function workspace_has_windows(workspace)
    for _, window in ipairs(windows) do
        if type(window) == "table" and window.workspace_id == workspace.id then
            return true
        end
    end
    return false
end

local function focused_workspace()
    local focused = nil
    for _, workspace in ipairs(workspaces) do
        if type(workspace) == "table"
            and (outputName == nil or outputName == "" or workspace.output == outputName)
        then
            if workspace.is_active == true then
                return workspace
            elseif workspace.is_focused == true then
                focused = workspace
            end
        end
    end
    return focused
end

local function focused_identity()
    local workspace = focused_workspace()
    if workspace == nil then
        return nil
    end
    local windowId = workspace.active_window_id
    for _, window in ipairs(windows) do
        if type(window) == "table" and window.is_focused == true then
            windowId = window.id
            break
        end
    end
    return `{workspace.id}:{tostring(windowId)}`
end

local function update_empty_workspace_launcher()
    if AXIS ~= "x" then
        return
    end
    local workspace = focused_workspace()
    local current = if workspace ~= nil
        then { id = workspace.id, empty = not workspace_has_windows(workspace) }
        else nil
    if edgeLauncherFocus ~= nil then
        local currentFocus = focused_identity()
        if currentFocus ~= nil and currentFocus ~= edgeLauncherFocus then
            edgeLauncherFocus = nil
            close_launcher()
        end
    end
    local previous = focusedWorkspaceState
    local changedWorkspace = current ~= nil and previous ~= nil and current.id ~= previous.id
    if previous ~= nil and previous.empty
        and (current == nil or changedWorkspace or not current.empty)
        and closeLauncherLeavingEmptyWorkspace
    then
        close_launcher()
    end
    if current ~= nil and current.empty
        and (previous == nil or changedWorkspace or not previous.empty)
        and openLauncherOnFocus
    then
        run_launcher_opening_command()
    end
    focusedWorkspaceState = current
end

local function refresh_layout()
    if layoutRequestInFlight then
        return
    end
    layoutRequestInFlight = true
    lastLayoutUpdateAt = noctalia.nowMs()
    local requestRevision = layoutRevision

    local results = {}
    local failures = {}
    local pending = 2
    local function on_result(name, result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            failures[name] = detail
        else
            local ok, decoded = pcall(noctalia.json.decode, result.stdout)
            if not ok or type(decoded) ~= "table" then
                failures[name] = `Could not parse Niri {name} response.`
            else
                results[name] = decoded
            end
        end

        pending -= 1
        if pending ~= 0 then
            return
        end

        layoutRequestInFlight = false
        if requestRevision ~= layoutRevision then
            refresh_layout()
            return
        end
        if next(failures) ~= nil then
            errorMessage = `Could not read Niri workspace layout: {tostring(failures.windows or failures.workspaces)}`
            render()
            return
        end

        windows = results.windows
        workspaces = results.workspaces
        if type(outputName) ~= "string" or outputName == "" then
            outputName = barWidget.outputName() or noctalia.focusedOutputName()
        end
        update_empty_workspace_launcher()
        suppressGestureProgress = false
        if triggerCompletion ~= nil then
            triggerCompletion.layoutReady = true
        end
        errorMessage = nil
        render()
    end

    for _, name in ipairs({ "windows", "workspaces" }) do
        local started = noctalia.runAsync({ "niri", "msg", "--json", name }, function(result)
            on_result(name, result)
        end, 5000)
        if not started then
            on_result(name, {
                timedOut = false,
                exitCode = 1,
                stderr = `Could not start Niri to read {name}.`,
                stdout = "",
            })
        end
    end
end

local function direction_offset(direction)
    if direction == "right" or direction == "down" then
        return 1
    elseif direction == "left" or direction == "up" then
        return -1
    end
    return 0
end

local function read_service_status()
    STATUS_PATH = STATUS_PATH or status_path()
    if STATUS_PATH == nil then
        errorMessage = "XDG_RUNTIME_DIR is not set; MX Mouse gesture data is unavailable."
        return
    end
    if not noctalia.fileExists(STATUS_PATH) then
        errorMessage = "nnmxd status is unavailable. Check that the service is installed and running."
        return
    end

    local contents, readError = noctalia.readFile(STATUS_PATH)
    if type(contents) ~= "string" then
        errorMessage = `Could not read nnmxd status: {tostring(readError)}`
        return
    end

    local ok, decoded = pcall(noctalia.json.decode, contents)
    if not ok or type(decoded) ~= "table" then
        errorMessage = "Could not parse nnmxd status."
        return
    end

    serviceStatus = decoded
    if type(serviceStatus.gesture) ~= "table" then
        errorMessage = "Update nnmxd to enable gesture-map progress and trigger indicators."
        return
    end
    if errorMessage ~= nil and string.find(errorMessage, "Niri", 1, true) then
        return
    end
    errorMessage = nil

    local gesture = serviceStatus.gesture
    local triggerCount = tonumber(gesture.triggerCount) or 0
    if lastTriggerCount == nil then
        lastTriggerCount = triggerCount
    elseif triggerCount > lastTriggerCount then
        lastTriggerCount = triggerCount
        layoutRevision += 1
        suppressGestureProgress = true
        if gesture.triggeredAxis == AXIS and direction_offset(gesture.triggeredDirection) ~= 0 then
            triggerCompletion = {
                direction = gesture.triggeredDirection,
                startedAt = noctalia.nowMs(),
                layoutReady = false,
                sourceKey = nil,
                launcherTriggered = false,
            }
        end
        refresh_layout()
    end
end

local function output_workspaces(includeEmpty)
    local allItems = {}
    for _, workspace in ipairs(workspaces) do
        if type(workspace) == "table"
            and type(workspace.id) == "number"
            and type(workspace.idx) == "number"
            and (outputName == nil or outputName == "" or workspace.output == outputName)
        then
            table.insert(allItems, workspace)
        end
    end
    table.sort(allItems, function(left, right)
        return left.idx < right.idx
    end)

    if includeEmpty or not hideEmptyWorkspaces or AXIS ~= "y" then
        return allItems
    end

    local result = {}
    for _, workspace in ipairs(allItems) do
        if workspace_has_windows(workspace)
            or workspace.is_active == true
            or workspace.is_focused == true
        then
            table.insert(result, workspace)
        end
    end
    return result
end

local function focused_window_on_widget_output()
    if outputName == nil or outputName == "" then
        return false
    end
    for _, window in ipairs(windows) do
        if type(window) == "table" and window.is_focused == true then
            for _, workspace in ipairs(workspaces) do
                if type(workspace) == "table"
                    and workspace.id == window.workspace_id
                then
                    return workspace.output == outputName
                end
            end
            break
        end
    end
    for _, workspace in ipairs(workspaces) do
        if type(workspace) == "table" and workspace.is_focused == true then
            return workspace.output == outputName
        end
    end
    local focusedOutput = noctalia.focusedOutputName()
    return type(focusedOutput) == "string" and focusedOutput ~= "" and focusedOutput == outputName
end

local function active_workspace(items)
    for _, workspace in ipairs(items) do
        if workspace.is_active == true then
            return workspace
        end
    end
    for _, workspace in ipairs(items) do
        if workspace.is_focused == true then
            return workspace
        end
    end
    return nil
end

local function workspace_columns(workspace)
    if workspace == nil then
        return {}
    end

    local columnsByIndex = {}
    for _, window in ipairs(windows) do
        local layout = type(window) == "table" and window.layout or nil
        local position = type(layout) == "table" and layout.pos_in_scrolling_layout or nil
        if type(window) == "table"
            and window.workspace_id == workspace.id
            and window.is_floating ~= true
            and type(position) == "table"
            and type(position[1]) == "number"
            and type(window.id) == "number"
        then
            local columnIndex = position[1]
            local column = columnsByIndex[columnIndex]
            if column == nil then
                column = { index = columnIndex, width = 0, windows = {} }
                columnsByIndex[columnIndex] = column
            end
            table.insert(column.windows, window)
            local tileSize = layout.tile_size
            local width = if type(tileSize) == "table" then tonumber(tileSize[1]) or 0 else 0
            column.width = math.max(column.width, width)
        end
    end

    local columns = {}
    for _, column in pairs(columnsByIndex) do
        local representative = nil
        for _, window in ipairs(column.windows) do
            if window.id == workspace.active_window_id or window.is_focused == true then
                representative = window
                break
            end
            local timestamp = window.focus_timestamp
            if representative == nil
                or (type(timestamp) == "table"
                    and type(representative.focus_timestamp) == "table"
                    and ((timestamp.secs or 0) > (representative.focus_timestamp.secs or 0)
                        or ((timestamp.secs or 0) == (representative.focus_timestamp.secs or 0)
                            and (timestamp.nanos or 0) > (representative.focus_timestamp.nanos or 0))))
            then
                representative = window
            end
        end
        column.window = representative or column.windows[1]
        table.insert(columns, column)
    end
    table.sort(columns, function(left, right)
        return left.index < right.index
    end)
    return columns
end

local function progress_target(selectedIndex, direction, itemCount)
    local offset = direction_offset(direction)
    if selectedIndex == nil or itemCount == 0 or offset == 0 then
        return nil
    end
    local targetIndex = selectedIndex + offset
    if targetIndex < 1 or targetIndex > itemCount then
        return nil
    end
    return targetIndex
end

local function workspace_target_exists(workspace, items, direction)
    if workspace == nil then
        return false
    end
    local offset = direction_offset(direction)
    if offset == 0 then
        return false
    end
    for index, item in ipairs(items) do
        if item.id == workspace.id then
            local targetIndex = index + offset
            return targetIndex >= 1 and targetIndex <= #items
        end
    end
    return false
end

local function axis_progress_allowed(axis, gesture, completingTrigger)
    if not dominantAxisProgress or completingTrigger then
        return true
    end
    local xProgress = math.clamp(tonumber(gesture.xProgress) or 0, 0, 1)
    local yProgress = math.clamp(tonumber(gesture.yProgress) or 0, 0, 1)
    if axis == "x" then
        return xProgress >= yProgress
    end
    return yProgress > xProgress
end

local function animate_progress(axis, target, direction, enabled, gestureActive, sourceKey)
    local animation = progressAnimation[axis]
    local now = noctalia.nowMs()
    local elapsed = math.clamp(now - animation.updatedAt, 0, 100)
    animation.updatedAt = now

    if sourceKey ~= animation.sourceKey then
        animation.value = 0
        animation.sourceKey = sourceKey
    end

    if not gestureActive or not enabled then
        animation.value = 0
        if not gestureActive then
            animation.direction = ""
        end
        return animation.value, animation.direction
    end

    if direction_offset(direction) == 0 then
        return animation.value, animation.direction
    end
    if animation.direction ~= direction then
        animation.value = 0
    end
    animation.direction = direction

    local amount = math.clamp(elapsed / PROGRESS_EASE_MS, 0, 1)
    local easedAmount = amount * amount * (3 - 2 * amount)
    animation.value += (target - animation.value) * easedAmount
    if math.abs(target - animation.value) < 0.001 then
        animation.value = target
    end
    return animation.value, animation.direction
end

local function animate_pill_progress(axis, key, showProgress, expand, direction)
    local states = pillProgressStates[axis]
    local state = states[key]
    local now = noctalia.nowMs()
    if state == nil then
        state = { visibility = 0, expansion = 0, direction = "", updatedAt = now }
        states[key] = state
    end
    if direction_offset(direction) ~= 0 then
        state.direction = direction
    end

    local elapsed = math.clamp(now - state.updatedAt, 0, 100)
    state.updatedAt = now
    local amount = math.clamp(elapsed / PROGRESS_VISIBILITY_EASE_MS, 0, 1)
    amount = amount * amount * (3 - 2 * amount)
    local visibilityTarget = if showProgress then 1 else 0
    local expansionTarget = if expand then 1 else 0
    state.visibility += (visibilityTarget - state.visibility) * amount
    state.expansion += (expansionTarget - state.expansion) * amount
    if math.abs(state.visibility - visibilityTarget) < 0.001 then
        state.visibility = visibilityTarget
    end
    if math.abs(state.expansion - expansionTarget) < 0.001 then
        state.expansion = expansionTarget
    end
    return state.visibility, state.expansion, state.direction
end

local function animate_workspace_pill_size(key, selected)
    local now = noctalia.nowMs()
    local target = if selected then 1 else 0
    if not animateWorkspacePillResizing then
        workspacePillSizeStates[key] = {
            value = target,
            from = target,
            target = target,
            startedAt = now,
        }
        return target
    end
    local state = workspacePillSizeStates[key]
    if state == nil then
        state = {
            value = target,
            from = target,
            target = target,
            startedAt = now,
        }
        workspacePillSizeStates[key] = state
        return state.value
    end
    if state.target ~= target then
        state.from = state.value
        state.target = target
        state.startedAt = now
    end
    local progress = math.clamp((now - state.startedAt) / workspacePillResizeDuration, 0, 1)
    local easedProgress = progress * progress * progress
        * (progress * (progress * 6 - 15) + 10)
    state.value = state.from + (state.target - state.from) * easedProgress
    return state.value
end

local function app_icon(appId, color, size)
    local path = if type(appId) == "string" and appId ~= "" then noctalia.appIconPath(appId, size) else nil
    if type(path) == "string" then
        return ui.image({ path = path, width = size, height = size, fit = "contain" })
    end
    return ui.glyph({ name = "window", size = size, color = color })
end

local function progress_segment(axis, length, thickness, color)
    return ui.progress({
        width = if axis == "x" then length else thickness,
        height = if axis == "x" then thickness else length,
        progress = 1,
        fill = color,
        track = color,
        radius = 3,
    })
end

local function make_pill(axis, index, item, selected, progressValue, direction, blockedDirection, progressVisibility, pillExpansion, width, height, workspaceSizeProgress)
    local fill = if selected then "surface_container_high" else "surface_container"
    local border = if selected then "primary" else "surface_container_highest"
    local progress = math.clamp(tonumber(progressValue) or 0, 0, 1)
    if axis == "y" and shrinkInactiveWorkspacePills then
        local squareSize = math.min(width, height)
        local expansion = math.clamp(workspaceSizeProgress or 0, 0, 1)
        width = squareSize + (width - squareSize) * expansion
        height = squareSize + (height - squareSize) * expansion
    end
    local progressOpacity = if dynamicProgressOpacity then progress else 1
    local iconSize = math.max(4, math.floor(math.min(width, height) * iconSizePercent / 100 + 0.5))
    local progressThickness = math.max(1, iconSize * progressThicknessPercent / 100)
    local expansion = (progressThickness + iconProgressGap) * pillExpansion
    local progressRunsHorizontally = if showProgressWhenInactive
        then widgetLayout == "horizontal" else axis == "x"
    if progressRunsHorizontally then
        width += expansion
    else
        height += expansion
    end
    local body = {}
    if axis == "x" then
        table.insert(body, app_icon(item.window.app_id, if progress > 0 then "on_primary" else "on_surface_variant", iconSize))
    else
        local workspaceName = if type(item.name) == "string"
            then string.match(item.name, "^%s*(.-)%s*$") or ""
            else ""
        local workspaceGlyph = workspaceGlyphs[workspaceName]
            or workspaceGlyphs[tostring(item.idx)]
        local workspaceLabel = if workspaceName ~= ""
            then string.upper(string.sub(workspaceName, 1, 1))
            else tostring(item.idx)
        local badgeContent = if workspaceGlyph ~= nil
            then ui.glyph({
                name = workspaceGlyph,
                size = iconSize * 0.7,
                color = if selected then "on_primary" else "on_surface",
            })
            else ui.label({
                text = workspaceLabel,
                fontSize = iconSize * 0.75,
                color = if selected then "on_primary" else "on_surface",
                textAlign = "center",
                width = iconSize,
                height = iconSize,
            })
        table.insert(body, ui.row({
            width = iconSize,
            height = iconSize,
            fill = if selected then "primary"
                elseif shrinkInactiveWorkspacePills then "surface_container"
                else "surface_container_highest",
            radius = math.min(workspaceBadgeRadius, iconSize / 3),
            align = "center",
            justify = "center",
        }, { badgeContent }))
    end

    local progressChildren = {}
    local progressWidget = nil
    if progressVisibility > 0 and axis == "x" then
        local progressWidth = math.max(1, width - (horizontalPillPadding * 2)
            - (progressRunsHorizontally and iconSize + iconProgressGap or 0)) * progressVisibility
        local launcherEdgeDirection = if launcherWorkspaceEdge == "start" then "left" else "right"
        local showLauncherGlyph = openLauncherAtWorkspaceEdge and blockedDirection == launcherEdgeDirection
        local launcherGlyphWidth = if showLauncherGlyph then iconSize + iconProgressGap else 0
        local trackWidth = math.max(1, progressWidth - launcherGlyphWidth)
        local warningWidth = if blockedDirection ~= "" and not showLauncherGlyph
            then math.min(4, trackWidth) else 0
        trackWidth -= warningWidth
        local fillWidth = trackWidth * progress
        local emptyWidth = trackWidth - fillWidth
        if blockedDirection == "left" and not showLauncherGlyph then
            table.insert(progressChildren, progress_segment("x", warningWidth, progressThickness, WARNING_COLOR))
        end
        if direction == "left" then
            if emptyWidth > 0 then
                table.insert(progressChildren, progress_segment("x", emptyWidth, progressThickness, "surface_container_highest"))
            end
            if fillWidth > 0 then
                table.insert(progressChildren, progress_segment("x", fillWidth, progressThickness, "primary"))
            end
        else
            if fillWidth > 0 then
                table.insert(progressChildren, progress_segment("x", fillWidth, progressThickness, "primary"))
            end
            if emptyWidth > 0 then
                table.insert(progressChildren, progress_segment("x", emptyWidth, progressThickness, "surface_container_highest"))
            end
        end
        if blockedDirection == "right" and not showLauncherGlyph then
            table.insert(progressChildren, progress_segment("x", warningWidth, progressThickness, WARNING_COLOR))
        end
        if showLauncherGlyph then
            local glyphWidget = ui.glyph({
                name = launcherGlyph,
                size = iconSize,
                color = "primary",
            })
            local glyphGap = ui.row({
                width = iconProgressGap,
                height = progressThickness,
            })
            if direction == "left" then
                table.insert(progressChildren, 1, glyphWidget)
                table.insert(progressChildren, 2, glyphGap)
            else
                table.insert(progressChildren, glyphGap)
                table.insert(progressChildren, glyphWidget)
            end
        end
        if #progressChildren == 0 then
            table.insert(progressChildren, ui.progress({
                width = progressWidth,
                height = progressThickness,
                progress = 0,
                fill = "primary",
                track = "surface_container_highest",
                radius = 3,
            }))
        end
        progressWidget = ui.row({
            width = progressWidth,
            height = progressThickness,
            opacity = progressOpacity,
            align = "center",
            gap = 0,
        }, progressChildren)
    elseif progressVisibility > 0 then
        local progressHeight = math.max(
            1,
            height - (verticalPillPadding * 2)
                - (not progressRunsHorizontally and iconSize + iconProgressGap or 0)
        ) * progressVisibility
        local warningHeight = if blockedDirection ~= "" then math.min(4, progressHeight) else 0
        local trackHeight = progressHeight - warningHeight
        local fillHeight = trackHeight * progress
        local emptyHeight = trackHeight - fillHeight
        if blockedDirection == "up" then
            table.insert(progressChildren, progress_segment("y", warningHeight, progressThickness, WARNING_COLOR))
        end
        if direction == "up" then
            if emptyHeight > 0 then
                table.insert(progressChildren, progress_segment("y", emptyHeight, progressThickness, "surface_container_highest"))
            end
            if fillHeight > 0 then
                table.insert(progressChildren, progress_segment("y", fillHeight, progressThickness, "primary"))
            end
        else
            if fillHeight > 0 then
                table.insert(progressChildren, progress_segment("y", fillHeight, progressThickness, "primary"))
            end
            if emptyHeight > 0 then
                table.insert(progressChildren, progress_segment("y", emptyHeight, progressThickness, "surface_container_highest"))
            end
        end
        if blockedDirection == "down" then
            table.insert(progressChildren, progress_segment("y", warningHeight, progressThickness, WARNING_COLOR))
        end
        if #progressChildren == 0 then
            table.insert(progressChildren, ui.progress({
                width = progressThickness,
                height = progressHeight,
                progress = 0,
                fill = "primary",
                track = "surface_container_highest",
                radius = 3,
            }))
        end
        progressWidget = ui.column({
            width = progressThickness,
            height = progressHeight,
            opacity = progressOpacity,
            align = "center",
            gap = 0,
        }, progressChildren)
    end

    if showProgressWhenInactive then
        if progressWidget ~= nil then
            table.insert(body, progressWidget)
        end
    else
        local icon = body[1]
        local children = {}
        if progressWidget ~= nil and (direction == "left" or direction == "up") then
            table.insert(children, progressWidget)
        end
        table.insert(children, icon)
        if progressWidget ~= nil and (direction == "right" or direction == "down") then
            table.insert(children, progressWidget)
        end
        body = {
            (if axis == "x" then ui.row else ui.column)({
                align = "center",
                justify = "center",
                gap = iconProgressGap * progressVisibility,
            }, children),
        }
    end

    local tooltip
    local onClick
    local pillPaddingV = if axis == "y" and shrinkInactiveWorkspacePills
        then 0 else verticalPillPadding
    if axis == "x" then
        local window = item.window
        tooltip = `{window.app_id or "Window"} · column {item.index} · click to focus`
        onClick = function()
            run_action("focus the window", { "focus-window", "--id", window.id })
        end
    else
        tooltip = `Workspace {item.idx} · click to switch`
        onClick = function()
            run_action("switch workspace", { "focus-workspace", item.idx })
        end
    end

    return arrange({
        key = `gesture-map-{axis}-{index}`,
        width = width,
        height = height,
        fill = fill,
        border = border,
        borderWidth = if selected then 1 else 0,
        radius = pillRadius,
        paddingH = horizontalPillPadding,
        paddingV = pillPaddingV,
        align = "center",
        justify = "center",
        gap = iconProgressGap * progressVisibility,
        onClick = onClick,
        tooltip = tooltip,
    }, body)
end

local function render_columns(workspace)
    local columns = workspace_columns(workspace)
    if #columns == 0 then
        local emptyWorkspace = ui.row({
            key = "gesture-map-x-empty",
            width = 28,
            height = 28,
            fill = "surface_container",
            border = "surface_container_highest",
            borderWidth = 1,
            radius = pillRadius,
            align = "center",
            justify = "center",
            onClick = if openLauncherOnEmptyWorkspace then run_launcher_opening_command else nil,
            tooltip = if openLauncherOnEmptyWorkspace
                then "Open the launcher on this empty workspace"
                else "No columns on the focused workspace",
        }, if openLauncherOnEmptyWorkspace
            then { ui.glyph({ name = "plus", size = 16, color = "on_surface_variant" }) }
            else {})
        return {
            emptyWorkspace,
        }
    end

    local totalWeight = 0
    local selectedIndex = nil
    for _, column in ipairs(columns) do
        totalWeight += if column.width > 0 then column.width else 1
    end
    for index, column in ipairs(columns) do
        for _, window in ipairs(column.windows) do
            if window.is_focused == true then
                selectedIndex = index
                break
            end
        end
        if selectedIndex ~= nil then
            break
        end
    end
    if selectedIndex == nil then
        for index, column in ipairs(columns) do
            if column.window ~= nil and column.window.id == workspace.active_window_id then
                selectedIndex = index
                break
            end
        end
    end

    local gesture = serviceStatus.gesture or {}
    local gestureOnOutput = focused_window_on_widget_output()
    local sourceKey = if selectedIndex ~= nil
        then `{workspace.id}:{columns[selectedIndex].index}` else nil
    local completingTrigger = gestureOnOutput and triggerCompletion ~= nil
        and (triggerCompletion.sourceKey == nil or triggerCompletion.sourceKey == sourceKey)
    if completingTrigger and triggerCompletion.sourceKey == nil then
        triggerCompletion.sourceKey = sourceKey
    end
    local axisProgressAllowed = axis_progress_allowed("x", gesture, completingTrigger)
    local progressDirection = if direction_offset(gesture.xDirection) ~= 0
        then gesture.xDirection
        else if completingTrigger then triggerCompletion.direction else progressAnimation.x.direction
    local progressTarget = progress_target(selectedIndex, progressDirection, #columns)
    local launcherEdgeDirection = if launcherWorkspaceEdge == "start" then "left" else "right"
    if completingTrigger and progressDirection == launcherEdgeDirection and progressTarget == nil
        and openLauncherAtWorkspaceEdge
        and not triggerCompletion.launcherTriggered
    then
        triggerCompletion.launcherTriggered = true
        if run_launcher_opening_command() then
            edgeLauncherFocus = focused_identity()
        end
    end
    local blockedDirection = if axisProgressAllowed
        and gestureOnOutput and (gesture.active == true or completingTrigger)
        and direction_offset(progressDirection) ~= 0
        and progressTarget == nil
        then progressDirection else ""
    local rawProgressValue = math.clamp(tonumber(gesture.xProgress) or 0, 0, 1)
    local rawProgress = if rawProgressValue > 0
        then math.max(PROGRESS_STEP, math.ceil(rawProgressValue / PROGRESS_STEP - 1e-6) * PROGRESS_STEP)
        else 0
    local progressEnabled = axisProgressAllowed and gestureOnOutput and (completingTrigger or (
        not suppressGestureProgress and gesture.active == true and direction_offset(gesture.xDirection) ~= 0
    ))
    local progressActive = axisProgressAllowed and gestureOnOutput and (
        (gesture.active == true and direction_offset(gesture.xDirection) ~= 0) or completingTrigger
    )
    local displayedProgress, displayedDirection = animate_progress(
        "x",
        if completingTrigger then 1 else rawProgress,
        progressDirection,
        progressEnabled,
        progressActive,
        sourceKey
    )
    local availableLength = math.max(0, widgetWidth - 2 * (#columns - 1))
    local result = {}
    for index, column in ipairs(columns) do
        local weight = if column.width > 0 then column.width else 1
        local minimumExtent = widgetWidth * targetMinWidthPercent / 100
        local extent = math.max(minimumExtent, availableLength * weight / math.max(1, totalWeight))
        local width = if widgetLayout == "vertical" then 28 else extent
        local height = if widgetLayout == "vertical" then extent else 28
        local pillKey = `{workspace.id}:{column.index}`
        local isTarget = index == selectedIndex
        local progressVisibility, pillExpansion, pillDirection = animate_pill_progress(
            "x",
            pillKey,
            showProgressWhenInactive or (isTarget and progressActive),
            isTarget and progressActive,
            if isTarget then displayedDirection else ""
        )
        table.insert(result, make_pill(
            "x",
            index,
            column,
            index == selectedIndex,
            if completingTrigger and index == selectedIndex then 1
                elseif index == selectedIndex then displayedProgress
                else 0,
            pillDirection,
            if isTarget then blockedDirection else "",
            progressVisibility,
            pillExpansion,
            width,
            height
        ))
    end
    return result
end

local function render_workspaces(items, allItems)
    if #items == 0 then
        return { ui.label({ text = "—", color = "on_surface_variant" }) }
    end

    local selectedIndex = nil
    for index, workspace in ipairs(items) do
        if workspace.is_active == true then
            selectedIndex = index
            break
        end
    end
    if selectedIndex == nil then
        for index, workspace in ipairs(items) do
            if workspace.is_focused == true then
                selectedIndex = index
                break
            end
        end
    end
    local gesture = serviceStatus.gesture or {}
    local gestureOnOutput = focused_window_on_widget_output()
    local sourceKey = if selectedIndex ~= nil then tostring(items[selectedIndex].id) else nil
    local completingTrigger = gestureOnOutput and triggerCompletion ~= nil
        and (triggerCompletion.sourceKey == nil or triggerCompletion.sourceKey == sourceKey)
    if completingTrigger and triggerCompletion.sourceKey == nil then
        triggerCompletion.sourceKey = sourceKey
    end
    local axisProgressAllowed = axis_progress_allowed("y", gesture, completingTrigger)
    local progressDirection = if direction_offset(gesture.yDirection) ~= 0
        then gesture.yDirection
        else if completingTrigger then triggerCompletion.direction else progressAnimation.y.direction
    local progressTargetExists = workspace_target_exists(
        if selectedIndex ~= nil then items[selectedIndex] else nil,
        allItems,
        progressDirection
    )
    local progressIndex = selectedIndex
    local blockedDirection = if axisProgressAllowed
        and gestureOnOutput and (gesture.active == true or completingTrigger)
        and direction_offset(progressDirection) ~= 0
        and not progressTargetExists
        then progressDirection else ""
    local rawProgressValue = math.clamp(tonumber(gesture.yProgress) or 0, 0, 1)
    local rawProgress = if rawProgressValue > 0
        then math.max(PROGRESS_STEP, math.ceil(rawProgressValue / PROGRESS_STEP - 1e-6) * PROGRESS_STEP)
        else 0
    local progressEnabled = axisProgressAllowed and gestureOnOutput and (completingTrigger or (
        not suppressGestureProgress and gesture.active == true and direction_offset(gesture.yDirection) ~= 0
    ))
    local progressActive = axisProgressAllowed and gestureOnOutput and (
        (gesture.active == true and direction_offset(gesture.yDirection) ~= 0) or completingTrigger
    )
    local displayedProgress, displayedDirection = animate_progress(
        "y",
        if completingTrigger then 1 else rawProgress,
        progressDirection,
        progressEnabled,
        progressActive,
        sourceKey
    )
    local result = {}
    for index, workspace in ipairs(items) do
        local isTarget = index == progressIndex
        local isSelected = index == selectedIndex
        local progressVisibility, pillExpansion, pillDirection = animate_pill_progress(
            "y",
            tostring(workspace.id),
            (showProgressWhenInactive and not (shrinkInactiveWorkspacePills and not isSelected))
                or (isTarget and progressActive),
            isTarget and progressActive,
            if isTarget then displayedDirection else ""
        )
        local workspaceSizeProgress = if shrinkInactiveWorkspacePills
            then animate_workspace_pill_size(tostring(workspace.id), isSelected)
            else 1
        table.insert(result, make_pill(
            "y",
            index,
            workspace,
            isSelected,
            if completingTrigger and index == selectedIndex then 1
                elseif index == progressIndex then displayedProgress
                else 0,
            pillDirection,
            if isTarget then blockedDirection else "",
            progressVisibility,
            pillExpansion,
            workspacePillWidth,
            workspacePillHeight,
            workspaceSizeProgress
        ))
    end
    return result
end

function render()
    local items = output_workspaces()
    local allItems = output_workspaces(true)
    local content
    local tooltip
    if AXIS == "x" then
        content = arrange({ key = "mxmouse-columns", gap = 2, align = "center" }, render_columns(active_workspace(items)))
        tooltip = "MX Mouse · focused workspace columns · click a pill to focus its window"
    else
        content = arrange({ key = "mxmouse-workspaces", gap = 2, align = "center" }, render_workspaces(items, allItems))
        tooltip = "MX Mouse · workspaces on this output · click a pill to switch"
    end
    barWidget.setVisible(true)
    barWidget.render(arrange({
        key = `mxmouse-gesture-map-{AXIS}`,
        align = "center",
        tooltip = errorMessage or tooltip,
    }, { content }))
end

function update()
    read_widget_settings()
    noctalia.setUpdateInterval(16)
    read_service_status()
    local now = noctalia.nowMs()
    if triggerCompletion ~= nil then
        local elapsed = now - triggerCompletion.startedAt
        if elapsed >= 48 and (triggerCompletion.layoutReady or elapsed >= 120) then
            triggerCompletion = nil
        end
    end
    if now - lastLayoutUpdateAt >= LAYOUT_REFRESH_INTERVAL_MS then
        refresh_layout()
    end
    render()
end

update()
