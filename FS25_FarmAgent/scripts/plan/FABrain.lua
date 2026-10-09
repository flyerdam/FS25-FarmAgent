-- FABrain: Farm Agent's built-in decision maker. Deterministic scoring rules, no model,
-- no network: every decision is a plain function of the farm snapshot and is written to
-- the decision log with its reason.
--
--   rankReadyCrops   which crops are worth harvesting, best first
--   planAllCrops     "harvest all crops": one plan across crops, machines never double-booked
--   autopilotStep    "take care of the farm": new work for idle machines only
--   shouldAutoResume hand a worker the player stopped back once the player has left it
--
-- Pure Lua; the game is reached only through the snapshot (FAFarmState) and the task
-- manager, which still validates and supervises everything the brain proposes.

FABrain = {}

FABrain.AUTO_RESUME_MS = 60000     -- player must have left the vehicle this long
FABrain.URGENT_SCORE = 100         -- an about-to-wither field outranks ~100 ha of normal crop

local function copySet(t)
    local c = {}
    for k, v in pairs(t or {}) do c[k] = v end
    return c
end

-- Ready crops on the farm, best first: score = sum(area_ha * readyFraction) + urgency.
-- Returns { {name=, title=, score=, fields=n}, ... }.
function FABrain.rankReadyCrops(snapshot, excludeFields)
    excludeFields = excludeFields or {}
    local byName = {}
    for _, f in ipairs(snapshot.fields or {}) do
        if not excludeFields[f.id] then
            for name, fraction in pairs(f.readyByCrop or {}) do
                if fraction >= FAPlanner.MIN_READY_FRACTION then
                    local entry = byName[name]
                    if entry == nil then
                        entry = { name = name, title = name, score = 0, fields = 0 }
                        byName[name] = entry
                    end
                    entry.fields = entry.fields + 1
                    entry.score = entry.score + (f.areaHa or 1) * fraction
                    if f.urgent and f.crop == name then
                        entry.score = entry.score + FABrain.URGENT_SCORE
                    end
                end
            end
        end
    end
    local titles = {}
    for _, c in ipairs(snapshot.crops or {}) do titles[c.name] = c.title end
    local ranked = {}
    for _, entry in pairs(byName) do
        entry.title = titles[entry.name] or entry.name
        table.insert(ranked, entry)
    end
    table.sort(ranked, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name < b.name
    end)
    return ranked
end

local function anyCompatibleCombine(view)
    for _, v in ipairs(view.vehicles or {}) do
        if FAPlanner.isCompatibleCombine(v) and not v.isBroken then
            return true
        end
    end
    return false
end

-- Plans every ready crop, best crop first. Each crop is planned on its own crop view;
-- machines used by an earlier crop are excluded for later crops.
-- opts: excludeVehicles, excludeFields, newId, noReport, noQueue (autopilot: only use
-- machines free right now), quiet.
function FABrain.planAllCrops(snapshot, opts)
    opts = opts or {}
    local newId = opts.newId or FAPlanner.newIdGenerator(1)
    local used = copySet(opts.excludeVehicles)
    local claimed = copySet(opts.excludeFields)
    local plan = {
        objective = { type = "HARVEST_READY_FIELDS", allCrops = true },
        tasks = {}, warnings = {}, decisions = {}, crops = {},
    }
    local fieldCount, combineIds = 0, {}

    for _, crop in ipairs(FABrain.rankReadyCrops(snapshot, claimed)) do
        local view = FAPlanner.viewForCrop(snapshot, crop.name)
        local sub = FAPlanner.planHarvest({ type = "HARVEST_READY_FIELDS", crop = crop.name }, view,
            { excludeVehicles = used, excludeFields = claimed, newId = newId, noReport = true, quiet = true })
        local added = 0
        for _, t in ipairs(sub.tasks) do
            table.insert(plan.tasks, t)
            if t.action == "HARVEST_FIELD" then
                claimed[t.fieldId] = true
                added = added + 1
                if t.vehicleId ~= nil then combineIds[t.vehicleId] = true end
            end
        end
        for id, _ in pairs(sub.usedVehicles or {}) do used[id] = true end

        local cropDecisions = {}
        for _, d in ipairs(sub.decisions) do table.insert(cropDecisions, d) end
        if added == 0 and not opts.noQueue and anyCompatibleCombine(view) then
            -- All capable combines are busy with a better crop: queue this crop's fields;
            -- the task manager binds them when a combine frees up (with an empty tank).
            for _, f in ipairs(view.fields) do
                if not claimed[f.id] and (f.readyFraction or 0) >= FAPlanner.MIN_READY_FRACTION then
                    table.insert(plan.tasks, { id = newId("H"), action = "HARVEST_FIELD", crop = crop.name, fieldId = f.id, deps = {} })
                    claimed[f.id] = true
                    added = added + 1
                    table.insert(cropDecisions, string.format("Field %s (%s): queued until a capable combine is free.", f.name, crop.title))
                end
            end
        end

        if added > 0 then
            table.insert(plan.crops, crop.name)
            fieldCount = fieldCount + added
            table.insert(plan.decisions, string.format("%s: %d ready field(s), priority score %.1f.", crop.title, crop.fields, crop.score))
            for _, d in ipairs(cropDecisions) do table.insert(plan.decisions, d) end
            for _, w in ipairs(sub.warnings) do table.insert(plan.warnings, w) end
        elseif not opts.quiet then
            table.insert(plan.warnings, string.format("%s is ready on %d field(s) but no available combine can harvest it.", crop.title, crop.fields))
        end
    end

    if #plan.tasks == 0 and not opts.quiet then
        table.insert(plan.warnings, "No owned field has a crop ready to harvest.")
    end

    if not opts.noReport and #plan.tasks > 0 then
        local deps = {}
        for _, t in ipairs(plan.tasks) do table.insert(deps, t.id) end
        table.insert(plan.tasks, { id = newId("R"), action = "REPORT", deps = deps })
    end

    local combineCount = 0
    for _ in pairs(combineIds) do combineCount = combineCount + 1 end
    plan.fieldCount = fieldCount
    plan.summary = string.format("Harvest %d field(s) across %d crop(s) (%s) with %d combine(s).",
        fieldCount, #plan.crops, table.concat(plan.crops, ", "), combineCount)
    return plan
end

-- Autopilot: new work for machines that are idle right now. busyVehicles / busyFields
-- come from the task manager (everything owned by non-terminal tasks).
-- settings (optional): { harvest = bool, ops = { FERTILIZE=true, ... }, seedCrop = name | "REPLANT" | nil }
function FABrain.autopilotStep(snapshot, busyVehicles, busyFields, newId, settings)
    settings = settings or { harvest = true, ops = {} }
    local plan = FABrain.planFarmWork(snapshot, {
        harvest = settings.harvest ~= false, ops = settings.ops or {}, seedCrop = settings.seedCrop,
        excludeVehicles = busyVehicles, excludeFields = busyFields, newId = newId,
        noReport = true, noQueue = true, quiet = true,
    })
    return plan.tasks, plan.decisions, plan.warnings
end

-- Hand back a worker the player stopped, once the player has left that vehicle for
-- AUTO_RESUME_MS. record = live vehicle record (nil if the vehicle is gone).
-- Returns resume(bool), and the updated "player left at" timestamp to store on the task.
function FABrain.shouldAutoResume(record, playerLeftAt, now)
    if record == nil or record.aiActive then
        return false, nil
    end
    if record.isEntered then
        return false, nil
    end
    playerLeftAt = playerLeftAt or now
    return now - playerLeftAt >= FABrain.AUTO_RESUME_MS, playerLeftAt
end

-- Field work (Milestone 2) ------------------------------------------------------------
--
-- Operations run by the vanilla FIELDWORK job with the matching tool attached:
--   CULTIVATE (cultivator), PLOW (plow), SEED (seeder), FERTILIZE (sprayer / spreader), LIME (lime spreader)

FABrain.ACTION_FOR_OP = {
    HARVEST = "HARVEST_FIELD", CULTIVATE = "CULTIVATE_FIELD", PLOW = "PLOW_FIELD",
    SEED = "SEED_FIELD", FERTILIZE = "FERTILIZE_FIELD", LIME = "LIME_FIELD",
}
FABrain.ID_PREFIX = { HARVEST = "H", CULTIVATE = "C", PLOW = "P", SEED = "S", FERTILIZE = "F", LIME = "M" }
FABrain.OP_FOR_ACTION = {}
for op, action in pairs(FABrain.ACTION_FOR_OP) do FABrain.OP_FOR_ACTION[action] = op end

FABrain.OP_TITLES = {
    HARVEST = "harvest", CULTIVATE = "cultivate", PLOW = "plow", SEED = "plant", FERTILIZE = "fertilize", LIME = "lime",
}

-- Order in which the autopilot / "do all field work" hands out work: time-critical first.
FABrain.WORK_ORDER = { "FERTILIZE", "LIME", "PLOW", "CULTIVATE", "SEED" }

local function contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

-- What a field needs, as { OP = fraction of the field }.
-- caps (optional) = { OP = true } for operations a free machine can do right now. A field
-- that should be plowed is cultivated instead when no plow rig is available (stubble
-- still gets worked; the plow counter just stays low).
function FABrain.fieldNeeds(field, caps)
    local needs = {}
    local soil = field.soil
    if soil == nil or (soil.valid or 0) == 0 or (soil.grass or 0) >= 0.5 then
        return needs
    end
    if (soil.stubble or 0) >= 0.5 then
        if (soil.plowNeeded or 0) >= 0.5 and (caps == nil or caps.PLOW) then
            needs.PLOW = soil.stubble
        else
            needs.CULTIVATE = soil.stubble
        end
    end
    if (soil.limeNeeded or 0) >= 0.5 and (soil.stubble or 0) + (soil.prepared or 0) >= 0.5 then
        needs.LIME = soil.limeNeeded
    end
    if (soil.prepared or 0) >= 0.5 then
        needs.SEED = soil.prepared
    end
    if (soil.growing or 0) >= 0.5 and (soil.lowFert or 0) >= 0.4 then
        needs.FERTILIZE = soil.lowFert
    end
    return needs
end

local function distance(ax, az, bx, bz)
    if ax == nil or bx == nil then return math.huge end
    local dx, dz = bx - ax, bz - az
    return math.sqrt(dx * dx + dz * dz)
end

local function toolSupportsCrop(v, cropName)
    for _, t in ipairs(v.tools or {}) do
        if t.kind == "SEEDER" and contains(t.seeds, cropName) then
            return true
        end
    end
    return false
end

-- Can this rig sow this crop now? Season comes from the game (getIsPlantableInPeriod with
-- the savegame's growth mode, so "seasons off" is handled there); some seeders may plant
-- outside the season (SowingMachine:getCanPlantOutsideSeason).
local function canSowNow(v, cropName, snapshot)
    if not toolSupportsCrop(v, cropName) then
        return false
    end
    if snapshot.plantable == nil or snapshot.plantable[cropName] then
        return true
    end
    for _, t in ipairs(v.tools or {}) do
        if t.kind == "SEEDER" and t.anySeason then
            return true
        end
    end
    return false
end
FABrain.canSowNow = canSowNow

-- Empty seeder/sprayer that the helper is not allowed to refill by itself.
local function suppliesMissing(v, op, helpers)
    helpers = helpers or {}
    for _, t in ipairs(v.tools or {}) do
        if (t.capacity or 0) > 0 and (t.fillLevel or 0) <= 0 then
            if t.kind == "SEEDER" and op == "SEED" and not helpers.buySeeds then
                return t.name .. " has no seeds (or enable 'helper buys seeds')"
            end
            if t.kind == "SPRAYER" and op == "FERTILIZE" and not helpers.buyFertilizer then
                return t.name .. " is empty (or enable 'helper buys fertilizer')"
            end
            if t.kind == "SPRAYER" and op == "LIME" then
                return t.name .. " has no lime - fill it first"
            end
        end
    end
    return nil
end

function FABrain.isCompatibleTool(v, op, cropName)
    if v.kind ~= "TOOL" or not v.canFieldWork or not contains(v.ops, op) then
        return false
    end
    if op == "SEED" and (cropName == nil or not toolSupportsCrop(v, cropName)) then
        return false
    end
    return true
end

FABrain.suppliesMissing = suppliesMissing

-- Free rigs for an operation (usable, not excluded, supplies OK). Warnings optional.
local function freeRigs(op, snapshot, excludeVehicles, warnings, title)
    local machines = {}
    for _, v in ipairs(snapshot.vehicles or {}) do
        if not excludeVehicles[v.id] and v.kind == "TOOL" and contains(v.ops, op) and v.canFieldWork then
            local missing = suppliesMissing(v, op, snapshot.helpers)
            if missing ~= nil then
                if warnings then table.insert(warnings, missing) end
            elseif FAPlanner.isUsable(v) then
                table.insert(machines, v)
            elseif warnings then
                table.insert(warnings, string.format("%s can %s but is busy/occupied.", v.name, title or op))
            end
        end
    end
    return machines
end

-- Operations a free machine can do right now: { HARVEST=true, PLOW=true, ... }.
function FABrain.freeCapabilities(snapshot, excludeVehicles)
    excludeVehicles = excludeVehicles or {}
    local caps = {}
    for _, op in ipairs({ "CULTIVATE", "PLOW", "SEED", "FERTILIZE", "LIME" }) do
        if #freeRigs(op, snapshot, excludeVehicles) > 0 then
            caps[op] = true
        end
    end
    return caps
end

-- Crop to sow on a field. policy = crop name, or "REPLANT": the crop last harvested there;
-- if that is unknown or cannot be sown now, the crop most grown / remembered on the farm
-- that a free seeder can sow now, else any crop a free seeder can sow now.
-- Returns cropName, reason  (nil, reason when nothing can be sown).
function FABrain.chooseSeedCrop(field, policy, snapshot, seeders)
    local function sowable(cropName)
        if #seeders == 0 then
            -- No free seeder yet (busy or empty): judge by the season alone; the task
            -- is queued and the seeder checked again when one becomes free.
            return snapshot.plantable == nil or snapshot.plantable[cropName] == true
        end
        for _, v in ipairs(seeders) do
            if canSowNow(v, cropName, snapshot) then return true end
        end
        return false
    end
    if policy ~= nil and policy ~= "REPLANT" then
        if sowable(policy) then
            return policy, "as ordered"
        end
        return nil, string.format("no free seeder can sow %s now (season or seed type)", policy)
    end
    if field.lastCrop ~= nil and sowable(field.lastCrop) then
        return field.lastCrop, "replanting the last crop"
    end
    local count = {}
    for _, f in ipairs(snapshot.fields or {}) do
        -- (not ipairs over { f.crop, f.lastCrop }: it stops at the first nil)
        if f.crop ~= nil then count[f.crop] = (count[f.crop] or 0) + 1 end
        if f.lastCrop ~= nil and f.lastCrop ~= f.crop then count[f.lastCrop] = (count[f.lastCrop] or 0) + 1 end
    end
    local best, bestCount = nil, 0
    for name, n in pairs(count) do
        if sowable(name) and (n > bestCount or (n == bestCount and best ~= nil and name < best)) then
            best, bestCount = name, n
        end
    end
    if best ~= nil then
        return best, string.format("%s; %s is the farm's main crop", field.lastCrop and (field.lastCrop .. " cannot be sown now") or "no remembered crop", best)
    end
    for _, c in ipairs(snapshot.crops or {}) do
        if sowable(c.name) then
            return c.name, "first crop a free seeder can sow now"
        end
    end
    return nil, "no free seeder can sow any crop in this period"
end

-- Plans one field operation. opts: fieldIds, crop (SEED: crop name or "REPLANT"),
-- caps (free capabilities, for the plow->cultivate fallback), excludeVehicles,
-- excludeFields, newId, noQueue, quiet, quietEmpty.
function FABrain.planOperation(op, snapshot, opts)
    opts = opts or {}
    local newId = opts.newId or FAPlanner.newIdGenerator(1)
    local excludeVehicles = opts.excludeVehicles or {}
    local excludeFields = opts.excludeFields or {}
    local plan = { tasks = {}, decisions = {}, warnings = {}, usedVehicles = {}, fieldCount = 0 }
    local title = FABrain.OP_TITLES[op] or op
    local wanted = nil
    if opts.fieldIds ~= nil then
        wanted = {}
        for _, id in ipairs(opts.fieldIds) do wanted[id] = true end
    end

    -- 1. Rigs that can do it (needed first: the seed crop depends on the free seeders).
    local machineWarnings = {}
    local machines = freeRigs(op, snapshot, excludeVehicles, machineWarnings, title)

    -- 2. Fields that need this operation (or were named explicitly).
    local fields = {}
    for _, f in ipairs(snapshot.fields or {}) do
        if not excludeFields[f.id] and (wanted == nil or wanted[f.id]) then
            local need = FABrain.fieldNeeds(f, opts.caps)[op]
            if need ~= nil or (wanted ~= nil and (f.soil == nil or (f.soil.grass or 0) < 0.5)) then
                local entry = { field = f, need = need or 1 }
                if op == "SEED" then
                    local crop, why = FABrain.chooseSeedCrop(f, opts.crop, snapshot, machines)
                    entry.crop, entry.why = crop, why
                    if crop == nil then
                        if not opts.quiet then
                            table.insert(plan.warnings, string.format("Field %s is ready to plant, but %s.", f.name, why))
                        end
                        entry = nil
                    end
                end
                if entry ~= nil then
                    table.insert(fields, entry)
                end
            end
        end
    end
    if #fields == 0 then
        if not opts.quiet and not opts.quietEmpty then
            table.insert(plan.warnings, string.format("No field needs '%s' right now.", title))
        end
        return plan
    end
    if not opts.quiet then
        for _, w in ipairs(machineWarnings) do table.insert(plan.warnings, w) end
    end
    if #machines == 0 then
        if not opts.quiet then
            table.insert(plan.warnings, string.format("No free tractor with a tool that can %s (attach one to a tractor).", title))
        end
        if opts.noQueue then
            return plan
        end
    end

    -- 3. Greedy nearest pairing; seeders must support the field's crop.
    local free = {}
    for _, v in ipairs(machines) do free[v.id] = v end
    local open = {}
    for i, e in ipairs(fields) do open[i] = e end
    while true do
        local bestI, bestV, bestD = nil, nil, math.huge
        for i, e in pairs(open) do
            for _, v in pairs(free) do
                if op ~= "SEED" or canSowNow(v, e.crop, snapshot) then
                    local d = distance(e.field.labelX, e.field.labelZ, v.x, v.z)
                    if d < bestD then bestI, bestV, bestD = i, v, d end
                end
            end
        end
        if bestI == nil then break end
        local e = open[bestI]
        open[bestI] = nil
        free[bestV.id] = nil
        plan.usedVehicles[bestV.id] = true
        local cropName = op == "SEED" and e.crop or (e.field.soil and e.field.soil.growingCrop) or nil
        table.insert(plan.tasks, { id = newId(FABrain.ID_PREFIX[op] or "W"), action = FABrain.ACTION_FOR_OP[op], op = op,
            crop = cropName, fieldId = e.field.id, vehicleId = bestV.id, deps = {} })
        local why = ""
        if op == "SEED" and e.why ~= nil then
            why = " - " .. e.why
        elseif op == "CULTIVATE" and e.field.soil and (e.field.soil.plowNeeded or 0) >= 0.5 then
            why = " - plowing is due but no plow rig is free"
        end
        table.insert(plan.decisions, string.format("Field %s: %s%s (%d%% of field, %.1f ha) -> %s (%.0f m away)%s.",
            e.field.name, title, op == "SEED" and (" " .. tostring(e.crop)) or "", math.floor(e.need * 100),
            e.field.areaHa or 0, bestV.name, bestD, why))
    end
    if not opts.noQueue then
        for _, e in pairs(open) do
            local cropName = op == "SEED" and e.crop or nil
            table.insert(plan.tasks, { id = newId(FABrain.ID_PREFIX[op] or "W"), action = FABrain.ACTION_FOR_OP[op], op = op,
                crop = cropName, fieldId = e.field.id, deps = {} })
            table.insert(plan.decisions, string.format("Field %s: '%s%s' queued until a capable tractor is free%s.", e.field.name, title,
                cropName and (" " .. cropName) or "", (op == "SEED" and e.why) and (" - " .. e.why) or ""))
        end
    end
    plan.fieldCount = #plan.tasks
    return plan
end

-- Everything the farm needs now: harvest + the requested field operations. One task per
-- field at a time (one machine per field); the rest follows on the next round.
-- opts: ops = { FERTILIZE=true, ... } (nil = all), harvest (default true), seedCrop,
-- excludeVehicles, excludeFields, newId, noQueue, noReport, quiet.
function FABrain.planFarmWork(snapshot, opts)
    opts = opts or {}
    local newId = opts.newId or FAPlanner.newIdGenerator(1)
    local used = copySet(opts.excludeVehicles)
    local claimed = copySet(opts.excludeFields)
    local plan = { objective = { type = "FARM_WORK" }, tasks = {}, decisions = {}, warnings = {} }

    if opts.harvest ~= false then
        local harvest = FABrain.planAllCrops(snapshot, { excludeVehicles = used, excludeFields = claimed, newId = newId,
            noReport = true, noQueue = opts.noQueue, quiet = opts.quiet })
        for _, t in ipairs(harvest.tasks) do
            table.insert(plan.tasks, t)
            if t.vehicleId then used[t.vehicleId] = true end
            if t.combineId then used[t.combineId] = true end
            if t.fieldId then claimed[t.fieldId] = true end
        end
        for _, d in ipairs(harvest.decisions) do table.insert(plan.decisions, d) end
        for _, w in ipairs(harvest.warnings) do table.insert(plan.warnings, w) end
    end

    -- What the free rigs can do right now decides plow vs cultivate.
    local caps = FABrain.freeCapabilities(snapshot, used)
    if opts.ops ~= nil and not opts.ops.PLOW then
        caps.PLOW = nil -- plowing not wanted: stubble that is due for plowing gets cultivated
    end
    for _, op in ipairs(FABrain.WORK_ORDER) do
        if opts.ops == nil or opts.ops[op] then
            if op ~= "SEED" or opts.seedCrop ~= nil then
                local sub = FABrain.planOperation(op, snapshot, { crop = opts.seedCrop, caps = caps, excludeVehicles = used,
                    excludeFields = claimed, newId = newId, noQueue = opts.noQueue, quiet = opts.quiet, quietEmpty = true })
                for _, t in ipairs(sub.tasks) do
                    table.insert(plan.tasks, t)
                    claimed[t.fieldId] = true
                end
                for id, _ in pairs(sub.usedVehicles) do used[id] = true end
                for _, d in ipairs(sub.decisions) do table.insert(plan.decisions, d) end
                for _, w in ipairs(sub.warnings) do table.insert(plan.warnings, w) end
            end
        end
    end

    if not opts.noReport and #plan.tasks > 0 then
        local deps = {}
        for _, t in ipairs(plan.tasks) do table.insert(deps, t.id) end
        table.insert(plan.tasks, { id = newId("R"), action = "REPORT", deps = deps })
    end
    local fieldTasks = 0
    for _, t in ipairs(plan.tasks) do
        if FABrain.OP_FOR_ACTION[t.action] ~= nil then fieldTasks = fieldTasks + 1 end
    end
    plan.summary = string.format("Farm work: %d field job(s) planned.", fieldTasks)
    return plan
end
