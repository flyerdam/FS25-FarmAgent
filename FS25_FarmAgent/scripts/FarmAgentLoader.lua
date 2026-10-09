-- FarmAgentLoader: entry point listed in modDesc.xml.

local modDirectory = g_currentModDirectory
local modName = g_currentModName

local files = {
    "scripts/util/FALog.lua",
    "scripts/util/FAJson.lua",
    "scripts/util/FAGeometry.lua",
    "scripts/plan/FALogistics.lua",
    "scripts/state/FAMemory.lua",
    "scripts/state/FAGameAdapter.lua",
    "scripts/state/FAFieldScanner.lua",
    "scripts/state/FAFarmState.lua",
    "scripts/exec/FAJobAdapter.lua",
    "scripts/plan/FAIntent.lua",
    "scripts/plan/FAPlanner.lua",
    "scripts/plan/FABrain.lua",
    "scripts/plan/FAValidator.lua",
    "scripts/exec/FATaskManager.lua",
    "scripts/bridge/FABridge.lua",
    "scripts/ui/FAHud.lua",
    "scripts/FarmAgent.lua",
}
for _, file in ipairs(files) do
    source(Utils.getFilename(file, modDirectory))
end

g_farmAgent = FarmAgent.new(modDirectory, modName)
addModEventListener(g_farmAgent)

-- Global hotkeys, registered the same way Courseplay registers its menu key.
local function addFarmAgentActionEvents(inputComponent, superFunc, ...)
    superFunc(inputComponent, ...)
    if g_farmAgent ~= nil and g_farmAgent.enabled then
        g_farmAgent:registerActionEvents()
    end
end
PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.overwrittenFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents, addFarmAgentActionEvents)
