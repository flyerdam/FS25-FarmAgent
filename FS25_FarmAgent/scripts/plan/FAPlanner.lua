-- FAPlanner: objective + farm snapshot -> task graph. Pure function, no game API.
--
-- Plan for HARVEST_READY_FIELDS (one crop):
--
--     HARVEST_FIELD (field A, combine 1) ---+
--     HARVEST_FIELD (field B, combine 2) ---+--> REPORT
--     HARVEST_FIELD (field C, unassigned) --+      ^
--     UNLOAD_COMBINE (combine 1 <- tractor+trailer, -> station) ---+
--     UNLOAD_COMBINE (combine 2 <- ...) --------------------------+
--
-- HARVEST tasks run in parallel; a field without a free combine stays queued and is
-- bound to the first compatible combine that finishes. Each UNLOAD_COMBINE task is a
-- long-running logistics loop serving one combine until all of its fields are done.
-- Multi-crop plans are built by FABrain by calling planHarvest once per crop.

FAPlanner = {}

FAPlanner.MIN_READY_FRACTION = 0.25    -- field counts as "ready" when >= 25% of samples are harvestable
FAPlanner.URGENT_BONUS_M = 5000        -- an about-to-wither field wins against fields up to 5 km closer

local function distance(ax, az, bx, bz)
    if ax == nil or bx == nil then
        return math.huge
    end
    local dx, dz = bx - ax, bz - az
    return math.sqrt(dx * dx + dz * dz)
end

local function contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then
            return true
        end
    end
    return false
end

local function shallowCopy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- Narrows a multi-crop snapshot to one crop: fills in the single-crop shortcuts
-- field.readyFraction, combine.supportsCrop, trailer.supportsCrop, station.acceptsCrop /
-- freeCapacity that planning and validation use. Snapshots that already carry the
-- shortcuts (no per-crop lists) pass through unchanged.
function FAPlanner.viewForCrop(snapshot, cropName)
    local view = shallowCopy(snapshot)
    view.crop = { name = cropName, title = cropName }
    for _, c in ipairs(snapshot.crops or {}) do
        if c.name == cropName then
            view.crop.title = c.title
        end
    end
    view.fields = {}
    for _, f in ipairs(snapshot.fields or {}) do
        local nf = shallowCopy(f)
        if f.readyByCrop ~= nil then
            nf.readyFraction = f.readyByCrop[cropName] or 0
            nf.urgent = f.urgent and f.crop == cropName
        end
        table.insert(view.fields, nf)
    end
    view.vehicles = {}
    for _, v in ipairs(snapshot.vehicles or {}) do
        local nv = shallowCopy(v)
        if v.combine ~= nil and v.combine.supportedCrops ~= nil then
            nv.combine = shallowCopy(v.combine)
            nv.combine.supportsCrop = contains(v.combine.supportedCrops, cropName)
            -- Grain of another crop still in the tank: unusable for this crop until emptied.
            nv.combine.holdsOtherCrop = (v.combine.fillLevel or 0) > 1 and v.combine.fillCrop ~= nil and v.combine.fillCrop ~= cropName
        end
        if v.trailers ~= nil then
            nv.trailers = {}
            for _, t in ipairs(v.trailers) do
                local nt = shallowCopy(t)
                if t.supportedCrops ~= nil then
                    nt.supportsCrop = contains(t.supportedCrops, cropName)
                end
                table.insert(nv.trailers, nt)
            end
        end
        table.insert(view.vehicles, nv)
    end
    view.stations = {}
    for _, s in ipairs(snapshot.stations or {}) do
        local ns = shallowCopy(s)
        if s.acceptedCrops ~= nil then
            local free = s.acceptedCrops[cropName]
            ns.acceptsCrop = free ~= nil
            ns.freeCapacity = free or 0
        end
        table.insert(view.stations, ns)
    end
    return view
end

-- Player in the cab of a parked vehicle is fine (vanilla lets you hire the helper from
-- the cab); a player actually driving it is not.
function FAPlanner.isPlayerDriving(v)
    return v.isEntered == true and not v.aiActive and (v.speedKmh or 0) > 1
end

function FAPlanner.isUsable(v)
    return not v.isBroken and not v.aiActive and not FAPlanner.isPlayerDriving(v)
        and not (v.combine ~= nil and v.combine.holdsOtherCrop)
end

-- Classification helpers (on a crop view), also used by the validator.
function FAPlanner.isCompatibleCombine(v)
    return v.kind == "COMBINE" and v.combine ~= nil and v.combine.supportsCrop == true and v.canFieldWork == true
end

function FAPlanner.isCompatibleTransport(v)
    if v.kind ~= "TRANSPORT" or not v.canGoTo or not v.canDeliver or v.trailers == nil then
        return false
    end
    for _, t in ipairs(v.trailers) do
        if t.supportsCrop then
            return true
        end
    end
    return false
end

-- Picks the delivery station: storage the farm owns first (player preference in
-- Milestone 1 = store, not sell), then selling stations, nearest to the fields.
function FAPlanner.chooseStation(stations, refX, refZ)
    local best, bestScore = nil, math.huge
    for _, s in ipairs(stations) do
        if s.acceptsCrop and (s.freeCapacity == -1 or s.freeCapacity > 0) then
            local score = distance(refX, refZ, s.x, s.z)
            if score == math.huge then
                score = 1e9 -- position unknown: still usable, ranked last
            end
            if s.isSellingStation then
                score = score + 100000
            end
            if best == nil or score < bestScore then
                best, bestScore = s, score
            end
        end
    end
    return best
end

-- Default task id generator: H1, L2, R3 ...
function FAPlanner.newIdGenerator(start)
    local n = (start or 1) - 1
    return function(prefix)
        n = n + 1
        return string.format("%s%d", prefix, n)
    end
end

-- objective: { type="HARVEST_READY_FIELDS", crop="WHEAT", fieldIds=nil|{...} }
-- snapshot:  crop view (FAPlanner.viewForCrop) or a Milestone-1 single-crop snapshot.
-- opts (all optional):
--   excludeVehicles = { [id]=true }  machines already used by another crop / task
--   excludeFields   = { [id]=true }  fields already being worked
--   newId           = id generator shared across crops
--   noReport        = true -> no REPORT task (autopilot, multi-crop merge)
--   quiet           = true -> do not warn about busy machines (autopilot runs every minute)
-- Returns plan = { objective, tasks, warnings, decisions, summary, usedVehicles }.
function FAPlanner.planHarvest(objective, snapshot, opts)
    opts = opts or {}
    local excludeVehicles = opts.excludeVehicles or {}
    local excludeFields = opts.excludeFields or {}
    local newId = opts.newId or FAPlanner.newIdGenerator(1)
    local plan = { objective = objective, tasks = {}, warnings = {}, decisions = {}, usedVehicles = {} }
    local cropName = objective.crop
    local cropTitle = (snapshot.crop and snapshot.crop.title) or cropName or "crop"

    local wanted = nil
    if objective.fieldIds ~= nil then
        wanted = {}
        for _, id in ipairs(objective.fieldIds) do
            wanted[id] = true
        end
    end

    -- 1. Ready fields
    local fields = {}
    for _, f in ipairs(snapshot.fields) do
        if (wanted == nil or wanted[f.id]) and not excludeFields[f.id] then
            if f.readyFraction ~= nil and f.readyFraction >= FAPlanner.MIN_READY_FRACTION then
                table.insert(fields, f)
            elseif wanted ~= nil then
                table.insert(plan.warnings, string.format("Field %s is not ready for %s harvest (%d%% ready, state %s).",
                    f.name, cropTitle, math.floor((f.readyFraction or 0) * 100), tostring(f.state)))
            end
        end
    end
    if wanted ~= nil then
        for id, _ in pairs(wanted) do
            local found = false
            for _, f in ipairs(snapshot.fields) do
                if f.id == id then found = true end
            end
            if not found then
                table.insert(plan.warnings, string.format("Field %d is not owned by your farm.", id))
            end
        end
    end
    if #fields == 0 then
        if not opts.quiet then
            table.insert(plan.warnings, string.format("No owned field has %s ready to harvest.", cropTitle))
        end
        plan.summary = "Nothing to do."
        return plan
    end

    -- 2. Machines
    local combines, transports = {}, {}
    for _, v in ipairs(snapshot.vehicles) do
        if not excludeVehicles[v.id] then
            if v.kind == "COMBINE" then
                if FAPlanner.isCompatibleCombine(v) then
                    if FAPlanner.isUsable(v) then
                        table.insert(combines, v)
                    elseif not opts.quiet then
                        table.insert(plan.warnings, string.format("%s is compatible but busy/occupied/broken.", v.name))
                    end
                elseif v.combine ~= nil and not v.combine.hasCutter and not opts.quiet then
                    table.insert(plan.warnings, string.format("%s has no header attached.", v.name))
                end
            elseif FAPlanner.isCompatibleTransport(v) and FAPlanner.isUsable(v) then
                table.insert(transports, v)
            end
        end
    end
    if #combines == 0 then
        if not opts.quiet then
            table.insert(plan.warnings, string.format("No available combine with a %s-capable header.", cropTitle))
        end
        plan.summary = "Cannot harvest: no compatible combine."
        return plan
    end
    for _, c in ipairs(combines) do
        if c.fuel ~= nil and c.fuel < 0.15 then
            table.insert(plan.warnings, string.format("%s is low on fuel (%d%%).", c.name, math.floor(c.fuel * 100)))
        end
    end

    -- 3. Greedy field <-> combine assignment: repeatedly take the best (closest, urgent
    --    first) free pair.
    local freeCombines = {}
    for _, c in ipairs(combines) do freeCombines[c.id] = c end
    local unassigned = {}
    for _, f in ipairs(fields) do unassigned[f.id] = f end

    local harvestTasks = {}
    while true do
        local bestField, bestCombine, bestScore, bestDist = nil, nil, math.huge, 0
        for _, f in pairs(unassigned) do
            for _, c in pairs(freeCombines) do
                local d = distance(f.labelX, f.labelZ, c.x, c.z)
                local score = d - (f.urgent and FAPlanner.URGENT_BONUS_M or 0)
                if score < bestScore or (score == bestScore and bestField ~= nil and f.id < bestField.id) then
                    bestField, bestCombine, bestScore, bestDist = f, c, score, d
                end
            end
        end
        if bestField == nil then
            break
        end
        local task = { id = newId("H"), action = "HARVEST_FIELD", crop = cropName, fieldId = bestField.id, vehicleId = bestCombine.id, deps = {} }
        table.insert(harvestTasks, task)
        plan.usedVehicles[bestCombine.id] = true
        table.insert(plan.decisions, string.format("Field %s: %s %d%% ready (%.1f ha)%s -> %s (%.0f m away).",
            bestField.name, cropTitle, math.floor(bestField.readyFraction * 100), bestField.areaHa or 0,
            bestField.urgent and ", about to wither" or "", bestCombine.name, bestDist))
        unassigned[bestField.id] = nil
        freeCombines[bestCombine.id] = nil
    end

    -- Remaining fields are queued (urgent first, then by id); bound at runtime.
    local queued = {}
    for _, f in pairs(unassigned) do table.insert(queued, f) end
    table.sort(queued, function(a, b)
        if (a.urgent == true) ~= (b.urgent == true) then
            return a.urgent == true
        end
        return a.id < b.id
    end)
    for _, f in ipairs(queued) do
        table.insert(harvestTasks, { id = newId("H"), action = "HARVEST_FIELD", crop = cropName, fieldId = f.id, vehicleId = nil, deps = {} })
        table.insert(plan.decisions, string.format("Field %s (%s): queued until a combine is free.", f.name, cropTitle))
    end

    -- 4. Logistics: one transport unit per combine that has work, nearest first.
    local refX, refZ = fields[1].labelX, fields[1].labelZ
    local station = FAPlanner.chooseStation(snapshot.stations, refX, refZ)
    if station == nil then
        table.insert(plan.warnings, string.format("No reachable silo or sell point accepts %s; combines will fill up and wait.", cropTitle))
    end

    local logisticsTasks = {}
    local freeTransports = {}
    for _, t in ipairs(transports) do freeTransports[t.id] = t end
    for _, h in ipairs(harvestTasks) do
        if h.vehicleId ~= nil and station ~= nil then
            local combine
            for _, c in ipairs(combines) do
                if c.id == h.vehicleId then combine = c end
            end
            local best, bestDist = nil, math.huge
            for _, t in pairs(freeTransports) do
                local d = distance(t.x, t.z, combine.x, combine.z)
                if d < bestDist then best, bestDist = t, d end
            end
            if best ~= nil then
                freeTransports[best.id] = nil
                plan.usedVehicles[best.id] = true
                table.insert(logisticsTasks, {
                    id = newId("L"), action = "UNLOAD_COMBINE", crop = cropName,
                    combineId = combine.id, vehicleId = best.id, stationId = station.id, deps = {},
                })
                table.insert(plan.decisions, string.format("%s will unload %s and deliver %s to %s.", best.name, combine.name, cropTitle, station.name))
            else
                table.insert(plan.warnings, string.format("No free tractor+trailer for %s; it will stop when its tank is full.", combine.name))
            end
        end
    end
    if #transports == 0 and not opts.quiet then
        table.insert(plan.warnings, string.format("No AI-capable tractor with a %s-capable trailer found (attach a trailer to a tractor).", cropTitle))
    end

    for _, t in ipairs(harvestTasks) do table.insert(plan.tasks, t) end
    for _, t in ipairs(logisticsTasks) do table.insert(plan.tasks, t) end

    if not opts.noReport then
        local reportDeps = {}
        for _, t in ipairs(plan.tasks) do table.insert(reportDeps, t.id) end
        table.insert(plan.tasks, { id = newId("R"), action = "REPORT", deps = reportDeps })
    end

    plan.stationId = station and station.id or nil
    plan.fieldCount = #fields
    plan.summary = string.format("Harvest %d %s field(s) with %d combine(s) and %d transport unit(s).",
        #fields, cropTitle, #combines, #logisticsTasks)
    return plan
end
