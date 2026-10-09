-- FAHud: in-game Farm Agent panel. Alt+K cycles STATUS -> PLAN -> FIELDS -> LOG -> hidden.
-- Draws with the engine's renderText/drawFilledRect, so it needs no GUI XML.

FAHud = {}
local FAHud_mt = { __index = FAHud }

FAHud.VIEWS = { "STATUS", "PLAN", "FIELDS", "LOG", "HIDDEN" }

local X = 0.012
local TOP = 0.93
local WIDTH = 0.30
local LINE = 0.0155
local SIZE = 0.0115
local SIZE_TITLE = 0.014

local STATE_COLORS = {
    RUNNING = { 0.55, 0.85, 1.0 },
    DONE = { 0.45, 0.9, 0.45 },
    FAILED = { 1.0, 0.4, 0.35 },
    ESCALATED = { 1.0, 0.65, 0.2 },
    RECOVERING = { 1.0, 0.85, 0.3 },
    VERIFYING = { 0.8, 0.8, 1.0 },
    CANCELLED = { 0.6, 0.6, 0.6 },
    PAUSED_BY_PLAYER = { 0.8, 0.7, 1.0 },
}

local LEVEL_COLORS = {
    WARN = { 1.0, 0.8, 0.3 },
    ERROR = { 1.0, 0.4, 0.35 },
    ATTENTION = { 1.0, 0.6, 0.2 },
    ACTION = { 0.6, 0.9, 1.0 },
    DECISION = { 0.85, 0.85, 1.0 },
}

function FAHud.new(agent)
    local self = setmetatable({}, FAHud_mt)
    self.agent = agent
    self.viewIndex = 1
    return self
end

function FAHud:cycleView()
    self.viewIndex = (self.viewIndex % #FAHud.VIEWS) + 1
end

function FAHud:getView()
    return FAHud.VIEWS[self.viewIndex]
end

function FAHud:setView(name)
    for i, v in ipairs(FAHud.VIEWS) do
        if v == name then
            self.viewIndex = i
        end
    end
end

local function truncate(text, maxChars)
    text = tostring(text or "")
    if #text > maxChars then
        return text:sub(1, maxChars - 1) .. "~"
    end
    return text
end

-- Line-based layout helper.
local function newCanvas()
    return { y = TOP, lines = {} }
end

local function addLine(canvas, text, color, bold, size, indent, bar)
    table.insert(canvas.lines, { text = text, color = color, bold = bold, size = size or SIZE, indent = indent or 0, bar = bar })
end

local function render(canvas)
    local height = #canvas.lines * LINE + 0.012
    drawFilledRect(X - 0.006, TOP - height + LINE, WIDTH + 0.012, height, 0, 0, 0, 0.62)
    local y = TOP
    for _, line in ipairs(canvas.lines) do
        local c = line.color or { 1, 1, 1 }
        setTextColor(c[1], c[2], c[3], 1)
        setTextBold(line.bold == true)
        renderText(X + line.indent, y, line.size, line.text)
        if line.bar ~= nil then
            local bx, bw = X + 0.20, 0.09
            drawFilledRect(bx, y + 0.002, bw, 0.007, 0.25, 0.25, 0.25, 0.9)
            drawFilledRect(bx, y + 0.002, bw * math.max(0, math.min(1, line.bar)), 0.007, 0.45, 0.85, 0.45, 0.95)
        end
        y = y - LINE
    end
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

function FAHud:draw()
    local view = self:getView()
    if view == "HIDDEN" then
        return
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    local canvas = newCanvas()
    local agent = self.agent
    local tm = agent.taskManager

    local header = "FARM AGENT"
    if agent.autopilot then
        header = header .. "  [AUTOPILOT]"
    end
    if tm.paused then
        header = header .. "  [PAUSED]"
    end
    header = header .. "  - " .. view .. "  (Alt+K)"
    addLine(canvas, header, { 1, 1, 1 }, true, SIZE_TITLE)
    local link = agent.bridge:isOnline() and "Claude: connected" or "Claude: offline (local parser)"
    addLine(canvas, link, agent.bridge:isOnline() and { 0.5, 0.9, 0.5 } or { 0.7, 0.7, 0.7 })

    if view == "STATUS" then
        self:drawStatus(canvas)
    elseif view == "PLAN" then
        self:drawPlan(canvas)
    elseif view == "FIELDS" then
        self:drawFields(canvas)
    elseif view == "LOG" then
        self:drawLog(canvas)
    end
    render(canvas)
end

function FAHud:drawStatus(canvas)
    local agent = self.agent
    local tm = agent.taskManager
    addLine(canvas, "Goal: " .. truncate(agent.goalText or "(none - press Alt+J)", 52), { 1, 0.95, 0.7 })
    addLine(canvas, "State: " .. tostring(agent.phase) .. " / " .. tostring(tm.status))

    local active = 0
    for _, view in ipairs(tm:getTaskViews()) do
        if view.action ~= "REPORT" then
            active = active + 1
            local color = STATE_COLORS[view.state] or { 0.85, 0.85, 0.85 }
            local showBar = view.action == "HARVEST_FIELD" and (view.state == "RUNNING" or view.state == "RECOVERING" or view.state == "DONE")
            addLine(canvas, truncate(string.format("%s %s", view.id, view.label), 34), color, false, SIZE, 0, showBar and view.progress or nil)
            local detail = view.state
            if view.substate ~= nil and view.state == "RUNNING" then
                detail = view.substate
            end
            if view.vehicle ~= nil then
                detail = detail .. " - " .. view.vehicle
            end
            addLine(canvas, truncate(detail, 50), { 0.75, 0.75, 0.75 }, false, SIZE * 0.92, 0.008)
            if view.note ~= nil and view.note ~= "" and view.state ~= "DONE" then
                addLine(canvas, truncate(view.note, 54), { 0.65, 0.65, 0.65 }, false, SIZE * 0.88, 0.008)
            end
        end
    end
    if active == 0 then
        addLine(canvas, "No active tasks.", { 0.7, 0.7, 0.7 })
    end

    if #tm.attention > 0 then
        addLine(canvas, "ATTENTION", { 1, 0.6, 0.2 }, true)
        for i = math.max(1, #tm.attention - 3), #tm.attention do
            addLine(canvas, truncate(tm.attention[i].text, 56), { 1, 0.75, 0.4 }, false, SIZE * 0.92)
        end
    end
    addLine(canvas, string.format("Workers %d/%d   Delivered %.0f l   Fields done %d",
        agent.aiActive or 0, agent.aiLimit or 0, tm.stats.delivered, tm.stats.fieldsDone), { 0.7, 0.7, 0.7 })
    addLine(canvas, "Alt+J command  Alt+L pause  Alt+End stop all", { 0.55, 0.55, 0.55 }, false, SIZE * 0.88)
end

function FAHud:drawPlan(canvas)
    local tm = self.agent.taskManager
    if tm.plan == nil then
        addLine(canvas, "No plan.", { 0.7, 0.7, 0.7 })
        return
    end
    addLine(canvas, truncate(tm.plan.summary or "", 56), { 1, 0.95, 0.7 })
    for i, view in ipairs(tm:getTaskViews()) do
        local mark = view.state == "DONE" and "[x]" or (view.state == "RUNNING" and "[>]" or "[ ]")
        local deps = ""
        if view.deps ~= nil and #view.deps > 0 and #view.deps <= 4 then
            deps = " <- " .. table.concat(view.deps, ",")
        elseif view.deps ~= nil and #view.deps > 4 then
            deps = " <- all"
        end
        addLine(canvas, truncate(string.format("%d. %s %s %s%s", i, mark, view.id, view.label, deps), 56),
            STATE_COLORS[view.state] or { 0.85, 0.85, 0.85 })
    end
    for _, w in ipairs(tm.plan.warnings or {}) do
        addLine(canvas, truncate("! " .. w, 56), { 1, 0.8, 0.3 }, false, SIZE * 0.92)
    end
end

-- One line per owned field: crop, state, and what the brain thinks it needs.
function FAHud:drawFields(canvas)
    local snapshot = self.agent.farmState and self.agent.farmState.snapshot
    if snapshot == nil or #(snapshot.fields or {}) == 0 then
        addLine(canvas, "No scan yet - menu > 'Show field overview'.", { 0.7, 0.7, 0.7 })
        return
    end
    local _, busyFields = self.agent.taskManager:getBusy()
    for i, f in ipairs(snapshot.fields) do
        if i > 18 then
            addLine(canvas, string.format("... %d more fields", #snapshot.fields - 18), { 0.6, 0.6, 0.6 })
            break
        end
        local needs = {}
        if (f.readyFraction or 0) >= FAPlanner.MIN_READY_FRACTION and f.state == "READY_TO_HARVEST" then
            table.insert(needs, "harvest")
        end
        for op, _ in pairs(FABrain.fieldNeeds(f)) do
            table.insert(needs, FABrain.OP_TITLES[op] or op)
        end
        table.sort(needs)
        local color = busyFields[f.id] and { 0.55, 0.85, 1.0 } or (#needs > 0 and { 1, 0.9, 0.6 } or { 0.75, 0.75, 0.75 })
        addLine(canvas, truncate(string.format("%-4s %-9s %-15s %s%s", f.name, tostring(f.crop or "-"), tostring(f.state),
            #needs > 0 and ("needs: " .. table.concat(needs, ", ")) or "ok", busyFields[f.id] and "  [working]" or ""), 62),
            color, false, SIZE * 0.9)
    end
end

function FAHud:drawLog(canvas)
    for _, entry in ipairs(FALog.getRecent(22)) do
        local color = LEVEL_COLORS[entry.level] or { 0.85, 0.85, 0.85 }
        addLine(canvas, truncate(string.format("%s %s", entry.time, entry.text), 60), color, false, SIZE * 0.92)
    end
end
