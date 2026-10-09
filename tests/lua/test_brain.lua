-- Tests for the built-in brain: crop views, crop ranking, multi-crop planning,
-- autopilot steps, auto-resume and the new commands.

local function farm()
    return {
        crops = { { name = "WHEAT", title = "Wheat" }, { name = "BARLEY", title = "Barley" } },
        fields = {
            { id = 1, name = "1", areaHa = 5, labelX = 0, labelZ = 0, crop = "WHEAT", state = "READY_TO_HARVEST", readyByCrop = { WHEAT = 0.95 } },
            { id = 2, name = "2", areaHa = 5, labelX = 400, labelZ = 0, crop = "WHEAT", state = "READY_TO_HARVEST", readyByCrop = { WHEAT = 0.9 } },
            { id = 3, name = "3", areaHa = 3, labelX = 800, labelZ = 0, crop = "BARLEY", state = "READY_TO_HARVEST", readyByCrop = { BARLEY = 1.0 } },
            { id = 4, name = "4", areaHa = 8, labelX = 900, labelZ = 0, crop = "OAT", state = "GROWING", readyByCrop = {} },
        },
        vehicles = {
            { id = 100, name = "Combine A (multi header)", kind = "COMBINE", x = 0, z = 0, canFieldWork = true,
              combine = { hasCutter = true, hasPipe = true, fillLevel = 0, capacity = 9000, supportedCrops = { "BARLEY", "WHEAT" } } },
            { id = 101, name = "Combine B (wheat header)", kind = "COMBINE", x = 400, z = 0, canFieldWork = true,
              combine = { hasCutter = true, hasPipe = true, fillLevel = 0, capacity = 9000, supportedCrops = { "WHEAT" } } },
            { id = 200, name = "Tractor 1", kind = "TRANSPORT", x = 10, z = 0, canGoTo = true, canDeliver = true,
              trailers = { { id = 201, supportedCrops = { "WHEAT", "BARLEY" } } } },
        },
        stations = {
            { id = 300, name = "Silo", isSellingStation = false, acceptedCrops = { WHEAT = 50000, BARLEY = 50000 }, x = 0, z = 0 },
        },
    }
end

local function tasksBy(plan, action)
    local list = {}
    for _, t in ipairs(plan.tasks) do
        if t.action == action then table.insert(list, t) end
    end
    return list
end

T.test("viewForCrop narrows the multi-crop snapshot", function()
    local view = FAPlanner.viewForCrop(farm(), "BARLEY")
    T.eq(view.fields[1].readyFraction, 0); T.eq(view.fields[3].readyFraction, 1.0)
    T.eq(view.vehicles[1].combine.supportsCrop, true); T.eq(view.vehicles[2].combine.supportsCrop, false)
    T.eq(view.vehicles[3].trailers[1].supportsCrop, true)
    T.eq(view.stations[1].acceptsCrop, true); T.eq(view.stations[1].freeCapacity, 50000)
    T.eq(view.crop.title, "Barley")
end)

T.test("a combine holding another crop is not usable until emptied", function()
    local snap = farm()
    snap.vehicles[1].combine.fillLevel = 3000
    snap.vehicles[1].combine.fillCrop = "WHEAT"
    T.eq(FAPlanner.isUsable(FAPlanner.viewForCrop(snap, "BARLEY").vehicles[1]), false)
    T.eq(FAPlanner.isUsable(FAPlanner.viewForCrop(snap, "WHEAT").vehicles[1]), true)
end)

T.test("crops ranked by ready area, urgency wins", function()
    local snap = farm()
    local ranked = FABrain.rankReadyCrops(snap)
    T.eq(ranked[1].name, "WHEAT"); T.eq(ranked[2].name, "BARLEY"); T.eq(#ranked, 2)
    snap.fields[3].urgent = true
    T.eq(FABrain.rankReadyCrops(snap)[1].name, "BARLEY", "about-to-wither barley first")
end)

T.test("harvest all crops: machines never double-booked, other crop queued", function()
    local plan = FABrain.planAllCrops(farm())
    local harvest = tasksBy(plan, "HARVEST_FIELD")
    T.eq(#harvest, 3)
    local byField = {}
    for _, t in ipairs(harvest) do byField[t.fieldId] = t end
    T.eq(byField[1].vehicleId, 100); T.eq(byField[1].crop, "WHEAT")
    T.eq(byField[2].vehicleId, 101); T.eq(byField[2].crop, "WHEAT")
    T.eq(byField[3].vehicleId, nil, "barley waits for combine A"); T.eq(byField[3].crop, "BARLEY")
    T.eq(byField[4], nil, "growing oats untouched")
    local logistics = tasksBy(plan, "UNLOAD_COMBINE")
    T.eq(#logistics, 1); T.eq(logistics[1].crop, "WHEAT")
    local report = tasksBy(plan, "REPORT")[1]
    T.eq(#report.deps, 4)
    local ids = {}
    for _, t in ipairs(plan.tasks) do
        T.eq(ids[t.id], nil, "unique task id " .. t.id)
        ids[t.id] = true
    end
    T.truthy(plan.summary:find("2 crop"))
end)

T.test("harvest all crops: every planned task validates on its crop view", function()
    local snap = farm()
    local plan = FABrain.planAllCrops(snap)
    for _, t in ipairs(plan.tasks) do
        local view = t.crop and FAPlanner.viewForCrop(snap, t.crop) or snap
        local ok, reason = FAValidator.validate(t, { snapshot = view, reservedBy = {}, taskId = t.id, tasks = {} })
        T.truthy(ok, tostring(t.id) .. " " .. tostring(reason))
    end
end)

T.test("autopilot step: only idle machines, no queued work, busy fields left alone", function()
    local snap = farm()
    local tasks = FABrain.autopilotStep(snap, { [101] = true }, { [1] = true }, FAPlanner.newIdGenerator(10))
    local harvest = {}
    for _, t in ipairs(tasks) do
        if t.action == "HARVEST_FIELD" then table.insert(harvest, t) end
        T.truthy(t.action ~= "REPORT", "no report in autopilot")
    end
    T.eq(#harvest, 1)
    T.eq(harvest[1].fieldId, 2, "best remaining wheat field"); T.eq(harvest[1].vehicleId, 100)
    T.eq(harvest[1].id, "H10")
end)

T.test("autopilot step: nothing to do is quiet", function()
    local snap = farm()
    local tasks, decisions, warnings = FABrain.autopilotStep(snap, { [100] = true, [101] = true }, {}, FAPlanner.newIdGenerator(1))
    T.eq(#tasks, 0); T.eq(#warnings, 0)
end)

T.test("auto-resume waits until the player has left for 60 s", function()
    local ok, leftAt = FABrain.shouldAutoResume({ isEntered = true, aiActive = false }, nil, 1000)
    T.eq(ok, false); T.eq(leftAt, nil)
    ok, leftAt = FABrain.shouldAutoResume({ isEntered = false, aiActive = false }, nil, 5000)
    T.eq(ok, false); T.eq(leftAt, 5000)
    ok = FABrain.shouldAutoResume({ isEntered = false, aiActive = false }, leftAt, 64000)
    T.eq(ok, false)
    ok = FABrain.shouldAutoResume({ isEntered = false, aiActive = false }, leftAt, 65000)
    T.eq(ok, true)
    T.eq(FABrain.shouldAutoResume({ isEntered = false, aiActive = true }, leftAt, 99000), false, "player restarted it himself")
end)

T.test("intent: all crops and autopilot", function()
    local crops = { { name = "WHEAT", title = "Wheat" } }
    T.eq(FAIntent.parse("harvest all crops", crops).allCrops, true)
    T.eq(FAIntent.parse("Harvest everything that's ready", crops).allCrops, true)
    T.eq(FAIntent.parse("harvest the wheat", crops).crop, "WHEAT")
    T.eq(FAIntent.parse("Take care of the farm while I'm away", crops).op, "AUTOPILOT_ON")
    T.eq(FAIntent.parse("autopilot", crops).op, "AUTOPILOT_ON")
    T.eq(FAIntent.parse("autopilot off", crops).op, "AUTOPILOT_OFF")
    T.eq(FAIntent.parse("stop autopilot", crops).op, "AUTOPILOT_OFF")
    T.eq(FAIntent.parse("stop everything", crops).op, "STOP_ALL")
end)
