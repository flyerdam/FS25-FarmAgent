-- FALog: concise, structured decision/action log.
-- This is what the player sees as the "reasoning" view. It records decisions and
-- actions, never model chain-of-thought.

FALog = {}

FALog.MAX_ENTRIES = 300
FALog.entries = {}
FALog.nextSeq = 1

FALog.LEVEL = {
    INFO = "INFO",
    DECISION = "DECISION",
    ACTION = "ACTION",
    WARN = "WARN",
    ERROR = "ERROR",
    ATTENTION = "ATTENTION",
}

-- Overridable clock. In game this returns the in-game time of day; in tests it can be stubbed.
function FALog.clock()
    if g_currentMission ~= nil and g_currentMission.environment ~= nil and g_currentMission.environment.dayTime ~= nil then
        local totalSeconds = math.floor(g_currentMission.environment.dayTime / 1000)
        local h = math.floor(totalSeconds / 3600) % 24
        local m = math.floor(totalSeconds / 60) % 60
        local s = totalSeconds % 60
        return string.format("%02d:%02d:%02d", h, m, s)
    end
    return "--:--:--"
end

-- Overridable sink for the game log (log.txt). Tests replace this to stay silent.
function FALog.sink(line)
    print(line)
end

function FALog.add(level, category, fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then
        text = tostring(fmt)
    end

    local entry = {
        seq = FALog.nextSeq,
        time = FALog.clock(),
        level = level,
        category = category or "",
        text = text,
    }
    FALog.nextSeq = FALog.nextSeq + 1

    table.insert(FALog.entries, entry)
    if #FALog.entries > FALog.MAX_ENTRIES then
        table.remove(FALog.entries, 1)
    end

    FALog.sink(string.format("[FarmAgent] %s %-9s %s %s", entry.time, level, entry.category, text))
    return entry
end

function FALog.info(category, fmt, ...)      return FALog.add(FALog.LEVEL.INFO, category, fmt, ...) end
function FALog.decision(category, fmt, ...)  return FALog.add(FALog.LEVEL.DECISION, category, fmt, ...) end
function FALog.action(category, fmt, ...)    return FALog.add(FALog.LEVEL.ACTION, category, fmt, ...) end
function FALog.warn(category, fmt, ...)      return FALog.add(FALog.LEVEL.WARN, category, fmt, ...) end
function FALog.error(category, fmt, ...)     return FALog.add(FALog.LEVEL.ERROR, category, fmt, ...) end
function FALog.attention(category, fmt, ...) return FALog.add(FALog.LEVEL.ATTENTION, category, fmt, ...) end

-- Returns the newest n entries, oldest first.
function FALog.getRecent(n)
    local result = {}
    local first = math.max(1, #FALog.entries - n + 1)
    for i = first, #FALog.entries do
        table.insert(result, FALog.entries[i])
    end
    return result
end

function FALog.clear()
    FALog.entries = {}
end
