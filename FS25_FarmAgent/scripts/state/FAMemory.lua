-- FAMemory: small, structured, persistent farm knowledge (one file per map + savegame).
--
--   combines[uniqueId] = { pipeX, pipeZ }          learned fully-unfolded pipe end (combine-local)
--   fields[fieldId]    = { lastCrop, harvests, stalls }
--
-- Stored as JSON inside <farmAgent><payload> in modSettings/FS25_FarmAgent/, written with
-- io "w" (the only io mode FS25 allows) and read back through the engine XML API.

FAMemory = {}
local FAMemory_mt = { __index = FAMemory }

function FAMemory.new(path, readPayload, writeFile)
    local self = setmetatable({}, FAMemory_mt)
    self.path = path
    self.readPayload = readPayload
    self.writeFile = writeFile
    self.data = { version = 1, combines = {}, fields = {}, vehicles = {}, settings = {} }
    self.dirty = false
    return self
end

function FAMemory:load()
    local payload = self.path ~= nil and self.readPayload(self.path) or nil
    if payload ~= nil and payload ~= "" then
        local data = FAJson.decode(payload)
        if type(data) == "table" then
            self.data.combines = type(data.combines) == "table" and data.combines or {}
            self.data.fields = type(data.fields) == "table" and data.fields or {}
            self.data.vehicles = type(data.vehicles) == "table" and data.vehicles or {}
            self.data.settings = type(data.settings) == "table" and data.settings or {}
            return true
        end
    end
    return false
end

function FAMemory:save()
    if not self.dirty or self.path == nil then
        return
    end
    local json = FAJson.encode(self.data):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    self.writeFile(self.path, '<?xml version="1.0" encoding="utf-8"?>\n<farmAgent><payload>' .. json .. "</payload></farmAgent>")
    self.dirty = false
end

local function fieldKey(fieldId)
    return tostring(fieldId)
end

function FAMemory:field(fieldId)
    local key = fieldKey(fieldId)
    local f = self.data.fields[key]
    if f == nil then
        f = {}
        self.data.fields[key] = f
    end
    return f
end

function FAMemory:setPipeOffset(uniqueId, x, z)
    local old = self.data.combines[uniqueId]
    if old == nil or math.abs((old.pipeX or 0) - x) > 0.2 or math.abs((old.pipeZ or 0) - z) > 0.2 then
        self.data.combines[uniqueId] = { pipeX = x, pipeZ = z }
        self.dirty = true
    end
end

function FAMemory:getPipeOffset(uniqueId)
    local c = self.data.combines[uniqueId]
    if c ~= nil and c.pipeX ~= nil then
        return c.pipeX, c.pipeZ
    end
    return nil
end

function FAMemory:recordHarvest(fieldId, cropName)
    local f = self:field(fieldId)
    f.lastCrop = cropName
    f.harvests = (f.harvests or 0) + 1
    self.dirty = true
end

function FAMemory:getLastCrop(fieldId)
    local f = self.data.fields[fieldKey(fieldId)]
    return f and f.lastCrop or nil
end

-- Player settings (auto fertilizing / liming, autopilot planting crop, ...).
function FAMemory:getSetting(key, default)
    local value = self.data.settings[key]
    if value == nil then
        return default
    end
    return value
end

function FAMemory:setSetting(key, value)
    if self.data.settings[key] ~= value then
        self.data.settings[key] = value
        self.dirty = true
    end
end

-- Where a vehicle stood (off the fields) before Farm Agent first used it: its parking spot.
function FAMemory:getHome(uniqueId)
    local v = self.data.vehicles[uniqueId]
    if v ~= nil and v.homeX ~= nil then
        return v.homeX, v.homeZ, v.homeDirX or 0, v.homeDirZ or 1
    end
    return nil
end

function FAMemory:setHome(uniqueId, x, z, dirX, dirZ)
    self.data.vehicles[uniqueId] = { homeX = x, homeZ = z, homeDirX = dirX, homeDirZ = dirZ }
    self.dirty = true
end

function FAMemory:recordStall(fieldId)
    local f = self:field(fieldId)
    f.stalls = (f.stalls or 0) + 1
    self.dirty = true
end
