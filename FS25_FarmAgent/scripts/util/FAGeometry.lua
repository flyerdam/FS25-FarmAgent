-- FAGeometry: pure 2D helpers on the x/z ground plane. No game API use.

FAGeometry = {}

function FAGeometry.distance(x1, z1, x2, z2)
    local dx, dz = x2 - x1, z2 - z1
    return math.sqrt(dx * dx + dz * dz)
end

-- Ray-casting point-in-polygon test. polygon = { {x=, z=}, ... }
function FAGeometry.isPointInPolygon(x, z, polygon)
    local inside = false
    local n = #polygon
    local j = n
    for i = 1, n do
        local xi, zi = polygon[i].x, polygon[i].z
        local xj, zj = polygon[j].x, polygon[j].z
        if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function FAGeometry.getBoundingBox(polygon)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(polygon) do
        minX = math.min(minX, p.x)
        maxX = math.max(maxX, p.x)
        minZ = math.min(minZ, p.z)
        maxZ = math.max(maxZ, p.z)
    end
    return minX, maxX, minZ, maxZ
end

-- Returns roughly targetCount evenly spaced points inside the polygon.
-- Used to sample crop state across a whole field rather than at one point.
function FAGeometry.samplePolygon(polygon, targetCount, minSpacing)
    if #polygon < 3 then
        return {}
    end
    targetCount = targetCount or 80
    minSpacing = minSpacing or 4

    local minX, maxX, minZ, maxZ = FAGeometry.getBoundingBox(polygon)
    local width, depth = maxX - minX, maxZ - minZ
    -- Spacing for the bounding box; the polygon fills part of it, so oversample a bit.
    local spacing = math.sqrt((width * depth) / (targetCount * 1.5))
    spacing = math.max(spacing, minSpacing)

    local points = {}
    local z = minZ + spacing * 0.5
    while z < maxZ do
        local x = minX + spacing * 0.5
        while x < maxX do
            if FAGeometry.isPointInPolygon(x, z, polygon) then
                table.insert(points, { x = x, z = z })
            end
            x = x + spacing
        end
        z = z + spacing
    end
    return points
end

-- Closest point on the polygon boundary to (x, z).
function FAGeometry.getClosestBoundaryPoint(polygon, x, z)
    local bestX, bestZ, bestDist = nil, nil, math.huge
    local n = #polygon
    for i = 1, n do
        local a = polygon[i]
        local b = polygon[(i % n) + 1]
        local abx, abz = b.x - a.x, b.z - a.z
        local lenSq = abx * abx + abz * abz
        local t = 0
        if lenSq > 0 then
            t = ((x - a.x) * abx + (z - a.z) * abz) / lenSq
            t = math.max(0, math.min(1, t))
        end
        local px, pz = a.x + abx * t, a.z + abz * t
        local d = FAGeometry.distance(x, z, px, pz)
        if d < bestDist then
            bestX, bestZ, bestDist = px, pz, d
        end
    end
    return bestX, bestZ, bestDist
end

-- Moves from (fromX, fromZ) towards (toX, toZ) by 'distance' metres.
function FAGeometry.moveTowards(fromX, fromZ, toX, toZ, distance)
    local d = FAGeometry.distance(fromX, fromZ, toX, toZ)
    if d < 0.001 then
        return fromX, fromZ
    end
    local f = distance / d
    return fromX + (toX - fromX) * f, fromZ + (toZ - fromZ) * f
end

-- Field-work start point: the boundary point nearest the vehicle, pulled 'inset' metres
-- towards an interior reference point, so the AI worker drives onto the field at its
-- nearest edge rather than through standing crop to the middle.
-- Returns x, z and a unit direction (dirX, dirZ) pointing into the field. Directions,
-- not angles, are returned so the game adapter can convert them with GIANTS' own
-- MathUtil.getYRotationFromDirection and its axis convention.
function FAGeometry.getFieldEntryPoint(polygon, interiorX, interiorZ, vehicleX, vehicleZ, inset)
    local bx, bz = FAGeometry.getClosestBoundaryPoint(polygon, vehicleX, vehicleZ)
    if bx == nil then
        return interiorX, interiorZ, 0, 1
    end
    local x, z = FAGeometry.moveTowards(bx, bz, interiorX, interiorZ, inset or 10)
    if not FAGeometry.isPointInPolygon(x, z, polygon) then
        -- Concave edge: fall back to the guaranteed interior point.
        x, z = interiorX, interiorZ
    end
    local dirX, dirZ = FAGeometry.normalize(interiorX - bx, interiorZ - bz)
    return x, z, dirX, dirZ
end

-- Point just outside the field, used as a standby spot for a trailer so it is not
-- parked in the crop the combine still has to harvest.
function FAGeometry.getStandbyPoint(polygon, interiorX, interiorZ, nearX, nearZ, outset)
    local bx, bz = FAGeometry.getClosestBoundaryPoint(polygon, nearX, nearZ)
    if bx == nil then
        return nearX, nearZ
    end
    local d = FAGeometry.distance(interiorX, interiorZ, bx, bz)
    if d < 0.001 then
        return bx, bz
    end
    local f = (outset or 12) / d
    return bx + (bx - interiorX) * f, bz + (bz - interiorZ) * f
end

function FAGeometry.normalize(x, z)
    local len = math.sqrt(x * x + z * z)
    if len < 0.000001 then
        return 0, 1
    end
    return x / len, z / len
end
