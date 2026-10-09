-- FAFieldScanner: measures crop state over a whole field by sampling FieldState at
-- many points inside the field polygon.
--
-- Why sampling: FS25 exposes crop state per position (FieldState:update(x, z)); there is
-- no public "percent harvested" API for player-owned fields (the mission completion
-- helpers only exist for contract missions). Sampling gives Farm Agent an independent
-- progress measurement, so it can verify that a worker really finished a field.

FAFieldScanner = {}
local FAFieldScanner_mt = { __index = FAFieldScanner }

FAFieldScanner.TARGET_SAMPLES = 80
FAFieldScanner.MIN_SPACING = 4

-- sampleFn(x, z) -> isValid, fruitTypeIndex, growthState. Defaults to the game adapter.
function FAFieldScanner.new(sampleFn, clockFn)
    local self = setmetatable({}, FAFieldScanner_mt)
    self.sampleFn = sampleFn or FAGameAdapter.sampleFieldPoint
    self.clockFn = clockFn or function() return g_time or 0 end
    self.fields = {}
    self.samplePoints = {}
    self.results = {}
    self.queue = {}
    self.queued = {}
    return self
end

function FAFieldScanner:setFields(fieldRecords)
    self.fields = {}
    for _, field in ipairs(fieldRecords) do
        self.fields[field.id] = field
    end
end

function FAFieldScanner:getSamplePoints(field)
    local points = self.samplePoints[field.id]
    if points == nil then
        points = FAGeometry.samplePolygon(field.polygon, FAFieldScanner.TARGET_SAMPLES, FAFieldScanner.MIN_SPACING)
        if #points == 0 and field.labelX ~= nil then
            points = { { x = field.labelX, z = field.labelZ } }
        end
        self.samplePoints[field.id] = points
    end
    return points
end

local function isEmptyFruit(fruitTypeIndex)
    local unknown = (FruitType ~= nil and FruitType.UNKNOWN) or 0
    return fruitTypeIndex == nil or fruitTypeIndex == 0 or fruitTypeIndex == unknown
end

-- Scans immediately. Result keeps counts per "fruitIndex:growthState" (crop readiness)
-- and every sample's soil values (ground type, fertilizer/lime/plow levels) for the
-- field-work operations. sampleFn returns:
--   isValid, fruitTypeIndex, growthState, groundType, sprayLevel, limeLevel, plowLevel
function FAFieldScanner:scanNow(fieldId)
    local field = self.fields[fieldId]
    if field == nil then
        return nil
    end
    local counts = {}
    local samples = {}
    local validCount = 0
    for _, p in ipairs(self:getSamplePoints(field)) do
        local isValid, fruitTypeIndex, growthState, groundType, sprayLevel, limeLevel, plowLevel = self.sampleFn(p.x, p.z)
        if isValid then
            validCount = validCount + 1
            if isEmptyFruit(fruitTypeIndex) then
                fruitTypeIndex, growthState = 0, 0
            end
            local key = fruitTypeIndex .. ":" .. (growthState or 0)
            counts[key] = (counts[key] or 0) + 1
            table.insert(samples, { f = fruitTypeIndex, gs = growthState or 0, gt = groundType or 0,
                sp = sprayLevel or 0, li = limeLevel or 0, pl = plowLevel or 0 })
        end
    end
    local result = { fieldId = fieldId, time = self.clockFn(), validCount = validCount, counts = counts, samples = samples }
    self.results[fieldId] = result
    self.queued[fieldId] = nil
    return result
end

function FAFieldScanner:request(fieldId)
    if self.fields[fieldId] ~= nil and not self.queued[fieldId] then
        self.queued[fieldId] = true
        table.insert(self.queue, fieldId)
    end
end

function FAFieldScanner:requestAll()
    for id, _ in pairs(self.fields) do
        self:request(id)
    end
end

function FAFieldScanner:isIdle()
    return #self.queue == 0
end

-- Spreads scanning over frames: at most maxFields per call.
function FAFieldScanner:update(maxFields)
    local n = 0
    while #self.queue > 0 and n < (maxFields or 2) do
        local fieldId = table.remove(self.queue, 1)
        if self.queued[fieldId] then
            self:scanNow(fieldId)
        end
        n = n + 1
    end
end

function FAFieldScanner:getResult(fieldId)
    return self.results[fieldId]
end

-- Fraction (0..1) of valid samples that hold 'crop' at a harvestable growth state.
function FAFieldScanner.getReadyFraction(result, crop)
    if result == nil or result.validCount == 0 or crop == nil then
        return 0
    end
    local ready = 0
    for key, count in pairs(result.counts) do
        local fruit, gs = key:match("^(%d+):(%d+)$")
        fruit, gs = tonumber(fruit), tonumber(gs)
        if fruit == crop.index and gs >= crop.minHarvest and gs <= crop.maxHarvest then
            ready = ready + count
        end
    end
    return ready / result.validCount
end

-- Dominant crop and its state: READY_TO_HARVEST, GROWING, HARVESTED, WITHERED, EMPTY, OTHER.
-- fruitLookup(index) -> crop description (FAGameAdapter.getFruitTypeByIndex in game).
function FAFieldScanner.classify(result, fruitLookup)
    if result == nil or result.validCount == 0 then
        return { cropName = nil, state = "UNKNOWN", fraction = 0 }
    end
    local perFruit = {}
    for key, count in pairs(result.counts) do
        local fruit = tonumber(key:match("^(%d+):"))
        perFruit[fruit] = (perFruit[fruit] or 0) + count
    end
    local dominant, dominantCount = nil, -1
    for fruit, count in pairs(perFruit) do
        if count > dominantCount then
            dominant, dominantCount = fruit, count
        end
    end
    if dominant == 0 then
        return { cropName = nil, state = "EMPTY", fraction = dominantCount / result.validCount }
    end
    local crop = fruitLookup(dominant)
    if crop == nil then
        return { cropName = "fruit#" .. tostring(dominant), state = "OTHER", fraction = dominantCount / result.validCount }
    end

    -- Most common growth state of the dominant crop.
    local modeGs, modeCount = 0, -1
    for key, count in pairs(result.counts) do
        local fruit, gs = key:match("^(%d+):(%d+)$")
        if tonumber(fruit) == dominant and count > modeCount then
            modeGs, modeCount = tonumber(gs), count
        end
    end
    local state = "OTHER"
    if modeGs >= crop.minHarvest and modeGs <= crop.maxHarvest then
        state = "READY_TO_HARVEST"
    elseif crop.witheredState ~= nil and modeGs == crop.witheredState then
        state = "WITHERED"
    elseif crop.cutState ~= nil and modeGs == crop.cutState then
        state = "HARVESTED"
    elseif modeGs > 0 and modeGs < crop.minHarvest then
        state = "GROWING"
    end
    return {
        cropName = crop.name,
        cropTitle = crop.title,
        state = state,
        growthState = modeGs,
        fraction = dominantCount / result.validCount,
        readyFraction = FAFieldScanner.getReadyFraction(result, crop),
    }
end

-- Soil / field-work analysis ------------------------------------------------------
--
-- ctx = {
--   fruitLookup = function(fruitIndex) -> crop description (name, minHarvest, maxHarvest, cutState, witheredState)
--   groundTypes = { PLOWED=, CULTIVATED=, SEEDBED=, ROLLED_SEEDBED=, STUBBLE_TILLAGE=, GRASS=, GRASS_CUT= } (FieldGroundType values)
--   limits      = { sprayMax=, limeMax=, plowMax= }  (0 = counter disabled in this game)
-- }

local function isGrassCrop(crop)
    local name = crop and crop.name or ""
    return name == "GRASS" or name == "MEADOW" or name:find("^MEADOW") ~= nil or name == "ALFALFA" or name == "CLOVER"
end

local function isPreparedGround(gt, groundTypes)
    return gt ~= 0 and (gt == groundTypes.CULTIVATED or gt == groundTypes.SEEDBED or gt == groundTypes.ROLLED_SEEDBED
        or gt == groundTypes.PLOWED or gt == groundTypes.STUBBLE_TILLAGE)
end

-- READY, GROWING, STUBBLE (needs tillage), PREPARED (ready to sow), GRASS (never tilled automatically), OTHER
function FAFieldScanner.classifySample(s, ctx)
    local groundTypes = ctx.groundTypes or {}
    if s.gt ~= 0 and (s.gt == groundTypes.GRASS or s.gt == groundTypes.GRASS_CUT) then
        return "GRASS"
    end
    if s.f ~= 0 then
        local crop = ctx.fruitLookup(s.f)
        if crop == nil then
            return "OTHER"
        end
        if isGrassCrop(crop) then
            return "GRASS"
        end
        if s.gs >= crop.minHarvest and s.gs <= crop.maxHarvest then
            return "READY"
        end
        if s.gs == crop.cutState or (crop.witheredState ~= nil and s.gs == crop.witheredState) then
            return "STUBBLE"
        end
        if s.gs > 0 and s.gs < crop.minHarvest then
            return "GROWING"
        end
        return "OTHER"
    end
    if isPreparedGround(s.gt, groundTypes) then
        return "PREPARED"
    end
    return "STUBBLE"
end

-- Field summary used by the brain to decide what a field needs.
function FAFieldScanner.soilSummary(result, ctx)
    local summary = { valid = 0, ready = 0, growing = 0, stubble = 0, prepared = 0, grass = 0,
        lowFert = 0, limeNeeded = 0, plowNeeded = 0, plowed = 0 }
    if result == nil or result.samples == nil or #result.samples == 0 then
        return summary
    end
    local limits = ctx.limits or {}
    local groundTypes = ctx.groundTypes or {}
    local n = #result.samples
    local growingCrops, sprayLevels = {}, {}
    for _, s in ipairs(result.samples) do
        local class = FAFieldScanner.classifySample(s, ctx)
        if class == "READY" then summary.ready = summary.ready + 1
        elseif class == "GROWING" then
            summary.growing = summary.growing + 1
            growingCrops[s.f] = (growingCrops[s.f] or 0) + 1
            sprayLevels[s.sp] = (sprayLevels[s.sp] or 0) + 1
            if (limits.sprayMax or 0) > 0 and s.sp < limits.sprayMax then
                summary.lowFert = summary.lowFert + 1
            end
        elseif class == "STUBBLE" then summary.stubble = summary.stubble + 1
        elseif class == "PREPARED" then summary.prepared = summary.prepared + 1
        elseif class == "GRASS" then summary.grass = summary.grass + 1
        end
        if class ~= "GRASS" then
            if (limits.limeMax or 0) > 0 and s.li == 0 then summary.limeNeeded = summary.limeNeeded + 1 end
            if (limits.plowMax or 0) > 0 and s.pl == 0 then summary.plowNeeded = summary.plowNeeded + 1 end
        end
        if s.gt ~= 0 and s.gt == groundTypes.PLOWED then summary.plowed = summary.plowed + 1 end
    end
    for _, key in ipairs({ "ready", "growing", "stubble", "prepared", "grass", "lowFert", "limeNeeded", "plowNeeded", "plowed" }) do
        summary[key] = summary[key] / n
    end
    summary.valid = n
    local best, bestCount = nil, 0
    for f, count in pairs(growingCrops) do
        if count > bestCount then best, bestCount = f, count end
    end
    if best ~= nil then
        local crop = ctx.fruitLookup(best)
        summary.growingCrop = crop and crop.name or nil
    end
    local mode, modeCount = 0, -1
    for level, count in pairs(sprayLevels) do
        if count > modeCount then mode, modeCount = level, count end
    end
    summary.sprayMode = mode
    return summary
end

-- Fraction (0..1) of the field where operation 'op' still has to be done.
-- extra = { crop = crop description (HARVEST/SEED), startSprayLevel = n (FERTILIZE) }
function FAFieldScanner.remaining(op, result, ctx, extra)
    extra = extra or {}
    if op == "HARVEST" then
        return FAFieldScanner.getReadyFraction(result, extra.crop)
    end
    if result == nil or result.samples == nil or #result.samples == 0 then
        return 1
    end
    local limits = ctx.limits or {}
    local groundTypes = ctx.groundTypes or {}
    local todo, total = 0, 0
    for _, s in ipairs(result.samples) do
        local class = FAFieldScanner.classifySample(s, ctx)
        if class ~= "GRASS" then
            if op == "CULTIVATE" then
                total = total + 1
                if class == "STUBBLE" then todo = todo + 1 end
            elseif op == "PLOW" then
                if class ~= "GROWING" and class ~= "READY" then
                    total = total + 1
                    if s.gt ~= groundTypes.PLOWED then todo = todo + 1 end
                end
            elseif op == "SEED" then
                total = total + 1
                local crop = extra.crop
                -- Sown = the crop is actually in the ground and alive (cut stubble is not).
                local sown = crop ~= nil and s.f == crop.index and (class == "GROWING" or class == "READY")
                if not sown then todo = todo + 1 end
            elseif op == "FERTILIZE" then
                if class == "GROWING" then
                    total = total + 1
                    if s.sp <= (extra.startSprayLevel or 0) and s.sp < (limits.sprayMax or 0) then todo = todo + 1 end
                end
            elseif op == "LIME" then
                total = total + 1
                if (limits.limeMax or 0) > 0 and s.li == 0 then todo = todo + 1 end
            end
        end
    end
    if total == 0 then
        return 0
    end
    return todo / total
end
