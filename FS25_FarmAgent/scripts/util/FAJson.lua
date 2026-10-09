-- FAJson: minimal JSON encoder/decoder (Lua 5.1) for the companion bridge.
-- FS25 has no built-in JSON library, so the bridge carries its own.

FAJson = {}

FAJson.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function isArray(t)
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            return false
        end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then
            return false
        end
    end
    return true
end

local encodeValue

local function encodeTable(t, depth)
    if depth > 32 then
        error("FAJson: nesting too deep")
    end
    if next(t) == nil then
        -- Empty tables are ambiguous in Lua; arrays are the common case in our payloads.
        return "[]"
    end
    local parts = {}
    if isArray(t) then
        for i = 1, #t do
            parts[i] = encodeValue(t[i], depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k, _ in pairs(t) do
        table.insert(keys, tostring(k))
    end
    table.sort(keys) -- deterministic output
    for _, k in ipairs(keys) do
        local v = t[k]
        if v == nil then
            v = t[tonumber(k)]
        end
        if type(v) ~= "function" and type(v) ~= "userdata" then
            table.insert(parts, encodeString(k) .. ":" .. encodeValue(v, depth + 1))
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(v, depth)
    local tv = type(v)
    if v == nil or v == FAJson.null then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return "null"
        end
        if math.floor(v) == v and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%.6g", v)
    elseif tv == "string" then
        return encodeString(v)
    elseif tv == "table" then
        return encodeTable(v, depth)
    end
    return "null"
end

function FAJson.encode(value)
    return encodeValue(value, 0)
end

-- Decoder ----------------------------------------------------------------

local function decodeError(str, pos, msg)
    error(string.format("FAJson: %s at position %d", msg, pos), 0)
end

local function skipWhitespace(str, pos)
    local _, e = str:find("^[ \n\r\t]*", pos)
    return e + 1
end

local decodeAt

local function decodeStringAt(str, pos)
    -- pos points at the opening quote
    local buffer = {}
    local i = pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then
            decodeError(str, i, "unterminated string")
        elseif c == '"' then
            return table.concat(buffer), i + 1
        elseif c == "\\" then
            local n = str:sub(i + 1, i + 1)
            local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if map[n] ~= nil then
                table.insert(buffer, map[n])
                i = i + 2
            elseif n == "u" then
                local hex = str:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if code == nil then
                    decodeError(str, i, "bad unicode escape")
                end
                -- Encode as UTF-8 (surrogate pairs are passed through as-is).
                if code < 0x80 then
                    table.insert(buffer, string.char(code))
                elseif code < 0x800 then
                    table.insert(buffer, string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40))
                else
                    table.insert(buffer, string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40))
                end
                i = i + 6
            else
                decodeError(str, i, "bad escape")
            end
        else
            table.insert(buffer, c)
            i = i + 1
        end
    end
end

decodeAt = function(str, pos)
    pos = skipWhitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skipWhitespace(str, pos + 1)
        if str:sub(pos, pos) == "}" then
            return obj, pos + 1
        end
        while true do
            pos = skipWhitespace(str, pos)
            if str:sub(pos, pos) ~= '"' then
                decodeError(str, pos, "expected object key")
            end
            local key
            key, pos = decodeStringAt(str, pos)
            pos = skipWhitespace(str, pos)
            if str:sub(pos, pos) ~= ":" then
                decodeError(str, pos, "expected ':'")
            end
            local value
            value, pos = decodeAt(str, pos + 1)
            obj[key] = value
            pos = skipWhitespace(str, pos)
            local d = str:sub(pos, pos)
            if d == "}" then
                return obj, pos + 1
            elseif d ~= "," then
                decodeError(str, pos, "expected ',' or '}'")
            end
            pos = pos + 1
        end
    elseif c == "[" then
        local arr = {}
        pos = skipWhitespace(str, pos + 1)
        if str:sub(pos, pos) == "]" then
            return arr, pos + 1
        end
        while true do
            local value
            value, pos = decodeAt(str, pos)
            table.insert(arr, value)
            pos = skipWhitespace(str, pos)
            local d = str:sub(pos, pos)
            if d == "]" then
                return arr, pos + 1
            elseif d ~= "," then
                decodeError(str, pos, "expected ',' or ']'")
            end
            pos = pos + 1
        end
    elseif c == '"' then
        return decodeStringAt(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    else
        local numStr = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if numStr == nil or numStr == "" then
            decodeError(str, pos, "unexpected character '" .. c .. "'")
        end
        return tonumber(numStr), pos + #numStr
    end
end

-- Returns value, or nil + error message. Never throws.
function FAJson.decode(str)
    if type(str) ~= "string" then
        return nil, "FAJson: input is not a string"
    end
    local ok, value, pos = pcall(decodeAt, str, 1)
    if not ok then
        return nil, value
    end
    pos = skipWhitespace(str, pos)
    if pos <= #str then
        return nil, "FAJson: trailing characters at position " .. pos
    end
    return value
end
