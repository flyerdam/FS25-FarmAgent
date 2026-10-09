-- Milestone 2 pure tests: under-pipe geometry, soil analysis, field needs, operation
-- planning, new commands, farm memory, validation of tool actions.

-- Under-pipe parking geometry -------------------------------------------------------------
local base = { pipeX = -5.0, pipeZ = 1.0, bodyHalfWidth = 1.6, headerHalfWidth = 3.0, headerZMin = 4.0,
    trailerHalfWidth = 1.25, tractorHalfWidth = 1.25, fillOffsetZ = -8 }
local function with(over)
    local p = {}
    for k, v in pairs(base) do p[k] = v end
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end

T.test("pipe pose: trailer under the pipe, nudged out to clear the header", function()
    local pose = FALogistics.computeUnderPipePose(with())
    T.eq(pose.obstacle, "header")
    T.near(pose.x, -5.25, 0.001, "lateral (same side as pipe)")
    T.near(pose.z, 9.0, 0.001, "AI node ahead of the pipe by the fill offset")
    T.near(pose.shift, 0.25, 0.001); T.near(pose.clearance, 1.0, 0.001)
end)

T.test("pipe pose: folded / moving pipe is refused", function()
    local pose, reason = FALogistics.computeUnderPipePose(with({ pipeX = 0.6 }))
    T.eq(pose, nil); T.truthy(reason:find("not unfolded"))
end)

T.test("pipe pose: pipe too short for a wide header is refused, not rammed", function()
    local pose, reason = FALogistics.computeUnderPipePose(with({ pipeX = 3.5 }))
    T.eq(pose, nil); T.truthy(reason:find("header"))
end)

T.test("pipe pose: header ahead of the tractor only needs body clearance", function()
    local pose = FALogistics.computeUnderPipePose(with({ headerZMin = 20, pipeX = 4.0 }))
    T.eq(pose.obstacle, "combine body"); T.near(pose.shift, 0, 0.001)
end)

-- Soil analysis -------------------------------------------------------------------------------
local GT = { NONE = 0, PLOWED = 1, CULTIVATED = 2, SEEDBED = 3, ROLLED_SEEDBED = 4, STUBBLE_TILLAGE = 5, GRASS = 6, GRASS_CUT = 7, SOWN = 8 }
local WHEAT = { index = 1, name = "WHEAT", title = "Wheat", minHarvest = 4, maxHarvest = 6, cutState = 10, witheredState = 8 }
local GRASS = { index = 9, name = "GRASS", title = "Grass", minHarvest = 2, maxHarvest = 4, cutState = 1 }
local CTX = {
    fruitLookup = function(i) if i == 1 then return WHEAT elseif i == 9 then return GRASS end end,
    groundTypes = GT,
    limits = { sprayMax = 2, limeMax = 3, plowMax = 1 },
}
local function result(samples)
    local r = { validCount = #samples, counts = {}, samples = samples }
    for _, s in ipairs(samples) do
        local key = s.f .. ":" .. s.gs
        r.counts[key] = (r.counts[key] or 0) + 1
    end
    return r
end
local function many(n, s)
    local list = {}
    for i = 1, n do
        local c = {}
        for k, v in pairs(s) do c[k] = v end
        list[i] = c
    end
    return list
end
local function concat(a, b)
    local r = {}
    for _, v in ipairs(a) do table.insert(r, v) end
    for _, v in ipairs(b) do table.insert(r, v) end
    return r
end

T.test("soil: harvested wheat needing a plow and lime", function()
    local s = FAFieldScanner.soilSummary(result(many(10, { f = 1, gs = 10, gt = GT.SOWN, sp = 0, li = 0, pl = 0 })), CTX)
    T.near(s.stubble, 1, 0.001); T.near(s.plowNeeded, 1, 0.001); T.near(s.limeNeeded, 1, 0.001)
    local needs = FABrain.fieldNeeds({ soil = s })
    T.truthy(needs.PLOW ~= nil and needs.CULTIVATE == nil, "plow counter at 0 -> plow")
    T.truthy(needs.LIME ~= nil)
end)

T.test("soil: cultivated empty field is ready to sow, growing crop needs fertilizer", function()
    local prepared = FAFieldScanner.soilSummary(result(many(10, { f = 0, gs = 0, gt = GT.CULTIVATED, sp = 0, li = 2, pl = 1 })), CTX)
    T.near(prepared.prepared, 1, 0.001)
    local needs = FABrain.fieldNeeds({ soil = prepared })
    T.truthy(needs.SEED ~= nil and needs.CULTIVATE == nil and needs.LIME == nil)

    local growing = FAFieldScanner.soilSummary(result(many(10, { f = 1, gs = 2, gt = GT.SOWN, sp = 1, li = 2, pl = 1 })), CTX)
    T.eq(growing.growingCrop, "WHEAT"); T.eq(growing.sprayMode, 1)
    T.truthy(FABrain.fieldNeeds({ soil = growing }).FERTILIZE ~= nil)
    local topped = FAFieldScanner.soilSummary(result(many(10, { f = 1, gs = 2, gt = GT.SOWN, sp = 2, li = 2, pl = 1 })), CTX)
    T.eq(FABrain.fieldNeeds({ soil = topped }).FERTILIZE, nil, "already at max fertilizer")
end)

T.test("soil: grassland is never tilled", function()
    local s = FAFieldScanner.soilSummary(result(many(10, { f = 9, gs = 1, gt = GT.GRASS, sp = 0, li = 0, pl = 0 })), CTX)
    T.near(s.grass, 1, 0.001)
    T.eq(next(FABrain.fieldNeeds({ soil = s })), nil)
end)

T.test("remaining work per operation is measured from the samples", function()
    local half = result(concat(many(5, { f = 1, gs = 10, gt = GT.SOWN, sp = 0, li = 0, pl = 0 }),
        many(5, { f = 0, gs = 0, gt = GT.CULTIVATED, sp = 0, li = 0, pl = 0 })))
    T.near(FAFieldScanner.remaining("CULTIVATE", half, CTX), 0.5, 0.001)
    T.near(FAFieldScanner.remaining("PLOW", half, CTX), 1.0, 0.001, "cultivated is not plowed")
    T.near(FAFieldScanner.remaining("SEED", half, CTX, { crop = WHEAT }), 1.0, 0.001)
    T.near(FAFieldScanner.remaining("LIME", half, CTX), 1.0, 0.001)
    local sown = result(many(10, { f = 1, gs = 1, gt = GT.SOWN, sp = 0, li = 3, pl = 1 }))
    T.near(FAFieldScanner.remaining("SEED", sown, CTX, { crop = WHEAT }), 0, 0.001)
    T.near(FAFieldScanner.remaining("LIME", sown, CTX), 0, 0.001)
    local fert = result(concat(many(6, { f = 1, gs = 2, gt = GT.SOWN, sp = 1, li = 3, pl = 1 }),
        many(4, { f = 1, gs = 2, gt = GT.SOWN, sp = 0, li = 3, pl = 1 })))
    T.near(FAFieldScanner.remaining("FERTILIZE", fert, CTX, { startSprayLevel = 0 }), 0.4, 0.001)
end)

-- Operation planning --------------------------------------------------------------------------------
local function farm()
    return {
        crops = { { name = "WHEAT", title = "Wheat" }, { name = "BARLEY", title = "Barley" } },
        plantable = { WHEAT = true },
        helpers = { buySeeds = true, buyFertilizer = true },
        fields = {
            { id = 1, name = "1", areaHa = 4, labelX = 0, labelZ = 0, readyByCrop = {}, lastCrop = "WHEAT",
              soil = { valid = 10, stubble = 1, plowNeeded = 0, limeNeeded = 0, prepared = 0, growing = 0, grass = 0, lowFert = 0 } },
            { id = 2, name = "2", areaHa = 4, labelX = 500, labelZ = 0, readyByCrop = {}, lastCrop = "WHEAT",
              soil = { valid = 10, stubble = 0, plowNeeded = 0, limeNeeded = 0, prepared = 1, growing = 0, grass = 0, lowFert = 0 } },
            { id = 3, name = "3", areaHa = 4, labelX = 900, labelZ = 0, readyByCrop = {}, lastCrop = "BARLEY",
              soil = { valid = 10, stubble = 0, plowNeeded = 0, limeNeeded = 0, prepared = 1, growing = 0, grass = 0, lowFert = 0 } },
            { id = 4, name = "4", areaHa = 4, labelX = 1300, labelZ = 0, readyByCrop = {},
              soil = { valid = 10, stubble = 0, plowNeeded = 0, limeNeeded = 0, prepared = 0, growing = 1, grass = 0, lowFert = 0.8, growingCrop = "WHEAT" } },
        },
        vehicles = {
            { id = 10, name = "Tractor+Cultivator", kind = "TOOL", ops = { "CULTIVATE" }, x = 0, z = 0, canFieldWork = true,
              tools = { { kind = "CULTIVATOR", name = "Cultivator" } } },
            { id = 11, name = "Tractor+Seeder", kind = "TOOL", ops = { "SEED" }, x = 600, z = 0, canFieldWork = true,
              tools = { { kind = "SEEDER", name = "Seeder", seeds = { "WHEAT", "BARLEY" }, fillLevel = 0, capacity = 3000 } } },
            { id = 12, name = "Tractor+Sprayer", kind = "TOOL", ops = { "FERTILIZE" }, x = 1300, z = 0, canFieldWork = true,
              tools = { { kind = "SPRAYER", name = "Sprayer", fillTypes = { "LIQUIDFERTILIZER" }, fillLevel = 500, capacity = 3000 } } },
        },
        stations = {},
    }
end

T.test("plan: cultivate stubble with the cultivator rig", function()
    local plan = FABrain.planOperation("CULTIVATE", farm())
    T.eq(#plan.tasks, 1); T.eq(plan.tasks[1].action, "CULTIVATE_FIELD"); T.eq(plan.tasks[1].fieldId, 1); T.eq(plan.tasks[1].vehicleId, 10)
    T.eq(plan.tasks[1].id, "C1")
end)

T.test("plan: replant uses the remembered crop and checks the season", function()
    local plan = FABrain.planOperation("SEED", farm(), { crop = "REPLANT" })
    local byField = {}
    for _, t in ipairs(plan.tasks) do byField[t.fieldId] = t end
    T.eq(byField[2].crop, "WHEAT"); T.eq(byField[2].vehicleId, 11)
    -- Barley (field 3's last crop) is out of season: the farm's main crop that can be
    -- sown now is planted instead, and the decision says why.
    T.eq(byField[3].crop, "WHEAT", "out-of-season barley replaced by an in-season crop")
    local why = false
    for _, d in ipairs(plan.decisions) do
        if d:find("BARLEY cannot be sown now") then why = true end
    end
    T.truthy(why)
end)

T.test("plan: empty seeder without 'helper buys seeds' is not used", function()
    local snap = farm()
    snap.helpers.buySeeds = false
    local plan = FABrain.planOperation("SEED", snap, { crop = "WHEAT" })
    T.eq(plan.tasks[1].vehicleId, nil, "queued, not assigned")
    T.truthy(plan.warnings[1]:find("no seeds"))
end)

T.test("plan: all farm work, one job per field, unique ids", function()
    local plan = FABrain.planFarmWork(farm(), { seedCrop = "REPLANT" })
    local byField, ids = {}, {}
    for _, t in ipairs(plan.tasks) do
        if t.fieldId then
            T.eq(byField[t.fieldId], nil, "one job per field " .. t.fieldId)
            byField[t.fieldId] = t.action
        end
        T.eq(ids[t.id], nil, "unique id " .. t.id)
        ids[t.id] = true
    end
    T.eq(byField[1], "CULTIVATE_FIELD"); T.eq(byField[2], "SEED_FIELD"); T.eq(byField[4], "FERTILIZE_FIELD")
    T.eq(plan.tasks[#plan.tasks].action, "REPORT")
end)

T.test("plan: autopilot without planting leaves prepared fields alone", function()
    local tasks = FABrain.autopilotStep(farm(), {}, {}, FAPlanner.newIdGenerator(1),
        { harvest = true, ops = { CULTIVATE = true, FERTILIZE = true }, seedCrop = nil })
    for _, t in ipairs(tasks) do
        T.truthy(t.action ~= "SEED_FIELD", "no seeding")
        T.truthy(t.vehicleId ~= nil, "autopilot never queues")
    end
    T.eq(#tasks, 2)
end)

local function plowRig()
    return { id = 13, name = "Tractor+Plow", kind = "TOOL", ops = { "PLOW" }, x = 0, z = 50, canFieldWork = true,
        tools = { { kind = "PLOW", name = "Plow" } } }
end

local function actionsByField(tasks)
    local byField = {}
    for _, t in ipairs(tasks) do
        if t.fieldId then byField[t.fieldId] = t.action end
    end
    return byField
end

T.test("plan: plowing due but no plow rig free -> cultivate instead", function()
    local snap = farm()
    snap.fields[1].soil.plowNeeded = 1
    local byField = actionsByField(FABrain.planFarmWork(snap, { seedCrop = "REPLANT" }).tasks)
    T.eq(byField[1], "CULTIVATE_FIELD", "no plow on the farm")

    snap = farm()
    snap.fields[1].soil.plowNeeded = 1
    table.insert(snap.vehicles, plowRig())
    byField = actionsByField(FABrain.planFarmWork(snap, { seedCrop = "REPLANT" }).tasks)
    T.eq(byField[1], "PLOW_FIELD", "free plow rig is used")

    -- Plow rig busy (autopilot exclusion) -> cultivate.
    byField = actionsByField(FABrain.autopilotStep(snap, { [13] = true }, {}, FAPlanner.newIdGenerator(1),
        { harvest = true, ops = { PLOW = true, CULTIVATE = true, SEED = true }, seedCrop = "REPLANT" }))
    T.eq(byField[1], "CULTIVATE_FIELD", "busy plow rig")

    -- Plowing switched off -> cultivate even though a plow rig is free.
    byField = actionsByField(FABrain.planFarmWork(snap, { seedCrop = "REPLANT", ops = { CULTIVATE = true, SEED = true } }).tasks)
    T.eq(byField[1], "CULTIVATE_FIELD", "plowing not wanted")
end)

T.test("plan: fertilizing and liming can be skipped", function()
    local snap = farm()
    snap.fields[1].soil.limeNeeded = 1
    table.insert(snap.vehicles, { id = 14, name = "Tractor+Spreader", kind = "TOOL", ops = { "LIME" }, x = 0, z = 20, canFieldWork = true,
        tools = { { kind = "SPRAYER", name = "Lime spreader", fillTypes = { "LIME" }, fillLevel = 500, capacity = 3000 } } })
    local byField = actionsByField(FABrain.planFarmWork(snap, { seedCrop = "REPLANT" }).tasks)
    T.eq(byField[1], "LIME_FIELD"); T.eq(byField[4], "FERTILIZE_FIELD")

    local settings = { harvest = true, ops = { PLOW = true, CULTIVATE = true, SEED = true, FERTILIZE = false, LIME = false }, seedCrop = "REPLANT" }
    byField = actionsByField(FABrain.autopilotStep(snap, {}, {}, FAPlanner.newIdGenerator(1), settings))
    T.eq(byField[1], "CULTIVATE_FIELD", "lime skipped: the stubble is cultivated")
    T.eq(byField[4], nil, "fertilizing skipped")
    T.eq(byField[2], "SEED_FIELD")
end)

T.test("autopilot: fields are worked independently, not in order", function()
    -- Field 1 is busy (being harvested / worked); field 2 is ready for planting now.
    local tasks = FABrain.autopilotStep(farm(), { [10] = true }, { [1] = true }, FAPlanner.newIdGenerator(1),
        { harvest = true, ops = { CULTIVATE = true, SEED = true, FERTILIZE = true }, seedCrop = "REPLANT" })
    local byField = actionsByField(tasks)
    T.eq(byField[1], nil, "busy field left alone")
    T.eq(byField[2], "SEED_FIELD", "planting starts while field 1 is busy")
    T.eq(byField[4], "FERTILIZE_FIELD")
end)

T.test("plan: unknown last crop -> the farm's main crop that can be sown now", function()
    local snap = farm()
    snap.fields[3].lastCrop = nil
    local crop, why = FABrain.chooseSeedCrop(snap.fields[3], "REPLANT", snap, { snap.vehicles[2] })
    T.eq(crop, "WHEAT"); T.truthy(why:find("main crop"))
    snap.plantable = {}
    crop = FABrain.chooseSeedCrop(snap.fields[3], "REPLANT", snap, { snap.vehicles[2] })
    T.eq(crop, nil, "nothing in season")
end)

-- Validation of tool actions ------------------------------------------------------------------------
T.test("validator: tool actions need the right rig, crop and season", function()
    local ctx = { snapshot = farm(), reservedBy = {} }
    T.eq(FAValidator.validate({ action = "CULTIVATE_FIELD", fieldId = 1, vehicleId = 10 }, ctx), true)
    local ok, reason = FAValidator.validate({ action = "CULTIVATE_FIELD", fieldId = 1, vehicleId = 11 }, ctx)
    T.eq(ok, false); T.truthy(reason:find("cultivate"))
    ok, reason = FAValidator.validate({ action = "SEED_FIELD", fieldId = 3, vehicleId = 11, crop = "BARLEY" }, ctx)
    T.eq(ok, false); T.truthy(reason:find("period"))
    ok = FAValidator.validate({ action = "SEED_FIELD", fieldId = 2, vehicleId = 11, crop = "WHEAT" }, ctx)
    T.eq(ok, true)
end)

-- Commands ---------------------------------------------------------------------------------------------
T.test("intent: field work commands", function()
    local crops = { { name = "WHEAT", title = "Wheat" }, { name = "BARLEY", title = "Barley" } }
    T.eq(FAIntent.parse("prepare the fields", crops).op, "PREPARE")
    local o = FAIntent.parse("plant barley on field 3", crops)
    T.eq(o.op, "SEED"); T.eq(o.crop, "BARLEY"); T.eq(o.fieldIds[1], 3)
    T.eq(FAIntent.parse("plant", crops).crop, "REPLANT")
    T.eq(FAIntent.parse("fertilize everything growing", crops).op, "FERTILIZE")
    T.eq(FAIntent.parse("spread lime", crops).op, "LIME")
    T.eq(FAIntent.parse("plow field 4", crops).op, "PLOW")
    T.eq(FAIntent.parse("cultivate", crops).op, "CULTIVATE")
    T.eq(FAIntent.parse("do all field work", crops).type, "FARM_WORK")
    T.eq(FAIntent.parse("harvest everything", crops).allCrops, true)
end)

-- Farm memory ------------------------------------------------------------------------------------------
T.test("memory: pipe offsets and last crops survive a save/load", function()
    local stored = nil
    local write = function(path, content) stored = content end
    local read = function(path)
        return stored and stored:match("<payload>(.-)</payload>"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
    end
    local m = FAMemory.new("mem.xml", read, write)
    m:setPipeOffset("combine-1", -5.2, 1.1)
    m:recordHarvest(12, "WHEAT")
    m:save()
    T.truthy(stored ~= nil)
    local m2 = FAMemory.new("mem.xml", read, write)
    T.eq(m2:load(), true)
    local x, z = m2:getPipeOffset("combine-1")
    T.near(x, -5.2, 0.001); T.near(z, 1.1, 0.001)
    T.eq(m2:getLastCrop(12), "WHEAT")
end)
