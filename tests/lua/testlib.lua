-- Minimal test helper for Lua 5.1.
T = { passed = 0, failed = 0, messages = {}, current = "" }

function T.test(name, fn)
    T.current = name
    local ok, err = pcall(fn)
    if ok then
        T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        table.insert(T.messages, "FAIL " .. name .. ": " .. tostring(err))
    end
end

function T.eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

function T.truthy(v, what)
    if not v then
        error((what or "condition") .. " was false/nil", 2)
    end
end

function T.near(actual, expected, tol, what)
    if math.abs(actual - expected) > tol then
        error(string.format("%s: expected ~%s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

function T.summary()
    if (FS_IO_VIOLATIONS or 0) > 0 then
        T.failed = T.failed + 1
        table.insert(T.messages, string.format("FAIL io sandbox: mod code tried io.open in a non-'w' mode %d time(s); FS25 forbids this", FS_IO_VIOLATIONS))
    end
    return T.passed, T.failed, T.messages
end

-- FS25 sandbox: "io.open, only write mode ('w') is allowed". Enforced here so any file
-- read sneaking into the mod fails the tests instead of the game. Tests themselves use
-- T.readFile / T.writeFile.
local realOpen = io.open
FS_IO_VIOLATIONS = 0
io.open = function(path, mode)
    if mode ~= "w" then
        FS_IO_VIOLATIONS = FS_IO_VIOLATIONS + 1
        return nil
    end
    return realOpen(path, mode)
end

function T.readFile(path)
    local f = realOpen(path, "r")
    if f == nil then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

function T.writeFile(path, content)
    local f = assert(realOpen(path, "w"))
    f:write(content)
    f:close()
end

-- What the companion writes: JSON inside <farmAgent><payload>.
function T.commandsXml(json)
    local escaped = json:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return '<?xml version="1.0" encoding="utf-8"?>\n<farmAgent><payload>' .. escaped .. "</payload></farmAgent>"
end

-- Fakes of the engine XML/file functions the bridge uses (scriptBinding.xml names).
function fileExists(path)
    local f = realOpen(path, "r")
    if f then f:close() return true end
    return false
end

local xmlHandles, nextXml = {}, 1
function loadXMLFile(name, path)
    local content = T.readFile(path)
    if content == nil then return 0 end
    local id = nextXml
    nextXml = nextXml + 1
    xmlHandles[id] = content
    return id
end

function getXMLString(id, nodePath)
    assert(nodePath == "farmAgent.payload", "unexpected XML path " .. tostring(nodePath))
    local inner = (xmlHandles[id] or ""):match("<payload>(.-)</payload>")
    if inner == nil then return nil end
    inner = inner:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
    return inner
end

function delete(id)
    xmlHandles[id] = nil
end
