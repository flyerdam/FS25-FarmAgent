-- FABridge: file-based link to the out-of-game companion (Claude).
--
-- FS25's Lua has no sockets/HTTP. Its io library is sandboxed to WRITE mode only
-- ("io.open, only write mode ('w') is allowed"), so the mod writes plain JSON files but
-- reads the companion's file through the engine XML API (loadXMLFile/getXMLString), with
-- the JSON carried as the text of one XML element. All files live in:
--   <Documents>/My Games/FarmingSimulator2025/modSettings/FS25_FarmAgent/
--
--   state.json     mod -> companion   farm state model, tasks, log, command results (every 5 s)
--   requests.json  mod -> companion   natural-language requests typed by the player
--   commands.xml   companion -> mod   <farmAgent><payload>{JSON: heartbeat, commands}</payload></farmAgent>
--
-- The companion never sends Lua: only JSON that the validator checks.

FABridge = {}
local FABridge_mt = { __index = FABridge }

FABridge.POLL_MS = 1000
FABridge.STATE_WRITE_MS = 5000
FABridge.ONLINE_TIMEOUT_MS = 15000
FABridge.REQUEST_TIMEOUT_MS = 90000

function FABridge.new(directory)
    local self = setmetatable({}, FABridge_mt)
    self.directory = directory
    self.now = 0
    self.pollTimer = 0
    self.stateTimer = FABridge.STATE_WRITE_MS
    self.lastCommandId = nil
    self.lastHeartbeat = nil
    self.lastHeartbeatChangeAt = nil
    self.requests = {}
    self.nextRequestId = 1
    self.commandResults = {}
    return self
end

-- Reads the JSON payload of an XML file written by the companion. io read mode is not
-- available to mods, so this goes through the engine's XML functions.
local function readXmlPayload(path)
    if not fileExists(path) then
        return nil
    end
    local xml = loadXMLFile("FarmAgentBridge", path)
    if xml == nil or xml == 0 then
        return nil
    end
    local payload = getXMLString(xml, "farmAgent.payload")
    delete(xml)
    return payload
end

local function writeFile(path, content)
    local file = io.open(path, "w")
    if file == nil then
        return false
    end
    file:write(content)
    file:close()
    return true
end

FABridge.readXmlPayload = readXmlPayload
FABridge.writeFile = writeFile

function FABridge:init(sessionId)
    createFolder(self.directory)
    -- Request ids restart at 1 every game session; the session id keeps them unique for
    -- the companion (which cannot otherwise tell session 2's request #1 from session 1's).
    self.sessionId = sessionId or "session"
    -- Ignore commands left over from a previous session.
    local data = self:readCommands()
    local maxId = 0
    if data ~= nil then
        for _, cmd in ipairs(data.commands or {}) do
            if type(cmd.id) == "number" and cmd.id > maxId then
                maxId = cmd.id
            end
        end
        self.lastHeartbeat = data.heartbeat
    end
    self.lastCommandId = maxId
    self:writeRequests()
    FALog.info("BRIDGE", "Bridge folder: %s (session %s)", self.directory, self.sessionId)
end

function FABridge:readCommands()
    local content = readXmlPayload(self.directory .. "commands.xml")
    if content == nil or content == "" then
        return nil
    end
    local data = FAJson.decode(content)
    if type(data) ~= "table" then
        return nil -- partially written; try again next poll
    end
    return data
end

function FABridge:isOnline()
    return self.lastHeartbeatChangeAt ~= nil and self.now - self.lastHeartbeatChangeAt < FABridge.ONLINE_TIMEOUT_MS
end

function FABridge:writeRequests()
    local items = {}
    local first = math.max(1, #self.requests - 19)
    for i = first, #self.requests do
        local r = self.requests[i]
        table.insert(items, { id = r.id, text = r.text, status = r.status })
    end
    writeFile(self.directory .. "requests.json", FAJson.encode({ session = self.sessionId, requests = items }))
end

function FABridge:sendRequest(text)
    local request = { id = self.nextRequestId, text = text, status = "SENT", sentAt = self.now }
    self.nextRequestId = self.nextRequestId + 1
    table.insert(self.requests, request)
    self:writeRequests()
    return request
end

function FABridge:getRequest(id)
    for _, r in ipairs(self.requests) do
        if r.id == id then
            return r
        end
    end
    return nil
end

function FABridge:setRequestStatus(id, status)
    local r = self:getRequest(id)
    if r ~= nil then
        r.status = status
        self:writeRequests()
    end
end

function FABridge:addCommandResult(commandId, ok, message)
    table.insert(self.commandResults, { commandId = commandId, ok = ok, message = message })
    if #self.commandResults > 20 then
        table.remove(self.commandResults, 1)
    end
    self.stateTimer = FABridge.STATE_WRITE_MS -- publish soon
end

-- handlers.onCommand(cmd), handlers.onRequestTimeout(request), handlers.buildState() -> table
function FABridge:update(dt, handlers)
    self.now = self.now + dt
    self.pollTimer = self.pollTimer + dt
    self.stateTimer = self.stateTimer + dt

    if self.pollTimer >= FABridge.POLL_MS then
        self.pollTimer = 0
        local data = self:readCommands()
        if data ~= nil then
            if data.heartbeat ~= nil and data.heartbeat ~= self.lastHeartbeat then
                if not self:isOnline() then
                    FALog.info("BRIDGE", "Claude companion connected.")
                end
                self.lastHeartbeat = data.heartbeat
                self.lastHeartbeatChangeAt = self.now
            end
            local pending = {}
            for _, cmd in ipairs(data.commands or {}) do
                if type(cmd) == "table" and type(cmd.id) == "number" and cmd.id > self.lastCommandId then
                    table.insert(pending, cmd)
                end
            end
            table.sort(pending, function(a, b) return a.id < b.id end)
            if #pending > 0 then
                self.stateTimer = FABridge.STATE_WRITE_MS -- publish the outcome right away
            end
            for _, cmd in ipairs(pending) do
                self.lastCommandId = cmd.id
                if cmd.session ~= nil and cmd.session ~= self.sessionId then
                    -- Late answer to a request from an earlier game session.
                    FALog.info("BRIDGE", "Ignored command %d from an earlier game session.", cmd.id)
                else
                    if cmd.requestId ~= nil then
                        self:setRequestStatus(cmd.requestId, "ANSWERED")
                    end
                    local ok, err = pcall(handlers.onCommand, cmd)
                    if not ok then
                        FALog.error("BRIDGE", "Command %d failed: %s", cmd.id, tostring(err))
                        self:addCommandResult(cmd.id, false, "internal error: " .. tostring(err))
                    end
                end
            end
        end
        for _, r in ipairs(self.requests) do
            if r.status == "SENT" and self.now - r.sentAt > FABridge.REQUEST_TIMEOUT_MS then
                r.status = "TIMED_OUT"
                self:writeRequests()
                handlers.onRequestTimeout(r)
            end
        end
    end

    if self.stateTimer >= FABridge.STATE_WRITE_MS then
        self.stateTimer = 0
        local ok, state = pcall(handlers.buildState)
        if ok and state ~= nil then
            state.commandResults = self.commandResults
            state.bridge = { lastCommandId = self.lastCommandId, companionOnline = self:isOnline() }
            writeFile(self.directory .. "state.json", FAJson.encode(state))
        elseif not ok then
            FALog.error("BRIDGE", "Could not build state: %s", tostring(state))
        end
    end
end
