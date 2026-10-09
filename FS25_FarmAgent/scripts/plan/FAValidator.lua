-- FAValidator: every structured action is checked here before execution, whether it
-- came from the deterministic planner or from Claude. Pure function over the snapshot.
--
-- Returns ok, reason, isTransient. Transient failures (vehicle busy, AI limit) mean
-- "try again later"; permanent ones mean the action can never succeed as written.

FAValidator = {}

FAValidator.SUPPORTED_ACTIONS = {
    HARVEST_FIELD = true,
    UNLOAD_COMBINE = true,
    DELIVER = true,
    STOP_TASK = true,
    WAIT = true,
    REPORT = true,
    CULTIVATE_FIELD = true,
    PLOW_FIELD = true,
    SEED_FIELD = true,
    FERTILIZE_FIELD = true,
    LIME_FIELD = true,
}

local function index(list)
    local byId = {}
    for _, item in ipairs(list or {}) do
        byId[item.id] = item
    end
    return byId
end

-- ctx = { snapshot = ..., reservedBy = { [vehicleId] = taskId }, taskId = <this task>, tasks = { [id] = task } }
function FAValidator.validate(action, ctx)
    if type(action) ~= "table" or type(action.action) ~= "string" then
        return false, "action must be an object with an 'action' field", false
    end
    if not FAValidator.SUPPORTED_ACTIONS[action.action] then
        return false, "action " .. action.action .. " is not supported in Milestone 1", false
    end

    local snapshot = ctx.snapshot
    local fields = index(snapshot.fields)
    local vehicles = index(snapshot.vehicles)
    local stations = index(snapshot.stations)

    local function checkVehicleFree(v)
        if v.isBroken then
            return false, v.name .. " is broken", false
        end
        if FAPlanner.isPlayerDriving(v) then
            return false, "player is driving " .. v.name, true
        end
        local reservedBy = ctx.reservedBy and ctx.reservedBy[v.id]
        if reservedBy ~= nil and reservedBy ~= ctx.taskId then
            return false, v.name .. " is assigned to task " .. reservedBy, true
        end
        if v.aiActive and reservedBy ~= ctx.taskId then
            return false, v.name .. " already has an AI worker that Farm Agent did not start", true
        end
        return true
    end

    if action.action == "HARVEST_FIELD" then
        local f = fields[action.fieldId]
        if f == nil then
            return false, "field " .. tostring(action.fieldId) .. " is not owned by the farm", false
        end
        if (f.readyFraction or 0) < 0.03 then
            return false, "field " .. f.name .. " has nothing ready to harvest", false
        end
        if action.vehicleId == nil then
            return true -- queued, bound later
        end
        local v = vehicles[action.vehicleId]
        if v == nil then
            return false, "vehicle " .. tostring(action.vehicleId) .. " not found", false
        end
        if v.kind ~= "COMBINE" or v.combine == nil then
            return false, v.name .. " is not a combine", false
        end
        if not v.combine.hasCutter then
            return false, v.name .. " has no header attached", false
        end
        if not v.combine.supportsCrop then
            return false, v.name .. "'s header/grain tank cannot harvest this crop", false
        end
        if not v.canFieldWork then
            return false, v.name .. " cannot run a vanilla field-work AI job", false
        end
        if v.fuel ~= nil and v.fuel < 0.03 then
            return false, v.name .. " is out of fuel", false
        end
        return checkVehicleFree(v)

    elseif action.action == "UNLOAD_COMBINE" then
        local c = vehicles[action.combineId]
        local v = vehicles[action.vehicleId]
        local s = stations[action.stationId]
        if c == nil or c.kind ~= "COMBINE" then
            return false, "combine " .. tostring(action.combineId) .. " not found", false
        end
        if not c.combine.hasPipe then
            return false, c.name .. " has no unloading pipe", false
        end
        if v == nil then
            return false, "transport vehicle " .. tostring(action.vehicleId) .. " not found", false
        end
        if not FAPlanner.isCompatibleTransport(v) then
            return false, v.name .. " is not an AI-capable tractor with a trailer for this crop", false
        end
        if s == nil or not s.acceptsCrop then
            return false, "station " .. tostring(action.stationId) .. " does not accept this crop", false
        end
        if s.freeCapacity ~= -1 and s.freeCapacity <= 0 then
            return false, s.name .. " is full", true
        end
        return checkVehicleFree(v)

    elseif action.action == "DELIVER" then
        local v = vehicles[action.vehicleId]
        local s = stations[action.stationId]
        if v == nil or not FAPlanner.isCompatibleTransport(v) then
            return false, "vehicle " .. tostring(action.vehicleId) .. " is not a transport unit", false
        end
        if s == nil or not s.acceptsCrop then
            return false, "station " .. tostring(action.stationId) .. " does not accept this crop", false
        end
        return checkVehicleFree(v)

    elseif FABrain.OP_FOR_ACTION[action.action] ~= nil then
        -- Field operations with a tool rig (cultivate, plow, seed, fertilize, lime).
        local op = FABrain.OP_FOR_ACTION[action.action]
        local f = fields[action.fieldId]
        if f == nil then
            return false, "field " .. tostring(action.fieldId) .. " is not owned by the farm", false
        end
        if f.soil ~= nil and (f.soil.grass or 0) >= 0.5 then
            return false, "field " .. f.name .. " is grassland - Farm Agent does not till grass", false
        end
        if op == "SEED" and action.crop == nil then
            return false, "planting needs a crop", false
        end
        if action.vehicleId == nil then
            return true -- queued, bound later
        end
        local v = vehicles[action.vehicleId]
        if v == nil then
            return false, "vehicle " .. tostring(action.vehicleId) .. " not found", false
        end
        if not FABrain.isCompatibleTool(v, op, action.crop) then
            return false, string.format("%s has no tool that can %s%s", v.name, FABrain.OP_TITLES[op] or op,
                op == "SEED" and (" " .. tostring(action.crop)) or ""), false
        end
        if op == "SEED" and not FABrain.canSowNow(v, action.crop, snapshot) then
            return false, action.crop .. " cannot be planted in this period", false
        end
        local missing = FABrain.suppliesMissing(v, op, snapshot.helpers)
        if missing ~= nil then
            return false, missing, true
        end
        if v.fuel ~= nil and v.fuel < 0.03 then
            return false, v.name .. " is out of fuel", false
        end
        return checkVehicleFree(v)

    elseif action.action == "STOP_TASK" then
        if ctx.tasks == nil or ctx.tasks[action.taskId] == nil then
            return false, "task " .. tostring(action.taskId) .. " does not exist", false
        end
        return true
    end

    return true
end
