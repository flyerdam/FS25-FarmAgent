-- FATaskManager: executes and supervises the task graph.
--
-- Farm Agent is the brain, vanilla AI workers are the hands: this module only ever
-- starts/stops vanilla jobs (through FAJobAdapter) and watches what happens.
--
-- Task states:
--   PENDING          not started yet
--   WAITING          blocked on a resource (free combine, AI worker limit, player in vehicle)
--   RUNNING          a vanilla AI job is working on it (see task.substate)
--   VERIFYING        the AI said "finished"; Farm Agent is checking the field itself
--   RECOVERING       stalled or failed; running the recovery ladder
--   WAITING_WEATHER  combine not allowed to thresh in rain
--   PAUSED_BY_PLAYER the player stopped this worker; never restarted automatically
--   ESCALATED        Farm Agent could not fix it; needs the player
--   DONE / FAILED / CANCELLED  terminal

FATaskManager = {}
local FATaskManager_mt = { __index = FATaskManager }

FATaskManager.TICK_MS = 1000
FATaskManager.SNAPSHOT_REFRESH_MS = 10000
FATaskManager.FIELD_RESCAN_MS = 20000
FATaskManager.STALL_MS = 45000                -- no movement for this long while "working" = stalled
FATaskManager.TRANSPORT_STALL_MS = 90000
FATaskManager.RECOVERY_HEALTHY_MS = 120000    -- recovery counter resets after this much healthy work
FATaskManager.COMBINE_FULL_RATIO = 0.98
FATaskManager.DELIVER_THRESHOLD = 0.6         -- trailer fill ratio that triggers a delivery run
FATaskManager.LOADING_START_TIMEOUT_MS = 20000
FATaskManager.LOADING_IDLE_MS = 15000
FATaskManager.RENDEZVOUS_TIMEOUT_MS = 360000
FATaskManager.MAX_RECOVERY_STEPS = 2
FATaskManager.MAX_PIPE_CORRECTIONS = 2
FATaskManager.DONE_READY_FRACTION = 0.03      -- <= 3% of samples still standing = field done
FATaskManager.DONE_WORK_FRACTION = 0.05       -- tool operations: <= 5% left = done (headland overlap)
FATaskManager.PRESTAGE_RATIO = 0.7            -- combine this full: trailer waits at the field edge
FATaskManager.PRESTAGE_DISTANCE = 120
FATaskManager.APPROACH_OFFSET = 20            -- straight run-in behind the parking point, metres
FATaskManager.FINAL_APPROACH_SPEED = 5        -- km/h on the run-in (vanilla default 10) for a precise stop
FATaskManager.MAX_CORRECTION_M = 15           -- further off than this = the combine moved, re-plan
FATaskManager.PARK_DELAY_MS = 5000            -- grace period after a job: new work may take the machine
FATaskManager.PARK_MAX_WAIT_MS = 900000       -- a combine waits this long for its last unload before parking
FATaskManager.PARK_TIMEOUT_MS = 600000        -- a park drive taking longer than this is abandoned
FATaskManager.PARK_OUTSETS = { 25, 45, 70 }   -- metres outside the field edge for the fallback spot

local TERMINAL = { DONE = true, FAILED = true, CANCELLED = true }

local MSG = {
    FINISHED = "AIMessageSuccessFinishedJob",
    STOPPED_BY_USER = "AIMessageSuccessStoppedByUser",
    OUT_OF_FUEL = "AIMessageErrorOutOfFuel",
    OUT_OF_FILL = "AIMessageErrorOutOfFill",
    OUT_OF_MONEY = "AIMessageErrorOutOfMoney",
    BROKEN = "AIMessageErrorVehicleBroken",
    DELETED = "AIMessageErrorVehicleDeleted",
    NOT_OWNED = "AIMessageErrorFieldNotOwned",
    NOT_READY = "AIMessageErrorFieldNotReady",
    NO_FIELD = "AIMessageErrorNoFieldFound",
    RAIN = "AIMessageErrorThreshingNotAllowed",
    STATION_FULL = "AIMessageErrorUnloadingStationFull",
    WRONG_SEASON = "AIMessageErrorWrongSeason",
}

function FATaskManager.new(agent)
    local self = setmetatable({}, FATaskManager_mt)
    self.agent = agent
    -- Parking survives plan changes (reset): a machine finishing the last task of one
    -- objective still has to get off the field.
    self.parkRequests = {}   -- [vehicleId] = { at, since, reason }
    self.parks = {}          -- [vehicleId] = { job, target, toHome, startedAt, fallbackTried }
    self.parkJobs = {}       -- [job] = vehicleId
    self.movedByAgent = {}   -- [vehicleId] = true once Farm Agent drove it this session
    self:reset()
    return self
end

function FATaskManager:reset()
    self.tasks = {}
    self.byId = {}
    self.jobToTask = {}
    self.attention = {}
    self.objective = nil
    self.plan = nil
    self.crop = nil
    self.continuous = false
    self.status = "IDLE"
    self.paused = false
    self.now = 0
    self.tickTimer = 0
    self.snapshotTimer = 0
    self.startedAt = 0
    self.stats = { delivered = 0, fieldsDone = 0 }
end

-- Plan loading ------------------------------------------------------------------

-- crop (optional): default crop description for tasks without their own 'crop' name.
-- continuous: autopilot plans never "complete"; new tasks keep being added.
function FATaskManager:loadPlan(plan, crop, continuous)
    if self:hasActiveWork() then
        self:stopAll("replaced by a new objective", true)
    end
    local keepNow = self.now
    self:reset()
    self.now = keepNow
    self.plan = plan
    self.objective = plan.objective
    self.crop = crop
    self.continuous = continuous == true
    self.status = "RUNNING"
    self.startedAt = self.now
    self:addTasks(plan.tasks)
end

-- Adds tasks to the running plan (used by loadPlan, the autopilot and dynamic logistics).
function FATaskManager:addTasks(tasks)
    for _, t in ipairs(tasks) do
        local task = {}
        for k, v in pairs(t) do task[k] = v end
        if task.id == nil or self.byId[task.id] ~= nil then
            task.id = self:newTaskId(task.action == "HARVEST_FIELD" and "H" or (task.action == "UNLOAD_COMBINE" and "L" or "T"))
        end
        task.deps = task.deps or {}
        task.state = "PENDING"
        task.substate = nil
        task.progress = 0
        task.note = ""
        task.recoveryStep = 0
        task.verifyRestarts = 0
        task.startFailures = 0
        if task.crop ~= nil and self.agent.getCrop ~= nil then
            task.cropDesc = self.agent:getCrop(task.crop)
        end
        table.insert(self.tasks, task)
        self.byId[task.id] = task
    end
    if self.status ~= "RUNNING" and self:hasActiveWork() then
        self.status = "RUNNING"
    end
end

-- Unique task id; numbers keep counting up across autopilot additions.
function FATaskManager:newTaskId(prefix)
    local n = #self.tasks + 1
    local id = prefix .. n
    while self.byId[id] ~= nil do
        n = n + 1
        id = prefix .. n
    end
    return id
end

function FATaskManager:taskCrop(task)
    return task.cropDesc or self.crop
end

function FATaskManager:taskCropName(task)
    local crop = self:taskCrop(task)
    return task.crop or (crop and crop.name)
end

-- Machines and fields owned by unfinished tasks (the autopilot must leave these alone).
function FATaskManager:getBusy()
    local vehicles, fields = {}, {}
    for _, t in ipairs(self.tasks) do
        if not TERMINAL[t.state] then
            if t.vehicleId ~= nil then vehicles[t.vehicleId] = true end
            -- A combine is only blocked while its trailer is actually unloading it.
            if t.combineId ~= nil and (t.substate == "WAIT_PIPE" or t.substate == "TO_COMBINE" or t.substate == "LOADING") then
                vehicles[t.combineId] = true
            end
            if FABrain.OP_FOR_ACTION[t.action] ~= nil and t.fieldId ~= nil then fields[t.fieldId] = true end
        end
    end
    return vehicles, fields
end

function FATaskManager:hasTasksWaitingForPlayer()
    for _, task in ipairs(self.tasks) do
        if task.state == "PAUSED_BY_PLAYER" or task.state == "ESCALATED" then
            return true
        end
    end
    return false
end

function FATaskManager:hasActiveWork()
    for _, task in ipairs(self.tasks) do
        if not TERMINAL[task.state] then
            return true
        end
    end
    return false
end

-- Helpers ------------------------------------------------------------------------

function FATaskManager:snapshot()
    return self.agent.farmState.snapshot
end

function FATaskManager:vehicleRef(id)
    local ref = self.agent.farmState.refs.vehicles[id]
    if ref ~= nil and FAGameAdapter.isVehicleValid(ref) then
        return ref
    end
    return nil
end

function FATaskManager:liveVehicle(id)
    local ref = self:vehicleRef(id)
    if ref == nil then
        return nil
    end
    local ok, record = pcall(FAGameAdapter.describeVehicle, ref)
    if ok then
        return record
    end
    return nil
end

function FATaskManager:vehicleName(id)
    local snapshot = self:snapshot()
    for _, v in ipairs(snapshot and snapshot.vehicles or {}) do
        if v.id == id then
            return v.name
        end
    end
    return "vehicle #" .. tostring(id)
end

function FATaskManager:fieldName(id)
    local field = self.agent.farmState.refs.fields[id]
    return field and field.name or ("#" .. tostring(id))
end

function FATaskManager:reservations()
    local reserved = {}
    for _, task in ipairs(self.tasks) do
        if not TERMINAL[task.state] and task.state ~= "PENDING" then
            if task.vehicleId ~= nil then
                reserved[task.vehicleId] = task.id
            end
        end
        -- A planned-but-pending task still owns its machines so other tasks don't take them.
        if task.state == "PENDING" and task.vehicleId ~= nil then
            reserved[task.vehicleId] = reserved[task.vehicleId] or task.id
        end
        -- A combine being unloaded belongs to its trailer until the unload is over (first
        -- in-game test: the combine was sent to the next field mid-unload and drove off).
        if task.action == "UNLOAD_COMBINE" and not TERMINAL[task.state] and task.combineId ~= nil
            and (task.substate == "WAIT_PIPE" or task.substate == "TO_COMBINE" or task.substate == "LOADING") then
            reserved[task.combineId] = reserved[task.combineId] or task.id
        end
    end
    return reserved
end

-- Snapshot narrowed to the task's crop (multi-crop snapshots carry per-crop lists).
function FATaskManager:cropView(task)
    local snapshot = self:snapshot()
    local cropName = self:taskCropName(task)
    if cropName ~= nil and snapshot ~= nil then
        return FAPlanner.viewForCrop(snapshot, cropName)
    end
    return snapshot
end

function FATaskManager:validationContext(task)
    return { snapshot = self:cropView(task), reservedBy = self:reservations(), taskId = task.id, tasks = self.byId }
end

function FATaskManager:setState(task, state, note)
    if task.state ~= state then
        task.state = state
        task.stateSince = self.now
        if TERMINAL[state] then
            self:onTaskTerminal(task, state)
        end
    end
    if note ~= nil then
        task.note = note
    end
end

function FATaskManager:taskLabel(task)
    local op = FABrain.OP_FOR_ACTION[task.action]
    local crop = self:taskCrop(task)
    local cropTitle = crop ~= nil and crop.title or task.crop
    if op == "HARVEST" then
        if cropTitle ~= nil then
            return string.format("Harvest field %s (%s)", self:fieldName(task.fieldId), cropTitle)
        end
        return string.format("Harvest field %s", self:fieldName(task.fieldId))
    elseif op == "SEED" then
        return string.format("Plant %s on field %s", tostring(cropTitle), self:fieldName(task.fieldId))
    elseif op ~= nil then
        local title = FABrain.OP_TITLES[op] or op
        return string.format("%s%s field %s", title:sub(1, 1):upper(), title:sub(2), self:fieldName(task.fieldId))
    elseif task.action == "UNLOAD_COMBINE" then
        return string.format("Unload %s", self:vehicleName(task.combineId))
    elseif task.action == "REPORT" then
        return "Report"
    end
    return task.action
end

function FATaskManager:addAttention(task, text)
    for _, a in ipairs(self.attention) do
        if a.taskId == (task and task.id) and a.text == text then
            return
        end
    end
    table.insert(self.attention, { taskId = task and task.id, text = text, time = FALog.clock() })
    FALog.attention(task and task.id or "", "%s", text)
    FAGameAdapter.notify(text, true)
end

function FATaskManager:clearAttention(task)
    for i = #self.attention, 1, -1 do
        if self.attention[i].taskId == task.id then
            table.remove(self.attention, i)
        end
    end
end

function FATaskManager:escalate(task, text)
    self:setState(task, "ESCALATED", text)
    self:addAttention(task, string.format("%s: %s", self:taskLabel(task), text))
end

-- Stops a job Farm Agent started, flagging it so the stop message is not misread as
-- the player taking over.
-- AISystem:stopJob publishes AI_JOB_STOPPED synchronously, so onAIJobStopped runs (and
-- clears task.job) before stopJob returns; keep a local reference.
function FATaskManager:stopOwnJob(task)
    local job = task.job
    if job ~= nil then
        task.expectStop = true
        if not FAJobAdapter.stopJob(job) then
            task.expectStop = false
        end
        self.jobToTask[job] = nil
        task.job = nil
        task.jobPurpose = nil
    end
end

function FATaskManager:attachJob(task, job, purpose)
    task.job = job
    task.jobPurpose = purpose
    task.jobStartedAt = self.now
    self.jobToTask[job] = task
end

-- Main loop ----------------------------------------------------------------------

function FATaskManager:update(dt)
    self.now = self.now + dt
    self.tickTimer = self.tickTimer + dt
    if self.tickTimer < FATaskManager.TICK_MS then
        return
    end
    self.tickTimer = 0

    -- Parking runs even when no objective is running (the last machine of a finished
    -- plan still has to leave the field).
    local okPark, errPark = pcall(self.processParking, self)
    if not okPark then
        FALog.error("PARK", "Internal error while parking: %s", tostring(errPark))
        self.parkRequests = {}
    end
    if self.status ~= "RUNNING" then
        return
    end

    self.snapshotTimer = self.snapshotTimer + FATaskManager.TICK_MS
    if self.snapshotTimer >= FATaskManager.SNAPSHOT_REFRESH_MS then
        self.snapshotTimer = 0
        self.agent:refreshSnapshot()
    end

    for _, task in ipairs(self.tasks) do
        local ok, err = pcall(self.updateTask, self, task)
        if not ok then
            FALog.error(task.id, "Internal error while supervising %s: %s", self:taskLabel(task), tostring(err))
            self:escalate(task, "internal Farm Agent error (see log.txt)")
        end
    end
    self:updateObjectiveStatus()
end

-- Field operation of a task (HARVEST, CULTIVATE, PLOW, SEED, FERTILIZE, LIME) or nil.
local function opOf(task)
    return FABrain.OP_FOR_ACTION[task.action]
end
FATaskManager.opOf = opOf

function FATaskManager:updateTask(task)
    if task.state == "PAUSED_BY_PLAYER" and self.agent.autopilot then
        self:checkAutoResume(task)
        return
    end
    if TERMINAL[task.state] or task.state == "ESCALATED" or task.state == "PAUSED_BY_PLAYER" then
        -- Escalated logistics keep watching so they can self-resolve (e.g. player parked the trailer).
        if task.state == "ESCALATED" and task.action == "UNLOAD_COMBINE" and task.substate == "LOADING" then
            self:updateLogistics(task)
        end
        return
    end
    if opOf(task) ~= nil then
        self:updateHarvest(task)
    elseif task.action == "UNLOAD_COMBINE" then
        self:updateLogistics(task)
    elseif task.action == "REPORT" then
        self:updateReport(task)
    end
end

-- FIELD WORK (harvest and tool operations share one supervisor) --------------------

function FATaskManager:soilContext()
    if self.agent.getSoilContext ~= nil then
        return self.agent:getSoilContext()
    end
    return {}
end

-- Fraction of the field where this task's operation still has to be done (measured).
function FATaskManager:remainingFor(task, result)
    return FAFieldScanner.remaining(opOf(task), result, self:soilContext(),
        { crop = self:taskCrop(task), startSprayLevel = task.startSprayLevel })
end

function FATaskManager:doneThreshold(task)
    return opOf(task) == "HARVEST" and FATaskManager.DONE_READY_FRACTION or FATaskManager.DONE_WORK_FRACTION
end

-- A combine may take a new crop only with an empty tank (or the same crop in it).
function FATaskManager:isCombineTankOk(vehicleId, task)
    local record = self:liveVehicle(vehicleId)
    if record == nil or record.combine == nil or (record.combine.fillLevel or 0) <= 1 then
        return true
    end
    local crop = self:taskCrop(task)
    local fillType = record.combine.fillTypeIndex
    return crop == nil or fillType == nil or fillType == 0 or fillType == crop.fillTypeIndex
end

-- Nearest free machine for a queued task: a combine for harvests, a tool rig otherwise.
function FATaskManager:findFreeMachineFor(task)
    local op = opOf(task)
    local view = self:cropView(task)
    local reserved = self:reservations()
    local field = self.agent.farmState.refs.fields[task.fieldId]
    local best, bestDist = nil, math.huge
    for _, v in ipairs(view.vehicles) do
        local capable
        if op == "HARVEST" then
            capable = FAPlanner.isCompatibleCombine(v) and self:isCombineTankOk(v.id, task)
        else
            capable = FABrain.isCompatibleTool(v, op, task.crop) and FABrain.suppliesMissing(v, op, view.helpers) == nil
        end
        if capable and FAPlanner.isUsable(v) and reserved[v.id] == nil then
            local d = FAGeometry.distance(v.x, v.z, field.labelX, field.labelZ)
            if d < bestDist then
                best, bestDist = v, d
            end
        end
    end
    return best
end
FATaskManager.findFreeCombineFor = FATaskManager.findFreeMachineFor

-- Autopilot: give a worker the player stopped back once the player has left that vehicle.
function FATaskManager:checkAutoResume(task)
    local record = task.vehicleId and self:liveVehicle(task.vehicleId)
    local resume, leftAt = FABrain.shouldAutoResume(record, task.playerLeftAt, self.now)
    task.playerLeftAt = leftAt
    if resume then
        task.playerLeftAt = nil
        task.recoveryStep = 0
        if task.action == "UNLOAD_COMBINE" then
            self:setState(task, "RUNNING", "taken back by autopilot")
            task.substate = "IDLE"
        else
            self:setState(task, "PENDING", "taken back by autopilot")
        end
        FALog.decision(task.id, "Autopilot: you left %s %d s ago - taking %s back.",
            self:vehicleName(task.vehicleId), FABrain.AUTO_RESUME_MS / 1000, self:taskLabel(task))
        FAGameAdapter.notify(string.format("autopilot resumed %s.", self:taskLabel(task)), false)
    end
end

-- Is an unfinished logistics task serving this combine for this crop?
function FATaskManager:findLogisticsFor(combineId, cropName)
    for _, t in ipairs(self.tasks) do
        if t.action == "UNLOAD_COMBINE" and t.combineId == combineId and not TERMINAL[t.state]
            and (cropName == nil or self:taskCropName(t) == nil or self:taskCropName(t) == cropName) then
            return t
        end
    end
    return nil
end

-- A queued field was just bound to a combine: give that combine a trailer for this crop
-- if it has none (nearest free compatible tractor+trailer, best station).
function FATaskManager:ensureLogistics(task)
    if opOf(task) ~= "HARVEST" then
        return
    end
    local cropName = self:taskCropName(task)
    if self:findLogisticsFor(task.vehicleId, cropName) ~= nil then
        return
    end
    local view = self:cropView(task)
    local field = self.agent.farmState.refs.fields[task.fieldId]
    local station = FAPlanner.chooseStation(view.stations, field.labelX, field.labelZ)
    if station == nil then
        return
    end
    local reserved = self:reservations()
    local best, bestDist = nil, math.huge
    for _, v in ipairs(view.vehicles) do
        if FAPlanner.isCompatibleTransport(v) and FAPlanner.isUsable(v) and reserved[v.id] == nil then
            local d = FAGeometry.distance(v.x, v.z, field.labelX, field.labelZ)
            if d < bestDist then
                best, bestDist = v, d
            end
        end
    end
    if best == nil then
        return
    end
    local logistics = { id = self:newTaskId("L"), action = "UNLOAD_COMBINE", crop = cropName,
        combineId = task.vehicleId, vehicleId = best.id, stationId = station.id, deps = {} }
    self:addTasks({ logistics })
    for _, t in ipairs(self.tasks) do
        if t.action == "REPORT" and not TERMINAL[t.state] then
            table.insert(t.deps, logistics.id)
        end
    end
    FALog.decision(logistics.id, "%s will unload %s on field %s and deliver to %s.",
        best.name, self:vehicleName(task.vehicleId), self:fieldName(task.fieldId), station.name)
end

function FATaskManager:updateHarvest(task)
    local op = opOf(task)
    if task.state == "PENDING" or task.state == "WAITING" then
        if self.paused or (task.retryAt ~= nil and self.now < task.retryAt) then
            return
        end
        if task.vehicleId == nil then
            local machine = self:findFreeMachineFor(task)
            if machine == nil then
                self:setState(task, "WAITING", op == "HARVEST" and "waiting for a free combine"
                    or string.format("waiting for a free tractor that can %s", FABrain.OP_TITLES[op] or op))
                return
            end
            task.vehicleId = machine.id
            FALog.decision(task.id, "Field %s: %s is free, assigning it.", self:fieldName(task.fieldId), machine.name)
            self:ensureLogistics(task)
        end
        -- A machine Farm Agent is about to drive off this field would block the new worker.
        local blocker = self:parkingBlockerOn(task.fieldId, task.vehicleId)
        if blocker ~= nil then
            self:setState(task, "WAITING", string.format("waiting for %s to leave the field", blocker))
            return
        end
        local ok, reason, transient = FAValidator.validate(task, self:validationContext(task))
        if not ok then
            if transient then
                self:setState(task, "WAITING", reason)
            else
                self:setState(task, "FAILED", reason)
                FALog.warn(task.id, "%s rejected: %s", self:taskLabel(task), reason)
            end
            return
        end
        self:startHarvestJob(task, false)

    elseif task.state == "RUNNING" then
        self:monitorHarvest(task)

    elseif task.state == "RECOVERING" then
        self:updateHarvestRecovery(task)

    elseif task.state == "WAITING_WEATHER" then
        local ref = self:vehicleRef(task.vehicleId)
        local record = ref and self:liveVehicle(task.vehicleId)
        if record ~= nil and record.combine ~= nil and not FAGameAdapter.isThreshingBlockedByRain(record.combine.ref) then
            FALog.decision(task.id, "Rain has stopped; restarting harvest on field %s.", self:fieldName(task.fieldId))
            self:startHarvestJob(task, true)
        end
    end
end

function FATaskManager:startHarvestJob(task, isDirectStart)
    local op = opOf(task)
    local ref = self:vehicleRef(task.vehicleId)
    local field = self.agent.farmState.refs.fields[task.fieldId]
    if ref == nil or field == nil then
        self:setState(task, "FAILED", "machine or field no longer exists")
        return
    end
    local record = self:liveVehicle(task.vehicleId)

    if op == "SEED" then
        local crop = self:taskCrop(task)
        if crop == nil or not FAJobAdapter.setSeedCrop(ref, crop.index) then
            self:setState(task, "FAILED", "the seeder cannot sow " .. tostring(task.crop))
            FALog.warn(task.id, "%s cannot sow %s.", record.name, tostring(task.crop))
            return
        end
    end

    self:noteJobStart(task.vehicleId, record)
    local x, z, dirX, dirZ = FAGeometry.getFieldEntryPoint(field.polygon, field.labelX, field.labelZ, record.x, record.z, 10)
    local job, err = FAJobAdapter.startFieldWork(ref, self.agent.farmId, x, z, dirX, dirZ, isDirectStart)
    if job == nil then
        task.startFailures = task.startFailures + 1
        if task.startFailures >= 3 then
            self:escalate(task, "could not start the AI worker: " .. tostring(err))
        else
            task.retryAt = self.now + 10000
            self:setState(task, "WAITING", "start failed (" .. tostring(err) .. "), retrying")
            FALog.warn(task.id, "Could not start AI worker on %s: %s", record.name, tostring(err))
        end
        return
    end

    self:attachJob(task, job, op)
    task.startFailures = 0
    task.lastX, task.lastZ, task.lastMoveAt = record.x, record.z, self.now
    task.startedAt = task.startedAt or self.now
    task.lastScanRequestAt = self.now
    if task.initialReady == nil then
        local result = self.agent.scanner:getResult(task.fieldId)
        if op == "FERTILIZE" and task.startSprayLevel == nil then
            task.startSprayLevel = FAFieldScanner.soilSummary(result, self:soilContext()).sprayMode or 0
        end
        task.initialReady = math.max(self:remainingFor(task, result), 0.01)
    end
    self:setState(task, "RUNNING", "")
    task.substate = isDirectStart and "WORKING" or "DRIVING_TO_FIELD"
    FALog.action(task.id, "%s AI worker: %s -> %s.", isDirectStart and "Restarted" or "Started", record.name, self:taskLabel(task))
end

-- Is a logistics task (not waiting on the player) serving this combine for this crop?
function FATaskManager:hasLogisticsFor(combineId, cropName)
    local t = self:findLogisticsFor(combineId, cropName)
    return t ~= nil and t.state ~= "ESCALATED"
end

-- Learns the fully unfolded pipe end of a combine (combine-local) and remembers it per
-- combine, so unloading never depends on catching the pipe mid-unfold.
function FATaskManager:pipeOffsetFor(combineRec)
    local combine = combineRec.combine and combineRec.combine.ref
    if combine == nil then
        return nil
    end
    local memory = self.agent.memory
    local id = FAGameAdapter.getUniqueId(combineRec.ref)
    local x, z = FAGameAdapter.getPipeLocalOffset(combine)
    if x ~= nil then
        if memory ~= nil then
            memory:setPipeOffset(id, x, z)
        end
        return x, z
    end
    if memory ~= nil then
        return memory:getPipeOffset(id)
    end
    return nil
end

function FATaskManager:monitorHarvest(task)
    local op = opOf(task)
    local record = self:liveVehicle(task.vehicleId)
    if record == nil then
        self:setState(task, "FAILED", "machine was sold or deleted")
        return
    end
    if op == "HARVEST" then
        -- A trailer may have become free since this harvest started: attach it.
        if self.now - (task.logisticsCheckAt or -math.huge) > 10000 then
            task.logisticsCheckAt = self.now
            if self:findLogisticsFor(task.vehicleId, self:taskCropName(task)) == nil then
                self:ensureLogistics(task)
            end
        end
        if record.combine ~= nil then
            self:pipeOffsetFor(record) -- learn while the AI has the pipe out
        end
    end
    if task.job ~= nil and not FAJobAdapter.isJobRunning(task.job) and self.now - (task.jobStartedAt or 0) > 5000 then
        -- Stop message missed (should not happen; AISystem publishes AI_JOB_STOPPED synchronously).
        local job = task.job
        self.jobToTask[job] = nil
        task.job = nil
        self:onHarvestJobEnded(task, "unknown", "AI worker disappeared")
        return
    end

    -- Progress: independent measurement by sampling the field.
    if self.now - (task.lastScanRequestAt or 0) > FATaskManager.FIELD_RESCAN_MS then
        task.lastScanRequestAt = self.now
        self.agent.scanner:request(task.fieldId)
    end
    local result = self.agent.scanner:getResult(task.fieldId)
    local remaining = self:remainingFor(task, result)
    task.progress = math.max(0, math.min(1, 1 - remaining / task.initialReady))

    -- Movement
    local moved = FAGeometry.distance(task.lastX, task.lastZ, record.x, record.z)
    if moved > 1.0 then
        task.lastX, task.lastZ, task.lastMoveAt = record.x, record.z, self.now
        if task.recoveryStep > 0 and task.recoveredAt == nil then
            task.recoveredAt = self.now
            FALog.info(task.id, "Recovery successful: %s is moving again.", record.name)
            self:clearAttention(task)
        end
    end
    if task.recoveredAt ~= nil and self.now - task.recoveredAt > FATaskManager.RECOVERY_HEALTHY_MS then
        task.recoveryStep = 0
        task.recoveredAt = nil
    end

    -- Legitimate waits are not stalls.
    local combine = record.combine
    local job = task.job
    if combine ~= nil then
        local full = combine.capacity > 0 and combine.fillLevel >= combine.capacity * FATaskManager.COMBINE_FULL_RATIO
        if full then
            task.substate = "WAITING_FOR_UNLOAD"
            task.lastMoveAt = self.now
            if not task.fullNotified then
                task.fullNotified = true
                if self:hasLogisticsFor(task.vehicleId, self:taskCropName(task)) then
                    FALog.info(task.id, "%s grain tank full; waiting for the assigned trailer.", record.name)
                else
                    self:addAttention(task, string.format("%s is full on field %s and no trailer is assigned - please unload it.", record.name, self:fieldName(task.fieldId)))
                end
            end
            return
        end
        if task.fullNotified then
            task.fullNotified = false
            self:clearAttention(task)
        end
        if FAGameAdapter.isThreshingBlockedByRain(combine.ref) then
            task.substate = "WAITING_RAIN"
            task.lastMoveAt = self.now
            return
        end
    end
    if job ~= nil and job.driveToTask ~= nil and job.currentTaskIndex == job.driveToTask.taskIndex then
        task.substate = "DRIVING_TO_FIELD"
    else
        task.substate = op == "HARVEST" and "HARVESTING" or "WORKING"
    end

    if self.now - task.lastMoveAt > FATaskManager.STALL_MS then
        FALog.warn(task.id, "%s has not moved for %d s (progress %d%%).", record.name, math.floor((self.now - task.lastMoveAt) / 1000), math.floor(task.progress * 100))
        self:beginHarvestRecovery(task, record)
    end
end

-- Answers the "why is it stuck?" checklist. Returns findings (strings) and a fatal reason if any.
function FATaskManager:diagnose(task, record)
    local findings = {}
    local fatal = nil
    if record.fuel ~= nil then
        table.insert(findings, string.format("fuel %d%%", math.floor(record.fuel * 100)))
        if record.fuel < 0.02 then fatal = "out of fuel - refuel it, then say 'resume'" end
    end
    table.insert(findings, string.format("damage %d%%", math.floor((record.damage or 0) * 100)))
    if record.isBroken then fatal = "vehicle is broken down - repair it, then say 'resume'" end
    table.insert(findings, task.job ~= nil and FAJobAdapter.isJobRunning(task.job) and "AI worker active" or "AI worker not running")

    local result = self.agent.scanner:scanNow(task.fieldId)
    local remaining = self:remainingFor(task, result)
    table.insert(findings, string.format("%d%% of the field still to do", math.floor(remaining * 100)))
    if remaining <= self:doneThreshold(task) then
        task.fieldLooksDone = true
    end

    local blocker = FAGameAdapter.findVehicleInFront(record.ref, 15, 5)
    if blocker ~= nil then
        table.insert(findings, "blocked by " .. blocker)
    else
        table.insert(findings, "nothing directly in front")
    end
    return findings, fatal
end

function FATaskManager:beginHarvestRecovery(task, record, reason)
    record = record or self:liveVehicle(task.vehicleId)
    if record == nil then
        self:setState(task, "FAILED", "machine was sold or deleted")
        return
    end
    FALog.decision(task.id, "Investigating %s%s.", record.name, reason and (" (" .. reason .. ")") or "")
    local findings, fatal = self:diagnose(task, record)
    FALog.decision(task.id, "Checks: %s.", table.concat(findings, ", "))
    if self.agent.memory ~= nil then
        self.agent.memory:recordStall(task.fieldId)
    end

    if task.fieldLooksDone then
        task.fieldLooksDone = nil
        self:stopOwnJob(task)
        self:finishHarvestVerified(task, "field measured as done")
        return
    end
    if fatal ~= nil then
        self:stopOwnJob(task)
        self:escalate(task, record.name .. ": " .. fatal)
        return
    end

    task.recoveryStep = task.recoveryStep + 1
    task.recoveredAt = nil
    if task.recoveryStep > FATaskManager.MAX_RECOVERY_STEPS then
        self:stopOwnJob(task)
        self:escalate(task, string.format("%s is still stuck after %d recovery attempts (%s). Please check it, then say 'resume'.",
            record.name, FATaskManager.MAX_RECOVERY_STEPS, table.concat(findings, ", ")))
        return
    end

    local mode = task.recoveryStep == 1 and "RESTART" or "REPOSITION"
    FALog.action(task.id, "Recovery attempt %d/%d: %s.", task.recoveryStep, FATaskManager.MAX_RECOVERY_STEPS,
        mode == "RESTART" and "stop worker and restart it in place" or "stop worker, back off 15 m, restart")
    self:stopOwnJob(task)
    task.recovery = { mode = mode, phase = "STOPPING", at = self.now }
    self:setState(task, "RECOVERING", "recovery attempt " .. task.recoveryStep)
end

function FATaskManager:updateHarvestRecovery(task)
    local r = task.recovery
    if r == nil then
        self:setState(task, "PENDING")
        return
    end
    if r.phase == "STOPPING" and self.now - r.at >= 3000 then
        local record = self:liveVehicle(task.vehicleId)
        if record == nil then
            self:setState(task, "FAILED", "machine was sold or deleted")
            return
        end
        if r.mode == "RESTART" then
            task.recovery = nil
            self:startHarvestJob(task, true)
        else
            local backX = record.x - record.dirX * 15
            local backZ = record.z - record.dirZ * 15
            self:noteJobStart(task.vehicleId, record)
            local job, err = FAJobAdapter.startGoTo(record.ref, self.agent.farmId, backX, backZ, record.dirX, record.dirZ, 0)
            if job == nil then
                FALog.warn(task.id, "Reposition failed (%s); restarting in place instead.", tostring(err))
                task.recovery = nil
                self:startHarvestJob(task, true)
            else
                self:attachJob(task, job, "REPOSITION")
                r.phase = "REPOSITIONING"
                r.at = self.now
            end
        end
    elseif r.phase == "REPOSITIONING" and self.now - r.at > 120000 then
        self:stopOwnJob(task)
        task.recovery = nil
        self:startHarvestJob(task, true)
    end
end

function FATaskManager:finishHarvestVerified(task, how)
    task.progress = 1
    self:setState(task, "DONE", how)
    self.stats.fieldsDone = self.stats.fieldsDone + 1
    self:clearAttention(task)
    if opOf(task) == "HARVEST" and self.agent.memory ~= nil and self:taskCropName(task) ~= nil then
        self.agent.memory:recordHarvest(task.fieldId, self:taskCropName(task))
    end
    FALog.info(task.id, "%s: done (%s).", self:taskLabel(task), how)
end

-- Never trust "finished" blindly: measure the field.
function FATaskManager:verifyHarvest(task)
    local result = self.agent.scanner:scanNow(task.fieldId)
    local remaining = self:remainingFor(task, result)
    if remaining <= self:doneThreshold(task) then
        self:finishHarvestVerified(task, string.format("verified, %d%% left to do", math.floor(remaining * 100 + 0.5)))
        return
    end
    task.verifyRestarts = task.verifyRestarts + 1
    if task.verifyRestarts <= 2 then
        FALog.warn(task.id, "AI worker reported %s finished, but %d%% is still to do. Restarting.", self:taskLabel(task), math.floor(remaining * 100))
        self:startHarvestJob(task, false)
    else
        self:escalate(task, string.format("AI worker keeps stopping with %d%% of the field still to do (odd field shape or obstacles?).", math.floor(remaining * 100)))
    end
end

function FATaskManager:onHarvestJobEnded(task, msgName, msgText)
    if task.state == "RECOVERING" and task.recovery ~= nil and task.recovery.phase == "REPOSITIONING" then
        FALog.action(task.id, "Repositioned (%s); restarting work.", msgName)
        task.recovery = nil
        self:startHarvestJob(task, true)
        return
    end

    if msgName == MSG.FINISHED then
        self:setState(task, "VERIFYING", "checking the field")
        FALog.info(task.id, "AI worker reports %s finished; verifying.", self:taskLabel(task))
        self:verifyHarvest(task)
    elseif msgName == MSG.STOPPED_BY_USER then
        self:setState(task, "PAUSED_BY_PLAYER", "you stopped the worker - Alt+L to hand it back")
        FALog.info(task.id, "Player stopped the worker on field %s. Farm Agent will not restart it until you press Alt+L or say 'resume'.", self:fieldName(task.fieldId))
        FAGameAdapter.notify(string.format("you stopped the worker on field %s. Press Alt+L to let Farm Agent continue.", self:fieldName(task.fieldId)), false)
    elseif msgName == MSG.OUT_OF_FUEL then
        self:escalate(task, "out of fuel - refuel it, then say 'resume' (or enable 'helper buys fuel')")
    elseif msgName == MSG.OUT_OF_FILL then
        self:escalate(task, "seeder/sprayer ran empty - refill it (or enable 'helper buys seeds/fertilizer'), then press Alt+L")
    elseif msgName == MSG.BROKEN then
        self:escalate(task, "vehicle broke down - repair it, then say 'resume'")
    elseif msgName == MSG.OUT_OF_MONEY then
        self.paused = true
        self:escalate(task, "farm is out of money for AI wages - Farm Agent paused")
    elseif msgName == MSG.RAIN then
        self:setState(task, "WAITING_WEATHER", "too wet to thresh")
        FALog.info(task.id, "Too wet to thresh; waiting for the rain to stop.")
    elseif msgName == MSG.WRONG_SEASON then
        self:setState(task, "FAILED", "not the planting season for " .. tostring(task.crop))
        FALog.warn(task.id, "%s: not the planting season.", self:taskLabel(task))
    elseif msgName == MSG.NOT_OWNED or msgName == MSG.DELETED then
        self:setState(task, "FAILED", msgText)
        FALog.warn(task.id, "%s failed: %s", self:taskLabel(task), msgText)
    elseif msgName == MSG.NOT_READY or msgName == MSG.NO_FIELD then
        local result = self.agent.scanner:scanNow(task.fieldId)
        if self:remainingFor(task, result) <= self:doneThreshold(task) then
            self:finishHarvestVerified(task, "field measured as done")
        else
            self:beginHarvestRecovery(task, nil, msgText)
        end
    else
        -- Not reachable, could not prepare, blocked, unknown...
        self:beginHarvestRecovery(task, nil, msgText)
    end
end

-- UNLOAD_COMBINE (logistics loop) ----------------------------------------------
--
--   IDLE -> (prestage near a filling combine) -> WAIT_PIPE -> TO_COMBINE -> LOADING
--        -> DELIVERING | TO_STANDBY -> IDLE ... -> DONE
-- Every substate has a deadline; a leg that overruns is re-planned or escalated, so the
-- loop can never spin forever (first in-game test: 10+ minutes of silent retries).

FATaskManager.SUBSTATE_DEADLINE_MS = {
    WAIT_PIPE = 90000, TO_COMBINE = 360000, LOADING = 240000, TO_STANDBY = 240000, DELIVERING = 1200000,
}

-- Unfinished harvests of this crop that this combine is (or may be) doing. Queued fields
-- of the same crop count, since this combine may be the one that takes them.
function FATaskManager:combineHasMoreWork(combineId, cropName)
    for _, t in ipairs(self.tasks) do
        if t.action == "HARVEST_FIELD" and not TERMINAL[t.state] and (t.vehicleId == combineId or t.vehicleId == nil) then
            local tCrop = self:taskCropName(t)
            if cropName == nil or tCrop == nil or tCrop == cropName then
                return true
            end
        end
    end
    return false
end

function FATaskManager:combineIsHarvesting(combineId)
    for _, t in ipairs(self.tasks) do
        if t.action == "HARVEST_FIELD" and t.vehicleId == combineId and not TERMINAL[t.state] then
            return true
        end
    end
    return false
end

function FATaskManager:currentFieldOf(combineId)
    for _, t in ipairs(self.tasks) do
        if t.action == "HARVEST_FIELD" and t.vehicleId == combineId and not TERMINAL[t.state] then
            return self.agent.farmState.refs.fields[t.fieldId]
        end
    end
    return nil
end

local function pickTrailer(record, crop)
    for _, t in ipairs(record.trailers or {}) do
        if crop ~= nil and crop.fillTypeIndex ~= nil and t.ref:getFillUnitSupportsFillType(t.fillUnitIndex, crop.fillTypeIndex) then
            return t
        end
    end
    return nil
end

function FATaskManager:setSubstate(task, substate)
    if task.substate ~= substate then
        task.substate = substate
        task.substateSince = self.now
    end
end

function FATaskManager:updateLogistics(task)
    if task.state == "PENDING" or task.state == "WAITING" then
        if self.paused then
            return
        end
        local ok, reason, transient = FAValidator.validate(task, self:validationContext(task))
        if not ok then
            if transient then
                self:setState(task, "WAITING", reason)
            else
                self:setState(task, "FAILED", reason)
                FALog.warn(task.id, "%s rejected: %s", self:taskLabel(task), reason)
            end
            return
        end
        self:setState(task, "RUNNING", "")
        self:setSubstate(task, "IDLE")
        FALog.action(task.id, "%s assigned as grain transport for %s.", self:vehicleName(task.vehicleId), self:vehicleName(task.combineId))
        return
    end

    local transport = self:liveVehicle(task.vehicleId)
    local combineRec = self:liveVehicle(task.combineId)
    if transport == nil or combineRec == nil or combineRec.combine == nil then
        self:stopOwnJob(task)
        self:setState(task, "FAILED", "transport or combine no longer exists")
        return
    end
    local trailer = pickTrailer(transport, self:taskCrop(task))
    if trailer == nil then
        self:stopOwnJob(task)
        self:escalate(task, transport.name .. " has no trailer for this crop any more")
        return
    end
    local combine = combineRec.combine
    -- Only grain of this task's crop counts: another crop in the tank belongs to the
    -- combine's next job and must not go into this trailer.
    local crop = self:taskCrop(task)
    local combineFill = combine.fillLevel
    if crop ~= nil and crop.fillTypeIndex ~= nil and combine.fillTypeIndex ~= nil and combine.fillTypeIndex ~= 0
        and combine.fillTypeIndex ~= crop.fillTypeIndex then
        combineFill = 0
    end
    local trailerRatio = trailer.capacity > 0 and trailer.fillLevel / trailer.capacity or 1
    local combineRatio = combine.capacity > 0 and combineFill / combine.capacity or 0
    local combineFull = combineRatio >= FATaskManager.COMBINE_FULL_RATIO
    local combineStopped = (combineRec.speedKmh or 0) < 1
    local moreWork = self:combineHasMoreWork(task.combineId, self:taskCropName(task))
    local sub = task.substate

    -- Deadline per substate: nothing may wait forever.
    local deadline = FATaskManager.SUBSTATE_DEADLINE_MS[sub]
    if deadline ~= nil and task.state ~= "ESCALATED" and self.now - (task.substateSince or self.now) > deadline then
        FALog.warn(task.id, "%s: %s took longer than %d s; re-planning this leg.", transport.name, sub, deadline / 1000)
        self:stopOwnJob(task)
        task.legTimeouts = (task.legTimeouts or 0) + 1
        if task.legTimeouts > 2 then
            self:escalate(task, string.format("%s keeps timing out (%s). Please check it, then press Alt+L.", transport.name, sub))
        else
            self:setSubstate(task, "IDLE")
        end
        return
    end

    -- Transport stall watchdog while driving. The counter is only reset after a leg
    -- actually completes, so repeated stalls escalate instead of looping.
    if task.job ~= nil and (sub == "TO_COMBINE" or sub == "DELIVERING" or sub == "TO_STANDBY") then
        if task.lastX == nil or FAGeometry.distance(task.lastX, task.lastZ, transport.x, transport.z) > 1 then
            task.lastX, task.lastZ, task.lastMoveAt = transport.x, transport.z, self.now
        elseif self.now - (task.lastMoveAt or self.now) > FATaskManager.TRANSPORT_STALL_MS then
            local blocker = FAGameAdapter.findVehicleInFront(transport.ref, 15, 5)
            FALog.warn(task.id, "%s has not moved for %d s%s.", transport.name, FATaskManager.TRANSPORT_STALL_MS / 1000, blocker and (" (blocked by " .. blocker .. ")") or "")
            task.transportStalls = (task.transportStalls or 0) + 1
            self:stopOwnJob(task)
            task.lastMoveAt = self.now
            if task.transportStalls >= 2 then
                self:escalate(task, transport.name .. " is stuck" .. (blocker and (" behind " .. blocker) or "") .. ". Please free it, then press Alt+L.")
            else
                FALog.action(task.id, "Recovery: re-planning the %s leg.", sub)
                self:setSubstate(task, "IDLE")
            end
            return
        end
    end

    if sub == "IDLE" then
        if self.paused then
            return
        end
        if trailer.fillLevel > 1 and (trailerRatio >= FATaskManager.DELIVER_THRESHOLD or (not moreWork and combineFill < 1)) then
            self:startDelivery(task, transport, trailer)
        elseif (combineFull or (not moreWork and combineFill > 1)) and combineStopped then
            if not combineRec.aiActive and combine.hasPipe and FAGameAdapter.getPipeTargetState(combine.ref) ~= 2 then
                -- Combine finished its field with grain left: unfold the pipe so it can
                -- unload (same setPipeState call the vanilla AI combine strategy uses).
                FAJobAdapter.setPipeState(combine.ref, 2)
                FALog.action(task.id, "Unfolding the pipe of %s for the final unload.", combineRec.name)
            end
            task.prestaged = false
            self:setSubstate(task, "WAIT_PIPE")
            self:tryRendezvous(task, transport, trailer, combineRec)
        elseif not moreWork and combineFill <= 1 and trailer.fillLevel <= 1 then
            if not combineRec.aiActive and combine.hasPipe then
                FAJobAdapter.setPipeState(combine.ref, 1)
            end
            self:setState(task, "DONE", string.format("all grain from %s delivered", combineRec.name))
            FALog.info(task.id, "%s: all grain from %s delivered.", transport.name, combineRec.name)
        elseif moreWork and combineRatio >= FATaskManager.PRESTAGE_RATIO and not task.prestaged
            and FAGeometry.distance(transport.x, transport.z, combineRec.x, combineRec.z) > FATaskManager.PRESTAGE_DISTANCE then
            -- Combine filling up: wait at the field edge instead of across the farm.
            task.prestaged = true
            FALog.decision(task.id, "%s is %d%% full; %s moves to the field edge to be ready.",
                combineRec.name, math.floor(combineRatio * 100), transport.name)
            self:startStandby(task, transport, combineRec)
        else
            task.note = string.format("standing by (combine %d%%, trailer %d%%)", math.floor(combineRatio * 100), math.floor(trailerRatio * 100))
        end

    elseif sub == "WAIT_PIPE" then
        if not combineStopped and combineRec.aiActive and not combineFull then
            self:setSubstate(task, "IDLE") -- combine carried on (it was not completely full)
        else
            self:tryRendezvous(task, transport, trailer, combineRec)
        end

    elseif sub == "LOADING" then
        local under = FAGameAdapter.getVehicleUnderPipe(combine.ref) == trailer.ref
        if trailer.fillLevel > (task.lastFill or 0) + 1 then
            task.lastFill = trailer.fillLevel
            task.lastFillChangeAt = self.now
            if not task.loadingStarted then
                task.loadingStarted = true
                FALog.info(task.id, "%s is unloading into %s.", combineRec.name, transport.name)
                if task.state == "ESCALATED" then
                    self:setState(task, "RUNNING", "")
                    self:clearAttention(task)
                end
            end
        end
        task.note = string.format("loading %d%%%s", math.floor(trailerRatio * 100), under and "" or " (not under pipe)")
        local combineLeft = not under and not combineStopped and combineRec.aiActive
        local done = combineFill < 1 or trailerRatio >= 0.98
            or (task.loadingStarted and self.now - task.lastFillChangeAt > FATaskManager.LOADING_IDLE_MS)
            or (combineLeft and self.now - task.arrivedAt > 5000)
        if done then
            if combineLeft and not (combineFill < 1) then
                FALog.info(task.id, "%s drove on before unloading finished; %s will meet it at the next stop.", combineRec.name, transport.name)
            end
            local loaded = trailer.fillLevel - (task.fillAtArrival or 0)
            FALog.info(task.id, "Loaded %.0f l; trailer %d%% full.", loaded, math.floor(trailerRatio * 100))
            task.transportStalls = 0
            task.legTimeouts = 0
            if trailer.fillLevel > 1 and (trailerRatio >= FATaskManager.DELIVER_THRESHOLD or not moreWork) then
                self:startDelivery(task, transport, trailer)
            elseif moreWork then
                self:startStandby(task, transport, combineRec)
            else
                self:setSubstate(task, "IDLE")
            end
        elseif not task.loadingStarted and task.state ~= "ESCALATED" and self.now - task.arrivedAt > FATaskManager.LOADING_START_TIMEOUT_MS then
            self:correctUnderPipe(task, transport, trailer, combineRec)
        end
    end
    -- TO_COMBINE / DELIVERING / TO_STANDBY progress is driven by job-ended events.
    if sub == "DELIVERING" and task.job ~= nil then
        FAJobAdapter.skipWaitingForFilling(task.job)
    end
end

-- Computes the under-pipe target from the learned, fully unfolded pipe position and
-- sends the rig. Stays in WAIT_PIPE (and says why) until that is possible.
function FATaskManager:tryRendezvous(task, transport, trailer, combineRec)
    local pipeX, pipeZ = self:pipeOffsetFor(combineRec)
    if pipeX == nil then
        task.note = "waiting for the pipe of " .. combineRec.name .. " to unfold"
        return
    end
    local x, z, dirX, dirZ, pose = FAGameAdapter.computeUnderPipeTarget(combineRec.combine.ref, transport.ref, trailer, pipeX, pipeZ)
    if x == nil then
        self:escalate(task, string.format("cannot park safely next to %s: %s. Please unload it yourself.", combineRec.name, tostring(z)))
        return
    end
    FALog.decision(task.id, "Pipe end %.1f m to the side; trailer line %.1f m%s, %.1f m clear of the %s.",
        math.abs(pipeX), math.abs(pose.x), pose.shift > 0.05 and string.format(" (moved out %.1f m)", pose.shift) or "",
        pose.clearance, pose.obstacle)
    self:startRendezvous(task, transport, trailer, combineRec, { x = x, z = z, dirX = dirX, dirZ = dirZ }, false)
end

-- isCorrection: short straight approach for small corrections.
function FATaskManager:startRendezvous(task, transport, trailer, combineRec, target, isCorrection)
    local approach = isCorrection and 8 or FATaskManager.APPROACH_OFFSET
    self:noteJobStart(task.vehicleId, transport)
    local job, err = FAJobAdapter.startGoTo(transport.ref, self.agent.farmId, target.x, target.z, target.dirX, target.dirZ,
        approach, FATaskManager.FINAL_APPROACH_SPEED)
    if job == nil then
        task.note = "could not start GoTo: " .. tostring(err)
        FALog.warn(task.id, "Could not send %s to %s: %s", transport.name, combineRec.name, tostring(err))
        return
    end
    self:attachJob(task, job, "TO_COMBINE")
    self:setSubstate(task, "TO_COMBINE")
    task.lastTarget = target
    task.lastX = nil
    FALog.action(task.id, "Sending %s under the pipe of %s.", transport.name, combineRec.name)
end

function FATaskManager:correctUnderPipe(task, transport, trailer, combineRec)
    task.pipeCorrections = (task.pipeCorrections or 0) + 1
    if task.pipeCorrections > FATaskManager.MAX_PIPE_CORRECTIONS or task.lastTarget == nil then
        self:escalate(task, string.format("could not park %s under the pipe of %s. Please position it; unloading continues automatically once grain flows.",
            transport.name, combineRec.name))
        return
    end
    if not FAGameAdapter.isPipeFullyUnfolded(combineRec.combine.ref) then
        task.note = "waiting for the pipe to finish unfolding before correcting"
        task.arrivedAt = self.now - FATaskManager.LOADING_START_TIMEOUT_MS + 5000
        task.pipeCorrections = task.pipeCorrections - 1
        return
    end
    local dx, dz = FAGameAdapter.getUnderPipeError(combineRec.combine.ref, trailer)
    if dx == nil then
        self:escalate(task, "cannot measure trailer position relative to the pipe")
        return
    end
    local err = math.sqrt(dx * dx + dz * dz)
    if err > FATaskManager.MAX_CORRECTION_M then
        -- The combine has moved (or the target was nonsense): plan from scratch.
        FALog.warn(task.id, "Trailer is %.0f m from the pipe - the combine moved; re-planning.", err)
        self:setSubstate(task, "IDLE")
        return
    end
    local target = { x = task.lastTarget.x - dx, z = task.lastTarget.z - dz, dirX = task.lastTarget.dirX, dirZ = task.lastTarget.dirZ }
    FALog.action(task.id, "Trailer is %.1f m off the pipe; correction %d/%d.", err, task.pipeCorrections, FATaskManager.MAX_PIPE_CORRECTIONS)
    self:startRendezvous(task, transport, trailer, combineRec, target, true)
end

function FATaskManager:startDelivery(task, transport, trailer)
    local station = self.agent.farmState.refs.stations[task.stationId]
    if station == nil then
        self:escalate(task, "the delivery station no longer exists")
        return
    end
    self:noteJobStart(task.vehicleId, transport)
    local job, err = FAJobAdapter.startDeliver(transport.ref, self.agent.farmId, station)
    if job == nil then
        task.deliverFailures = (task.deliverFailures or 0) + 1
        if task.deliverFailures >= 3 then
            self:escalate(task, "could not start delivery: " .. tostring(err))
        else
            task.note = "delivery start failed: " .. tostring(err)
            FALog.warn(task.id, "Could not start delivery for %s: %s", transport.name, tostring(err))
        end
        return
    end
    task.deliverFailures = 0
    self:attachJob(task, job, "DELIVERING")
    self:setSubstate(task, "DELIVERING")
    task.fillBeforeDelivery = trailer.fillLevel
    task.lastX = nil
    FALog.action(task.id, "%s delivering %.0f l to %s.", transport.name, trailer.fillLevel, station:getName())
end

function FATaskManager:startStandby(task, transport, combineRec)
    local field = self:currentFieldOf(task.combineId)
    if field == nil then
        self:setSubstate(task, "IDLE")
        return
    end
    local x, z = FAGeometry.getStandbyPoint(field.polygon, field.labelX, field.labelZ, combineRec.x or transport.x, combineRec.z or transport.z, 15)
    local dirX, dirZ = FAGeometry.normalize(x - field.labelX, z - field.labelZ)
    self:noteJobStart(task.vehicleId, transport)
    local job = FAJobAdapter.startGoTo(transport.ref, self.agent.farmId, x, z, dirX, dirZ, 0)
    if job == nil then
        self:setSubstate(task, "IDLE")
        FALog.warn(task.id, "Could not move %s off the field; it waits where it is.", transport.name)
        return
    end
    self:attachJob(task, job, "TO_STANDBY")
    self:setSubstate(task, "TO_STANDBY")
    task.lastX = nil
    FALog.action(task.id, "%s moving to the edge of field %s to wait for the next unload.", transport.name, field.name or "")
end

function FATaskManager:onLogisticsJobEnded(task, purpose, msgName, msgText)
    if msgName == MSG.STOPPED_BY_USER then
        self:setState(task, "PAUSED_BY_PLAYER", "player stopped the transport worker")
        FALog.info(task.id, "Player stopped %s. Press Alt+L to hand it back.", self:vehicleName(task.vehicleId))
        return
    end

    if purpose == "TO_COMBINE" then
        if msgName == MSG.FINISHED then
            local transport = self:liveVehicle(task.vehicleId)
            local trailer = transport and pickTrailer(transport, self:taskCrop(task))
            self:setSubstate(task, "LOADING")
            task.arrivedAt = self.now
            task.loadingStarted = false
            task.fillAtArrival = trailer and trailer.fillLevel or 0
            task.lastFill = task.fillAtArrival
            task.lastFillChangeAt = self.now
            task.transportStalls = 0
            FALog.info(task.id, "%s arrived at %s.", self:vehicleName(task.vehicleId), self:vehicleName(task.combineId))
        else
            task.gotoFailures = (task.gotoFailures or 0) + 1
            if task.gotoFailures >= 2 then
                self:escalate(task, "transport could not reach the combine: " .. msgText)
            else
                FALog.warn(task.id, "GoTo to combine failed (%s); will retry.", msgText)
                self:setSubstate(task, "IDLE")
            end
        end

    elseif purpose == "TO_STANDBY" then
        if msgName ~= MSG.FINISHED then
            FALog.warn(task.id, "Could not reach standby point (%s); waiting in place.", msgText)
        else
            task.transportStalls = 0
        end
        self:setSubstate(task, "IDLE")
        task.pipeCorrections = 0

    elseif purpose == "DELIVERING" then
        local transport = self:liveVehicle(task.vehicleId)
        local trailer = transport and pickTrailer(transport, self:taskCrop(task))
        local now = trailer and trailer.fillLevel or 0
        local delivered = (task.fillBeforeDelivery or 0) - now
        if msgName == MSG.FINISHED and delivered > 1 then
            self.stats.delivered = self.stats.delivered + delivered
            FALog.info(task.id, "Delivered %.0f l (verified: trailer went from %.0f l to %.0f l).", delivered, task.fillBeforeDelivery or 0, now)
            self:setSubstate(task, "IDLE")
            task.pipeCorrections = 0
            task.gotoFailures = 0
            task.transportStalls = 0
            task.legTimeouts = 0
            task.prestaged = false
        elseif msgName == MSG.STATION_FULL then
            self:escalate(task, "the silo is full - choose another station or sell, then press Alt+L")
        else
            task.deliverFailures = (task.deliverFailures or 0) + 1
            if task.deliverFailures >= 2 then
                self:escalate(task, string.format("delivery did not unload (%s, %.0f l still on trailer)", msgText, now))
            else
                FALog.warn(task.id, "Delivery ended without unloading (%s); retrying.", msgText)
                self:setSubstate(task, "IDLE")
            end
        end
    end
end

-- PARKING ------------------------------------------------------------------------
--
-- A vanilla AI worker leaves its machine where the job ended - usually on the field, where
-- it blocks the next worker (in-game report). After a short grace period (new work may take
-- the machine straight away) Farm Agent drives it to its home spot - where the player had
-- it parked before Farm Agent first used it - or, without one, just outside the field.
-- Only machines Farm Agent itself drove are moved; the player's own parking is respected.

function FATaskManager:onTaskTerminal(task, state)
    if state ~= "CANCELLED" and task.vehicleId ~= nil and (opOf(task) ~= nil or task.action == "UNLOAD_COMBINE") then
        self:requestPark(task.vehicleId)
    end
    if self.agent.onWorkFreed ~= nil then
        self.agent:onWorkFreed()
    end
end

function FATaskManager:requestPark(vehicleId, fallbackOnly)
    if not self.movedByAgent[vehicleId] or self.parks[vehicleId] ~= nil then
        return
    end
    local existing = self.parkRequests[vehicleId]
    self.parkRequests[vehicleId] = {
        at = self.now + FATaskManager.PARK_DELAY_MS,
        since = existing and existing.since or self.now,
        fallbackOnly = fallbackOnly == true,
    }
end

-- Is Farm Agent currently driving this machine to its parking spot? (Such a machine counts
-- as free: the park drive is cancelled when work takes it.)
function FATaskManager:isParking(vehicleId)
    return self.parks[vehicleId] ~= nil
end

function FATaskManager:fieldContaining(x, z)
    if x == nil then
        return nil
    end
    for _, field in pairs(self.agent.farmState.refs.fields) do
        if field.polygon ~= nil and FAGeometry.isPointInPolygon(x, z, field.polygon) then
            return field
        end
    end
    return nil
end

-- Called before Farm Agent starts any job on a machine: drops its parking and, if the
-- player left it somewhere off the fields, remembers that spot as its home.
function FATaskManager:noteJobStart(vehicleId, record)
    self.parkRequests[vehicleId] = nil
    self:cancelPark(vehicleId)
    local memory = self.agent.memory
    if not self.movedByAgent[vehicleId] and memory ~= nil and record ~= nil and record.ref ~= nil
        and record.x ~= nil and self:fieldContaining(record.x, record.z) == nil then
        local uid = FAGameAdapter.getUniqueId(record.ref)
        local hx, hz = memory:getHome(uid)
        if hx == nil or FAGeometry.distance(hx, hz, record.x, record.z) > 5 then
            memory:setHome(uid, record.x, record.z, record.dirX or 0, record.dirZ or 1)
            FALog.info("PARK", "%s: its current spot is its parking spot after work.", record.name or self:vehicleName(vehicleId))
        end
    end
    self.movedByAgent[vehicleId] = true
end

function FATaskManager:cancelPark(vehicleId)
    local park = self.parks[vehicleId]
    if park == nil then
        return false
    end
    self.parks[vehicleId] = nil
    if park.job ~= nil then
        -- Unregister first: stopJob publishes the stop event synchronously.
        self.parkJobs[park.job] = nil
        FAJobAdapter.stopJob(park.job)
    end
    return true
end

function FATaskManager:cancelAllParking()
    local ids = {}
    for id in pairs(self.parks) do
        table.insert(ids, id)
    end
    for _, id in ipairs(ids) do
        self:cancelPark(id)
    end
    self.parkRequests = {}
    return #ids
end

-- Name of a machine that is still to be parked (or being parked) inside this field, other
-- than exceptId. Field work waits for it so the two do not collide.
function FATaskManager:parkingBlockerOn(fieldId, exceptId)
    if next(self.parkRequests) == nil and next(self.parks) == nil then
        return nil
    end
    local field = self.agent.farmState.refs.fields[fieldId]
    if field == nil or field.polygon == nil then
        return nil
    end
    local function check(id)
        if id == exceptId then
            return nil
        end
        local record = self:liveVehicle(id)
        if record ~= nil and FAGeometry.isPointInPolygon(record.x, record.z, field.polygon) then
            return record.name
        end
        return nil
    end
    for id in pairs(self.parkRequests) do
        local name = check(id)
        if name ~= nil then return name end
    end
    for id in pairs(self.parks) do
        local name = check(id)
        if name ~= nil then return name end
    end
    return nil
end

-- Where to park: the machine's home spot if it has one off the fields, else a free spot
-- just outside the field it stands in. Returns x, z, dirX, dirZ, toHome.
function FATaskManager:parkingTarget(record, field, fallbackOnly)
    local memory = self.agent.memory
    if not fallbackOnly and memory ~= nil then
        local hx, hz, hdx, hdz = memory:getHome(FAGameAdapter.getUniqueId(record.ref))
        if hx ~= nil and self:fieldContaining(hx, hz) == nil then
            return hx, hz, hdx, hdz, true
        end
    end
    for _, outset in ipairs(FATaskManager.PARK_OUTSETS) do
        local x, z = FAGeometry.getStandbyPoint(field.polygon, field.labelX, field.labelZ, record.x, record.z, outset)
        local free = self:fieldContaining(x, z) == nil
        for otherId, park in pairs(self.parks) do
            if otherId ~= record.id and FAGeometry.distance(park.x, park.z, x, z) < 12 then
                free = false
            end
        end
        if free then
            local dirX, dirZ = FAGeometry.normalize(x - field.labelX, z - field.labelZ)
            return x, z, dirX, dirZ, false
        end
    end
    return nil
end

function FATaskManager:processParking()
    for id, park in pairs(self.parks) do
        if self.now - park.startedAt > FATaskManager.PARK_TIMEOUT_MS then
            FALog.warn("PARK", "%s did not reach its parking spot in %d min; leaving it where it is.",
                self:vehicleName(id), FATaskManager.PARK_TIMEOUT_MS / 60000)
            self:cancelPark(id)
        end
    end
    if next(self.parkRequests) == nil then
        return
    end
    local reserved = self:reservations()
    local due = {}
    for id, req in pairs(self.parkRequests) do
        if self.now >= req.at then
            table.insert(due, id)
        end
    end
    table.sort(due, function(a, b) return tostring(a) < tostring(b) end)
    for _, id in ipairs(due) do
        if not self:tryPark(id, self.parkRequests[id], reserved) then
            self.parkRequests[id] = nil
        end
    end
end

-- Returns true to keep the request (try again later), false to drop it.
function FATaskManager:tryPark(id, req, reserved)
    if reserved[id] ~= nil then
        local owner = self.byId[reserved[id]]
        if owner ~= nil and owner.action == "UNLOAD_COMBINE" and owner.combineId == id
            and self.now - req.since < FATaskManager.PARK_MAX_WAIT_MS then
            return true -- its trailer is collecting the last grain right now
        end
        return false -- new work took the machine; that work moves it
    end
    if self.paused then
        return true
    end
    local record = self:liveVehicle(id)
    if record == nil or record.aiActive then
        return false -- sold, or someone else's worker is driving it
    end
    if record.isEntered and (record.speedKmh or 0) > 1 then
        return false -- the player is driving it
    end
    local field = self:fieldContaining(record.x, record.z)
    if field == nil then
        return false -- already off the fields
    end
    if record.combine ~= nil and (record.combine.fillLevel or 0) > 1 and self:findLogisticsFor(id, nil) ~= nil
        and self.now - req.since < FATaskManager.PARK_MAX_WAIT_MS then
        return true -- its trailer still has to collect the last grain here
    end
    local active, limit = FAGameAdapter.getAILimit()
    if active ~= nil and limit ~= nil and active >= limit then
        return true -- no free helper right now
    end
    local x, z, dirX, dirZ, toHome = self:parkingTarget(record, field, req.fallbackOnly)
    if x == nil then
        FALog.warn("PARK", "%s: no free spot found next to field %s; leaving it there.", record.name, field.name or "")
        return false
    end
    if record.combine ~= nil and record.combine.hasPipe and FAGameAdapter.getPipeTargetState(record.combine.ref) ~= 1 then
        FAJobAdapter.setPipeState(record.combine.ref, 1) -- never drive off with the pipe out
    end
    local job, err = FAJobAdapter.startGoTo(record.ref, self.agent.farmId, x, z, dirX, dirZ, 0)
    if job == nil then
        req.failures = (req.failures or 0) + 1
        if req.failures >= 3 then
            FALog.warn("PARK", "Could not send %s to park (%s); leaving it on field %s.", record.name, tostring(err), field.name or "")
            return false
        end
        req.at = self.now + 10000
        return true
    end
    self.parks[id] = { job = job, toHome = toHome, startedAt = self.now, x = x, z = z, fieldId = field.id }
    self.parkJobs[job] = id
    FALog.action("PARK", "%s is done on field %s; driving it %s so it does not block the next worker.",
        record.name, field.name or "", toHome and "back to its parking spot" or "just off the field")
    return false
end

function FATaskManager:onParkJobEnded(id, job, aiMessage)
    self.parkJobs[job] = nil
    local park = self.parks[id]
    self.parks[id] = nil
    if park == nil then
        return
    end
    local msgName = FAJobAdapter.getMessageName(aiMessage)
    local name = self:vehicleName(id)
    if msgName == MSG.FINISHED then
        FALog.info("PARK", "%s parked %s.", name, park.toHome and "at its parking spot" or "next to the field")
        if park.toHome then
            self.movedByAgent[id] = nil -- back where the player left it
        end
    elseif msgName == MSG.STOPPED_BY_USER then
        FALog.info("PARK", "You stopped %s while it was parking; leaving it where it is.", name)
    elseif park.toHome then
        FALog.warn("PARK", "%s could not reach its parking spot (%s); parking it next to the field instead.",
            name, FAJobAdapter.getMessageText(aiMessage, job))
        self:requestPark(id, true)
    else
        FALog.warn("PARK", "%s could not park off the field (%s).", name, FAJobAdapter.getMessageText(aiMessage, job))
    end
    if self.agent.onWorkFreed ~= nil then
        self.agent:onWorkFreed()
    end
end

-- Job events ---------------------------------------------------------------------

-- Subscribed to MessageType.AI_JOB_STOPPED (payload: job, aiMessage).
function FATaskManager:onAIJobStopped(job, aiMessage)
    local parkedId = self.parkJobs[job]
    if parkedId ~= nil then
        self:onParkJobEnded(parkedId, job, aiMessage)
        return
    end
    local task = self.jobToTask[job]
    if task == nil then
        return
    end
    self.jobToTask[job] = nil
    task.job = nil
    local purpose = task.jobPurpose
    task.jobPurpose = nil
    if task.expectStop then
        task.expectStop = false
        return
    end
    local msgName = FAJobAdapter.getMessageName(aiMessage)
    local msgText = FAJobAdapter.getMessageText(aiMessage, job)
    FALog.info(task.id, "AI job ended: %s.", msgName)
    local ok, err = pcall(function()
        if opOf(task) ~= nil then
            self:onHarvestJobEnded(task, msgName, msgText)
        else
            self:onLogisticsJobEnded(task, purpose, msgName, msgText)
        end
    end)
    if not ok then
        FALog.error(task.id, "Internal error handling job end: %s", tostring(err))
        self:escalate(task, "internal Farm Agent error (see log.txt)")
    end
end

-- REPORT / objective -------------------------------------------------------------

function FATaskManager:updateReport(task)
    for _, depId in ipairs(task.deps or {}) do
        local dep = self.byId[depId]
        if dep ~= nil and not TERMINAL[dep.state] then
            return
        end
    end
    -- "harvested 2, cultivated 1; 1 not done; 8000 l delivered; 34 min"
    local doneByOp, order, failed = {}, {}, 0
    for _, t in ipairs(self.tasks) do
        local op = opOf(t)
        if op ~= nil then
            if t.state == "DONE" then
                if doneByOp[op] == nil then
                    doneByOp[op] = 0
                    table.insert(order, op)
                end
                doneByOp[op] = doneByOp[op] + 1
            else
                failed = failed + 1
            end
        end
    end
    local PAST = { HARVEST = "harvested", CULTIVATE = "cultivated", PLOW = "plowed", SEED = "planted", FERTILIZE = "fertilized", LIME = "limed" }
    local parts = {}
    for _, op in ipairs(order) do
        table.insert(parts, string.format("%s %d", PAST[op] or op, doneByOp[op]))
    end
    local minutes = (self.now - self.startedAt) / 60000
    local summary = string.format("Objective complete: %s%s%s, %.0f min.",
        #parts > 0 and table.concat(parts, ", ") or "nothing done",
        failed > 0 and string.format("; %d field job(s) not done", failed) or "",
        self.stats.delivered > 0 and string.format("; %.0f l delivered", self.stats.delivered) or "", minutes)
    self:setState(task, "DONE", summary)
    FALog.info("REPORT", "%s", summary)
    FAGameAdapter.notify(summary, false)
end

function FATaskManager:updateObjectiveStatus()
    if self.status ~= "RUNNING" or self.continuous then
        return -- autopilot plans never complete; they idle until new work appears
    end
    local allTerminal = true
    for _, t in ipairs(self.tasks) do
        if not TERMINAL[t.state] then
            allTerminal = false
        end
    end
    if allTerminal and #self.tasks > 0 then
        local anyFailed = false
        for _, t in ipairs(self.tasks) do
            if t.state ~= "DONE" then anyFailed = true end
        end
        self.status = anyFailed and "COMPLETE_WITH_ISSUES" or "COMPLETE"
        self.agent:onObjectiveFinished(self.status)
    end
end

-- Player controls ------------------------------------------------------------------

function FATaskManager:pause()
    self.paused = true
    FALog.action("CONTROL", "Farm Agent paused: no new work will be dispatched. Running AI workers continue.")
end

function FATaskManager:resume()
    self.paused = false
    local count = 0
    for _, t in ipairs(self.tasks) do
        if t.state == "PAUSED_BY_PLAYER" or t.state == "ESCALATED" then
            self:stopOwnJob(t)
            t.recoveryStep = 0
            t.startFailures = 0
            t.deliverFailures = 0
            t.gotoFailures = 0
            t.transportStalls = 0
            t.pipeCorrections = 0
            if t.action == "UNLOAD_COMBINE" and t.substate ~= nil then
                self:setState(t, "RUNNING", "resumed")
                t.substate = "IDLE"
            else
                self:setState(t, "PENDING", "resumed")
            end
            count = count + 1
        end
    end
    self.attention = {}
    if self.status ~= "RUNNING" and self:hasActiveWork() then
        self.status = "RUNNING"
    end
    FALog.action("CONTROL", "Farm Agent resumed (%d task(s) handed back).", count)
end

-- keepParking: machines already driving off the fields carry on (a new plan replaced the old one).
function FATaskManager:stopAll(reason, keepParking)
    local stopped = 0
    for _, t in ipairs(self.tasks) do
        if t.job ~= nil then
            self:stopOwnJob(t)
            stopped = stopped + 1
        end
        if not TERMINAL[t.state] then
            self:setState(t, "CANCELLED", reason or "stopped by player")
        end
    end
    if not keepParking then
        stopped = stopped + self:cancelAllParking()
    end
    self.attention = {}
    if self.status == "RUNNING" then
        self.status = "STOPPED"
    end
    FALog.action("CONTROL", "Stopped all Farm Agent work (%d AI worker(s) stopped)%s.", stopped, reason and (": " .. reason) or "")
end

function FATaskManager:cancelTask(taskId)
    local task = self.byId[taskId]
    if task == nil then
        return false
    end
    self:stopOwnJob(task)
    self:setState(task, "CANCELLED", "cancelled")
    FALog.action(task.id, "Cancelled %s.", self:taskLabel(task))
    return true
end

-- Views for HUD / bridge -------------------------------------------------------------

function FATaskManager:getTaskViews()
    local views = {}
    for _, t in ipairs(self.tasks) do
        local vehicleName = t.vehicleId and self:vehicleName(t.vehicleId) or nil
        table.insert(views, {
            id = t.id,
            action = t.action,
            label = self:taskLabel(t),
            state = t.state,
            substate = t.substate,
            progress = t.progress,
            vehicle = vehicleName,
            deps = t.deps,
            note = t.note,
        })
    end
    return views
end
