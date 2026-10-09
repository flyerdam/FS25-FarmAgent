-- FAIntent: deterministic command parser.
--
-- Two jobs:
--  1. Control commands (stop / pause / resume / status) are ALWAYS parsed locally, so the
--     player's override never depends on the LLM bridge being online.
--  2. Fallback for objectives when the Claude companion is offline. Milestone 1 only
--     understands harvest objectives.
--
-- Output objective shape (same shape the companion produces):
--   { type = "HARVEST_READY_FIELDS", crop = "WHEAT", fieldIds = {12, 14} | nil }
--   { type = "CONTROL", op = "STOP_ALL" | "PAUSE" | "RESUME" | "STATUS" }

FAIntent = {}

-- Common words -> FS25 fruit type names. Anything else is matched against the
-- game's own fruit names/titles at runtime.
FAIntent.CROP_SYNONYMS = {
    corn = "MAIZE", maize = "MAIZE",
    canola = "CANOLA", rapeseed = "CANOLA", rape = "CANOLA",
    soy = "SOYBEAN", soya = "SOYBEAN", soybean = "SOYBEAN", soybeans = "SOYBEAN",
    oat = "OAT", oats = "OAT",
    wheat = "WHEAT", barley = "BARLEY", sorghum = "SORGHUM",
    sunflower = "SUNFLOWER", sunflowers = "SUNFLOWER",
    rice = "RICE",
}

local function normalize(text)
    text = string.lower(text or "")
    text = text:gsub("[%p]", " ")
    return " " .. text:gsub("%s+", " ") .. " "
end

local function hasWord(norm, word)
    return norm:find(" " .. word .. " ", 1, true) ~= nil
end

local function hasAny(norm, words)
    for _, w in ipairs(words) do
        if hasWord(norm, w) then
            return true
        end
    end
    return false
end

local function firstWord(norm)
    return norm:match("^ (%S+)")
end

local CONTROL_VERBS = {
    stop = "STOP_ALL", halt = "STOP_ALL", abort = "STOP_ALL", cancel = "STOP_ALL",
    pause = "PAUSE", hold = "PAUSE",
    resume = "RESUME", continue = "RESUME", unpause = "RESUME",
    status = "STATUS", report = "STATUS",
}

-- Control commands. Checked first, and never sent to the LLM. Only a leading verb
-- counts ("Stop everything", "pause"), so "harvest wheat and continue" is not RESUME.
-- Phrases that switch the autopilot ("take care of the farm") on or off.
local AUTOPILOT_ON = { "autopilot on", "autopilot", "auto pilot", "autonomous", "take care of the farm",
    "take care of farm", "run the farm", "manage the farm", "auto harvest", "keep the combines busy", "keep combines busy" }
local AUTOPILOT_OFF = { "autopilot off", "auto pilot off", "stop autopilot", "disable autopilot", "manual mode", "autonomous off" }

local function hasPhrase(norm, phrases)
    for _, p in ipairs(phrases) do
        if norm:find(" " .. p .. " ", 1, true) then
            return true
        end
    end
    return false
end

function FAIntent.parseControl(text)
    local norm = normalize(text)
    if hasPhrase(norm, AUTOPILOT_OFF) then
        return { type = "CONTROL", op = "AUTOPILOT_OFF" }
    end
    if hasPhrase(norm, AUTOPILOT_ON) then
        return { type = "CONTROL", op = "AUTOPILOT_ON" }
    end
    local op = CONTROL_VERBS[firstWord(norm) or ""]
    if op == nil and norm:find(" stop all ", 1, true) then
        op = "STOP_ALL"
    end
    if op == nil then
        return nil
    end
    return { type = "CONTROL", op = op }
end

-- knownCrops = { {name="WHEAT", title="Wheat"}, ... } from the game.
function FAIntent.findCrop(text, knownCrops)
    local norm = normalize(text)
    for word, cropName in pairs(FAIntent.CROP_SYNONYMS) do
        if hasWord(norm, word) then
            return cropName
        end
    end
    for _, crop in ipairs(knownCrops or {}) do
        if hasWord(norm, string.lower(crop.name)) or (crop.title ~= nil and hasWord(norm, string.lower(crop.title))) then
            return crop.name
        end
    end
    return nil
end

function FAIntent.findFieldIds(text)
    local ids = {}
    local norm = normalize(text)
    -- "field 12", "fields 3 and 7", "fields 3 7 9"
    local start = norm:find(" fields? ")
    if start ~= nil then
        for number in norm:sub(start):gmatch("(%d+)") do
            table.insert(ids, tonumber(number))
        end
    end
    if #ids == 0 then
        return nil
    end
    return ids
end

-- Returns objective or nil, reason.
function FAIntent.parse(text, knownCrops)
    local control = FAIntent.parseControl(text)
    if control ~= nil then
        return control
    end

    local norm = normalize(text)

    -- Field work with tools (checked before harvest: "plant wheat after harvest" is planting).
    local fieldIds = FAIntent.findFieldIds(text)
    if hasPhrase(norm, { "field work", "all field work", "do all work", "whatever is needed", "what the farm needs" })
        or hasAny(norm, { "fieldwork" }) then
        return { type = "FARM_WORK" }
    end
    if hasAny(norm, { "plant", "planting", "sow", "sowing", "seed", "seeding", "drill" }) then
        local crop = FAIntent.findCrop(text, knownCrops)
        return { type = "FIELD_WORK", op = "SEED", crop = crop or "REPLANT", fieldIds = fieldIds }
    end
    if hasAny(norm, { "lime", "liming" }) then
        return { type = "FIELD_WORK", op = "LIME", fieldIds = fieldIds }
    end
    if hasAny(norm, { "fertilize", "fertilise", "fertilizing", "fertilising", "spray", "spraying", "manure", "slurry" }) then
        return { type = "FIELD_WORK", op = "FERTILIZE", fieldIds = fieldIds }
    end
    if hasAny(norm, { "plow", "plough", "plowing", "ploughing" }) then
        return { type = "FIELD_WORK", op = "PLOW", fieldIds = fieldIds }
    end
    if hasAny(norm, { "cultivate", "cultivating", "till", "tillage", "disc", "grub" }) then
        return { type = "FIELD_WORK", op = "CULTIVATE", fieldIds = fieldIds }
    end
    if hasAny(norm, { "prepare", "preparation", "stubble" }) then
        return { type = "FIELD_WORK", op = "PREPARE", fieldIds = fieldIds }
    end
    -- "do everything" (but "harvest everything" stays a harvest command below).
    if hasAny(norm, { "everything" }) and not hasAny(norm, { "harvest", "harvesting" }) then
        return { type = "FARM_WORK" }
    end

    if hasAny(norm, { "harvest", "harvesting", "combine", "thresh", "reap" }) then
        local crop = FAIntent.findCrop(text, knownCrops)
        local fieldIds = FAIntent.findFieldIds(text)
        if crop == nil and fieldIds == nil then
            -- "harvest all crops", "harvest everything", "harvest what's ready": every ready crop.
            return { type = "HARVEST_READY_FIELDS", allCrops = true }
        end
        return { type = "HARVEST_READY_FIELDS", crop = crop, fieldIds = fieldIds }
    end

    return nil, "Try: 'harvest all crops', 'prepare fields', 'plant wheat', 'fertilize', 'lime', " ..
        "'do all field work', 'take care of the farm' (autopilot), or stop / pause / resume. Alt+J shows the menu."
end
