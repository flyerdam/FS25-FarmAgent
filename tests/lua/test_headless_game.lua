-- Boots the real mod (FarmAgentLoader.lua and every module) against a fake FS25 engine.
-- The fake exposes only the API names documented in docs/FEASIBILITY.md, so this catches
-- typos / nil calls in the game-coupled layers that the pure tests cannot reach.
-- It does NOT prove the real engine behaves like the fake.

local E = { notifications = {}, rendered = 0, consoleCommands = {}, subscribers = {}, nextJobId = 1 }

-- Engine functions ----------------------------------------------------------------------
local function node(x, z, dirX, dirZ) return { x = x, y = 0, z = z, dirX = dirX or 0, dirZ = dirZ or 1 } end
function getWorldTranslation(n) return n.x, n.y, n.z end
function localDirectionToWorld(n) return n.dirX, 0, n.dirZ end
-- Local frame of a node: z along its heading (dirX, dirZ), x perpendicular.
local function toLocal(n, x, z)
    local dx, dz = x - n.x, z - n.z
    return dx * n.dirZ - dz * n.dirX, dx * n.dirX + dz * n.dirZ
end
function localToLocal(a, b) local lx, lz = toLocal(b, a.x, a.z) return lx, 0, lz end
function localToWorld(n, lx, ly, lz)
    return n.x + lx * n.dirZ + lz * n.dirX, ly, n.z - lx * n.dirX + lz * n.dirZ
end
function worldToLocal(n, x, y, z) local lx, lz = toLocal(n, x, z) return lx, y, lz end
function renderText() E.rendered = E.rendered + 1 end
function setTextColor() end
function setTextBold() end
function setTextAlignment() end
function drawFilledRect() end
RenderText = { ALIGN_LEFT = 0, ALIGN_RIGHT = 2 }
function createFolder(path)
    os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
end
function getUserProfileAppPath() return TEST_TMP .. "/" end
function getDate(fmt) return "20261008154500" end
function addConsoleCommand(name, desc, fn, target) E.consoleCommands[name] = { fn = fn, target = target } end
function removeConsoleCommand(name) E.consoleCommands[name] = nil end
function source(path) dofile(path) end
function addModEventListener(listener) E.listener = listener end
g_currentModDirectory = MOD_ROOT .. "/"
g_currentModName = "FS25_FarmAgent"
g_time = 0

Utils = {
    getFilename = function(f, dir) return dir .. f end,
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
}
MathUtil = { getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end }
-- In the real game ClassUtil.getClassNameByObject is NOT callable from mods (observed in
-- log.txt), so the fake deliberately leaves it out.
ClassUtil = {}
local objects = {}
NetworkUtil = {
    getObjectId = function(o) return o.id end,
    getObject = function(id) return objects[id] end,
}
MessageType = { AI_JOB_STOPPED = "AI_JOB_STOPPED" }
g_messageCenter = {
    subscribe = function(self, t, cb, target) E.subscribers[t] = { cb = cb, target = target } end,
    unsubscribeAll = function(self, target) E.subscribers = {} end,
}
FSBaseMission = { INGAME_NOTIFICATION_CRITICAL = 1, INGAME_NOTIFICATION_INFO = 2 }
g_gui = { getIsGuiVisible = function() return false end }
g_i18n = { getText = function(_, k) return k end }
g_localPlayer = { farmId = 1 }
InputAction = { FA_COMMAND = "FA_COMMAND", FA_TOGGLE_PANEL = "FA_TOGGLE_PANEL", FA_PAUSE = "FA_PAUSE", FA_STOP_ALL = "FA_STOP_ALL" }
E.actions = {}
g_inputBinding = {
    registerActionEvent = function(_, action, target, cb) E.actions[action] = { target = target, cb = cb } return true, action end,
    setActionEventTextVisibility = function() end,
}
PlayerInputComponent = { registerGlobalPlayerActionEvents = function() end }
TextInputDialog = { show = function(cb, target) cb(target, E.dialogText, true) end }
-- Vanilla OptionDialog fake: picks the entry containing E.menuChoice, else "Type a command..."
-- (so the older tests keep typing their command through the menu's text box).
E.menus = {}
OptionDialog = { show = function(cb, title, text, options)
    table.insert(E.menus, { title = title, text = text, options = options })
    local wanted = E.menuChoice or "Type a command"
    E.menuChoice = nil
    for i, o in ipairs(options) do
        if o:find(wanted, 1, true) then cb(i) return end
    end
    cb(0)
end }
-- AI messages only answer isa(Class), like GIANTS' Class() objects.
local function messageClass()
    local cls = {}
    cls.new = function()
        return { isa = function(self, other) return other == cls end }
    end
    return cls
end
AIMessageSuccessStoppedByUser = messageClass()
AIMessageSuccessFinishedJob = messageClass()
AIMessageErrorOutOfFuel = messageClass()
AIMessageErrorNotReachable = messageClass()
FruitType = { UNKNOWN = 0 }

-- Classes for isa() -----------------------------------------------------------------------
UnloadingStation = {}
SellingStation = {}

-- Soil / season API (names verified in the FS25 source) -----------------------------------------
FieldDensityMap = { SPRAY_LEVEL = "SPRAY_LEVEL", PLOW_LEVEL = "PLOW_LEVEL", LIME_LEVEL = "LIME_LEVEL" }
Platform = { gameplay = { usePlowCounter = true, useLimeCounter = true } }
FieldGroundType = { NONE = 0, PLOWED = 1, CULTIVATED = 2, SEEDBED = 3, ROLLED_SEEDBED = 4, STUBBLE_TILLAGE = 5, GRASS = 6, GRASS_CUT = 7, SOWN = 8 }
E.plantable = true
local function plantable(self, growthMode, period) return E.plantable end

-- Crops / fill types ---------------------------------------------------------------------------
local WHEAT = { index = 1, name = "WHEAT", minHarvestingGrowthState = 4, maxHarvestingGrowthState = 6, cutState = 10, witheredState = 8, getIsPlantableInPeriod = plantable }
local BARLEY = { index = 2, name = "BARLEY", minHarvestingGrowthState = 4, maxHarvestingGrowthState = 6, cutState = 10, witheredState = 8, getIsPlantableInPeriod = plantable }
local FRUITS = { WHEAT = WHEAT, BARLEY = BARLEY }
g_fruitTypeManager = {
    getFruitTypeByName = function(_, n) return FRUITS[n] end,
    getFruitTypeByIndex = function(_, i) if i == 1 then return WHEAT elseif i == 2 then return BARLEY end end,
    getFillTypeIndexByFruitTypeIndex = function(_, i) return 10 + i end, -- WHEAT 11, BARLEY 12
    getFruitTypes = function() return { WHEAT, BARLEY } end,
}
local FILL_NAMES = { [11] = "WHEAT", [12] = "BARLEY", [20] = "DIESEL", [30] = "FERTILIZER", [31] = "LIME" }
g_fillTypeManager = {
    getFillTypeTitleByIndex = function(_, i) if i == 11 then return "Wheat" elseif i == 12 then return "Barley" end end,
    getFillTypeIndexByName = function(_, n) for i, name in pairs(FILL_NAMES) do if name == n then return i end end end,
    getFillTypeNameByIndex = function(_, i) return FILL_NAMES[i] end,
}

-- Fields -----------------------------------------------------------------------------------------
-- Field 12 (x 0..100) grows wheat; field 13 (x 200..300) grows barley once added by a test.
E.fieldGrowth = 5
E.barleyGrowth = 5
E.ground = FieldGroundType.SOWN
E.spray, E.lime, E.plow = 1, 2, 1
FieldState = { new = function()
    return { update = function(self, x, z)
        self.isValid = z >= 0 and z <= 100 and ((x >= 0 and x <= 100) or (x >= 200 and x <= 300))
        if x >= 200 then
            self.fruitTypeIndex, self.growthState = 2, E.barleyGrowth
        else
            self.fruitTypeIndex, self.growthState = 1, E.fieldGrowth
        end
        if self.growthState == 0 then self.fruitTypeIndex = 0 end
        self.groundType, self.sprayLevel, self.limeLevel, self.plowLevel = E.ground, E.spray, E.lime, E.plow
    end }
end }
local function makeField(id, x0)
    return {
        areaHa = 1, posX = x0 + 50, posZ = 50, farmland = { id = 7 },
        polygonPoints = { node(x0, 0), node(x0 + 100, 0), node(x0 + 100, 100), node(x0, 100) },
        getId = function() return id end, getName = function() return tostring(id) end,
    }
end
local field = makeField(12, 0)
local fieldList = { field }
g_fieldManager = { getFields = function() return fieldList end }
g_farmlandManager = { getFarmlandOwner = function(_, id) return id == 7 and 1 or 0 end }
g_farmManager = { getFarmById = function() return { getBalance = function() return 184230 end } end }

-- Vehicles -----------------------------------------------------------------------------------------
local function makeVehicle(id, name, x, z)
    local v = { id = id, rootNode = node(x, z, 1, 0), spec_aiJobVehicle = {}, aiActive = false, fill = {}, cap = {}, fillType = {} }
    v.rootVehicle = v
    v.childVehicles = { v }
    objects[id] = v
    function v:getFullName() return name end
    function v:getOwnerFarmId() return 1 end
    function v:getChildVehicles() return self.childVehicles end
    function v:getLastSpeed() return self.speed or 0 end
    function v:getIsAIActive() return self.aiActive end
    function v:getIsEntered() return self.entered == true end
    function v:getDamageAmount() return 0.04 end
    function v:getConsumerFillUnitIndex(ft) if ft == 20 then return 9 end end
    function v:getFillUnitFillLevelPercentage() return 0.72 end
    function v:getFillUnitFillLevel(i) return self.fill[i] or 0 end
    function v:getFillUnitCapacity(i) return self.cap[i] or 0 end
    function v:getFillUnitFillType(i) return self.fillType[i] or 0 end
    function v:getFillUnitSupportsFillType(i, ft) return ft == 11 or ft == 12 end
    function v:getAIDirectionNode() return self.rootNode end
    return v
end

local combine = makeVehicle(21, "Case IH Axial-Flow", -30, 50)
combine.spec_combine = { fillUnitIndex = 1 }
combine.spec_cutter = { fruitTypeIndices = { 1, 2 } }
combine.spec_pipe = { targetState = 1, nearestObjectInTriggers = {} }
combine.cap[1] = 10000
local pipeNode = node(-30, 57) -- 7 m to the side: pipe unfolded
function combine:getCurrentDischargeNode() return { node = pipeNode, fillUnitIndex = 1 } end
function combine:getIsThreshingDuringRain() return false end
function combine:setPipeState(s) self.spec_pipe.targetState = s end

local tractor = makeVehicle(31, "Fendt 942", -80, 50)
local trailer = makeVehicle(32, "Krampe Bandit", -88, 50)
trailer.spec_aiJobVehicle = nil
trailer.rootVehicle = tractor
trailer.cap[1] = 20000
trailer.fillNode = node(-88, 50)
function trailer:getAIDischargeNodes() return { { fillUnitIndex = 1, node = self.fillNode } } end
function trailer:getFillUnitExactFillRootNode() return self.fillNode end
function trailer:getFillUnitRootNode() return self.fillNode end
tractor.childVehicles = { tractor, trailer }

local pallet = makeVehicle(41, "Seed pallet", 500, 500)

-- Tractor with a cultivator (field-work rig).
local rigTractor = makeVehicle(61, "Fendt 724", 40, -40)
local cultivator = makeVehicle(62, "Horsch Terrano", 34, -40)
cultivator.spec_aiJobVehicle = nil
cultivator.rootVehicle = rigTractor
cultivator.spec_cultivator = {}
rigTractor.childVehicles = { rigTractor, cultivator }
pallet.spec_aiJobVehicle = nil

-- AI system ---------------------------------------------------------------------------------------
local jobTypes = { "GOTO", "FIELDWORK", "CONVEYOR", "DELIVER", "LOAD_AND_DELIVER" }
local function newJob(typeName)
    local job = { typeName = typeName }
    job.positionAngleParameter = { setPosition = function(p, x, z) job.x, job.z = x, z end, setAngle = function(p, a) job.angle = a end }
    job.vehicleParameter = { setVehicle = function(p, v) job.vehicle = v end }
    job.unloadingStationParameter = { setUnloadingStation = function(p, s) job.station = s end }
    job.loopingParameter = { setIsLooping = function(p, l) job.looping = l end }
    job.driveToTask = { taskIndex = 1, setTargetOffset = function(t, o) job.offset = o end }
    setmetatable(job.driveToTask, { __newindex = function(t, k, v) if k == "maxSpeed" then job.finalSpeed = v end rawset(t, k, v) end })
    job.currentTaskIndex = 2
    function job:getIsAvailableForVehicle(v)
        if typeName == "FIELDWORK" then
            if v.spec_combine ~= nil then return true end
            for _, c in ipairs(v.childVehicles or {}) do
                if c.spec_cultivator or c.spec_sowingMachine or c.spec_plow or c.spec_sprayer then return true end
            end
            return false
        end
        return v.spec_aiJobVehicle ~= nil
    end
    function job:applyCurrentState(v, mission, farmId, isDirectStart) self.vehicle = v; self.isDirectStart = isDirectStart end
    function job:setValues() end
    function job:validate() return self.vehicle ~= nil, nil end
    function job:delete() end
    return job
end
g_currentMission = {
    maxNumHirables = 10,
    environment = { dayTime = 12 * 3600000 + 31 * 60000 + 4000, currentPeriod = 5 },
    missionInfo = { helperBuyFuel = true, helperBuySeeds = true, helperBuyFertilizer = true, growthMode = 1, mapTitle = "Test Map" },
    fieldGroundSystem = { getMaxValue = function(_, map)
        if map == "SPRAY_LEVEL" then return 2 elseif map == "PLOW_LEVEL" then return 1 elseif map == "LIME_LEVEL" then return 3 end
        return 0
    end },
    getIsServer = function() return true end,
    addIngameNotification = function(_, t, text) table.insert(E.notifications, text) end,
    accessHandler = { canPlayerAccess = function() return true end },
    vehicleSystem = { vehicles = { combine, tractor, trailer, pallet, rigTractor, cultivator } },
    aiJobTypeManager = {
        getJobTypeIndexByName = function(_, n) for i, t in ipairs(jobTypes) do if t == n then return i end end end,
        createJob = function(_, i) return newJob(jobTypes[i]) end,
    },
    aiSystem = {
        jobs = {},
        getActiveJobs = function(self) local l = {} for _, j in pairs(self.jobs) do table.insert(l, j) end return l end,
        getAILimitedReached = function() return false end,
        startJob = function(self, job, farmId)
            job.jobId = E.nextJobId; E.nextJobId = E.nextJobId + 1
            self.jobs[job.jobId] = job
            job.vehicle.aiActive = true
            E.lastJob = job
        end,
        getJobById = function(self, id) return self.jobs[id] end,
        stopJob = function(self, job, msg)
            self.jobs[job.jobId] = nil
            job.vehicle.aiActive = false
            local s = E.subscribers[MessageType.AI_JOB_STOPPED]
            s.cb(s.target, job, msg)
        end,
        skipCurrentTask = function() end,
    },
}
local silo = { id = 51, getName = function() return "Farm silo" end, getIsFillTypeAISupported = function(_, ft) return ft == 11 or ft == 12 end,
    getFreeCapacity = function() return 100000 end, getAITargetPositionAndDirection = function() return -200, 0, 1, 0 end }
function silo:isa(cls) return cls == UnloadingStation end
g_currentMission.storageSystem = { getUnloadingStations = function() return { silo } end }
objects[51] = silo

-- Boot -------------------------------------------------------------------------------------------------
local function frames(n, ms)
    for _ = 1, n do
        g_time = g_time + (ms or 100)
        E.listener:update(ms or 100)
        E.listener:draw()
    end
end

T.test("headless: mod loads, registers console, input and panel", function()
    dofile(MOD_ROOT .. "/scripts/FarmAgentLoader.lua")
    T.truthy(E.listener ~= nil, "mod event listener")
    E.listener:loadMap("map")
    T.eq(E.listener.enabled, true)
    T.truthy(E.consoleCommands.faCommand ~= nil and E.consoleCommands.faScan ~= nil, "console commands")
    PlayerInputComponent.registerGlobalPlayerActionEvents({})
    T.truthy(E.actions.FA_COMMAND ~= nil and E.actions.FA_STOP_ALL ~= nil, "hotkeys")
    frames(1)
    T.truthy(E.rendered > 0, "panel drawn")
end)

T.test("headless: faScan lists the ready field and classifies vehicles", function()
    local agent = E.listener
    agent:consoleScan()
    local snap = agent.farmState.snapshot
    T.eq(#snap.fields, 1); T.eq(snap.fields[1].state, "READY_TO_HARVEST"); T.eq(snap.fields[1].crop, "WHEAT")
    local kinds = {}
    for _, v in ipairs(snap.vehicles) do kinds[v.name] = v.kind end
    T.eq(kinds["Case IH Axial-Flow"], "COMBINE"); T.eq(kinds["Fendt 942"], "TRANSPORT")
    T.eq(kinds["Seed pallet"], nil, "pallet skipped")
end)

T.test("headless: Alt+J command plans and starts a vanilla field-work job", function()
    local agent = E.listener
    E.dialogText = "Harvest all ready wheat fields"
    local a = E.actions.FA_COMMAND
    a.cb(a.target)
    T.eq(agent.phase, "SCANNING")
    frames(5)
    T.eq(agent.phase, "EXECUTING")
    frames(12) -- one supervision tick
    T.eq(E.lastJob.typeName, "FIELDWORK"); T.eq(E.lastJob.vehicle, combine)
    T.truthy(E.lastJob.x >= 0 and E.lastJob.x <= 100, "start point inside the field")
    T.eq(agent.taskManager.byId.H1.state, "RUNNING")
    T.eq(agent.taskManager.byId.L2.state, "RUNNING")
    for i = 1, 3 do E.listener.hud:cycleView(); frames(1) end -- PLAN, LOG, HIDDEN
end)

T.test("headless: full tank sends the trailer under the pipe, then delivery", function()
    local agent = E.listener
    local harvestJob = E.lastJob
    combine.fill[1] = 10000
    frames(11)
    T.eq(E.lastJob.typeName, "FIELDWORK", "pipe still folded: the trailer waits instead of guessing")
    T.eq(agent.taskManager.byId.L2.substate, "WAIT_PIPE")
    -- The vanilla AI combine unfolds the pipe once the tank is completely full.
    combine.spec_pipe.targetState, combine.spec_pipe.currentState = 2, 2
    frames(11)
    T.eq(E.lastJob.typeName, "GOTO"); T.eq(E.lastJob.vehicle, tractor)
    -- tractor AI node at trailer fill node + 8 m: target = pipe + 8 m along heading
    T.near(E.lastJob.x, -22, 0.01, "x"); T.near(E.lastJob.z, 57, 0.01, "z"); T.eq(E.lastJob.offset, 20)
    T.eq(E.lastJob.finalSpeed, 5, "slow final approach")
    T.truthy(agent.memory:getPipeOffset("21") ~= nil, "pipe position learned and remembered")
    g_currentMission.aiSystem:stopJob(E.lastJob, AIMessageSuccessFinishedJob.new())
    T.eq(agent.taskManager.byId.L2.substate, "LOADING")
    combine.spec_pipe.nearestObjectInTriggers.objectId = 32
    for _ = 1, 4 do
        trailer.fill[1] = trailer.fill[1] == nil and 4000 or trailer.fill[1] + 4000
        combine.fill[1] = math.max(0, combine.fill[1] - 4000)
        frames(10)
    end
    T.eq(E.lastJob.typeName, "DELIVER", "trailer >= 60% goes to the silo")
    T.eq(E.lastJob.station, silo); T.eq(E.lastJob.looping, false)

    -- AI says the field is done, the scan agrees.
    E.fieldGrowth = 10
    g_currentMission.aiSystem:stopJob(harvestJob, AIMessageSuccessFinishedJob.new())
    T.eq(agent.taskManager.byId.H1.state, "DONE")

    local state = FAJson.decode(T.readFile(TEST_TMP .. "/modSettings/FS25_FarmAgent/state.json"))
    T.eq(state.phase, "EXECUTING"); T.truthy(#state.tasks >= 3, "tasks published")
end)

-- Replays the first in-game test session: worker started, player sits in the combine and
-- stops the helper, then wants Farm Agent to continue.
T.test("headless: player stops the helper from the cab, Alt+L hands it back", function()
    local agent = E.listener
    E.fieldGrowth = 5 -- field ready again
    trailer.fill[1] = 0
    combine.fill[1] = 0
    E.dialogText = "harvest all ready wheat fields"
    E.actions.FA_COMMAND.cb(E.actions.FA_COMMAND.target)
    frames(15)
    local h
    for _, t in ipairs(agent.taskManager.tasks) do
        if t.action == "HARVEST_FIELD" and t.state ~= "DONE" then h = t end
    end
    T.eq(h.state, "RUNNING")

    combine.entered = true -- player climbs in and presses the helper key
    local notes = #E.notifications
    local ok = pcall(g_currentMission.aiSystem.stopJob, g_currentMission.aiSystem, E.lastJob, AIMessageSuccessStoppedByUser.new())
    T.eq(ok, true, "stop message handled without error")
    T.eq(h.state, "PAUSED_BY_PLAYER")
    T.truthy(#E.notifications > notes, "player told how to hand it back")
    frames(30)
    T.eq(h.state, "PAUSED_BY_PLAYER", "no automatic restart")

    E.actions.FA_PAUSE.cb(E.actions.FA_PAUSE.target) -- Alt+L
    frames(12)
    T.eq(h.state, "RUNNING", "restarted while the player sits in the parked combine")
    T.eq(combine.aiActive, true)

    -- Player actually driving: Farm Agent must not grab the vehicle.
    agent.taskManager:stopOwnJob(h)
    h.state = "PENDING"
    combine.speed = 8
    frames(12)
    T.truthy(h.state ~= "RUNNING", "no takeover while the player drives")
    combine.speed = 0
    combine.entered = false
end)

local function harvestTasks()
    local running, queued = {}, {}
    for _, t in ipairs(E.listener.taskManager.tasks) do
        if t.action == "HARVEST_FIELD" then
            table.insert(t.vehicleId ~= nil and running or queued, t)
        end
    end
    return running, queued
end

T.test("headless: 'harvest all crops' plans wheat and barley, one combine does both in turn", function()
    local agent = E.listener
    agent:applyControl("STOP_ALL")
    table.insert(fieldList, makeField(13, 200))
    E.fieldGrowth, E.barleyGrowth = 5, 5
    combine.fill[1], trailer.fill[1] = 0, 0
    E.dialogText = "harvest all crops"
    E.actions.FA_COMMAND.cb(E.actions.FA_COMMAND.target)
    frames(5)
    local running, queued = harvestTasks()
    T.eq(#running, 1); T.eq(#queued, 1)
    T.truthy(running[1].crop ~= queued[1].crop, "one task per crop")
    frames(12)
    T.eq(E.lastJob.typeName, "FIELDWORK")

    if running[1].crop == "WHEAT" then E.fieldGrowth = 10 else E.barleyGrowth = 10 end
    g_currentMission.aiSystem:stopJob(E.lastJob, AIMessageSuccessFinishedJob.new())
    T.eq(running[1].state, "DONE")
    frames(30, 1000)
    T.eq(queued[1].vehicleId, 21, "queued crop bound to the freed combine")
    T.eq(queued[1].state, "RUNNING")
    T.eq(E.lastJob.typeName, "FIELDWORK"); T.eq(E.lastJob.vehicle, combine)
end)

T.test("headless: autopilot starts harvesting by itself when a field ripens", function()
    local agent = E.listener
    agent:applyControl("STOP_ALL")
    E.fieldGrowth, E.barleyGrowth = 3, 3 -- nothing ready
    combine.fill[1], trailer.fill[1] = 0, 0
    E.dialogText = "Take care of the farm while I'm away"
    E.actions.FA_COMMAND.cb(E.actions.FA_COMMAND.target)
    T.eq(agent.autopilot, true)
    local jobsBefore = E.nextJobId
    frames(10)
    T.eq(E.nextJobId, jobsBefore, "nothing ready, nothing started")

    E.barleyGrowth = 5 -- barley ripens
    frames(63, 1000)   -- next autopilot round
    local running = harvestTasks()
    T.eq(#running, 1)
    T.eq(running[1].fieldId, 13); T.eq(running[1].crop, "BARLEY"); T.eq(running[1].state, "RUNNING")
    T.eq(E.lastJob.typeName, "FIELDWORK"); T.eq(E.lastJob.vehicle, combine)
    T.eq(agent.taskManager.continuous, true)

    E.dialogText = "autopilot off"
    E.actions.FA_COMMAND.cb(E.actions.FA_COMMAND.target)
    T.eq(agent.autopilot, false)
    agent:applyControl("STOP_ALL")
    table.remove(fieldList) -- leave the fake farm as the remaining tests expect
end)

T.test("headless: Alt+J menu buttons - 'Prepare harvested fields' cultivates the stubble with the rig", function()
    local agent = E.listener
    agent:applyControl("STOP_ALL")
    E.fieldGrowth = 10          -- field 12: harvested wheat stubble
    E.ground = FieldGroundType.SOWN
    E.plow, E.lime = 1, 2       -- no plow / lime needed
    combine.fill[1], trailer.fill[1] = 0, 0
    E.menuChoice = "Prepare harvested fields"
    E.actions.FA_COMMAND.cb(E.actions.FA_COMMAND.target)
    local menu = E.menus[#E.menus]
    T.eq(menu.title, "Farm Agent")
    local labels = table.concat(menu.options, " | ")
    for _, want in ipairs({ "Harvest all ready crops", "Plant a crop", "Fertilize", "Autopilot", "Stop everything", "Type a command" }) do
        T.truthy(labels:find(want, 1, true), "menu has " .. want)
    end
    frames(5)
    frames(12)
    local cultivate
    for _, t in ipairs(agent.taskManager.tasks) do
        if t.action == "CULTIVATE_FIELD" then cultivate = t end
    end
    T.truthy(cultivate ~= nil, "cultivation planned")
    T.eq(cultivate.vehicleId, 61); T.eq(cultivate.state, "RUNNING")
    T.eq(E.lastJob.typeName, "FIELDWORK"); T.eq(E.lastJob.vehicle, rigTractor)

    -- Field becomes cultivated; the AI reports done; Farm Agent measures it.
    E.fieldGrowth, E.ground = 0, FieldGroundType.CULTIVATED
    g_currentMission.aiSystem:stopJob(E.lastJob, AIMessageSuccessFinishedJob.new())
    T.eq(cultivate.state, "DONE")

    agent.hud:setView("FIELDS")
    agent:backgroundRefresh()
    frames(3)
    local before = E.rendered
    frames(1)
    T.truthy(E.rendered > before, "field overview drawn")
    local snap = agent.farmState.snapshot
    T.eq(snap.fields[1].soil.prepared, 1, "field 12 now ready to sow")

    -- No seeder on the farm: the plant menu says so instead of opening an empty list.
    local notes = #E.notifications
    E.menuChoice = "Plant a crop"
    E.actions.FA_COMMAND.cb(E.actions.FA_COMMAND.target)
    T.truthy(E.notifications[#E.notifications]:find("no crop your seeders can sow"), "plant menu explains")
    agent.hud:setView("STATUS")
end)

T.test("headless: an error during loadMap disables the mod instead of breaking map loading", function()
    local agent = FarmAgent.new(MOD_ROOT .. "/", "FS25_FarmAgent")
    local realPath = getUserProfileAppPath
    getUserProfileAppPath = function() error("simulated engine failure") end
    local ok = pcall(agent.loadMap, agent, "map")
    getUserProfileAppPath = realPath
    T.eq(ok, true, "loadMap must never throw into the game's loading callback")
    T.eq(agent.enabled, false)
    agent:update(100) -- disabled agent ignores frames
    agent:draw()
end)

T.test("headless: an error during update disables the mod and stops its workers", function()
    local agent = E.listener
    local realUpdate = agent.taskManager.update
    agent.taskManager.update = function() error("simulated bug") end
    local ok = pcall(agent.update, agent, 100)
    agent.taskManager.update = realUpdate
    T.eq(ok, true, "update must never throw into the game loop")
    T.eq(agent.enabled, false)
    agent.enabled = true -- restore for the next test
end)

T.test("headless: stop all stops every agent worker", function()
    E.listener:applyControl("STOP_ALL")
    local running = 0
    for _ in pairs(g_currentMission.aiSystem.jobs) do running = running + 1 end
    T.eq(running, 0)
    E.listener:deleteMap()
    T.eq(E.consoleCommands.faCommand, nil, "console commands removed")
end)
