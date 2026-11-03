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
local LAYOUT_REFRESH_INTERVAL_MS = 300
local lastTriggerCount = nil
local errorMessage = nil
local suppressGestureProgress = false
local triggerCompletion = nil
local PROGRESS_STEP = 0.01
local PROGRESS_EASE_MS = 64
local WARNING_COLOR = "#f97316"
local widgetLayout = if AXIS == "y" then "vertical" else "horizontal"
local widgetWidth = 190
local targetMinWidthPercent = 10
local pillRadius = 6
local iconSizePercent = 70
local horizontalPillPadding = 2
local verticalPillPadding = 2
local progressThicknessPercent = 40
local iconProgressGap = 3
local workspaceGlyphs = {}
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
    widgetWidth = setting("widget_width", 190, 60, 600)
    targetMinWidthPercent = setting("target_min_width_percent", 10, 1, 50)
    pillRadius = setting("pill_radius", 6, 0, 24)
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
            }
        end
        refresh_layout()
    end
end

local function output_workspaces()
    local result = {}
    for _, workspace in ipairs(workspaces) do
        if type(workspace) == "table"
            and type(workspace.id) == "number"
            and type(workspace.idx) == "number"
            and (outputName == nil or outputName == "" or workspace.output == outputName)
        then
            table.insert(result, workspace)
        end
    end
    table.sort(result, function(left, right)
        return left.idx < right.idx
    end)
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
                    and workspace.output == outputName
                then
                    return true
                end
            end
            return false
        end
    end
    return false
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

local function make_pill(axis, index, item, selected, progressValue, direction, blockedDirection, width, height)
    local fill = if selected then "surface_container_high" else "surface_container"
    local border = if selected then "primary" else "surface_container_highest"
    local progress = math.clamp(tonumber(progressValue) or 0, 0, 1)
    local iconSize = math.max(4, math.floor(math.min(width, height) * iconSizePercent / 100 + 0.5))
    local progressThickness = math.max(1, iconSize * progressThicknessPercent / 100)
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
            fill = if selected then "primary" else "surface_container_highest",
            radius = math.min(pillRadius, iconSize / 3),
            align = "center",
            justify = "center",
        }, { badgeContent }))
    end

    local progressChildren = {}
    if axis == "x" then
        local progressWidth = math.max(1, width - (horizontalPillPadding * 2)
            - (widgetLayout == "horizontal" and iconSize + iconProgressGap or 0))
        local warningWidth = if blockedDirection ~= "" then math.min(4, progressWidth) else 0
        local trackWidth = progressWidth - warningWidth
        local fillWidth = trackWidth * progress
        local emptyWidth = trackWidth - fillWidth
        if blockedDirection == "left" then
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
        if blockedDirection == "right" then
            table.insert(progressChildren, progress_segment("x", warningWidth, progressThickness, WARNING_COLOR))
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
        table.insert(body, ui.row({
            width = progressWidth,
            height = progressThickness,
            align = "center",
            gap = 0,
        }, progressChildren))
    else
        local progressHeight = math.max(
            1,
            height - (verticalPillPadding * 2)
                - (widgetLayout == "vertical" and iconSize + iconProgressGap or 0)
        )
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
        table.insert(body, ui.column({
            width = progressThickness,
            height = progressHeight,
            align = "center",
            gap = 0,
        }, progressChildren))
    end

    local tooltip
    local onClick
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
        paddingV = verticalPillPadding,
        align = "center",
        justify = "center",
        gap = iconProgressGap,
        onClick = onClick,
        tooltip = tooltip,
    }, body)
end

local function render_columns(workspace)
    local columns = workspace_columns(workspace)
    if #columns == 0 then
        return {
            ui.row({
                key = "gesture-map-x-empty",
                width = 28,
                height = 28,
                fill = "surface_container",
                border = "surface_container_highest",
                borderWidth = 1,
                radius = pillRadius,
                tooltip = "No columns on the focused workspace",
            }),
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
    local progressDirection = if direction_offset(gesture.xDirection) ~= 0
        then gesture.xDirection
        else if completingTrigger then triggerCompletion.direction else progressAnimation.x.direction
    local progressTarget = progress_target(selectedIndex, progressDirection, #columns)
    local blockedDirection = if gestureOnOutput and (gesture.active == true or completingTrigger)
        and direction_offset(progressDirection) ~= 0
        and progressTarget == nil
        then progressDirection else ""
    local rawProgressValue = math.clamp(tonumber(gesture.xProgress) or 0, 0, 1)
    local rawProgress = if rawProgressValue > 0
        then math.max(PROGRESS_STEP, math.ceil(rawProgressValue / PROGRESS_STEP - 1e-6) * PROGRESS_STEP)
        else 0
    local progressEnabled = gestureOnOutput and (completingTrigger or (
        not suppressGestureProgress and gesture.active == true and direction_offset(gesture.xDirection) ~= 0
    ))
    local progressActive = gestureOnOutput and (gesture.active == true or completingTrigger)
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
        table.insert(result, make_pill(
            "x",
            index,
            column,
            index == selectedIndex,
            if completingTrigger and index == selectedIndex then 1
                elseif index == selectedIndex then displayedProgress
                else 0,
            displayedDirection,
            if index == selectedIndex then blockedDirection else "",
            width,
            height
        ))
    end
    return result
end

local function render_workspaces(items)
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
    local gesture = serviceStatus.gesture or {}
    local gestureOnOutput = focused_window_on_widget_output()
    local sourceKey = if selectedIndex ~= nil then tostring(items[selectedIndex].id) else nil
    local completingTrigger = gestureOnOutput and triggerCompletion ~= nil
        and (triggerCompletion.sourceKey == nil or triggerCompletion.sourceKey == sourceKey)
    if completingTrigger and triggerCompletion.sourceKey == nil then
        triggerCompletion.sourceKey = sourceKey
    end
    local availableLength = math.max(0, widgetWidth - 2 * (#items - 1))
    local progressDirection = if direction_offset(gesture.yDirection) ~= 0
        then gesture.yDirection
        else if completingTrigger then triggerCompletion.direction else progressAnimation.y.direction
    local progressTarget = progress_target(selectedIndex, progressDirection, #items)
    local blockedDirection = if gestureOnOutput and (gesture.active == true or completingTrigger)
        and direction_offset(progressDirection) ~= 0
        and progressTarget == nil
        then progressDirection else ""
    local rawProgressValue = math.clamp(tonumber(gesture.yProgress) or 0, 0, 1)
    local rawProgress = if rawProgressValue > 0
        then math.max(PROGRESS_STEP, math.ceil(rawProgressValue / PROGRESS_STEP - 1e-6) * PROGRESS_STEP)
        else 0
    local progressEnabled = gestureOnOutput and (completingTrigger or (
        not suppressGestureProgress and gesture.active == true and direction_offset(gesture.yDirection) ~= 0
    ))
    local progressActive = gestureOnOutput and (gesture.active == true or completingTrigger)
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
        table.insert(result, make_pill(
            "y",
            index,
            workspace,
            index == selectedIndex,
            if completingTrigger and index == selectedIndex then 1
                elseif index == selectedIndex then displayedProgress
                else 0,
            displayedDirection,
            if index == selectedIndex then blockedDirection else "",
            if widgetLayout == "vertical" then 26
                else math.max(widgetWidth * targetMinWidthPercent / 100, availableLength / #items),
            if widgetLayout == "vertical"
                then math.max(widgetWidth * targetMinWidthPercent / 100, availableLength / #items)
                else 26
        ))
    end
    return result
end

function render()
    local items = output_workspaces()
    local content
    local tooltip
    if AXIS == "x" then
        content = arrange({ key = "mxmouse-columns", gap = 2, align = "center" }, render_columns(active_workspace(items)))
        tooltip = "MX Mouse · focused workspace columns · click a pill to focus its window"
    else
        content = arrange({ key = "mxmouse-workspaces", gap = 2, align = "center" }, render_workspaces(items))
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
