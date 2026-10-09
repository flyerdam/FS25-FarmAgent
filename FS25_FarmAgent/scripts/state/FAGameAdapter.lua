-- FAGameAdapter: the ONLY module that reads FS25 game state.
-- Everything above this layer works on plain Lua tables, so the planner and validator
-- never depend on FS25 implementation details and can be tested outside the game.
--
-- Every API used here was verified against GIANTS' shipped game source (sdk/debugger/
-- gameSource.zip, game 1.21.1.0) or a real call site in it. See docs/FEASIBILITY.md.

FAGameAdapter = {}

local function safe(fn, ...)
    local ok, a, b, c, d, e = pcall(fn, ...)
    if ok then
        return a, b, c, d, e
    end
    return nil
end

-- Farm / mission ------------------------------------------------------------

function FAGameAdapter.isServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

function FAGameAdapter.getFarmId()
    -- Same source GIANTS' own AISystem console command uses for job start.
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        return g_localPlayer.farmId
    end
    return nil
end

function FAGameAdapter.getMoney(farmId)
    local farm = g_farmManager:getFarmById(farmId)
    if farm ~= nil then
        return safe(farm.getBalance, farm)
    end
    return nil
end

function FAGameAdapter.getAILimit()
    local active = 0
    local jobs = g_currentMission.aiSystem:getActiveJobs()
    if jobs ~= nil then
        active = #jobs
    end
    return active, g_currentMission.maxNumHirables, g_currentMission.aiSystem:getAILimitedReached()
end

-- Crops -----------------------------------------------------------------------

-- Plain description of a fruit type: what "ready" means comes from the game's own
-- foliage definition (min/maxHarvestingGrowthState), never from a hard-coded table.
function FAGameAdapter.describeFruitType(fruitType)
    if fruitType == nil then
        return nil
    end
    local fillTypeIndex = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitType.index)
    local title = fruitType.name
    if fillTypeIndex ~= nil then
        title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or title
    end
    return {
        index = fruitType.index,
        name = fruitType.name,
        title = title,
        fillTypeIndex = fillTypeIndex,
        minHarvest = fruitType.minHarvestingGrowthState,
        maxHarvest = fruitType.maxHarvestingGrowthState,
        cutState = fruitType.cutState,
        witheredState = fruitType.witheredState,
    }
end

function FAGameAdapter.getFruitTypeByName(name)
    if name == nil then
        return nil
    end
    return FAGameAdapter.describeFruitType(g_fruitTypeManager:getFruitTypeByName(string.upper(name)))
end

function FAGameAdapter.getFruitTypeByIndex(index)
    return FAGameAdapter.describeFruitType(g_fruitTypeManager:getFruitTypeByIndex(index))
end

-- Full descriptions of every crop that has a harvestable growth state and a fill type.
function FAGameAdapter.listHarvestableCrops()
    local result = {}
    for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do
        local desc = FAGameAdapter.describeFruitType(fruitType)
        if desc ~= nil and desc.minHarvest ~= nil and desc.minHarvest > 0 and desc.fillTypeIndex ~= nil then
            table.insert(result, desc)
        end
    end
    table.sort(result, function(a, b) return a.index < b.index end)
    return result
end

-- { {name="WHEAT", title="Wheat"}, ... } for the natural-language crop matcher.
function FAGameAdapter.listFruitTypeNames()
    local result = {}
    for _, desc in ipairs(FAGameAdapter.listHarvestableCrops()) do
        table.insert(result, { name = desc.name, title = desc.title })
    end
    return result
end

-- Fields ------------------------------------------------------------------------

-- Fields owned by farmId, with world-space boundary polygons.
function FAGameAdapter.getOwnedFields(farmId)
    local result = {}
    for _, field in pairs(g_fieldManager:getFields()) do
        local farmland = field.farmland
        if farmland ~= nil and g_farmlandManager:getFarmlandOwner(farmland.id) == farmId then
            local polygon = {}
            for _, node in ipairs(field.polygonPoints or {}) do
                local x, _, z = getWorldTranslation(node)
                table.insert(polygon, { x = x, z = z })
            end
            table.insert(result, {
                id = field:getId(),
                name = field:getName() or tostring(field:getId()),
                areaHa = field.areaHa,
                -- posX/posZ is the polygon label point computed by Field:load; it lies inside the field.
                labelX = field.posX,
                labelZ = field.posZ,
                farmlandId = farmland.id,
                polygon = polygon,
                ref = field,
            })
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

-- One FieldState instance reused for all point samples (FieldState:update(x, z) is the
-- same call FieldManager uses for its debug field-status overlay).
local sharedFieldState = nil

function FAGameAdapter.sampleFieldPoint(x, z)
    if sharedFieldState == nil then
        sharedFieldState = FieldState.new()
    end
    sharedFieldState:update(x, z)
    if not sharedFieldState.isValid then
        return false
    end
    local s = sharedFieldState
    return true, s.fruitTypeIndex, s.growthState, s.groundType, s.sprayLevel, s.limeLevel, s.plowLevel
end

-- Maximum soil levels. 0 = that counter is disabled in this game (same rule as
-- FieldManager: Platform.gameplay.usePlowCounter / useLimeCounter).
function FAGameAdapter.getFieldLimits()
    local system = g_currentMission.fieldGroundSystem
    local limits = { sprayMax = system:getMaxValue(FieldDensityMap.SPRAY_LEVEL) or 0, plowMax = 0, limeMax = 0 }
    if Platform.gameplay.usePlowCounter then
        limits.plowMax = system:getMaxValue(FieldDensityMap.PLOW_LEVEL) or 0
    end
    if Platform.gameplay.useLimeCounter then
        limits.limeMax = system:getMaxValue(FieldDensityMap.LIME_LEVEL) or 0
    end
    return limits
end

-- FieldGroundType values Farm Agent cares about (names -> numbers).
function FAGameAdapter.getGroundTypes()
    local result = {}
    for _, name in ipairs({ "PLOWED", "CULTIVATED", "SEEDBED", "ROLLED_SEEDBED", "STUBBLE_TILLAGE", "GRASS", "GRASS_CUT", "SOWN", "NONE" }) do
        result[name] = FieldGroundType[name]
    end
    return result
end

-- Whether the crop may be sown in the current period (the same check the vanilla AI uses
-- before stopping with AIMessageErrorWrongSeason).
function FAGameAdapter.isPlantableNow(crop)
    -- The savegame's growth mode is passed through, so with seasonal growth off the game
    -- itself answers "plantable". If the check cannot run, allow it: the vanilla worker
    -- reports AIMessageErrorWrongSeason, which Farm Agent handles.
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(crop.index)
    if fruitType == nil or fruitType.getIsPlantableInPeriod == nil then
        return true
    end
    local ok, plantable = pcall(fruitType.getIsPlantableInPeriod, fruitType,
        g_currentMission.missionInfo.growthMode, g_currentMission.environment.currentPeriod)
    if not ok then
        return true
    end
    return plantable == true
end

-- "Helper buys ..." game settings: when on, vanilla AI workers buy fuel / seeds /
-- fertilizer themselves (Motorized, SowingMachine, Sprayer specs).
function FAGameAdapter.getHelperSettings()
    local info = g_currentMission.missionInfo
    return { buyFuel = info.helperBuyFuel == true, buySeeds = info.helperBuySeeds == true, buyFertilizer = info.helperBuyFertilizer == true }
end

-- Vehicles ----------------------------------------------------------------------

local function getFuelLevel(vehicle)
    if vehicle.getConsumerFillUnitIndex == nil then
        return nil
    end
    for _, fuelName in ipairs({ "DIESEL", "ELECTRICCHARGE", "METHANE" }) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fuelName)
        if fillTypeIndex ~= nil then
            local fillUnitIndex = safe(vehicle.getConsumerFillUnitIndex, vehicle, fillTypeIndex)
            if fillUnitIndex ~= nil then
                return safe(vehicle.getFillUnitFillLevelPercentage, vehicle, fillUnitIndex)
            end
        end
    end
    return nil
end

local function describeCombine(combine)
    local spec = combine.spec_combine
    local fillUnitIndex = spec.fillUnitIndex
    local info = {
        ref = combine,
        fillUnitIndex = fillUnitIndex,
        fillLevel = combine:getFillUnitFillLevel(fillUnitIndex) or 0,
        capacity = combine:getFillUnitCapacity(fillUnitIndex) or 0,
        fillTypeIndex = combine:getFillUnitFillType(fillUnitIndex),
        cutterFruitIndices = {},
        hasCutter = false,
        hasPipe = combine.spec_pipe ~= nil,
    }
    -- Headers may be attached implements or part of the combine itself.
    for _, child in ipairs(combine.rootVehicle:getChildVehicles()) do
        local cutterSpec = child.spec_cutter
        if cutterSpec ~= nil and cutterSpec.fruitTypeIndices ~= nil then
            info.hasCutter = true
            for _, fruitTypeIndex in ipairs(cutterSpec.fruitTypeIndices) do
                info.cutterFruitIndices[fruitTypeIndex] = true
            end
        end
    end
    return info
end

local function describeTrailers(root)
    local trailers = {}
    for _, child in ipairs(root:getChildVehicles()) do
        if child ~= root and child.getAIDischargeNodes ~= nil then
            local nodes = safe(child.getAIDischargeNodes, child) or {}
            for _, dischargeNode in ipairs(nodes) do
                local fillUnitIndex = dischargeNode.fillUnitIndex
                table.insert(trailers, {
                    ref = child,
                    id = NetworkUtil.getObjectId(child),
                    name = child:getFullName(),
                    fillUnitIndex = fillUnitIndex,
                    fillLevel = child:getFillUnitFillLevel(fillUnitIndex) or 0,
                    capacity = child:getFillUnitCapacity(fillUnitIndex) or 0,
                    fillTypeIndex = child:getFillUnitFillType(fillUnitIndex),
                })
            end
        end
    end
    return trailers
end

local function fillTypeName(index)
    if index == nil or index == 0 then
        return nil
    end
    return g_fillTypeManager:getFillTypeNameByIndex(index)
end

-- Field-work implements attached to a root vehicle (seeders, plows, cultivators, sprayers).
function FAGameAdapter.describeTools(root)
    local tools = {}
    for _, child in ipairs(root:getChildVehicles()) do
        if child ~= root then
            local tool = nil
            if child.spec_sowingMachine ~= nil then
                tool = { kind = "SEEDER", seeds = {} }
                for _, fruitIndex in ipairs(child.spec_sowingMachine.seeds or {}) do
                    table.insert(tool.seeds, fruitIndex)
                end
                tool.fillUnitIndex = safe(child.getSowingMachineFillUnitIndex, child)
                tool.anySeason = child.getCanPlantOutsideSeason ~= nil and safe(child.getCanPlantOutsideSeason, child) == true
            elseif child.spec_plow ~= nil then
                tool = { kind = "PLOW" }
            elseif child.spec_cultivator ~= nil then
                tool = { kind = "CULTIVATOR" }
            elseif child.spec_sprayer ~= nil then
                tool = { kind = "SPRAYER", fillTypes = {} }
                tool.fillUnitIndex = safe(child.getSprayerFillUnitIndex, child)
                if tool.fillUnitIndex ~= nil then
                    for fillTypeIndex, _ in pairs(child:getFillUnitSupportedFillTypes(tool.fillUnitIndex) or {}) do
                        local name = fillTypeName(fillTypeIndex)
                        if name ~= nil then
                            table.insert(tool.fillTypes, name)
                        end
                    end
                    tool.currentFill = fillTypeName(child:getFillUnitFillType(tool.fillUnitIndex))
                    tool.lastFill = fillTypeName(child:getFillUnitLastValidFillType(tool.fillUnitIndex))
                end
            end
            if tool ~= nil then
                tool.ref = child
                tool.name = child:getFullName()
                if tool.fillUnitIndex ~= nil then
                    tool.fillLevel = child:getFillUnitFillLevel(tool.fillUnitIndex) or 0
                    tool.capacity = child:getFillUnitCapacity(tool.fillUnitIndex) or 0
                end
                table.insert(tools, tool)
            end
        end
    end
    return tools
end

local function hasName(list, name)
    for _, v in ipairs(list or {}) do
        if v == name then return true end
    end
    return false
end

-- The single field operation a tool rig performs. One vanilla field-work job runs ALL
-- attached tools, so a cultivator+seeder rig is only ever used to SEED.
function FAGameAdapter.toolOperations(tools)
    local kinds = {}
    for _, t in ipairs(tools) do kinds[t.kind] = t end
    if kinds.SEEDER then return { "SEED" } end
    if kinds.PLOW then return { "PLOW" } end
    if kinds.CULTIVATOR then return { "CULTIVATE" } end
    local sprayer = kinds.SPRAYER
    if sprayer then
        local holdsLime = sprayer.currentFill == "LIME" or (sprayer.currentFill == nil and sprayer.lastFill == "LIME")
        if holdsLime or (hasName(sprayer.fillTypes, "LIME") and not hasName(sprayer.fillTypes, "FERTILIZER")
            and not hasName(sprayer.fillTypes, "LIQUIDFERTILIZER")) then
            return { "LIME" }
        end
        for _, ft in ipairs({ "FERTILIZER", "LIQUIDFERTILIZER", "MANURE", "LIQUIDMANURE", "DIGESTATE" }) do
            if hasName(sprayer.fillTypes, ft) then
                return { "FERTILIZE" }
            end
        end
    end
    return {}
end

-- Live description of a root vehicle (tractor, combine, ...).
function FAGameAdapter.describeVehicle(root)
    local x, _, z = getWorldTranslation(root.rootNode)
    local dirX, _, dirZ = localDirectionToWorld(root.rootNode, 0, 0, 1)
    local record = {
        ref = root,
        id = NetworkUtil.getObjectId(root),
        name = root:getFullName(),
        x = x, z = z, dirX = dirX, dirZ = dirZ,
        speedKmh = root:getLastSpeed(),
        fuel = getFuelLevel(root),
        damage = root.getDamageAmount ~= nil and safe(root.getDamageAmount, root) or 0,
        isBroken = root.isBroken == true,
        aiActive = root:getIsAIActive(),
        isEntered = root.getIsEntered ~= nil and root:getIsEntered() or false,
        kind = "OTHER",
    }

    for _, child in ipairs(root:getChildVehicles()) do
        if child.spec_combine ~= nil then
            record.kind = "COMBINE"
            record.combine = describeCombine(child)
            break
        end
    end

    if record.kind ~= "COMBINE" then
        local tools = FAGameAdapter.describeTools(root)
        if #tools > 0 then
            record.kind = "TOOL"
            record.tools = tools
            record.ops = FAGameAdapter.toolOperations(tools)
        else
            local trailers = describeTrailers(root)
            if #trailers > 0 then
                record.kind = "TRANSPORT"
                record.trailers = trailers
            end
        end
    end

    record.canFieldWork = FAJobAdapter.isJobAvailable("FIELDWORK", root)
    record.canGoTo = FAJobAdapter.isJobAvailable("GOTO", root)
    record.canDeliver = FAJobAdapter.isJobAvailable("DELIVER", root)
    return record
end

-- All root vehicles owned by farmId that can host an AI worker (spec_aiJobVehicle).
-- This skips pallets, bales-as-vehicles and unattached implements.
function FAGameAdapter.listVehicles(farmId)
    local result = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.rootVehicle == vehicle and vehicle.spec_aiJobVehicle ~= nil
            and vehicle:getOwnerFarmId() == farmId and vehicle.rootNode ~= nil then
            local record = safe(FAGameAdapter.describeVehicle, vehicle)
            if record ~= nil then
                table.insert(result, record)
            end
        end
    end
    return result
end

function FAGameAdapter.isVehicleValid(vehicle)
    return vehicle ~= nil and not vehicle.isDeleted and not vehicle.isDeleting and vehicle.rootNode ~= nil
end

-- Name of the nearest other vehicle in a box in front of 'root' (lengthAhead metres
-- ahead, halfWidth to each side), or nil. Used to diagnose "worker stuck".
function FAGameAdapter.findVehicleInFront(root, lengthAhead, halfWidth)
    local ownChildren = {}
    for _, child in ipairs(root:getChildVehicles()) do
        ownChildren[child] = true
    end
    local bestName, bestDist = nil, math.huge
    for _, other in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not ownChildren[other] and other.rootNode ~= nil then
            local x, y, z = getWorldTranslation(other.rootNode)
            local lx, _, lz = worldToLocal(root.rootNode, x, y, z)
            if lz > 0 and lz < lengthAhead and math.abs(lx) < halfWidth and lz < bestDist then
                bestName, bestDist = other:getFullName(), lz
            end
        end
    end
    return bestName
end

-- True when the combine is threshing-blocked by rain (vanilla rule, Combine spec).
function FAGameAdapter.isThreshingBlockedByRain(combine)
    if combine == nil or combine.getIsThreshingDuringRain == nil then
        return false
    end
    return safe(combine.getIsThreshingDuringRain, combine, false) == true
end

-- Combine pipe / trailer interaction ------------------------------------------

-- The vehicle the combine's pipe trigger currently sees (vanilla AIDriveStrategyCombine
-- uses exactly this to decide whether to unload).
function FAGameAdapter.getVehicleUnderPipe(combine)
    local spec = combine.spec_pipe
    if spec == nil or spec.nearestObjectInTriggers == nil or spec.nearestObjectInTriggers.objectId == nil then
        return nil
    end
    return NetworkUtil.getObject(spec.nearestObjectInTriggers.objectId)
end

-- Pipe.setPipeState sets currentState = 0 while the pipe moves and back to the target
-- state once the animation has finished, so 2/2 means "fully unfolded".
function FAGameAdapter.isPipeFullyUnfolded(combine)
    local spec = combine.spec_pipe
    return spec ~= nil and spec.targetState == 2 and spec.currentState == 2
end

function FAGameAdapter.getPipeTargetState(combine)
    return combine.spec_pipe ~= nil and combine.spec_pipe.targetState or nil
end

-- Pipe end in combine-local metres (x lateral, z forward) - only while fully unfolded;
-- callers cache it (FAMemory) so later rendezvous do not depend on unfold timing.
function FAGameAdapter.getPipeLocalOffset(combine)
    if not FAGameAdapter.isPipeFullyUnfolded(combine) then
        return nil
    end
    local dischargeNode = combine.getCurrentDischargeNode ~= nil and combine:getCurrentDischargeNode() or nil
    if dischargeNode == nil or dischargeNode.node == nil then
        return nil
    end
    local x, _, z = localToLocal(dischargeNode.node, combine.rootVehicle.rootNode, 0, 0, 0)
    return x, z
end

-- Stable id across game sessions (for the farm memory).
function FAGameAdapter.getUniqueId(vehicle)
    if vehicle.getUniqueId ~= nil then
        local ok, id = pcall(vehicle.getUniqueId, vehicle)
        if ok and id ~= nil then
            return tostring(id)
        end
    end
    return tostring(NetworkUtil.getObjectId(vehicle))
end

local function halfWidth(vehicle, default)
    if vehicle.size ~= nil and vehicle.size.width ~= nil then
        return vehicle.size.width * 0.5
    end
    return default or 1.5
end

-- Body and header footprint of a combine (vehicle.size from the store XML).
function FAGameAdapter.getCombineGeometry(combine)
    local root = combine.rootVehicle
    local geometry = { bodyHalfWidth = halfWidth(root, 1.75), headerHalfWidth = 0, headerZMin = nil }
    for _, child in ipairs(root:getChildVehicles()) do
        if child ~= root and child.spec_cutter ~= nil then
            local _, _, hz = localToLocal(child.rootNode, root.rootNode, 0, 0, 0)
            local length = child.size ~= nil and child.size.length or 2
            geometry.headerHalfWidth = math.max(geometry.headerHalfWidth, halfWidth(child, 3))
            geometry.headerZMin = math.min(geometry.headerZMin or math.huge, hz - length * 0.5)
        end
    end
    return geometry
end

-- Trailer fill volume relative to the tractor's AI node, and the rig's widths.
function FAGameAdapter.getTransportGeometry(transportRoot, trailer)
    local fillNode = trailer.ref:getFillUnitExactFillRootNode(trailer.fillUnitIndex)
        or trailer.ref:getFillUnitRootNode(trailer.fillUnitIndex)
    if fillNode == nil then
        return nil
    end
    local aiNode = transportRoot:getAIDirectionNode() or transportRoot.rootNode
    local _, _, tz = localToLocal(fillNode, aiNode, 0, 0, 0)
    return { fillOffsetZ = tz, trailerHalfWidth = halfWidth(trailer.ref, 1.25), tractorHalfWidth = halfWidth(transportRoot, 1.25) }
end

-- Where the transport rig's AI node must drive so the trailer sits under the pipe end,
-- clear of body and header. pipeX/pipeZ = fully unfolded pipe end (combine-local).
-- Returns worldX, worldZ, dirX, dirZ, pose  or  nil, reason.
function FAGameAdapter.computeUnderPipeTarget(combine, transportRoot, trailer, pipeX, pipeZ)
    if pipeX == nil then
        return nil, "pipe position unknown (waiting for the pipe to unfold)"
    end
    local transport = FAGameAdapter.getTransportGeometry(transportRoot, trailer)
    if transport == nil then
        return nil, "trailer has no fill root node"
    end
    local geometry = FAGameAdapter.getCombineGeometry(combine)
    local pose, reason = FALogistics.computeUnderPipePose({
        pipeX = pipeX, pipeZ = pipeZ,
        bodyHalfWidth = geometry.bodyHalfWidth, headerHalfWidth = geometry.headerHalfWidth, headerZMin = geometry.headerZMin,
        trailerHalfWidth = transport.trailerHalfWidth, tractorHalfWidth = transport.tractorHalfWidth,
        fillOffsetZ = transport.fillOffsetZ,
    })
    if pose == nil then
        return nil, reason
    end
    local root = combine.rootVehicle.rootNode
    local wx, _, wz = localToWorld(root, pose.x, 0, pose.z)
    local dirX, _, dirZ = localDirectionToWorld(root, 0, 0, 1)
    return wx, wz, dirX, dirZ, pose
end

-- World-space vector (dx, dz) from the pipe end to the trailer's fill volume.
-- Used to correct a GoTo target that parked the trailer slightly off.
function FAGameAdapter.getUnderPipeError(combine, trailer)
    local dischargeNode = combine:getCurrentDischargeNode()
    local fillNode = trailer.ref:getFillUnitExactFillRootNode(trailer.fillUnitIndex)
        or trailer.ref:getFillUnitRootNode(trailer.fillUnitIndex)
    if dischargeNode == nil or dischargeNode.node == nil or fillNode == nil then
        return nil
    end
    local fx, _, fz = getWorldTranslation(fillNode)
    local px, _, pz = getWorldTranslation(dischargeNode.node)
    return fx - px, fz - pz
end

-- Unloading stations -----------------------------------------------------------

-- Stations the player can use, with record.accepts[cropName] = free capacity for every
-- crop (from 'crops') the station accepts from AI workers.
function FAGameAdapter.listUnloadingStations(crops, farmId)
    local result = {}
    for _, station in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        if station:isa(UnloadingStation) and g_currentMission.accessHandler:canPlayerAccess(station) then
            local record = {
                ref = station,
                id = NetworkUtil.getObjectId(station),
                name = station:getName(),
                isSellingStation = station:isa(SellingStation),
                accepts = {},
            }
            for _, crop in ipairs(crops) do
                local fillTypeIndex = crop.fillTypeIndex
                if fillTypeIndex ~= nil and station:getIsFillTypeAISupported(fillTypeIndex) then
                    record.accepts[crop.name] = station:getFreeCapacity(fillTypeIndex, farmId) or 0
                    if record.x == nil then
                        local x, z = station:getAITargetPositionAndDirection(fillTypeIndex)
                        record.x, record.z = x, z
                    end
                end
            end
            table.insert(result, record)
        end
    end
    return result
end

-- Messages ---------------------------------------------------------------------

function FAGameAdapter.notify(text, isCritical)
    local notificationType = isCritical and FSBaseMission.INGAME_NOTIFICATION_CRITICAL or FSBaseMission.INGAME_NOTIFICATION_INFO
    g_currentMission:addIngameNotification(notificationType, "Farm Agent: " .. text)
end
