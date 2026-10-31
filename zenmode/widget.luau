--!nonstrict

local active = false
local toggleZen = noctalia.getConfig("toggle_zen") == true
local outputName = barWidget.outputName() or noctalia.focusedOutputName()
local stateKey = if type(outputName) == "string" and outputName ~= ""
    then "zenmode.output." .. outputName
    else nil

local function render()
    barWidget.setGlyph("focus")
    barWidget.setTooltip(if toggleZen then "Toggle Zen Mode" else "Exit Zen Mode")
    barWidget.setVisible(toggleZen or active)
end

if stateKey ~= nil then
    active = noctalia.state.get(stateKey) == true
    noctalia.state.watch(stateKey, function(value)
        active = value == true
        render()
    end)
end

function update()
    noctalia.setUpdateInterval(1000)
    toggleZen = noctalia.getConfig("toggle_zen") == true
    render()
end

function onClick()
    if not toggleZen and not active then
        return
    end

    local event = if toggleZen then "toggle" else "exit"
    local started = noctalia.runAsync({
        "noctalia",
        "msg",
        "plugin",
        "ffngs/zenmode:service",
        "all",
        event,
        outputName or "",
    }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or `exit status {result.exitCode}`
            noctalia.notifyError("Zen Mode", `Could not {event} the focused window: {detail}`)
        end
    end, 10000)

    if not started then
        noctalia.notifyError("Zen Mode", "Could not start Noctalia to update the focused window.")
    end
end

render()
