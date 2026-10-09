-- Unit tests for JSON, geometry, intent parsing, field scanning, planner and validator.

local square = { { x = 0, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 100 }, { x = 0, z = 100 } }

-- JSON -----------------------------------------------------------------------------
T.test("json round trip", function()
    local src = { a = 1, b = "x\"y\n", c = { 1, 2, 3 }, d = true, e = { f = 2.5 } }
    local decoded = FAJson.decode(FAJson.encode(src))
    T.eq(decoded.a, 1); T.eq(decoded.b, "x\"y\n"); T.eq(#decoded.c, 3); T.eq(decoded.d, true); T.eq(decoded.e.f, 2.5)
end)

T.test("json decodes companion command file", function()
    local data = FAJson.decode('{"heartbeat": 17, "commands": [{"id": 3, "type": "objective", "objective": {"type": "HARVEST_READY_FIELDS", "crop": "WHEAT", "fieldIds": null}, "say": "On it \\u00e9"}]}')
    T.eq(data.heartbeat, 17)
    T.eq(data.commands[1].objective.crop, "WHEAT")
    T.eq(data.commands[1].objective.fieldIds, nil)
end)

T.test("json rejects partial file without throwing", function()
    local value, err = FAJson.decode('{"heartbeat": 1, "comm')
    T.eq(value, nil); T.truthy(err)
end)

T.test("json encodes inf as null", function()
    T.eq(FAJson.encode({ x = math.huge }), '{"x":null}')
end)

-- Geometry --------------------------------------------------------------------------
T.test("point in polygon", function()
    T.truthy(FAGeometry.isPointInPolygon(50, 50, square))
    T.truthy(not FAGeometry.isPointInPolygon(150, 50, square))
end)

T.test("sample polygon gives inside points near target count", function()
    local pts = FAGeometry.samplePolygon(square, 80, 2)
    T.truthy(#pts >= 40 and #pts <= 140, "sample count " .. #pts)
    for _, p in ipairs(pts) do T.truthy(FAGeometry.isPointInPolygon(p.x, p.z, square)) end
end)

T.test("field entry point is inside, near the vehicle side, pointing inward", function()
    local x, z, dx, dz = FAGeometry.getFieldEntryPoint(square, 50, 50, -40, 50, 10)
    T.near(x, 10, 0.01, "x"); T.near(z, 50, 0.01, "z")
    T.near(dx, 1, 0.01, "dirX"); T.near(dz, 0, 0.01, "dirZ")
end)

T.test("standby point is outside the field", function()
    local x, z = FAGeometry.getStandbyPoint(square, 50, 50, 50, 120, 12)
    T.truthy(not FAGeometry.isPointInPolygon(x, z, square), "standby outside")
end)

-- Intent ------------------------------------------------------------------------------
local crops = { { name = "WHEAT", title = "Wheat" }, { name = "BARLEY", title = "Barley" }, { name = "MAIZE", title = "Corn" } }

T.test("intent: harvest all ready wheat fields", function()
    local o = FAIntent.parse("Harvest all ready wheat fields.", crops)
    T.eq(o.type, "HARVEST_READY_FIELDS"); T.eq(o.crop, "WHEAT"); T.eq(o.fieldIds, nil)
end)

T.test("intent: corn maps to MAIZE", function()
    T.eq(FAIntent.parse("Harvest the corn.", crops).crop, "MAIZE")
end)

T.test("intent: field numbers", function()
    local o = FAIntent.parse("harvest fields 3 and 7", crops)
    T.eq(o.fieldIds[1], 3); T.eq(o.fieldIds[2], 7)
end)

T.test("intent: control verbs only when leading", function()
    T.eq(FAIntent.parse("Stop everything", crops).op, "STOP_ALL")
    T.eq(FAIntent.parse("pause", crops).op, "PAUSE")
    T.eq(FAIntent.parse("Harvest wheat and continue until done", crops).type, "HARVEST_READY_FIELDS")
end)

T.test("intent: unsupported objective explains milestone scope", function()
    local o, reason = FAIntent.parse("Make as much money as possible", crops)
    T.eq(o, nil); T.truthy(reason:find("harvest"))
end)

-- Scanner -----------------------------------------------------------------------------
local WHEAT = { index = 1, name = "WHEAT", title = "Wheat", fillTypeIndex = 11, minHarvest = 4, maxHarvest = 6, cutState = 10, witheredState = 8 }
local function lookup(i) if i == 1 then return WHEAT end end

T.test("scanner measures ready fraction across the field", function()
    -- Left 30% of the field still standing (gs 5), the rest cut (gs 10).
    local scanner = FAFieldScanner.new(function(x, z) return true, 1, (x < 30) and 5 or 10 end, function() return 0 end)
    scanner:setFields({ { id = 1, polygon = square, labelX = 50, labelZ = 50 } })
    local r = scanner:scanNow(1)
    T.near(FAFieldScanner.getReadyFraction(r, WHEAT), 0.3, 0.08, "ready fraction")
    local c = FAFieldScanner.classify(r, lookup)
    T.eq(c.state, "HARVESTED"); T.eq(c.cropName, "WHEAT")
end)

T.test("scanner classifies a ready field", function()
    local scanner = FAFieldScanner.new(function() return true, 1, 5 end, function() return 0 end)
    scanner:setFields({ { id = 1, polygon = square, labelX = 50, labelZ = 50 } })
    local c = FAFieldScanner.classify(scanner:scanNow(1), lookup)
    T.eq(c.state, "READY_TO_HARVEST"); T.near(c.readyFraction, 1, 0.001)
end)

-- Planner + validator --------------------------------------------------------------------
local function snapshotFixture()
    return {
        crop = { name = "WHEAT", title = "Wheat" },
        fields = {
            { id = 1, name = "1", areaHa = 1, labelX = 50, labelZ = 50, readyFraction = 0.95, state = "READY_TO_HARVEST" },
            { id = 2, name = "2", areaHa = 2, labelX = 500, labelZ = 50, readyFraction = 0.9, state = "READY_TO_HARVEST" },
            { id = 3, name = "3", areaHa = 2, labelX = 900, labelZ = 50, readyFraction = 0.0, state = "GROWING" },
            { id = 4, name = "4", areaHa = 1, labelX = 1500, labelZ = 50, readyFraction = 0.8, state = "READY_TO_HARVEST" },
        },
        vehicles = {
            { id = 100, name = "Combine A", kind = "COMBINE", x = 0, z = 0, canFieldWork = true, fuel = 0.8,
              combine = { hasCutter = true, hasPipe = true, supportsCrop = true } },
            { id = 101, name = "Combine B", kind = "COMBINE", x = 520, z = 0, canFieldWork = true, fuel = 0.8,
              combine = { hasCutter = true, hasPipe = true, supportsCrop = true } },
            { id = 102, name = "Combine C (corn header)", kind = "COMBINE", x = 0, z = 0, canFieldWork = true,
              combine = { hasCutter = true, hasPipe = true, supportsCrop = false } },
            { id = 200, name = "Tractor+Trailer", kind = "TRANSPORT", x = 10, z = 0, canGoTo = true, canDeliver = true,
              trailers = { { id = 201, supportsCrop = true, fillLevel = 0, capacity = 20000 } } },
        },
        stations = {
            { id = 300, name = "Sell point", isSellingStation = true, acceptsCrop = true, freeCapacity = -1, x = 0, z = 0 },
            { id = 301, name = "Farm silo", isSellingStation = false, acceptsCrop = true, freeCapacity = 100000, x = 2000, z = 0 },
        },
    }
end

T.test("planner assigns nearest combines, queues the rest, prefers own silo", function()
    local plan = FAPlanner.planHarvest({ type = "HARVEST_READY_FIELDS", crop = "WHEAT" }, snapshotFixture())
    local byField = {}
    for _, t in ipairs(plan.tasks) do
        if t.action == "HARVEST_FIELD" then byField[t.fieldId] = t end
    end
    T.eq(byField[1].vehicleId, 100, "field 1 combine")
    T.eq(byField[2].vehicleId, 101, "field 2 combine")
    T.eq(byField[4].vehicleId, nil, "field 4 queued")
    T.eq(byField[3], nil, "growing field excluded")
    local logistics = 0
    for _, t in ipairs(plan.tasks) do
        if t.action == "UNLOAD_COMBINE" then
            logistics = logistics + 1
            T.eq(t.stationId, 301, "silo preferred over sell point")
        end
    end
    T.eq(logistics, 1, "one transport unit available")
    T.eq(plan.tasks[#plan.tasks].action, "REPORT")
end)

T.test("planner reports when nothing is ready", function()
    local snap = snapshotFixture()
    for _, f in ipairs(snap.fields) do f.readyFraction = 0 end
    local plan = FAPlanner.planHarvest({ type = "HARVEST_READY_FIELDS", crop = "WHEAT" }, snap)
    T.eq(#plan.tasks, 0); T.truthy(plan.warnings[1]:find("No owned field"))
end)

T.test("validator rejects hallucinated or incompatible actions", function()
    local ctx = { snapshot = snapshotFixture(), reservedBy = {} }
    local ok, reason = FAValidator.validate({ action = "HARVEST_FIELD", fieldId = 99, vehicleId = 100 }, ctx)
    T.eq(ok, false); T.truthy(reason:find("not owned"))
    ok, reason = FAValidator.validate({ action = "HARVEST_FIELD", fieldId = 1, vehicleId = 102 }, ctx)
    T.eq(ok, false); T.truthy(reason:find("cannot harvest"))
    ok = FAValidator.validate({ action = "HARVEST_FIELD", fieldId = 1, vehicleId = 100 }, ctx)
    T.eq(ok, true)
    ok, reason = FAValidator.validate({ action = "BUY_VEHICLE" }, ctx)
    T.eq(ok, false); T.truthy(reason:find("not supported"))
    ok, reason = FAValidator.validate("rm -rf", ctx)
    T.eq(ok, false)
end)

T.test("validator: busy vehicle is a transient failure", function()
    local ctx = { snapshot = snapshotFixture(), reservedBy = { [100] = "H9" }, taskId = "H1" }
    local ok, reason, transient = FAValidator.validate({ action = "HARVEST_FIELD", fieldId = 1, vehicleId = 100 }, ctx)
    T.eq(ok, false); T.eq(transient, true); T.truthy(reason:find("H9"))
end)
