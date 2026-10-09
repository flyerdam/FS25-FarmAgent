-- Simulated-world tests for FATaskManager: the game adapter and job adapter are replaced
-- by a mock world where "vanilla jobs" start, stop and report messages like FS25 does
-- (AISystem publishes AI_JOB_STOPPED synchronously inside stopJob).

FruitType = { UNKNOWN = 0 }
local WHEAT = { index = 1, name = "WHEAT", title = "Wheat", fillTypeIndex = 11, minHarvest = 4, maxHarvest = 6, cutState = 10, witheredState = 8 }
local SQUARE = { { x = 0, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 100 }, { x = 0, z = 100 } }

local W, TM, agent, combine, transport, rig

local function endJob(job, msgName)
    W.jobs[job.jobId] = nil
    job.vehicle.mock.aiActive = false
    TM:onAIJobStopped(job, { name = msgName })
end

local function newJob(kind, ref, extra)
    local job = { jobId = W.nextJobId, type = kind, vehicle = ref, currentTaskIndex = 2, driveToTask = { taskIndex = 1 } }
    for k, v in pairs(extra or {}) do job[k] = v end
    W.nextJobId = W.nextJobId + 1
    W.jobs[job.jobId] = job
    ref.mock.aiActive = true
    W.lastJob = job
    table.insert(W.jobLog, kind)
    return job
end

FAGameAdapter = {
    describeVehicle = function(ref)
        local m = ref.mock
        local r = { ref = ref, id = m.id, name = m.name, x = m.x, z = m.z, dirX = 1, dirZ = 0, speedKmh = m.speed,
            fuel = m.fuel, damage = 0, isBroken = false, aiActive = m.aiActive, isEntered = false, kind = m.kind,
            canFieldWork = true, canGoTo = true, canDeliver = true }
        if m.kind == "COMBINE" then
            r.combine = { ref = ref, fillLevel = m.fill, capacity = m.cap, hasCutter = true, hasPipe = true, cutterFruitIndices = { [1] = true },
                fillTypeIndex = m.fillType }
        elseif m.kind == "TOOL" then
            r.tools, r.ops = m.tools, m.ops
        else
            r.trailers = { { ref = ref.trailer, id = m.id + 1, name = "Trailer", fillUnitIndex = 1, fillLevel = m.trailerFill, capacity = m.trailerCap } }
        end
        return r
    end,
    isVehicleValid = function(ref) return ref ~= nil and not ref.deleted end,
    isThreshingBlockedByRain = function() return W.rain == true end,
    findVehicleInFront = function() return W.blocker end,
    notify = function(text) table.insert(W.notifications, text) end,
    getVehicleUnderPipe = function() return W.underPipe end,
    -- Pipe model: the vanilla AI unfolds it when the tank is completely full; Farm Agent
    -- unfolds it (targetState 2) for a final unload. Fully unfolded = target and current 2.
    isPipeFullyUnfolded = function(ref)
        return ref.spec_pipe.targetState == 2 or (ref.mock.aiActive and ref.mock.fill >= ref.mock.cap)
    end,
    getPipeTargetState = function(ref) return ref.spec_pipe.targetState end,
    getPipeLocalOffset = function(ref)
        if FAGameAdapter.isPipeFullyUnfolded(ref) then return 6, 0 end
        return nil
    end,
    getUniqueId = function(ref) return "combine-" .. tostring(ref.mock.id) end,
    computeUnderPipeTarget = function(c, t, trailer, pipeX, pipeZ)
        W.lastPipeOffset = { pipeX, pipeZ }
        return 10, 20, 1, 0, { x = pipeX, z = pipeZ, shift = 0, clearance = 1.5, obstacle = "header" }
    end,
    getUnderPipeError = function() return 1.5, 0.5 end,
    getAILimit = function() return W.aiActiveCount or 0, W.aiLimit or 10 end,
}

FAJobAdapter = {
    startFieldWork = function(ref, farmId, x, z, dx, dz, direct) return newJob("FIELDWORK", ref, { direct = direct == true }) end,
    startGoTo = function(ref, farmId, x, z) W.lastGoTo = { x = x, z = z }; return newJob("GOTO", ref) end,
    startDeliver = function(ref) return newJob("DELIVER", ref) end,
    isJobRunning = function(job) return job ~= nil and W.jobs[job.jobId] ~= nil end,
    stopJob = function(job)
        if W.jobs[job.jobId] ~= nil then
            endJob(job, "AIMessageSuccessStoppedByUser")
            return true
        end
        return false
    end,
    skipWaitingForFilling = function() return false end,
    setPipeState = function(ref, state) ref:setPipeState(state) end,
    setSeedCrop = function(ref, index) return W.seederCrops == nil or W.seederCrops[index] == true end,
    getMessageName = function(m) return m and m.name or "none" end,
    getMessageText = function(m) return m and m.name or "none" end,
}

local function plainVehicle(ref)
    local r = FAGameAdapter.describeVehicle(ref)
    local v = { id = r.id, name = r.name, kind = r.kind, x = r.x, z = r.z, aiActive = r.aiActive, isEntered = false,
        isBroken = false, fuel = r.fuel, canFieldWork = true, canGoTo = true, canDeliver = true }
    if r.combine then v.combine = { hasCutter = true, hasPipe = true, supportsCrop = true } end
    if r.trailers then v.trailers = { { id = r.id + 1, supportsCrop = true } } end
    if r.tools then v.tools, v.ops = r.tools, r.ops end
    return v
end

-- Soil context used by the field-work metrics (FieldGroundType-like values).
local SOIL_CTX = {
    fruitLookup = function(i) if i == 1 then return WHEAT end end,
    groundTypes = { PLOWED = 1, CULTIVATED = 2, SEEDBED = 3, ROLLED_SEEDBED = 4, STUBBLE_TILLAGE = 5, GRASS = 6, GRASS_CUT = 7, SOWN = 8 },
    limits = { sprayMax = 2, limeMax = 3, plowMax = 1 },
}

local function setup()
    W = { jobs = {}, nextJobId = 1, ready = 0.9, notifications = {}, jobLog = {} }
    combine = { mock = { id = 100, name = "Combine", kind = "COMBINE", x = 0, z = 50, speed = 0, fuel = 0.8, aiActive = false, fill = 0, cap = 5000 },
        spec_pipe = { targetState = 1 } }
    function combine:setPipeState(s) self.spec_pipe.targetState = s end
    transport = { mock = { id = 200, name = "Tractor", kind = "TRANSPORT", x = -50, z = 50, speed = 0, fuel = 0.8, aiActive = false, trailerFill = 0, trailerCap = 10000 },
        trailer = { getFillUnitSupportsFillType = function() return true end } }

    -- Tractor + cultivator / seeder rig for field-work tests.
    rig = { mock = { id = 400, name = "Rig", kind = "TOOL", x = -20, z = 50, speed = 0, fuel = 0.8, aiActive = false,
        ops = { "CULTIVATE" }, tools = { { kind = "CULTIVATOR", name = "Cultivator" } } } }

    -- Default field: wheat, the left W.ready share still standing. W.sampler overrides
    -- (isValid, fruit, growth, groundType, spray, lime, plow).
    local scanner = FAFieldScanner.new(function(x, z)
        if W.sampler then return W.sampler(x, z) end
        return true, 1, (x < 100 * W.ready) and 5 or 10, 8, 0, 2, 1
    end, function() return 0 end)
    local field = { id = 1, name = "1", polygon = SQUARE, labelX = 50, labelZ = 50, areaHa = 1 }
    scanner:setFields({ field })
    scanner:scanNow(1)

    agent = {
        farmId = 1,
        scanner = scanner,
        farmState = {
            refs = { vehicles = { [100] = combine, [200] = transport, [400] = rig }, fields = { [1] = field },
                stations = { [300] = { getName = function() return "Silo" end } } },
        },
    }
    function agent:getSoilContext() return SOIL_CTX end
    function agent:refreshSnapshot()
        -- The tractor+trailer exists on the farm only in logistics tests; otherwise the task
        -- manager would (correctly) attach it to harvests by itself.
        local vehicles = { plainVehicle(combine) }
        if W.withTransport then
            table.insert(vehicles, plainVehicle(transport))
        end
        if W.withRig then
            table.insert(vehicles, plainVehicle(rig))
        end
        -- Same rule as FAFarmState.refresh: a machine Farm Agent is only parking is free.
        for _, v in ipairs(vehicles) do
            if v.aiActive and TM ~= nil and TM:isParking(v.id) then v.aiActive = false end
        end
        self.farmState.snapshot = {
            fields = { { id = 1, name = "1", readyFraction = FAFieldScanner.getReadyFraction(scanner:getResult(1), WHEAT), labelX = 50, labelZ = 50 } },
            vehicles = vehicles,
            stations = { { id = 300, name = "Silo", acceptsCrop = true, freeCapacity = -1 } },
            helpers = { buySeeds = true, buyFertilizer = true },
        }
    end
    function agent:onObjectiveFinished(status) W.finished = status end
    agent:refreshSnapshot()
    TM = FATaskManager.new(agent)
end

local function tick(n, fn)
    for _ = 1, n do
        if fn then fn() end
        TM:update(1000)
        agent.scanner:update(10)
    end
end

local function harvestPlan(withLogistics)
    W.withTransport = withLogistics == true
    agent:refreshSnapshot()
    local tasks = { { id = "H1", action = "HARVEST_FIELD", fieldId = 1, vehicleId = 100, deps = {} } }
    local deps = { "H1" }
    if withLogistics then
        table.insert(tasks, { id = "L2", action = "UNLOAD_COMBINE", combineId = 100, vehicleId = 200, stationId = 300, deps = {} })
        table.insert(deps, "L2")
    end
    table.insert(tasks, { id = "R3", action = "REPORT", deps = deps })
    return { objective = { type = "HARVEST_READY_FIELDS", crop = "WHEAT" }, tasks = tasks, warnings = {}, decisions = {} }
end

T.test("harvest: AI 'finished' is verified by measuring the field", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    tick(1)
    local h = TM.byId.H1
    T.eq(h.state, "RUNNING"); T.eq(W.lastJob.type, "FIELDWORK")

    W.ready = 0.4 -- AI claims done, but 40% still standing
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(h.state, "RUNNING", "restarted instead of trusting the AI")
    T.eq(h.verifyRestarts, 1)
    T.eq(#W.jobLog, 2)

    W.ready = 0.0
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(h.state, "DONE")
    tick(1)
    T.eq(TM.byId.R3.state, "DONE")
    T.eq(W.finished, "COMPLETE")
end)

T.test("harvest: stall -> restart -> reposition -> escalate -> resume", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    tick(1)
    local h = TM.byId.H1
    tick(46) -- combine never moves
    T.eq(h.state, "RECOVERING"); T.eq(h.recoveryStep, 1)
    tick(4)
    T.eq(h.state, "RUNNING", "restarted in place"); T.eq(W.lastJob.direct, true)

    tick(46)
    T.eq(h.state, "RECOVERING"); T.eq(h.recoveryStep, 2)
    tick(4)
    T.eq(W.lastJob.type, "GOTO", "reposition uses a vanilla GoTo job")
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(h.state, "RUNNING"); T.eq(W.lastJob.type, "FIELDWORK")

    tick(46)
    T.eq(h.state, "ESCALATED", "gives up after 2 attempts")
    T.eq(#TM.attention, 1)
    T.eq(W.jobs[W.lastJob.jobId], nil, "worker stopped when escalating")

    TM:resume()
    tick(1)
    T.eq(h.state, "RUNNING"); T.eq(#TM.attention, 0)
end)

T.test("harvest: movement resets the stall timer", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    tick(1)
    tick(120, function() combine.mock.x = combine.mock.x + 2 end)
    T.eq(TM.byId.H1.state, "RUNNING"); T.eq(TM.byId.H1.recoveryStep, 0)
end)

T.test("harvest: a full grain tank is a wait, not a stall", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    tick(1)
    combine.mock.fill = 5000
    tick(100)
    local h = TM.byId.H1
    T.eq(h.state, "RUNNING"); T.eq(h.substate, "WAITING_FOR_UNLOAD")
    T.eq(#TM.attention, 1, "no trailer assigned -> player is told")
end)

T.test("player stopping a worker is respected", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    tick(1)
    local jobsBefore = #W.jobLog
    endJob(W.lastJob, "AIMessageSuccessStoppedByUser")
    tick(10)
    T.eq(TM.byId.H1.state, "PAUSED_BY_PLAYER")
    T.eq(#W.jobLog, jobsBefore, "no automatic restart")
end)

T.test("out of fuel escalates instead of retrying", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    tick(1)
    endJob(W.lastJob, "AIMessageErrorOutOfFuel")
    T.eq(TM.byId.H1.state, "ESCALATED")
end)

T.test("logistics: unload under pipe, standby, final unload, verified delivery", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    local h, l = TM.byId.H1, TM.byId.L2
    T.eq(h.state, "RUNNING"); T.eq(l.state, "RUNNING"); T.eq(l.substate, "IDLE")
    local harvestJob = W.lastJob

    combine.mock.fill = 5000 -- tank full, combine waits with pipe out
    tick(1)
    T.eq(l.substate, "TO_COMBINE"); T.eq(W.lastJob.type, "GOTO")
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(l.substate, "LOADING")

    W.underPipe = transport.trailer
    tick(5, function()
        transport.mock.trailerFill = transport.mock.trailerFill + 1000
        combine.mock.fill = combine.mock.fill - 1000
    end)
    T.eq(l.substate, "TO_STANDBY", "half-full trailer waits off the crop")
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(l.substate, "IDLE")

    -- Field finishes with 3000 l left in the tank.
    combine.mock.fill = 3000
    W.ready = 0.0
    endJob(harvestJob, "AIMessageSuccessFinishedJob")
    T.eq(h.state, "DONE")
    tick(1)
    T.eq(combine.spec_pipe.targetState, 2, "pipe unfolded for final unload")
    tick(1)
    T.eq(l.substate, "TO_COMBINE")
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    tick(3, function()
        transport.mock.trailerFill = transport.mock.trailerFill + 1000
        combine.mock.fill = combine.mock.fill - 1000
    end)
    T.eq(l.substate, "DELIVERING"); T.eq(W.lastJob.type, "DELIVER")

    transport.mock.trailerFill = 0
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(TM.stats.delivered, 8000, "delivery measured from trailer fill")
    tick(1)
    T.eq(l.state, "DONE"); T.eq(combine.spec_pipe.targetState, 1, "pipe folded again")
    tick(1)
    T.eq(W.finished, "COMPLETE")
end)

T.test("logistics: trailer that never gets under the pipe is corrected, then escalated", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    local l = TM.byId.L2
    combine.mock.fill = 5000
    tick(1)
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    tick(21) -- nothing flows
    T.eq(l.substate, "TO_COMBINE"); T.eq(l.pipeCorrections, 1)
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    tick(21)
    T.eq(l.pipeCorrections, 2)
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    tick(21)
    T.eq(l.state, "ESCALATED")

    -- Player parks the trailer by hand: grain starts flowing and the task picks itself up.
    tick(2, function()
        transport.mock.trailerFill = transport.mock.trailerFill + 1000
        combine.mock.fill = combine.mock.fill - 1000
    end)
    T.eq(l.state, "RUNNING", "self-resolved once loading started")
end)

T.test("stop all cancels everything and stops workers", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    TM:stopAll("test")
    for _, t in ipairs(TM.tasks) do T.eq(t.state, "CANCELLED") end
    local running = 0
    for _ in pairs(W.jobs) do running = running + 1 end
    T.eq(running, 0)
end)

T.test("autopilot: a worker the player stopped is taken back after the player left for 60 s", function()
    setup()
    agent.autopilot = true
    TM:loadPlan(harvestPlan(false), WHEAT, true)
    tick(1)
    local h = TM.byId.H1
    endJob(W.lastJob, "AIMessageSuccessStoppedByUser")
    T.eq(h.state, "PAUSED_BY_PLAYER")
    tick(30)
    T.eq(h.state, "PAUSED_BY_PLAYER", "not yet")
    tick(35)
    T.eq(h.state, "RUNNING", "taken back")
    T.eq(W.lastJob.type, "FIELDWORK")
end)

T.test("without autopilot a stopped worker stays stopped", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    tick(1)
    endJob(W.lastJob, "AIMessageSuccessStoppedByUser")
    tick(120)
    T.eq(TM.byId.H1.state, "PAUSED_BY_PLAYER")
end)

T.test("continuous plans never complete and accept new tasks", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT, true)
    tick(1)
    W.ready = 0
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    tick(5)
    T.eq(TM.status, "RUNNING"); T.eq(W.finished, nil)
    W.ready = 0.9
    agent.scanner:scanNow(1)
    TM:addTasks({ { id = "H1", action = "HARVEST_FIELD", fieldId = 1, vehicleId = 100 } })
    T.eq(#TM.tasks, 3, "duplicate id renamed, task added")
    tick(1)
    T.eq(TM.tasks[3].state, "RUNNING")
end)

T.test("a free trailer is attached to a running harvest automatically", function()
    setup()
    TM:loadPlan(harvestPlan(false), WHEAT)
    W.withTransport = true -- a tractor+trailer becomes available after planning
    agent:refreshSnapshot()
    tick(12)
    local logistics
    for _, t in ipairs(TM.tasks) do
        if t.action == "UNLOAD_COMBINE" then logistics = t end
    end
    T.truthy(logistics ~= nil, "logistics task created")
    T.eq(logistics.combineId, 100); T.eq(logistics.vehicleId, 200)
    local report = TM.byId.R3
    T.eq(report.deps[#report.deps], logistics.id, "report waits for it")
end)

-- Milestone 2: tool operations and the logistics fixes from the first in-game test --------

local function rigPlan(action, extra)
    W.withRig = true
    agent:refreshSnapshot()
    local task = { id = "C1", action = action, fieldId = 1, vehicleId = 400, deps = {} }
    for k, v in pairs(extra or {}) do task[k] = v end
    return { objective = { type = "FIELD_WORK" }, tasks = { task, { id = "R2", action = "REPORT", deps = { "C1" } } }, warnings = {}, decisions = {} }
end

-- Field: x < 100 * W.stubble still harvested stubble, the rest cultivated.
local function cultivationSampler(x, z)
    if x < 100 * W.stubble then
        return true, 1, 10, 8, 0, 2, 1
    end
    return true, 0, 0, 2, 0, 2, 1
end

T.test("cultivate: vanilla field work, finished only when the field measures cultivated", function()
    setup()
    W.sampler, W.stubble = cultivationSampler, 1.0
    agent.scanner:scanNow(1)
    TM:loadPlan(rigPlan("CULTIVATE_FIELD"), nil)
    tick(1)
    local c = TM.byId.C1
    T.eq(c.state, "RUNNING"); T.eq(W.lastJob.type, "FIELDWORK"); T.eq(W.lastJob.vehicle, rig)
    T.eq(TM:taskLabel(c), "Cultivate field 1")

    W.stubble = 0.4
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(c.state, "RUNNING", "40% stubble left -> restarted")

    W.stubble = 0.02
    tick(25, function() rig.mock.x = rig.mock.x + 2 end)
    T.truthy(c.progress > 0.9, "progress from the scan: " .. tostring(c.progress))
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(c.state, "DONE")
    tick(1)
    T.eq(W.finished, "COMPLETE")
end)

T.test("seed: a seeder that cannot sow the crop fails cleanly", function()
    setup()
    rig.mock.ops = { "SEED" }
    rig.mock.tools = { { kind = "SEEDER", name = "Seeder", seeds = { "WHEAT" }, fillLevel = 100, capacity = 1000 } }
    W.sampler = function() return true, 0, 0, 2, 0, 2, 1 end
    agent.scanner:scanNow(1)
    W.seederCrops = {} -- FAJobAdapter.setSeedCrop finds no matching seed slot
    TM:loadPlan(rigPlan("SEED_FIELD", { crop = "WHEAT", cropDesc = WHEAT }), nil)
    TM.byId.C1.cropDesc = WHEAT
    tick(1)
    T.eq(TM.byId.C1.state, "FAILED")
end)

T.test("seeder running empty escalates with a refill hint", function()
    setup()
    W.sampler, W.stubble = cultivationSampler, 1.0
    agent.scanner:scanNow(1)
    TM:loadPlan(rigPlan("CULTIVATE_FIELD"), nil)
    tick(1)
    endJob(W.lastJob, "AIMessageErrorOutOfFill")
    T.eq(TM.byId.C1.state, "ESCALATED")
    T.truthy(TM.attention[1].text:find("refill"))
end)

T.test("regression: trailer waits for the pipe instead of guessing (final unload)", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    local l = TM.byId.L2
    combine.mock.fill = 3000
    W.ready = 0
    endJob(W.lastJob, "AIMessageSuccessFinishedJob") -- field done, grain left, AI off
    tick(1)
    T.eq(combine.spec_pipe.targetState, 2, "pipe unfold requested")
    -- mock: pipe fully unfolded once targetState is 2 -> rendezvous in the same round
    T.eq(l.substate, "TO_COMBINE")
    T.eq(W.lastPipeOffset[1], 6, "target built from the fully unfolded pipe")
end)

T.test("regression: repeated transport stalls escalate instead of looping forever", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    local l = TM.byId.L2
    combine.mock.fill = 5000
    tick(1)
    T.eq(l.substate, "TO_COMBINE")
    tick(93) -- stuck on the header (stall after 90 s, re-sent on the next round)
    T.eq(l.substate, "TO_COMBINE", "first stall: re-planned and sent again")
    T.eq(l.transportStalls, 1)
    tick(93)
    T.eq(l.state, "ESCALATED", "second stall: escalated")
end)

T.test("regression: a combine being unloaded is not given the next field", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    local l = TM.byId.L2
    combine.mock.fill = 5000
    tick(1)
    endJob(W.lastJob, "AIMessageSuccessFinishedJob") -- trailer arrived
    T.eq(l.substate, "LOADING")
    local reserved = TM:reservations()
    T.eq(reserved[100] ~= nil, true, "combine reserved during loading")
    TM:addTasks({ { action = "HARVEST_FIELD", fieldId = 1 } })
    T.eq(TM:findFreeMachineFor(TM.tasks[#TM.tasks]), nil)
end)

T.test("regression: nothing to load ends LOADING at once; a combine that drives on ends it too", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    local l = TM.byId.L2
    combine.mock.fill = 5000
    tick(1)
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    combine.mock.fill = 0 -- someone else emptied it
    tick(1)
    T.truthy(l.substate ~= "LOADING", "left LOADING: " .. tostring(l.substate))

    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    l = TM.byId.L2
    combine.mock.fill = 5000
    tick(1)
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    combine.mock.fill = 4800
    combine.mock.speed = 5 -- AI resumed harvesting, trailer not under pipe
    combine.mock.aiActive = true
    tick(7)
    T.truthy(l.substate ~= "LOADING", "combine drove on -> " .. tostring(l.substate))
end)

T.test("regression: every logistics leg has a deadline", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    local l = TM.byId.L2
    combine.mock.fill = 5000
    tick(1)
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    W.underPipe = transport.trailer
    -- grain trickles in very slowly: never "done", never idle long enough
    tick(245, function() transport.mock.trailerFill = transport.mock.trailerFill + 2; combine.mock.fill = combine.mock.fill - 2 end)
    T.truthy(l.substate ~= "LOADING" or l.state == "ESCALATED", "LOADING deadline enforced")
end)

-- Parking: machines must not stay on the field after their job (in-game report) -----------

local function countJobs(kind)
    local n = 0
    for _, k in ipairs(W.jobLog) do if k == kind then n = n + 1 end end
    return n
end

local function finishCultivation()
    setup()
    agent.memory = FAMemory.new(nil, function() return nil end, function() end)
    W.sampler, W.stubble = cultivationSampler, 1.0
    agent.scanner:scanNow(1)
    TM:loadPlan(rigPlan("CULTIVATE_FIELD"), nil)
    tick(1) -- rig starts at (-20, 50), off the field: that is its home
    T.eq(TM.byId.C1.state, "RUNNING")
    rig.mock.x = 50 -- the AI worker finishes in the middle of the field
    W.stubble = 0
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(TM.byId.C1.state, "DONE")
end

T.test("parking: a finished machine drives back to where it was before the job", function()
    finishCultivation()
    tick(3)
    T.eq(countJobs("GOTO"), 0, "grace period: new work may take it first")
    tick(4)
    T.eq(countJobs("GOTO"), 1); T.eq(W.lastJob.vehicle, rig)
    T.eq(W.lastGoTo.x, -20); T.eq(W.lastGoTo.z, 50)
    T.truthy(TM:isParking(400))
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.truthy(not TM:isParking(400))
    tick(20)
    T.eq(countJobs("GOTO"), 1, "parked once")
end)

T.test("parking: no home spot -> just outside the field, never inside another field", function()
    setup()
    W.sampler, W.stubble = cultivationSampler, 1.0
    agent.scanner:scanNow(1)
    TM:loadPlan(rigPlan("CULTIVATE_FIELD"), nil) -- no memory: no home spot
    tick(1)
    rig.mock.x, rig.mock.z = 90, 50
    W.stubble = 0
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    tick(7)
    T.eq(countJobs("GOTO"), 1)
    T.truthy(not FAGeometry.isPointInPolygon(W.lastGoTo.x, W.lastGoTo.z, SQUARE), "target is off the field")
    T.truthy(W.lastGoTo.x > 100, "nearest edge: " .. tostring(W.lastGoTo.x))
end)

T.test("parking: new work within the grace period takes the machine instead", function()
    finishCultivation()
    tick(2)
    W.stubble = 1
    agent.scanner:scanNow(1)
    TM:addTasks({ { id = "C9", action = "CULTIVATE_FIELD", fieldId = 1, vehicleId = 400 } })
    tick(8)
    T.eq(countJobs("GOTO"), 0, "no park drive")
    T.eq(TM.byId.C9.state, "RUNNING")
end)

T.test("parking: a park drive is cancelled when work takes the machine", function()
    finishCultivation()
    tick(7)
    T.truthy(TM:isParking(400))
    local parkJob = W.lastJob
    agent:refreshSnapshot()
    W.stubble = 1
    agent.scanner:scanNow(1)
    TM:addTasks({ { id = "C9", action = "CULTIVATE_FIELD", fieldId = 1, vehicleId = 400 } })
    tick(1)
    T.eq(W.jobs[parkJob.jobId], nil, "park drive stopped")
    T.truthy(not TM:isParking(400))
    T.eq(TM.byId.C9.state, "RUNNING"); T.eq(W.lastJob.type, "FIELDWORK")
end)

T.test("parking: a combine with grain waits for its last unload; field work waits for it", function()
    setup()
    TM:loadPlan(harvestPlan(true), WHEAT)
    tick(1)
    combine.mock.x = 50
    combine.mock.fill = 3000
    W.ready = 0
    endJob(W.lastJob, "AIMessageSuccessFinishedJob")
    T.eq(TM.byId.H1.state, "DONE")
    tick(8)
    T.truthy(not TM:isParking(100), "grain still in the tank")
    T.truthy(TM.parkRequests[100] ~= nil, "parking still wanted")
    T.eq(TM:parkingBlockerOn(1, 400), "Combine")

    -- Unload done, logistics finished: now the combine leaves.
    combine.mock.fill = 0
    TM:stopOwnJob(TM.byId.L2)
    TM:setState(TM.byId.L2, "DONE", "test")
    tick(7)
    T.truthy(TM:isParking(100), "combine driven off the field")
end)

T.test("parking: machines Farm Agent never drove are left alone; stop all cancels parking", function()
    setup()
    TM:requestPark(200)
    T.eq(TM.parkRequests[200], nil, "player-parked machine is never moved")
    finishCultivation()
    tick(7)
    T.truthy(TM:isParking(400))
    TM:stopAll("test")
    T.truthy(not TM:isParking(400))
    local running = 0
    for _ in pairs(W.jobs) do running = running + 1 end
    T.eq(running, 0)
end)

T.test("parking: home unreachable -> parks next to the field instead", function()
    finishCultivation()
    tick(7)
    endJob(W.lastJob, "AIMessageErrorCouldNotBeReached")
    tick(7)
    T.eq(countJobs("GOTO"), 2)
    T.truthy(W.lastGoTo.x ~= -20 or W.lastGoTo.z ~= 50, "fallback spot, not home again")
    T.truthy(not FAGeometry.isPointInPolygon(W.lastGoTo.x, W.lastGoTo.z, SQUARE))
end)
