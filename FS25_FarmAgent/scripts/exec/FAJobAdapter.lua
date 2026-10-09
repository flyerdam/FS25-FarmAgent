-- FAJobAdapter: the ONLY module that changes the game. It does so exclusively by
-- creating and stopping vanilla FS25 AI jobs (FIELDWORK, GOTO, DELIVER).
-- Farm Agent never steers a vehicle itself.
--
-- Start flow mirrors GIANTS' own AISystem:consoleCommandAIStart:
--   createJob -> set parameters -> setValues -> validate -> aiSystem:startJob

FAJobAdapter = {}

local prototypes = {}

local function getJobTypeIndex(typeName)
    return g_currentMission.aiJobTypeManager:getJobTypeIndexByName(typeName)
end

local function createJob(typeName)
    local typeIndex = getJobTypeIndex(typeName)
    if typeIndex == nil then
        return nil, "AI job type " .. typeName .. " is not registered"
    end
    local job = g_currentMission.aiJobTypeManager:createJob(typeIndex)
    if job == nil then
        return nil, "could not create AI job " .. typeName
    end
    return job
end

-- Uses the job class's own getIsAvailableForVehicle (e.g. AIJobFieldWork checks
-- getCanStartFieldWork + getIsAIJobSupported) on a cached prototype instance.
function FAJobAdapter.isJobAvailable(typeName, vehicle)
    local proto = prototypes[typeName]
    if proto == nil then
        proto = createJob(typeName)
        if proto == nil then
            return false
        end
        prototypes[typeName] = proto
    end
    local ok, available = pcall(proto.getIsAvailableForVehicle, proto, vehicle)
    return ok and available == true
end

-- True when the player sits in the vehicle AND is driving it. Sitting in the cab of a
-- parked vehicle is fine: vanilla also lets you hire the helper from inside the cab.
function FAJobAdapter.isPlayerDriving(vehicle)
    local entered = vehicle.getIsEntered ~= nil and vehicle:getIsEntered()
    return entered and not vehicle:getIsAIActive() and (vehicle:getLastSpeed() or 0) > 1
end

-- Checks shared by all starts. Player authority: never take over a vehicle the player is driving.
local function preflight(vehicle)
    if not FAGameAdapter.isVehicleValid(vehicle) then
        return false, "vehicle no longer exists"
    end
    if g_currentMission.aiSystem:getAILimitedReached() then
        return false, "AI worker limit reached"
    end
    if vehicle:getIsAIActive() then
        return false, "vehicle already has an active AI worker"
    end
    if FAJobAdapter.isPlayerDriving(vehicle) then
        return false, "player is driving this vehicle"
    end
    return true
end

local function validateAndStart(job, farmId)
    job:setValues()
    local ok, errorMessage = job:validate(farmId)
    if not ok then
        return nil, errorMessage or "job validation failed"
    end
    g_currentMission.aiSystem:startJob(job, farmId)
    return job
end

-- Vanilla field work (harvest, cultivate, sow...). The worker first drives to (x, z)
-- facing (dirX, dirZ), then detects the field there and generates its own course.
-- isDirectStart = start working at the vehicle's current position (used by recovery).
function FAJobAdapter.startFieldWork(vehicle, farmId, x, z, dirX, dirZ, isDirectStart)
    local ok, reason = preflight(vehicle)
    if not ok then
        return nil, reason
    end
    local job, err = createJob("FIELDWORK")
    if job == nil then
        return nil, err
    end
    job:applyCurrentState(vehicle, g_currentMission, farmId, isDirectStart == true)
    if not isDirectStart then
        job.positionAngleParameter:setPosition(x, z)
        job.positionAngleParameter:setAngle(MathUtil.getYRotationFromDirection(dirX, dirZ))
    end
    return validateAndStart(job, farmId)
end

-- Selects the crop on every attached seeder (SowingMachine:setSeedFruitType, the same
-- call the seed-selection key uses). Returns false if no seeder can sow this crop.
function FAJobAdapter.setSeedCrop(root, fruitTypeIndex)
    local any = false
    for _, child in ipairs(root:getChildVehicles()) do
        local spec = child.spec_sowingMachine
        if spec ~= nil then
            for _, seed in ipairs(spec.seeds or {}) do
                if seed == fruitTypeIndex then
                    child:setSeedFruitType(fruitTypeIndex)
                    any = true
                end
            end
        end
    end
    return any
end

-- Unfold (2) / fold (1) a combine pipe - same call the vanilla AI combine strategy makes.
function FAJobAdapter.setPipeState(combine, state)
    if combine.spec_pipe ~= nil and combine.spec_pipe.targetState ~= state then
        combine:setPipeState(state)
    end
end

-- Vanilla "Go To". approachOffset > 0 makes the drive-to task first aim at a point that
-- many metres behind the target, then drive straight in (same mechanism AIJobDeliver
-- uses to line trailers up with unloading triggers).
-- finalSpeed (km/h, optional): speed of the final straight leg. AITaskDriveTo uses its
-- maxSpeed field (default 10) for that leg; slower = stops closer to the target.
function FAJobAdapter.startGoTo(vehicle, farmId, x, z, dirX, dirZ, approachOffset, finalSpeed)
    local ok, reason = preflight(vehicle)
    if not ok then
        return nil, reason
    end
    local job, err = createJob("GOTO")
    if job == nil then
        return nil, err
    end
    job:applyCurrentState(vehicle, g_currentMission, farmId, false)
    job.vehicleParameter:setVehicle(vehicle)
    job.positionAngleParameter:setPosition(x, z)
    job.positionAngleParameter:setAngle(MathUtil.getYRotationFromDirection(dirX, dirZ))
    job:setValues()
    if approachOffset ~= nil and approachOffset > 0 and job.driveToTask ~= nil then
        job.driveToTask:setTargetOffset(approachOffset)
    end
    if finalSpeed ~= nil and job.driveToTask ~= nil then
        job.driveToTask.maxSpeed = finalSpeed
    end
    local valid, errorMessage = job:validate(farmId)
    if not valid then
        return nil, errorMessage or "job validation failed"
    end
    g_currentMission.aiSystem:startJob(job, farmId)
    return job
end

-- Vanilla "Deliver", non-looping. With every trailer fill unit already loaded,
-- AIJobDeliver:getStartTaskIndex skips the loading leg and drives straight to the station.
function FAJobAdapter.startDeliver(vehicle, farmId, station)
    local ok, reason = preflight(vehicle)
    if not ok then
        return nil, reason
    end
    local job, err = createJob("DELIVER")
    if job == nil then
        return nil, err
    end
    job:applyCurrentState(vehicle, g_currentMission, farmId, false)
    job.unloadingStationParameter:setUnloadingStation(station)
    job.loopingParameter:setIsLooping(false)
    return validateAndStart(job, farmId)
end

function FAJobAdapter.isJobRunning(job)
    return job ~= nil and job.jobId ~= nil and g_currentMission.aiSystem:getJobById(job.jobId) ~= nil
end

function FAJobAdapter.stopJob(job)
    if FAJobAdapter.isJobRunning(job) then
        g_currentMission.aiSystem:stopJob(job, AIMessageSuccessStoppedByUser.new())
        return true
    end
    return false
end

-- A Deliver job whose trailer has an empty secondary fill unit waits in
-- AITaskWaitForFilling; vanilla allows skipping that task once something valid is loaded.
function FAJobAdapter.skipWaitingForFilling(job)
    if job ~= nil and job.waitForFillingTask ~= nil and job.currentTaskIndex == job.waitForFillingTask.taskIndex
        and job.getCanSkipTask ~= nil and job:getCanSkipTask() then
        g_currentMission.aiSystem:skipCurrentTask(job)
        return true
    end
    return false
end

-- Stop reasons Farm Agent reacts to. Resolved with aiMessage:isa(Class): in game,
-- ClassUtil.getClassNameByObject is NOT callable from mods ("attempt to call a nil value"),
-- even though GIANTS' own scripts use it.
local MESSAGE_CLASS_NAMES = {
    "AIMessageSuccessFinishedJob", "AIMessageSuccessStoppedByUser", "AIMessageSuccessSiloEmpty",
    "AIMessageErrorOutOfFuel", "AIMessageErrorOutOfMoney", "AIMessageErrorOutOfFill",
    "AIMessageErrorVehicleBroken", "AIMessageErrorVehicleDeleted", "AIMessageErrorFieldNotOwned",
    "AIMessageErrorFieldNotReady", "AIMessageErrorNoFieldFound", "AIMessageErrorThreshingNotAllowed",
    "AIMessageErrorUnloadingStationFull", "AIMessageErrorUnloadingStationDeleted", "AIMessageErrorWrongSeason",
    "AIMessageErrorNotReachable", "AIMessageErrorCouldNotPrepare", "AIMessageErrorBlockedByObject",
    "AIMessageErrorGraintankIsFull", "AIMessageErrorImplementWrongWay", "AIMessageErrorNoValidFillTypeLoaded",
    "AIMessageErrorUnknown",
}

-- Mods run in their own environment; class globals are still reachable through it.
local function lookupGlobal(name)
    local env = (getfenv ~= nil and getfenv(1)) or _G or {}
    local value = env[name]
    if value == nil and _G ~= nil then
        value = _G[name]
    end
    return value
end

-- "AIMessageErrorOutOfFuel", "AIMessageSuccessFinishedJob", ...
function FAJobAdapter.getMessageName(aiMessage)
    if aiMessage == nil then
        return "none"
    end
    if type(aiMessage) == "table" and aiMessage.isa ~= nil then
        for _, name in ipairs(MESSAGE_CLASS_NAMES) do
            local class = lookupGlobal(name)
            if class ~= nil then
                local ok, isClass = pcall(aiMessage.isa, aiMessage, class)
                if ok and isClass then
                    return name
                end
            end
        end
    end
    return "unknown"
end

function FAJobAdapter.getMessageText(aiMessage, job)
    if aiMessage ~= nil and aiMessage.getMessage ~= nil then
        local ok, text = pcall(aiMessage.getMessage, aiMessage, job)
        if ok and text ~= nil then
            return text
        end
    end
    return FAJobAdapter.getMessageName(aiMessage)
end

function FAJobAdapter.reset()
    for _, proto in pairs(prototypes) do
        pcall(proto.delete, proto)
    end
    prototypes = {}
end
