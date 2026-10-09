-- FarmAgent: wires the layers together.
--
--   player text --> FAIntent (control, always local) --+--> stop / pause / resume
--                                                     |
--                   Claude companion (via FABridge) --+--> objective or task list
--                   or local FAIntent fallback        |
--                                                     v
--   FAFieldScanner + FAFarmState --> FAPlanner --> FAValidator --> FATaskManager --> FAJobAdapter --> vanilla AI

FarmAgent = {}
local FarmAgent_mt = { __index = FarmAgent }

FarmAgent.BRIDGE_FOLDER = "modSettings/FS25_FarmAgent/"
FarmAgent.IDLE_STATE_REFRESH_MS = 60000
FarmAgent.AUTOPILOT_INTERVAL_MS = 30000   -- autopilot re-checks the farm at least this often (real time)
FarmAgent.AUTOPILOT_EVENT_DELAY_MS = 2000  -- ...and this soon after a machine becomes free

FarmAgent.PHASE = {
    IDLE = "IDLE",
    WAITING_FOR_CLAUDE = "WAITING_FOR_CLAUDE",
    SCANNING = "SCANNING",
    EXECUTING = "EXECUTING",
    DONE = "DONE",
}

function FarmAgent.new(modDirectory, modName)
    local self = setmetatable({}, FarmAgent_mt)
    self.modDirectory = modDirectory
    self.modName = modName
    self.enabled = false
    self.phase = FarmAgent.PHASE.IDLE
    self.goalText = nil
    self.idleRefreshTimer = 0
    self.aiTimer = 0
    self.autopilot = false
    self.autopilotTimer = 0
    self.autopilotScanning = false
    -- What the autopilot may do. SEED uses seedCrop: "REPLANT" = the crop last harvested on
    -- that field (from farm memory), or a crop name chosen in the menu.
    self.autopilotSettings = {
        harvest = true,
        ops = { FERTILIZE = true, LIME = true, PLOW = true, CULTIVATE = true, SEED = true },
        seedCrop = "REPLANT",
    }
    self.memorySaveTimer = 0
    self.cropCache = {}
    return self
end

-- Player settings live in the farm memory (per savegame).
function FarmAgent:applySettings()
    local m = self.memory
    local ops = self.autopilotSettings.ops
    ops.FERTILIZE = m:getSetting("autoFertilize", true)
    ops.LIME = m:getSetting("autoLime", true)
    local seed = m:getSetting("seedCrop", "REPLANT")
    self.autopilotSettings.seedCrop = seed ~= "OFF" and seed or nil
    ops.SEED = seed ~= "OFF"
end

-- Operations allowed for autopilot and "do all field work" (skip fertilizing / liming).
function FarmAgent:allowedOps()
    local ops = {}
    for op, on in pairs(self.autopilotSettings.ops) do ops[op] = on end
    return ops
end

function FarmAgent:toggleSetting(key, op, label)
    local value = not self.memory:getSetting(key, true)
    self.memory:setSetting(key, value)
    self.autopilotSettings.ops[op] = value
    self.memory:save()
    FALog.decision("SETTINGS", "%s: %s (autopilot and 'do all field work'; a direct command still works).", label, value and "ON" or "OFF")
    FAGameAdapter.notify(string.format("%s %s.", label, value and "ON" or "OFF"), false)
end

-- Called by the task manager when a machine becomes free (job done, parked, ...):
-- the autopilot looks for new work right away instead of waiting for its timer.
function FarmAgent:onWorkFreed()
    if self.autopilot then
        self.autopilotTimer = math.max(self.autopilotTimer, FarmAgent.AUTOPILOT_INTERVAL_MS - FarmAgent.AUTOPILOT_EVENT_DELAY_MS)
    end
end

-- Field-scan context (ground types, soil limits); refreshed with every snapshot.
function FarmAgent:getSoilContext()
    if self.soilContext == nil then
        self.soilContext = FAFarmState.soilContext()
    end
    return self.soilContext
end

-- One memory file per map + savegame slot.
function FarmAgent:memoryPath()
    local info = g_currentMission.missionInfo or {}
    local key = tostring(info.mapTitle or "map")
    if info.savegameDirectory ~= nil then
        key = key .. "_" .. (tostring(info.savegameDirectory):match("([^/\\]+)$") or "save")
    end
    key = key:gsub("[^%w_%-]", "_")
    return getUserProfileAppPath() .. FarmAgent.BRIDGE_FOLDER .. "memory_" .. key .. ".xml"
end

-- Crop description by FS25 fruit name (cached).
function FarmAgent:getCrop(name)
    if name == nil then
        return nil
    end
    local crop = self.cropCache[name]
    if crop == nil then
        crop = FAGameAdapter.getFruitTypeByName(name)
        self.cropCache[name] = crop
    end
    return crop
end

-- Mod event listener -----------------------------------------------------------

-- Every entry point the game calls is wrapped: loadMap runs inside the game's map-loading
-- callback, so an uncaught error there stalls the loading screen. A Farm Agent failure must
-- only ever disable Farm Agent.
function FarmAgent:disableAfterError(where, err)
    self.enabled = false
    FALog.error("AGENT", "Farm Agent disabled after an error in %s: %s", where, tostring(err))
    if self.taskManager ~= nil then
        pcall(self.taskManager.stopAll, self.taskManager, "Farm Agent error")
    end
    if g_currentMission ~= nil then
        pcall(FAGameAdapter.notify, "disabled after an internal error (see log.txt).", true)
    end
end

function FarmAgent:loadMap(filename)
    local ok, err = pcall(self.loadMapInternal, self, filename)
    if not ok then
        self:disableAfterError("loadMap", err)
    end
end

function FarmAgent:loadMapInternal(filename)
    if g_currentMission == nil or not FAGameAdapter.isServer() then
        FALog.warn("AGENT", "Farm Agent needs to run on the host/singleplayer; disabled.")
        return
    end
    self.scanner = FAFieldScanner.new()
    self.bridge = FABridge.new(getUserProfileAppPath() .. FarmAgent.BRIDGE_FOLDER)
    self.bridge:init(getDate("%Y%m%d%H%M%S"))
    self.memory = FAMemory.new(self:memoryPath(), FABridge.readXmlPayload, FABridge.writeFile)
    if self.memory:load() then
        FALog.info("MEMORY", "Farm memory loaded (%s).", self.memory.path)
    end
    self:applySettings()
    self.farmState = FAFarmState.new(self.scanner, self.memory)
    self.taskManager = FATaskManager.new(self)
    self.farmState.isParking = function(id) return self.taskManager:isParking(id) end
    self.hud = FAHud.new(self)
    self.bridgeHandlers = {
        onCommand = function(cmd) self:onBridgeCommand(cmd) end,
        onRequestTimeout = function(request) self:onRequestTimeout(request) end,
        buildState = function() return self:buildBridgeState() end,
    }

    g_messageCenter:subscribe(MessageType.AI_JOB_STOPPED, self.onAIJobStopped, self)

    addConsoleCommand("faCommand", "Farm Agent: give a command, e.g. faCommand harvest all ready wheat fields", "consoleCommand", self)
    addConsoleCommand("faStatus", "Farm Agent: print status", "consoleStatus", self)
    addConsoleCommand("faScan", "Farm Agent: scan owned fields and print crop state", "consoleScan", self)
    addConsoleCommand("faStopAll", "Farm Agent: stop all agent work", "consoleStopAll", self)
    addConsoleCommand("faPause", "Farm Agent: pause dispatching", "consolePause", self)
    addConsoleCommand("faResume", "Farm Agent: resume and retry escalated tasks", "consoleResume", self)

    self.enabled = true
    FALog.info("AGENT", "Farm Agent 0.4 (Milestone 3) loaded. Alt+J opens the menu.")
end

function FarmAgent:deleteMap()
    if self.memory ~= nil then
        pcall(self.memory.save, self.memory)
    end
    pcall(g_messageCenter.unsubscribeAll, g_messageCenter, self)
    for _, name in ipairs({ "faCommand", "faStatus", "faScan", "faStopAll", "faPause", "faResume" }) do
        pcall(removeConsoleCommand, name)
    end
    pcall(FAJobAdapter.reset)
    self.enabled = false
end

function FarmAgent:update(dt)
    if not self.enabled then
        return
    end
    local ok, err = pcall(self.updateInternal, self, dt)
    if not ok then
        self:disableAfterError("update", err)
    end
end

function FarmAgent:updateInternal(dt)
    self.bridge:update(dt, self.bridgeHandlers)

    self.scanner:update(1) -- one field (~80 FieldState samples) per frame
    if self.phase == FarmAgent.PHASE.SCANNING and self.scanner:isIdle() then
        self:planAndExecute()
    end
    if self.refreshWhenScanned and self.scanner:isIdle() and self.farmId ~= nil then
        self.refreshWhenScanned = false
        self.soilContext = nil
        self.farmState:refresh(self.farmId, nil)
    end

    self.taskManager:update(dt)

    self.aiTimer = self.aiTimer + dt
    if self.aiTimer > 2000 then
        self.aiTimer = 0
        self.aiActive, self.aiLimit = FAGameAdapter.getAILimit()
    end

    self:updateAutopilot(dt)

    self.memorySaveTimer = self.memorySaveTimer + dt
    if self.memorySaveTimer > 30000 then
        self.memorySaveTimer = 0
        self.memory:save()
    end

    -- Keep the state model fresh for Claude while idle, so it can answer questions
    -- like "which fields are ready?" from real data.
    if not self.autopilot and self.phase ~= FarmAgent.PHASE.SCANNING and self.phase ~= FarmAgent.PHASE.EXECUTING and self.bridge:isOnline() then
        self.idleRefreshTimer = self.idleRefreshTimer + dt
        if self.idleRefreshTimer > FarmAgent.IDLE_STATE_REFRESH_MS then
            self.idleRefreshTimer = 0
            self:backgroundRefresh()
        end
    end
end

function FarmAgent:draw()
    if self.enabled and self.hud ~= nil and not g_gui:getIsGuiVisible() then
        local ok, err = pcall(self.hud.draw, self.hud)
        if not ok then
            self.hud = nil -- keep the agent running, drop only the panel
            FALog.error("HUD", "Panel disabled after an error: %s", tostring(err))
        end
    end
end

function FarmAgent:keyEvent(unicode, sym, modifier, isDown) end
function FarmAgent:mouseEvent(posX, posY, isDown, isUp, button) end

-- Input ------------------------------------------------------------------------

function FarmAgent:registerActionEvents()
    local ok, err = pcall(self.registerActionEventsInternal, self)
    if not ok then
        FALog.error("INPUT", "Could not register Farm Agent hotkeys: %s (console commands still work)", tostring(err))
    end
end

function FarmAgent:registerActionEventsInternal()
    local actions = {
        { InputAction.FA_COMMAND, FarmAgent.onInputCommand },
        { InputAction.FA_TOGGLE_PANEL, FarmAgent.onInputTogglePanel },
        { InputAction.FA_PAUSE, FarmAgent.onInputPause },
        { InputAction.FA_STOP_ALL, FarmAgent.onInputStopAll },
    }
    for _, a in ipairs(actions) do
        if a[1] ~= nil then
            local _, eventId = g_inputBinding:registerActionEvent(a[1], self, a[2], false, true, false, true)
            if eventId ~= nil then
                g_inputBinding:setActionEventTextVisibility(eventId, false)
            end
        end
    end
end

-- Alt+J: command menu (vanilla OptionDialog - a list of buttons, no custom GUI XML).
function FarmAgent:onInputCommand()
    if not self.enabled or g_gui:getIsGuiVisible() then
        return
    end
    local ok, err = pcall(self.showMenu, self)
    if not ok then
        FALog.error("MENU", "Menu failed (%s); opening the text box instead.", tostring(err))
        self:showTextInput()
    end
end

function FarmAgent:showTextInput()
    TextInputDialog.show(FarmAgent.onCommandDialogClosed, self, "", "Farm Agent - what should the farm do?", nil, 200, g_i18n:getText("button_ok"))
end

-- Menu entries: { text, action } - built fresh so labels show the current state.
function FarmAgent:buildMenu()
    local tm = self.taskManager
    local seed = self.autopilotSettings.seedCrop
    local entries = {
        { "Harvest all ready crops", function() self:submitObjective({ type = "HARVEST_READY_FIELDS", allCrops = true }, "Harvest all ready crops") end },
        { "Prepare harvested fields (plow or cultivate)", function() self:submitObjective({ type = "FIELD_WORK", op = "PREPARE" }, "Prepare fields") end },
        { "Plant a crop...", function() self:showPlantMenu() end },
        { "Replant the last crop on prepared fields", function() self:submitObjective({ type = "FIELD_WORK", op = "SEED", crop = "REPLANT" }, "Replant fields") end },
        { "Fertilize growing crops", function() self:submitObjective({ type = "FIELD_WORK", op = "FERTILIZE" }, "Fertilize") end },
        { "Spread lime where needed", function() self:submitObjective({ type = "FIELD_WORK", op = "LIME" }, "Lime") end },
        { "Do all field work the farm needs now", function() self:submitObjective({ type = "FARM_WORK" }, "All field work") end },
        { self.autopilot and "Autopilot: ON  (turn off)" or "Autopilot: OFF  (turn on - take care of the farm)",
            function() self:applyControl(self.autopilot and "AUTOPILOT_OFF" or "AUTOPILOT_ON") end },
        { "Autopilot planting: " .. (seed == nil and "off" or (seed == "REPLANT" and "replant last crop" or seed)) .. "  (change)",
            function() self:cycleAutopilotPlanting() end },
        { "Auto fertilizing: " .. (self.autopilotSettings.ops.FERTILIZE and "ON  (turn off)" or "OFF  (turn on)"),
            function() self:toggleSetting("autoFertilize", "FERTILIZE", "Auto fertilizing") end },
        { "Auto liming: " .. (self.autopilotSettings.ops.LIME and "ON  (turn off)" or "OFF  (turn on)"),
            function() self:toggleSetting("autoLime", "LIME", "Auto liming") end },
        { tm.paused and "Resume Farm Agent" or (tm:hasTasksWaitingForPlayer() and "Hand stopped/stuck work back (resume)" or "Pause (no new work)"),
            function() self:onInputPause() end },
        { "Stop everything", function() self:applyControl("STOP_ALL") end },
        { "Show field overview (panel)", function() self.hud:setView("FIELDS"); self:backgroundRefresh() end },
        { "Type a command...", function() self:showTextInput() end },
    }
    return entries
end

function FarmAgent:showMenu()
    local entries = self:buildMenu()
    local texts = {}
    for i, e in ipairs(entries) do texts[i] = e[1] end
    OptionDialog.show(function(item)
        if item ~= nil and item > 0 and entries[item] ~= nil then
            FALog.info("PLAYER", "Menu: %s", entries[item][1])
            local ok, err = pcall(entries[item][2])
            if not ok then
                FALog.error("MENU", "Menu action failed: %s", tostring(err))
            end
        end
    end, "Farm Agent", self:menuSubtitle(), texts)
end

function FarmAgent:menuSubtitle()
    local tm = self.taskManager
    local running = 0
    for _, t in ipairs(tm.tasks) do
        if t.state == "RUNNING" then running = running + 1 end
    end
    return string.format("%d job(s) running%s%s", running, self.autopilot and ", autopilot on" or "",
        #tm.attention > 0 and string.format(", %d need you", #tm.attention) or "")
end

-- Crops that can be sown now and that at least one seeder can sow.
function FarmAgent:plantableCropsWithSeeders()
    local seederCrops = {}
    for _, record in ipairs(FAGameAdapter.listVehicles(FAGameAdapter.getFarmId())) do
        for _, tool in ipairs(record.tools or {}) do
            for _, fruitIndex in ipairs(tool.seeds or {}) do seederCrops[fruitIndex] = true end
        end
    end
    local result = {}
    for _, crop in ipairs(FAGameAdapter.listHarvestableCrops()) do
        if seederCrops[crop.index] and FAGameAdapter.isPlantableNow(crop) then
            table.insert(result, crop)
        end
    end
    return result
end

function FarmAgent:showPlantMenu()
    local crops = self:plantableCropsWithSeeders()
    if #crops == 0 then
        FAGameAdapter.notify("no crop your seeders can sow is in season now (or no seeder is attached to a tractor).", true)
        return
    end
    local texts = {}
    for i, c in ipairs(crops) do texts[i] = c.title end
    OptionDialog.show(function(item)
        if item ~= nil and item > 0 and crops[item] ~= nil then
            local crop = crops[item]
            FALog.info("PLAYER", "Menu: plant %s", crop.title)
            self:submitObjective({ type = "FIELD_WORK", op = "SEED", crop = crop.name }, "Plant " .. crop.title)
        end
    end, "Farm Agent - plant which crop?", "In season now, and your seeders can sow it.", texts)
end

-- Autopilot planting: replant -> each in-season crop -> off -> replant ...
function FarmAgent:cycleAutopilotPlanting()
    local options = { "REPLANT" }
    for _, crop in ipairs(self:plantableCropsWithSeeders()) do table.insert(options, crop.name) end
    table.insert(options, false)
    local current = self.autopilotSettings.seedCrop or false
    local nextIndex = 1
    for i, o in ipairs(options) do
        if o == current then nextIndex = (i % #options) + 1 end
    end
    local value = options[nextIndex]
    self.autopilotSettings.seedCrop = value or nil
    self.autopilotSettings.ops.SEED = value ~= false
    self.memory:setSetting("seedCrop", value == false and "OFF" or value)
    self.memory:save()
    FALog.decision("AUTOPILOT", "Autopilot planting: %s.", value == false and "off" or (value == "REPLANT" and "replant last crop" or value))
    FAGameAdapter.notify("autopilot planting: " .. (value == false and "off" or (value == "REPLANT" and "replant last crop" or value)), false)
end

-- Menu buttons go straight to a structured objective (no parsing involved).
function FarmAgent:submitObjective(objective, label)
    self.goalText = label
    self:applyObjective(objective)
end

function FarmAgent:onCommandDialogClosed(text, clickOk)
    if clickOk and text ~= nil and text ~= "" then
        self:submitCommand(text)
    end
end

function FarmAgent:onInputTogglePanel()
    if self.enabled then
        self.hud:cycleView()
    end
end

function FarmAgent:onInputPause()
    if not self.enabled then
        return
    end
    -- Alt+L hands work back whenever something is waiting on the player; otherwise it pauses.
    if self.taskManager.paused or self.taskManager:hasTasksWaitingForPlayer() then
        self:applyControl("RESUME")
    else
        self:applyControl("PAUSE")
    end
end

function FarmAgent:onInputStopAll()
    if self.enabled then
        self:applyControl("STOP_ALL")
    end
end

-- Commands -------------------------------------------------------------------------

function FarmAgent:submitCommand(text)
    FALog.info("PLAYER", "\"%s\"", text)

    -- Player authority: control commands never wait for the LLM.
    local control = FAIntent.parseControl(text)
    if control ~= nil then
        self:applyControl(control.op)
        return
    end

    self.goalText = text
    if self.bridge:isOnline() then
        local request = self.bridge:sendRequest(text)
        self.phase = FarmAgent.PHASE.WAITING_FOR_CLAUDE
        FALog.action("AGENT", "Asked Claude to interpret request #%d.", request.id)
        return
    end
    self:applyLocalParse(text, "Claude companion offline - using the local command parser.")
end

function FarmAgent:applyLocalParse(text, why)
    if why ~= nil then
        FALog.info("AGENT", "%s", why)
    end
    local objective, reason = FAIntent.parse(text, FAGameAdapter.listFruitTypeNames())
    if objective == nil then
        self.phase = FarmAgent.PHASE.IDLE
        FALog.warn("AGENT", "%s", reason)
        FAGameAdapter.notify(reason, true)
        return
    end
    if objective.type == "CONTROL" then
        self:applyControl(objective.op)
        return
    end
    self:applyObjective(objective)
end

function FarmAgent:onRequestTimeout(request)
    if self.phase == FarmAgent.PHASE.WAITING_FOR_CLAUDE then
        self:applyLocalParse(request.text, string.format("Claude did not answer request #%d in time - using the local parser.", request.id))
    end
end

function FarmAgent:applyControl(op)
    local tm = self.taskManager
    if op == "STOP_ALL" then
        if self.autopilot then
            self:setAutopilot(false)
        end
        tm:stopAll("player command")
        self.phase = FarmAgent.PHASE.IDLE
        FAGameAdapter.notify("stopped all agent work.", false)
    elseif op == "AUTOPILOT_ON" then
        self:setAutopilot(true)
    elseif op == "AUTOPILOT_OFF" then
        self:setAutopilot(false)
    elseif op == "PAUSE" then
        tm:pause()
        FAGameAdapter.notify("paused (running workers continue).", false)
    elseif op == "RESUME" then
        tm:resume()
        if tm.status == "RUNNING" then
            self.phase = FarmAgent.PHASE.EXECUTING
        end
        FAGameAdapter.notify("resumed.", false)
    elseif op == "STATUS" then
        self:consoleStatus()
    end
end

-- Autopilot ------------------------------------------------------------------------

function FarmAgent:setAutopilot(on)
    if on == self.autopilot then
        return
    end
    self.autopilot = on
    if on then
        self.goalText = "Autopilot: take care of the farm"
        self.autopilotTimer = FarmAgent.AUTOPILOT_INTERVAL_MS -- first check right away
        if self.taskManager:hasActiveWork() then
            self.taskManager.continuous = true
        end
        FALog.decision("AUTOPILOT", "Autopilot ON: every %d s (and whenever a machine becomes free) every idle machine gets the most useful job it can do now - harvest, plow/cultivate, plant, fertilize, lime.",
            FarmAgent.AUTOPILOT_INTERVAL_MS / 1000)
        FAGameAdapter.notify("autopilot ON - Farm Agent keeps your machines busy. Say 'autopilot off' to stop.", false)
    else
        self.autopilotScanning = false
        self.taskManager.continuous = false -- running work finishes normally, nothing new starts
        FALog.decision("AUTOPILOT", "Autopilot OFF: running work finishes, no new work is started.")
        FAGameAdapter.notify("autopilot OFF.", false)
    end
end

function FarmAgent:updateAutopilot(dt)
    if not self.autopilot or self.taskManager.paused or self.phase == FarmAgent.PHASE.SCANNING then
        return
    end
    if self.autopilotScanning then
        if self.scanner:isIdle() then
            self.autopilotScanning = false
            self:autopilotStep()
        end
        return
    end
    self.autopilotTimer = self.autopilotTimer + dt
    if self.autopilotTimer >= FarmAgent.AUTOPILOT_INTERVAL_MS then
        self.autopilotTimer = 0
        local farmId = FAGameAdapter.getFarmId()
        if farmId == nil then
            return
        end
        self.farmId = farmId
        self.farmState:loadFields(farmId)
        self.scanner:requestAll()
        self.autopilotScanning = true
    end
end

-- One autopilot decision round on a fresh scan.
function FarmAgent:autopilotStep()
    local tm = self.taskManager
    local snapshot = self.farmState:refresh(self.farmId, nil)
    local busyVehicles, busyFields = tm:getBusy()
    local tasks, decisions = FABrain.autopilotStep(snapshot, busyVehicles, busyFields, FAPlanner.newIdGenerator(#tm.tasks + 1), self.autopilotSettings)

    local valid = self:validateTasks(tasks, snapshot, {})
    if #valid == 0 then
        return
    end
    for _, d in ipairs(decisions) do
        FALog.decision("AUTOPILOT", "%s", d)
    end
    if tm:hasActiveWork() then
        tm:addTasks(valid)
        tm.continuous = true
    else
        tm:loadPlan({ objective = { type = "AUTOPILOT" }, tasks = valid, warnings = {}, decisions = decisions,
            summary = "Autopilot: keeping the farm running." }, nil, true)
    end
    self.phase = FarmAgent.PHASE.EXECUTING
    local labels = {}
    for _, t in ipairs(valid) do
        if FABrain.OP_FOR_ACTION[t.action] ~= nil then
            table.insert(labels, tm:taskLabel(t))
        end
    end
    if #labels > 0 then
        FAGameAdapter.notify("autopilot: " .. table.concat(labels, ", ") .. ".", false)
    end
end

-- Validates tasks on their crop's view; drops (and logs) invalid ones.
function FarmAgent:validateTasks(tasks, snapshot, warnings)
    local reserved, valid = {}, {}
    for _, task in ipairs(tasks) do
        local view = task.crop and FAPlanner.viewForCrop(snapshot, task.crop) or snapshot
        local ok, reason = FAValidator.validate(task, { snapshot = view, reservedBy = reserved, taskId = task.id, tasks = {} })
        if ok then
            if task.vehicleId ~= nil then
                reserved[task.vehicleId] = task.id
            end
            table.insert(valid, task)
        else
            FALog.warn("PLAN", "Dropped %s: %s", tostring(task.id), reason)
            table.insert(warnings, tostring(task.id) .. " dropped: " .. reason)
        end
    end
    return valid
end

-- Bridge commands from the companion. Shapes are documented in companion/README.md.
function FarmAgent:onBridgeCommand(cmd)
    if type(cmd.say) == "string" and cmd.say ~= "" then
        FALog.info("CLAUDE", "%s", cmd.say)
    end
    if cmd.type == "reply" then
        if self.phase == FarmAgent.PHASE.WAITING_FOR_CLAUDE then
            self.phase = FarmAgent.PHASE.IDLE
        end
        if type(cmd.say) == "string" then
            FAGameAdapter.notify(cmd.say, false)
        end
        self.bridge:addCommandResult(cmd.id, true, "reply shown")
    elseif cmd.type == "control" then
        if self.phase == FarmAgent.PHASE.WAITING_FOR_CLAUDE then
            self.phase = FarmAgent.PHASE.IDLE
        end
        self:applyControl(cmd.op)
        self.bridge:addCommandResult(cmd.id, true, "control " .. tostring(cmd.op))
    elseif cmd.type == "objective" then
        self:applyObjective(cmd.objective, cmd.id)
    elseif cmd.type == "tasks" then
        self:applyObjective(cmd.objective, cmd.id, cmd.tasks)
    else
        self.bridge:addCommandResult(cmd.id, false, "unknown command type " .. tostring(cmd.type))
    end
end

-- Objective -> scan -> plan -> execute -------------------------------------------

-- explicitTasks (optional): a task list proposed by Claude instead of the planner's.
function FarmAgent:applyObjective(objective, commandId, explicitTasks)
    local function reject(reason)
        FALog.warn("AGENT", "Objective rejected: %s", reason)
        FAGameAdapter.notify(reason, true)
        if commandId ~= nil then
            self.bridge:addCommandResult(commandId, false, reason)
        end
        self.phase = FarmAgent.PHASE.IDLE
    end

    if type(objective) ~= "table" then
        reject("Objective must be a table.")
        return
    end
    local crop = nil
    if objective.type == "HARVEST_READY_FIELDS" then
        if objective.crop == "ALL" or objective.crop == "ANY" then
            objective.crop = nil
            objective.allCrops = true
        end
        if objective.allCrops then
            objective.crop = nil
        elseif objective.crop ~= nil then
            crop = FAGameAdapter.getFruitTypeByName(objective.crop)
            if crop == nil then
                reject("Unknown crop '" .. tostring(objective.crop) .. "'.")
                return
            end
        elseif type(objective.fieldIds) ~= "table" then
            reject("Objective needs a crop or field ids.")
            return
        end
    elseif objective.type == "FIELD_WORK" then
        local validOps = { CULTIVATE = true, PLOW = true, SEED = true, FERTILIZE = true, LIME = true, PREPARE = true }
        if not validOps[objective.op or ""] then
            reject("Unknown field operation '" .. tostring(objective.op) .. "'.")
            return
        end
        if objective.op == "SEED" then
            objective.crop = objective.crop or "REPLANT"
            if objective.crop ~= "REPLANT" and FAGameAdapter.getFruitTypeByName(objective.crop) == nil then
                reject("Unknown crop '" .. tostring(objective.crop) .. "'.")
                return
            end
        end
    elseif objective.type ~= "FARM_WORK" then
        reject("Unsupported objective type " .. tostring(objective.type) .. ".")
        return
    end

    self.farmId = FAGameAdapter.getFarmId()
    if self.farmId == nil then
        reject("No player farm.")
        return
    end

    self.pending = { objective = objective, crop = crop, commandId = commandId, explicitTasks = explicitTasks }
    local fields = self.farmState:loadFields(self.farmId)
    self.scanner:requestAll()
    self.phase = FarmAgent.PHASE.SCANNING
    local what = ""
    if crop then what = " for " .. crop.title
    elseif objective.allCrops then what = " for every ready crop"
    elseif objective.type == "FIELD_WORK" then what = " (" .. string.lower(objective.op) .. ")"
    elseif objective.type == "FARM_WORK" then what = " for all field work" end
    FALog.action("AGENT", "Scanning %d owned field(s)%s.", #fields, what)
end

-- Crop of a field-id-only objective = the crop actually ready on the first listed field.
function FarmAgent:inferCrop(objective)
    for _, fieldId in ipairs(objective.fieldIds or {}) do
        local class = FAFieldScanner.classify(self.scanner:getResult(fieldId), FAGameAdapter.getFruitTypeByIndex)
        if class.cropName ~= nil and class.state == "READY_TO_HARVEST" then
            return FAGameAdapter.getFruitTypeByName(class.cropName)
        end
    end
    return nil
end

function FarmAgent:refreshSnapshot()
    if self.farmId ~= nil then
        self.soilContext = nil -- re-read soil limits / ground types with the snapshot
        self.farmState:refresh(self.farmId, self.taskManager.crop or (self.pending and self.pending.crop))
    end
end

function FarmAgent:planAndExecute()
    local pending = self.pending
    self.pending = nil
    if pending == nil then
        self.phase = FarmAgent.PHASE.IDLE
        return
    end
    local objective = pending.objective
    local tm = self.taskManager
    -- New work is ADDED next to running work (only idle machines, untouched fields);
    -- "stop everything" is the way to clear the board.
    local adding = tm:hasActiveWork()
    local busyVehicles, busyFields = {}, {}
    if adding then
        busyVehicles, busyFields = tm:getBusy()
    end
    local opts = { excludeVehicles = busyVehicles, excludeFields = busyFields,
        newId = FAPlanner.newIdGenerator(#tm.tasks + 1), noReport = true }

    local crop, snapshot, plan
    if objective.type == "HARVEST_READY_FIELDS" and objective.allCrops then
        -- The brain ranks every ready crop and plans them together.
        snapshot = self.farmState:refresh(self.farmId, nil)
        plan = FABrain.planAllCrops(snapshot, opts)
    elseif objective.type == "HARVEST_READY_FIELDS" then
        crop = pending.crop or self:inferCrop(objective)
        if crop == nil then
            self.phase = adding and FarmAgent.PHASE.EXECUTING or FarmAgent.PHASE.IDLE
            FALog.warn("AGENT", "None of the requested fields has a crop ready to harvest.")
            FAGameAdapter.notify("none of the requested fields is ready to harvest.", true)
            if pending.commandId then self.bridge:addCommandResult(pending.commandId, false, "no ready crop on requested fields") end
            return
        end
        objective.crop = crop.name
        snapshot = self.farmState:refresh(self.farmId, crop)
        if pending.explicitTasks ~= nil then
            plan = self:planFromExplicitTasks(objective, pending.explicitTasks, snapshot)
        else
            plan = FAPlanner.planHarvest(objective, snapshot, opts)
        end
    else
        snapshot = self.farmState:refresh(self.farmId, nil)
        plan = self:planFieldObjective(objective, snapshot, opts)
    end

    for _, d in ipairs(plan.decisions) do
        FALog.decision("PLAN", "%s", d)
    end
    for _, w in ipairs(plan.warnings) do
        FALog.warn("PLAN", "%s", w)
    end

    -- Validate every task once more before anything moves.
    plan.tasks = self:validateTasks(plan.tasks, snapshot, plan.warnings)

    local workCount = 0
    for _, t in ipairs(plan.tasks) do
        if FABrain.OP_FOR_ACTION[t.action] ~= nil then workCount = workCount + 1 end
    end
    if workCount == 0 then
        self.phase = adding and FarmAgent.PHASE.EXECUTING or FarmAgent.PHASE.IDLE
        local why = plan.warnings[1] or "nothing to do"
        FAGameAdapter.notify(why, true)
        if pending.commandId then self.bridge:addCommandResult(pending.commandId, false, why) end
        return
    end

    if adding then
        tm:addTasks(plan.tasks)
        FALog.decision("PLAN", "Added to the running work.")
    else
        local deps = {}
        for _, t in ipairs(plan.tasks) do table.insert(deps, t.id) end
        table.insert(plan.tasks, { id = opts.newId("R"), action = "REPORT", deps = deps })
        tm:loadPlan(plan, crop, self.autopilot)
    end
    self.phase = FarmAgent.PHASE.EXECUTING
    FALog.decision("PLAN", "%s", plan.summary)
    FAGameAdapter.notify(plan.summary, false)
    if pending.commandId then
        self.bridge:addCommandResult(pending.commandId, true, plan.summary)
    end
end

-- FIELD_WORK (one operation, or PREPARE = plow/cultivate as each field needs) and
-- FARM_WORK (everything the farm needs now) objectives.
function FarmAgent:planFieldObjective(objective, snapshot, opts)
    if objective.type == "FARM_WORK" then
        return FABrain.planFarmWork(snapshot, { seedCrop = self.autopilotSettings.seedCrop, ops = self:allowedOps(),
            excludeVehicles = opts.excludeVehicles, excludeFields = opts.excludeFields, newId = opts.newId, noReport = true })
    end
    local op = objective.op
    local plan = { objective = objective, tasks = {}, decisions = {}, warnings = {} }
    if op == "PREPARE" then
        if objective.fieldIds == nil then
            plan = FABrain.planFarmWork(snapshot, { harvest = false, ops = { PLOW = true, CULTIVATE = true },
                excludeVehicles = opts.excludeVehicles, excludeFields = opts.excludeFields, newId = opts.newId, noReport = true })
            plan.objective = objective
        else
            -- Named fields: plow where the plow counter asks for it and a plow rig is free,
            -- otherwise cultivate.
            local used = {}
            for k, v in pairs(opts.excludeVehicles) do used[k] = v end
            for _, id in ipairs(objective.fieldIds) do
                local fieldOp = "CULTIVATE"
                local caps = FABrain.freeCapabilities(snapshot, used)
                for _, f in ipairs(snapshot.fields) do
                    if f.id == id and FABrain.fieldNeeds(f, caps).PLOW then fieldOp = "PLOW" end
                end
                local sub = FABrain.planOperation(fieldOp, snapshot, { fieldIds = { id }, excludeVehicles = used,
                    excludeFields = opts.excludeFields, newId = opts.newId })
                for _, t in ipairs(sub.tasks) do table.insert(plan.tasks, t) end
                for vid, _ in pairs(sub.usedVehicles) do used[vid] = true end
                for _, d in ipairs(sub.decisions) do table.insert(plan.decisions, d) end
                for _, w in ipairs(sub.warnings) do table.insert(plan.warnings, w) end
            end
        end
    else
        local sub = FABrain.planOperation(op, snapshot, { fieldIds = objective.fieldIds, crop = objective.crop,
            excludeVehicles = opts.excludeVehicles, excludeFields = opts.excludeFields, newId = opts.newId })
        plan.tasks, plan.decisions, plan.warnings = sub.tasks, sub.decisions, sub.warnings
    end
    plan.summary = string.format("%s: %d field job(s) planned.", op == "PREPARE" and "Prepare fields" or (FABrain.OP_TITLES[op] or op), #plan.tasks)
    return plan
end

-- Turns a Claude-proposed task list into a plan; ids and the REPORT task are added here,
-- and every task is validated afterwards like planner output.
function FarmAgent:planFromExplicitTasks(objective, tasks, snapshot)
    local plan = { objective = objective, tasks = {}, warnings = {}, decisions = {} }
    local n = 0
    for _, t in ipairs(tasks or {}) do
        if type(t) == "table" and FAValidator.SUPPORTED_ACTIONS[t.action] and t.action ~= "REPORT" then
            n = n + 1
            local prefix = t.action == "HARVEST_FIELD" and "H" or "L"
            table.insert(plan.tasks, {
                id = prefix .. n, action = t.action, crop = objective.crop, fieldId = t.fieldId, vehicleId = t.vehicleId,
                combineId = t.combineId, stationId = t.stationId, deps = {},
            })
            table.insert(plan.decisions, string.format("Claude proposed %s%s.", t.action,
                t.fieldId and (" on field " .. tostring(t.fieldId)) or ""))
        else
            table.insert(plan.warnings, "Ignored unsupported task " .. tostring(type(t) == "table" and t.action or t))
        end
    end
    plan.summary = string.format("Executing %d task(s) proposed by Claude.", n)
    return plan
end

function FarmAgent:onObjectiveFinished(status)
    self.phase = FarmAgent.PHASE.DONE
    FALog.info("AGENT", "Objective finished with status %s.", status)
end

-- Called by g_messageCenter from inside the game's own AISystem:stopJob, i.e. from the
-- game's update loop. An error here would surface as "Error: Running LUA method 'update'"
-- and break the game's job bookkeeping, so it is fully contained.
function FarmAgent:onAIJobStopped(job, aiMessage)
    if self.enabled then
        local ok, err = pcall(self.taskManager.onAIJobStopped, self.taskManager, job, aiMessage)
        if not ok then
            FALog.error("AGENT", "Error handling a stopped AI job: %s", tostring(err))
        end
    end
end

function FarmAgent:backgroundRefresh()
    local farmId = FAGameAdapter.getFarmId()
    if farmId == nil then
        return
    end
    self.farmId = farmId
    self.farmState:loadFields(farmId)
    self.scanner:requestAll()
    self.refreshWhenScanned = true -- publish once the scan has finished (field overview)
end

-- State published to the companion ----------------------------------------------

function FarmAgent:buildBridgeState()
    local tm = self.taskManager
    return {
        schema = 1,
        mod = "FS25_FarmAgent",
        milestone = 1,
        gameTime = FALog.clock(),
        phase = self.phase,
        goal = self.goalText,
        paused = tm.paused,
        autopilot = self.autopilot,
        objective = tm.objective,
        objectiveStatus = tm.status,
        farm = self.farmState.snapshot,
        tasks = tm:getTaskViews(),
        attention = tm.attention,
        stats = tm.stats,
        log = FALog.getRecent(30),
        supportedActions = { "HARVEST_FIELD", "UNLOAD_COMBINE" },
        supportedControls = { "STOP_ALL", "PAUSE", "RESUME", "STATUS", "AUTOPILOT_ON", "AUTOPILOT_OFF" },
    }
end

-- Console --------------------------------------------------------------------------

function FarmAgent:consoleCommand(...)
    local text = table.concat({ ... }, " ")
    if text == "" then
        return "Usage: faCommand <text>, e.g. faCommand harvest all ready wheat fields"
    end
    self:submitCommand(text)
    return "Farm Agent: command submitted."
end

function FarmAgent:consoleStatus()
    local tm = self.taskManager
    local lines = { string.format("Farm Agent phase=%s objective=%s paused=%s autopilot=%s companion=%s",
        self.phase, tm.status, tostring(tm.paused), tostring(self.autopilot), self.bridge:isOnline() and "online" or "offline") }
    for _, v in ipairs(tm:getTaskViews()) do
        table.insert(lines, string.format("  %-4s %-28s %-17s %-18s %3d%% %s", v.id, v.label, v.state, v.substate or "",
            math.floor((v.progress or 0) * 100), v.note or ""))
    end
    for _, a in ipairs(tm.attention) do
        table.insert(lines, "  ATTENTION: " .. a.text)
    end
    local text = table.concat(lines, "\n")
    print(text)
    return text
end

function FarmAgent:consoleScan()
    local farmId = FAGameAdapter.getFarmId()
    if farmId == nil then
        return "No player farm."
    end
    local fields = self.farmState:loadFields(farmId)
    local lines = { string.format("Farm Agent scan of %d owned field(s):", #fields) }
    for _, field in ipairs(fields) do
        local result = self.scanner:scanNow(field.id)
        local class = FAFieldScanner.classify(result, FAGameAdapter.getFruitTypeByIndex)
        table.insert(lines, string.format("  field %-6s %6.2f ha  %-10s %-17s gs=%-3s ready=%3d%%  samples=%d",
            field.name, field.areaHa or 0, tostring(class.cropName), class.state, tostring(class.growthState),
            math.floor((class.readyFraction or 0) * 100), result and result.validCount or 0))
    end
    local snapshot = self.farmState:refresh(farmId, nil)
    for _, v in ipairs(snapshot.vehicles) do
        if v.kind ~= "OTHER" then
            table.insert(lines, string.format("  vehicle %-6s %-9s %-36s fieldwork=%s goto=%s deliver=%s",
                tostring(v.id), v.kind, v.name, tostring(v.canFieldWork), tostring(v.canGoTo), tostring(v.canDeliver)))
        end
    end
    local text = table.concat(lines, "\n")
    print(text)
    return "Farm Agent: scan printed to log/console."
end

function FarmAgent:consoleStopAll() self:applyControl("STOP_ALL") return "Farm Agent: stopped." end
function FarmAgent:consolePause() self:applyControl("PAUSE") return "Farm Agent: paused." end
function FarmAgent:consoleResume() self:applyControl("RESUME") return "Farm Agent: resumed." end
