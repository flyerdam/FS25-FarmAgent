-- FAFarmState: builds the Farm State Model - plain tables describing the farm - from the
-- game adapter. The snapshot holds no game object references; those live in self.refs,
-- keyed by the same ids, for the executor to use.
--
-- The snapshot is multi-crop: every field lists readiness per crop present, every combine
-- and trailer lists the crops it can take, every station lists the crops it accepts.
-- FAPlanner.viewForCrop() narrows it to one crop for planning/validation.

FAFarmState = {}
local FAFarmState_mt = { __index = FAFarmState }

function FAFarmState.new(scanner, memory)
    local self = setmetatable({}, FAFarmState_mt)
    self.scanner = scanner
    self.memory = memory
    self.fieldRecords = {}
    self.snapshot = nil
    self.refs = { vehicles = {}, stations = {}, fields = {} }
    return self
end

-- Loads owned fields into the scanner. Call before scanning.
function FAFarmState:loadFields(farmId)
    self.fieldRecords = FAGameAdapter.getOwnedFields(farmId)
    self.refs.fields = {}
    for _, field in ipairs(self.fieldRecords) do
        self.refs.fields[field.id] = field
    end
    self.scanner:setFields(self.fieldRecords)
    return self.fieldRecords
end

local function round(v, digits)
    if v == nil then
        return nil
    end
    local m = 10 ^ (digits or 2)
    return math.floor(v * m + 0.5) / m
end

local function combineSupportsCrop(combineInfo, crop)
    if crop == nil or not combineInfo.cutterFruitIndices[crop.index] then
        return false
    end
    local combine = combineInfo.ref
    return crop.fillTypeIndex ~= nil and combine:getFillUnitSupportsFillType(combineInfo.fillUnitIndex, crop.fillTypeIndex) == true
end

local function contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then
            return true
        end
    end
    return false
end

-- Plain vehicle record from a live adapter record. crops = harvestable crop descriptions.
function FAFarmState.toPlainVehicle(record, crops)
    local v = {
        id = record.id,
        name = record.name,
        kind = record.kind,
        x = round(record.x, 1), z = round(record.z, 1),
        dirX = record.dirX, dirZ = record.dirZ,
        speedKmh = round(record.speedKmh, 1),
        fuel = round(record.fuel, 3),
        damage = round(record.damage, 3),
        isBroken = record.isBroken,
        aiActive = record.aiActive,
        isEntered = record.isEntered,
        canFieldWork = record.canFieldWork,
        canGoTo = record.canGoTo,
        canDeliver = record.canDeliver,
    }
    if record.combine ~= nil then
        local headerCrops, supported, fillCrop = {}, {}, nil
        for _, crop in ipairs(crops) do
            if crop.fillTypeIndex == record.combine.fillTypeIndex then
                fillCrop = crop.name
            end
            if record.combine.cutterFruitIndices[crop.index] then
                table.insert(headerCrops, crop.name)
                if combineSupportsCrop(record.combine, crop) then
                    table.insert(supported, crop.name)
                end
            end
        end
        v.combine = {
            fillLevel = round(record.combine.fillLevel, 0),
            capacity = round(record.combine.capacity, 0),
            hasCutter = record.combine.hasCutter,
            hasPipe = record.combine.hasPipe,
            headerCrops = headerCrops,
            supportedCrops = supported,
            fillCrop = fillCrop, -- crop currently in the grain tank (nil when empty/unknown)
        }
    end
    if record.tools ~= nil then
        v.ops = record.ops
        v.tools = {}
        for _, t in ipairs(record.tools) do
            local seeds = nil
            if t.seeds ~= nil then
                seeds = {}
                for _, crop in ipairs(crops) do
                    for _, fruitIndex in ipairs(t.seeds) do
                        if fruitIndex == crop.index then table.insert(seeds, crop.name) end
                    end
                end
            end
            table.insert(v.tools, {
                kind = t.kind, name = t.name, seeds = seeds, fillTypes = t.fillTypes, anySeason = t.anySeason,
                currentFill = t.currentFill, fillLevel = round(t.fillLevel, 0), capacity = round(t.capacity, 0),
            })
        end
    end
    if record.trailers ~= nil then
        v.trailers = {}
        for _, t in ipairs(record.trailers) do
            local supported = {}
            for _, crop in ipairs(crops) do
                if crop.fillTypeIndex ~= nil and t.ref:getFillUnitSupportsFillType(t.fillUnitIndex, crop.fillTypeIndex) == true then
                    table.insert(supported, crop.name)
                end
            end
            table.insert(v.trailers, {
                id = t.id,
                name = t.name,
                fillLevel = round(t.fillLevel, 0),
                capacity = round(t.capacity, 0),
                supportedCrops = supported,
            })
        end
    end
    return v
end

-- Builds the full snapshot. focusCrop (optional) adds the single-crop shortcuts
-- (readyFraction / supportsCrop / acceptsCrop) for that crop, as in Milestone 1.
function FAFarmState:refresh(farmId, focusCrop)
    local crops = FAGameAdapter.listHarvestableCrops()
    local snapshot = {
        farmId = farmId,
        money = FAGameAdapter.getMoney(farmId),
        fields = {},
        vehicles = {},
        stations = {},
        crops = {},
    }
    snapshot.plantable = {}
    for _, crop in ipairs(crops) do
        table.insert(snapshot.crops, { name = crop.name, title = crop.title })
        if FAGameAdapter.isPlantableNow(crop) then
            snapshot.plantable[crop.name] = true
        end
    end
    local active, limit = FAGameAdapter.getAILimit()
    snapshot.ai = { activeJobs = active, workerLimit = limit }
    snapshot.helpers = FAGameAdapter.getHelperSettings()
    snapshot.limits = FAGameAdapter.getFieldLimits()
    local soilCtx = FAFarmState.soilContext()

    for _, field in ipairs(self.fieldRecords) do
        local result = self.scanner:getResult(field.id)
        local class = FAFieldScanner.classify(result, FAGameAdapter.getFruitTypeByIndex)
        local readyByCrop = {}
        for _, crop in ipairs(crops) do
            local fraction = FAFieldScanner.getReadyFraction(result, crop)
            if fraction > 0 then
                readyByCrop[crop.name] = round(fraction, 3)
            end
        end
        local dominant = class.cropName and FAGameAdapter.getFruitTypeByName(class.cropName) or nil
        table.insert(snapshot.fields, {
            id = field.id,
            name = field.name,
            areaHa = round(field.areaHa, 2),
            labelX = field.labelX, labelZ = field.labelZ,
            crop = class.cropName,
            state = class.state,
            growthState = class.growthState,
            -- Last harvestable stage: next growth step withers the crop.
            urgent = dominant ~= nil and class.state == "READY_TO_HARVEST" and class.growthState == dominant.maxHarvest
                and dominant.witheredState ~= nil,
            readyFraction = round(class.readyFraction or 0, 3),
            readyByCrop = readyByCrop,
            soil = FAFarmState.roundSoil(FAFieldScanner.soilSummary(result, soilCtx)),
            lastCrop = self.memory ~= nil and self.memory:getLastCrop(field.id) or nil,
            scanned = result ~= nil,
        })
    end

    self.refs.vehicles = {}
    for _, record in ipairs(FAGameAdapter.listVehicles(farmId)) do
        self.refs.vehicles[record.id] = record.ref
        local plain = FAFarmState.toPlainVehicle(record, crops)
        -- A vehicle Farm Agent is only parking is free for new work (the park drive is
        -- cancelled when a job takes it).
        if plain.aiActive and self.isParking ~= nil and self.isParking(record.id) then
            plain.aiActive = false
            plain.parking = true
        end
        table.insert(snapshot.vehicles, plain)
    end

    self.refs.stations = {}
    for _, station in ipairs(FAGameAdapter.listUnloadingStations(crops, farmId)) do
        self.refs.stations[station.id] = station.ref
        local accepted = {}
        for name, free in pairs(station.accepts) do
            accepted[name] = free ~= math.huge and round(free, 0) or -1
        end
        table.insert(snapshot.stations, {
            id = station.id,
            name = station.name,
            isSellingStation = station.isSellingStation,
            acceptedCrops = accepted,
            x = round(station.x, 1), z = round(station.z, 1),
        })
    end

    if focusCrop ~= nil then
        snapshot = FAPlanner.viewForCrop(snapshot, focusCrop.name)
    end
    self.snapshot = snapshot
    return snapshot
end

FAFarmState.contains = contains

-- Context for FAFieldScanner.soilSummary / remaining (game lookups).
function FAFarmState.soilContext()
    return {
        fruitLookup = FAGameAdapter.getFruitTypeByIndex,
        groundTypes = FAGameAdapter.getGroundTypes(),
        limits = FAGameAdapter.getFieldLimits(),
    }
end

function FAFarmState.roundSoil(soil)
    local r = {}
    for k, v in pairs(soil) do
        r[k] = type(v) == "number" and round(v, 3) or v
    end
    return r
end

-- Polygons for the planner (kept out of the snapshot to keep the bridge file small).
function FAFarmState:getFieldPolygon(fieldId)
    local field = self.refs.fields[fieldId]
    return field and field.polygon or nil
end
