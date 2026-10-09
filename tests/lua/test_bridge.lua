-- FABridge against real files in a temp folder (TEST_TMP is set by run_tests.py).
-- io.open is restricted to "w" by testlib, as in FS25.

createFolder = function() end

local dir = TEST_TMP .. "/"

local function writeCommands(json)
    T.writeFile(dir .. "commands.xml", T.commandsXml(json))
end

local function readJson(name)
    return FAJson.decode(T.readFile(dir .. name) or "")
end

T.test("bridge: ignores stale commands, processes new ones in order, detects heartbeat", function()
    writeCommands('{"heartbeat": 1, "commands": [{"id": 1, "type": "reply", "say": "old"}]}')
    local bridge = FABridge.new(dir)
    bridge:init("S1")
    local seen = {}
    local handlers = {
        onCommand = function(cmd) table.insert(seen, cmd.id) end,
        onRequestTimeout = function() end,
        buildState = function() return { phase = "IDLE" } end,
    }
    bridge:update(1000, handlers)
    T.eq(#seen, 0, "stale command from previous session ignored")
    T.eq(bridge:isOnline(), false, "unchanged heartbeat = offline")

    local req = bridge:sendRequest("Harvest all ready wheat fields & more <stuff>")
    local requests = readJson("requests.json")
    T.eq(requests.session, "S1")
    T.eq(requests.requests[1].text, "Harvest all ready wheat fields & more <stuff>")

    writeCommands('{"heartbeat": 2, "commands": [{"id": 3, "type": "reply", "say": "a & b <c>"}, {"id": 2, "session": "S1", "requestId": ' .. req.id .. ', "type": "objective"}]}')
    bridge:update(1000, handlers)
    T.eq(seen[1], 2); T.eq(seen[2], 3)
    T.eq(bridge:isOnline(), true)
    T.eq(bridge:getRequest(req.id).status, "ANSWERED")

    bridge:update(1000, handlers)
    T.eq(#seen, 2, "each command handled once")

    writeCommands('{"heartbeat": 3, "commands": [{"id": 4, "session": "OLD", "requestId": 1, "type": "objective"}]}')
    bridge:update(1000, handlers)
    T.eq(#seen, 2, "late answer from an earlier game session ignored")

    T.writeFile(dir .. "commands.xml", '<?xml version="1.0"?><farmAgent><payload>{"heartbeat": 3, "comm')
    bridge:update(1000, handlers) -- partially written file is skipped, no error

    local state = readJson("state.json")
    T.eq(state.phase, "IDLE")
    T.eq(state.bridge.lastCommandId, 4)
end)

T.test("bridge: unanswered request times out to the local parser", function()
    writeCommands('{"heartbeat": 10, "commands": []}')
    local bridge = FABridge.new(dir)
    bridge:init("S2")
    local timedOut = nil
    local handlers = {
        onCommand = function() end,
        onRequestTimeout = function(r) timedOut = r.text end,
        buildState = function() return {} end,
    }
    bridge:sendRequest("harvest wheat")
    for _ = 1, 95 do bridge:update(1000, handlers) end
    T.eq(timedOut, "harvest wheat")
end)

T.test("bridge: works with no companion file at all", function()
    local emptyDir = TEST_TMP .. "/empty_bridge/"
    os.execute('mkdir "' .. emptyDir:gsub("/", "\\") .. '" 2>nul')
    local bridge = FABridge.new(emptyDir)
    bridge:init("S3")
    bridge:update(1000, { onCommand = function() end, onRequestTimeout = function() end, buildState = function() return {} end })
    T.eq(bridge:isOnline(), false)
end)
