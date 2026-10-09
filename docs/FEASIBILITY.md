# Farm Agent: feasibility, architecture, and API mapping (Milestone 1)

## How this was researched

No API in this document is guessed. Sources, in order of authority:

1. **GIANTS' shipped game source** from your install:
   `Farming Simulator 25\sdk\debugger\gameSource.zip` (game 1.21.1.0). It's the Lua source
   GIANTS ships for its debugger. Some function bodies are stripped. Where a body is missing,
   the method is treated as real only if the game's own code calls it.
2. **`sdk\debugger\scriptBinding.xml`**, the engine function list (`worldToLocal`,
   `localToLocal`, `renderText`, `drawFilledRect`, …).
3. **Courseplay 8.1.0.3** (installed in your mods folder). It's working ModHub code, so it
   shows real FS25 usage (`createFolder`, `TextInputDialog.show`, the input hook,
   `registerJobType`).
4. **GDN docs** (gdn.giants-software.com, script v1.20). For the classes I checked, the docs
   match the stripped source, so they add little beyond (1).

Evidence labels used below:
- **[src]**: the definition is in the shipped source.
- **[call]**: only a game call site is visible.
- **[CP]**: confirmed by Courseplay's usage.

> Nothing here has been run inside FS25 yet. Logic is unit-tested in a Lua 5.1 simulation.
> Behaviour against the live engine is what Milestone 1 testing has to confirm.

---

## A. Feasibility: what the public API allows

| # | Question | Answer |
|---|---|---|
| 1 | AI-worker APIs? | **Yes, complete and job-based.** `g_currentMission.aiJobTypeManager` registers job types `GOTO`, `FIELDWORK`, `CONVEYOR`, `DELIVER`, `LOAD_AND_DELIVER` [src]. `g_currentMission.aiSystem` has `startJob`, `stopJob`, `getActiveJobs`, `getJobById`, `skipCurrentTask` and `getAILimitedReached` [src]. Lifecycle is published on `g_messageCenter`: `AI_JOB_STARTED`, `AI_JOB_STOPPED (job, aiMessage)`, `AI_JOB_REMOVED` [src]. Stop reasons are typed classes, for example `AIMessageErrorOutOfFuel`, `…NotReachable`, `…ThreshingNotAllowed`, `…UnloadingStationFull`, `AIMessageSuccessFinishedJob` (28 in total) [src]. |
| 2 | Navigation / pathfinding? | **Indirect only.** The engine plans the drive when a job's `AITaskDriveTo` calls `vehicle:setAITarget(...)` [src]. There is no "plan a path / is X reachable?" query for mods. You learn reachability by trying, and failures come back as `AIMessageErrorNotReachable`. `NavigationSystem` only holds map navigation markers [src]. Mods can add obstacles and blocking regions (`aiSystem:addObstacle`, `addBlockingRegion`) [src]. |
| 3 | Start/stop AI from a mod? | **Yes.** It's the same sequence as GIANTS' own `AISystem:consoleCommandAIStart`: `createJob(typeIndex)`, set parameters, `job:setValues()`, `job:validate(farmId)`, then `aiSystem:startJob(job, farmId)` [src]. Multiplayer clients send `AIJobStartRequestEvent` instead [src]. To stop: `aiSystem:stopJob(job, AIMessageSuccessStoppedByUser.new())` [src]. |
| 4 | Inspect fields? | **Yes.** `g_fieldManager:getFields()` [call]. On a field: `getId()`, `getName()` [call], and `areaHa`, `polygonPoints`, `posX/posZ` (an interior label point) and `farmland` [src]. Ownership comes from `g_farmlandManager:getFarmlandOwner(field.farmland.id)` [src]. |
| 5 | Crop state? | **Per position, not per field.** `FieldState.new():update(x, z)` gives `fruitTypeIndex`, `growthState`, `weedState`, `sprayLevel`, `limeLevel`, `plowLevel`, `rollerLevel`, `stubbleShredLevel`, `stoneLevel` and `groundType` [src fields, call update]. "Ready" is read from the crop's own definition, `FruitTypeDesc.minHarvestingGrowthState..maxHarvestingGrowthState`, plus `cutState` and `witheredState` [src]. There's **no "% harvested" API for owned fields**; the completion helpers are mission-only. Farm Agent therefore samples about 80 points per field polygon. |
| 6 | Vehicles and implements? | **Yes.** `g_currentMission.vehicleSystem.vehicles` [src], plus `rootVehicle` and `getChildVehicles()` [src]. Capabilities come from specializations: `spec_combine`, `spec_cutter.fruitTypeIndices` (crops the header can cut), `spec_pipe` and `spec_aiJobVehicle` [src]. Also `getFullName`, `getOwnerFarmId`, `getLastSpeed()` (km/h), `getDamageAmount`, `isBroken` and `getIsAIActive` [src]. Whether a vehicle can run a job comes from the job class itself: `job:getIsAvailableForVehicle(v)` [src]. |
| 7 | Fill levels? | **Yes.** The FillUnit spec has `getFillUnitFillLevel`, `getFillUnitCapacity`, `getFillUnitFillType`, `getFillUnitSupportsFillType` and `getFillUnitFillLevelPercentage` [src]. Fuel uses `getConsumerFillUnitIndex(FillType.DIESEL)` [src]. Stations offer `getFreeCapacity(fillType, farmId)` and `getIsFillTypeAISupported` [call]. |
| 8 | Products on the ground? | **Yes, by area query.** Windrows and heaps are height-map fill types: `DensityMapHeightUtil.getFillLevelAtArea(...)` [call]. Not needed for Milestone 1. |
| 9 | Grass, windrows, bales? | Grass is a fruit type with growth states. Mown grass is a windrow fill type (`fruitTypeManager:getWindrowFillTypeIndexByFruitTypeIndex`) [src]. Bales are `Bale` objects; Courseplay keeps its own bale registry and filters with `object:isa(Bale)` [CP]. Vanilla AI can mow, ted, rake and bale as field work. There's no vanilla bale collection; Courseplay's `BALE_FINDER_CP` covers it [CP]. |
| 10 | Transport tasks? | **Partly.** `DELIVER`: drive to a loading point, wait until filled, drive to a station, discharge, optionally loop [src]. `LOAD_AND_DELIVER`: load at a loading station, then deliver [src]. `GOTO`: drive to a position and heading [src]. **There's no vanilla "unload the combine" job.** A vanilla AI combine that fills up parks with its pipe out and **waits until a trailer under the pipe has emptied it** (`AIDriveStrategyCombine`, `wasCompletelyFull`) [src]. Farm Agent uses that behaviour: GoTo under the pipe, then Deliver to the silo. |
| 11 | Courseplay / AutoDrive? | **Courseplay integrates cleanly.** It registers `FIELDWORK_CP`, `COMBINE_UNLOADER_CP`, `BALE_FINDER_CP`, `SILO_LOADER_CP` and `BUNKER_SILO_CP` through the same `aiJobTypeManager:registerJobType` [CP]. It also exposes vehicle functions such as `getIsCpActive`, `getCpFieldWorkProgress`, `getIsCpHarvesterWaitingForUnload`, `startCpCombineUnloaderUnloading` and `getCpCombineUnloaderJob` [CP]. One catch: **its unloader only serves Courseplay-driven combines** (`combineToUnload:getIsCpActive()`) [CP], so it's an all-or-nothing pipeline choice. AutoDrive isn't installed here, so its API is **unverified**. Courseplay can hand full trailers to AutoDrive or to the Giants unloader [CP]. |
| 12 | Impossible / hard? | See section F. |

**Verdict:** the core idea works on the public API. Farm Agent decides, and vanilla jobs do the
driving. Starting, stopping and observing workers is fully supported and typed. The hard parts
are measuring progress (solved by sampling), combine unloading (no vanilla job), and talking to
an LLM (no network, so a file bridge is used).

---

## B. Architecture

```
 PLAYER ── Alt+J text box / console "faCommand ..."
   │
   ▼
 ┌──────────────────────── FS25_FarmAgent (Lua, in game) ─────────────────────────┐
 │ FAIntent.parseControl   stop / pause / resume / status: ALWAYS local (player   │
 │                         authority never waits for the LLM)                     │
 │        │ anything else                                                         │
 │        ▼                                                                       │
 │ FABridge ── requests.json ───────────────►  companion (Python, outside game)   │
 │          ◄── commands.xml (JSON payload) ─  Claude + read-only tools:          │
 │          ── state.json (farm model) ──────►  get_farm_state ▸ submit_objective │
 │   (offline/timeout ⇒ FAIntent.parse fallback)  submit_tasks ▸ control ▸ reply  │
 │        │ objective {HARVEST_READY_FIELDS, crop, fieldIds} or task list         │
 │        ▼                                                                       │
 │ FAFieldScanner (samples FieldState) + FAFarmState (Farm State Model)           │
 │        ▼                                                                       │
 │ FABrain (rules + scoring: rank crops, multi-crop plans, autopilot rounds)      │
 │   └► FAPlanner (one crop view at a time) ──► task graph                        │
 │        ──► FAValidator (every task, on its crop's view, every source)          │
 │        ▼                                                                       │
 │ FATaskManager: 1 s supervision tick, binds queued fields to free combines,     │
 │                logistics loop per combine, stall detection, recovery ladder,   │
 │                independent completion check, escalation to the player          │
 │        ▼                                                                       │
 │ FAJobAdapter: ONLY writer. createJob / setValues / validate / startJob /       │
 │               stopJob for FIELDWORK, GOTO, DELIVER                             │
 │ FAGameAdapter: ONLY reader of game state                                       │
 │ FAHud: STATUS / PLAN / LOG panel (Alt+K)   FALog: concise decision log         │
 └────────────────────────────────────────────────────────────────────────────────┘
   │ vanilla AI jobs
   ▼
 FS25: AISystem, AI drive strategies, navigation, implements, triggers, unloading
```

**Layering rule:** only `FAGameAdapter` reads the game and only `FAJobAdapter` changes it.
Planner, validator, scanner logic, intent, JSON and geometry are pure Lua and are unit-tested
outside the game.

**Local vs cloud split, as you asked:** everything time-critical (vehicle control, the 1 s
monitor, stall detection, recovery and validation) runs in game with no LLM involved. Claude
only turns language into a structured objective or task list, using real state from tools.

### Task graph for "Harvest all ready wheat fields"

```
 H1 HARVEST_FIELD (field 12, Combine A) ─┐
 H2 HARVEST_FIELD (field 19, Combine B) ─┤
 H3 HARVEST_FIELD (field 31, queued)  ───┼──►  R REPORT (verified totals)
 L4 UNLOAD_COMBINE (A ◄ Fendt+trailer ► silo) ─┤
 L5 UNLOAD_COMBINE (B ◄ ...)            ───────┘
```

Each UNLOAD_COMBINE task runs this loop until its combine has no work left:

```
 IDLE ─combine full & stopped─► TO_COMBINE (vanilla GoTo, aligned under pipe end)
   ▲                                  │ arrived
   │                                  ▼
   ├──◄ TO_STANDBY (GoTo just outside the field) ◄─ trailer < 60% ─ LOADING (watch pipe trigger + fill)
   │                                                                  │ trailer ≥ 60% or field done
   └──◄─────────── verified by trailer fill drop ◄── DELIVERING (vanilla Deliver, non-looping)
```

### Recovery ladder (harvest)

1. **Stall:** the vehicle is "working" but moved less than 1 m in 45 s. Full tanks and rain
   pauses don't count.
2. **Diagnose and log:** fuel, damage, broken, AI job alive, field still standing (fresh scan),
   and any vehicle in a 15 m × 10 m box ahead.
3. **Attempt 1:** stop the worker and restart field work in place (`isDirectStart`).
4. **Attempt 2:** stop, back off 15 m with a vanilla GoTo, then restart.
5. **Otherwise:** escalate to the player, stop the worker, and wait for "resume".

**Never fake success.** When the AI reports "finished", the field is re-sampled. If more than
3 % is still standing, the worker is restarted, up to twice, and then the task escalates.
Deliveries count as done only when the trailer's fill level actually drops.

---

## C. API mapping

| Capability | FS25 API used | Evidence |
|---|---|---|
| Farm of the player | `g_localPlayer.farmId` | [src] `AISystem:consoleCommandAIStart` |
| Money | `g_farmManager:getFarmById(id):getBalance()` | [src] `AIJob:updateCost` |
| Owned fields | `g_fieldManager:getFields()`, `field.farmland.id`, `g_farmlandManager:getFarmlandOwner` | [call] / [src] |
| Field geometry | `field.polygonPoints` → `getWorldTranslation`, `field.posX/posZ`, `field.areaHa` | [src] `Field:load` |
| Crop at a point | `FieldState.new()`, `fieldState:update(x,z)`, `.isValid/.fruitTypeIndex/.growthState` | [src] / [call] `FieldManager` |
| Ready / cut / withered | `fruitType.minHarvestingGrowthState`, `maxHarvestingGrowthState`, `cutState`, `witheredState` | [src] `FruitTypeDesc` |
| Crop ↔ fill type | `g_fruitTypeManager:getFruitTypeByName/ByIndex/getFillTypeIndexByFruitTypeIndex`, `g_fillTypeManager:getFillTypeTitleByIndex` | [src] |
| Vehicles | `g_currentMission.vehicleSystem.vehicles`, `rootVehicle`, `getChildVehicles`, `spec_aiJobVehicle` | [src] |
| Combine and header | `spec_combine.fillUnitIndex`, `spec_cutter.fruitTypeIndices`, `getFillUnitSupportsFillType` | [src] `Cutter`, `Combine` |
| Fill levels | `getFillUnitFillLevel/Capacity/FillType` | [src] `FillUnit` |
| Fuel / damage / speed | `getConsumerFillUnitIndex`, `getFillUnitFillLevelPercentage`, `getDamageAmount`, `isBroken`, `getLastSpeed` | [src] |
| Can run job X | `job:getIsAvailableForVehicle(vehicle)` | [src] each `AIJob*` |
| Start field work | `createJob(FIELDWORK)`, `applyCurrentState`, `positionAngleParameter:setPosition/setAngle`, `setValues`, `validate`, `aiSystem:startJob` | [src] |
| Drive somewhere | `GOTO` + `driveToTask:setTargetOffset` (straight approach) | [src] `AIJobGoTo`, `AITaskDriveTo` |
| Deliver to silo | `DELIVER`, `unloadingStationParameter:setUnloadingStation`, `loopingParameter:setIsLooping(false)` | [src] `AIJobDeliver` |
| Stuck Deliver wait | `job:getCanSkipTask()`, `aiSystem:skipCurrentTask(job)` | [src] |
| Stop worker | `aiSystem:stopJob(job, AIMessageSuccessStoppedByUser.new())` | [src] |
| Why it stopped | `MessageType.AI_JOB_STOPPED`, `ClassUtil.getClassNameByObject(aiMessage)` | [src] |
| Worker limit | `aiSystem:getAILimitedReached()`, `g_currentMission.maxNumHirables` | [src] |
| Pipe / trailer under pipe | `combine:getCurrentDischargeNode().node`, `spec_pipe.nearestObjectInTriggers.objectId` → `NetworkUtil.getObject` | [src] `AIDriveStrategyCombine` |
| Final unload of a parked combine | `combine:setPipeState(2)` | [src] `AIDriveStrategyCombine` |
| Rain | `combine:getIsThreshingDuringRain()` | [src] `Combine` |
| Stations | `storageSystem:getUnloadingStations()`, `isa(UnloadingStation/SellingStation)`, `accessHandler:canPlayerAccess`, `getAITargetPositionAndDirection`, `getFreeCapacity`, `getName` | [src] `AIJobDeliver` |
| Blocker check | `worldToLocal(root.rootNode, x,y,z)` | scriptBinding.xml |
| HUD | `renderText`, `setTextColor/Bold/Alignment`, `drawFilledRect`, `RenderText.ALIGN_LEFT` | scriptBinding.xml / [call] |
| Text box | `TextInputDialog.show(cb, target, text, title, nil, maxChars, okText)` | [CP] |
| Hotkeys | modDesc `<actions>`, override `PlayerInputComponent.registerGlobalPlayerActionEvents`, `g_inputBinding:registerActionEvent` | [CP] `Courseplay:setupGui` |
| Console | `addConsoleCommand` / `removeConsoleCommand` | [CP] / [src] |
| Write files | `getUserProfileAppPath()`, `createFolder`, `io.open(path, "w")` (**write mode only**) | [CP] + confirmed in game log |
| Read files | `fileExists`, `loadXMLFile`, `getXMLString(xml, "farmAgent.payload")`, `delete(xml)`; reading with `io.open(..., "r")` is blocked by the FS25 sandbox | scriptBinding.xml + game log |
| Session id | `getDate("%Y%m%d%H%M%S")` | [call] |
| Notifications | `g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_*)` | [src] `AIJob:showNotification` |

---

## F. Known limitations

**From the FS25 API (cannot be fixed in the mod)**

- **No network from Lua.** The LLM is reached through files plus an external companion
  process. Latency is about 1 s of polling plus model time.
- **Sandboxed file I/O.** `io.open` only accepts mode `"w"`; the game logs
  `io.open, only write mode ('w') is allowed` otherwise. That broke the first build: the error
  happened during map loading and stalled the loading screen at 57 %. The mod now reads the
  companion's file through the engine XML API. The tests enforce the same `"w"`-only rule, and
  every game entry point (`loadMap`, `update`, `draw`, hotkeys) is wrapped so an error disables
  Farm Agent instead of blocking the game.
- **No reachability query.** Farm Agent only learns that a target is unreachable when a job
  fails with `AIMessageErrorNotReachable`.
- **No "percent harvested" for owned fields.** Progress is estimated by sampling about 80 points
  per field, which is coarse on very large or oddly shaped fields.
- **No vanilla combine-unloader job.** The rendezvous (GoTo under the pipe end) is Farm Agent's
  own composition of vanilla pieces. Its precision depends on the engine's drive-to accuracy,
  which hasn't been measured in game yet. Two automatic corrections are tried, then the player
  is asked.
- **Stripped source.** Some methods (`FieldState:update`, `Field:getId`, the `UnloadingStation`
  internals) are known only from call sites, so their exact edge-case behaviour is unverified.
- **Pipe side and trailer fill node** are read from live vehicle nodes. Exotic mod vehicles with
  non-standard discharge setups may not line up.

**Milestone 1 scope (deliberately left out)**

- Harvest only (any crop a combine header supports). No cultivate, seed, fertilize, grass,
  animals or selling.
- No economics, purchasing, refuelling or repair. If the in-game option *Helper buys fuel* is
  off, an out-of-fuel worker is escalated to you.
- Singleplayer or host only (`multiplayer supported="false"`).
- No persistent farm memory yet, and the plan isn't saved with the savegame. After a reload,
  give the command again.
- Courseplay isn't driven yet. Milestone 1 uses vanilla jobs only.
- Self-propelled combines are expected. Trailed harvesters should work, since the root vehicle
  runs the job, but are untested.
- One transport unit per combine. Extra trailers stay idle.

**Not yet verified in the real game**

The mod has been syntax-checked under Lua 5.1 and its logic simulated. Every point where it
touches the engine (job start, field sampling, rendezvous accuracy, the HUD and the input hook)
still needs an in-game test, which is the purpose of the Milestone 1 testing procedure.


---

## Milestone 2 additions

### API mapping (field work, pipe, memory, menu)

| Capability | FS25 API used | Evidence |
|---|---|---|
| Soil per point | `FieldState:update` → `groundType`, `sprayLevel`, `limeLevel`, `plowLevel` | [src] `FieldState.new`, `PlowMission` |
| Ground types | `FieldGroundType.PLOWED / CULTIVATED / SEEDBED / ROLLED_SEEDBED / STUBBLE_TILLAGE / GRASS / GRASS_CUT / SOWN` | [call] `FieldManager`, `MapOverlayGenerator` |
| Soil maxima | `g_currentMission.fieldGroundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL / PLOW_LEVEL / LIME_LEVEL)` + `Platform.gameplay.usePlowCounter / useLimeCounter` | [src] `FieldManager:loadMapData` |
| "Needs plowing / lime" | level 0 (what the game's own map overlay colours as needing it) | [src] `MapOverlayGenerator` |
| Planting season | `fruitType:getIsPlantableInPeriod(missionInfo.growthMode, environment.currentPeriod)` | [call] `SowingMachine`, `PlaceableVine` |
| Tools on a tractor | `spec_sowingMachine.seeds`, `spec_plow`, `spec_cultivator`, `spec_sprayer` + `getSprayerFillUnitIndex`, `getFillUnitSupportedFillTypes`, `getFillUnitLastValidFillType` | [src] |
| Choose the seed | `implement:setSeedFruitType(fruitTypeIndex)` (same as the seed-selection key) | [src] `SowingMachine` |
| Helper buys supplies | `missionInfo.helperBuySeeds / helperBuyFertilizer / helperBuyFuel` | [src] `SowingMachine`, `Sprayer:getExternalFill`, `Motorized` |
| Field work job | the same vanilla `FIELDWORK` job as harvesting; it runs every attached tool | [src] `AIJobFieldWork` |
| Pipe fully unfolded | `spec_pipe.targetState == 2 and spec_pipe.currentState == 2` (`setPipeState` sets `currentState = 0` while moving) | [src] `Pipe:setPipeState`, `Pipe:onUpdateTick` |
| Pipe end (combine-local) | `localToLocal(getCurrentDischargeNode().node, combine.rootNode)` | [src] |
| Vehicle footprint | `vehicle.size.width / length` | [src] `Vehicle:load`, `AIDrivable` |
| Slower final approach | `job.driveToTask.maxSpeed` (field read by `AITaskDriveTo:onTargetReached`) | [src] |
| Stable vehicle id (memory) | `vehicle:getUniqueId()` | [src] |
| Menu | `OptionDialog.show(callback(item), title, text, options)` | [call] `ConsumableActivatable`, [CP] |
| Read files | `loadXMLFile` / `getXMLString` (io read mode is blocked) | game log + scriptBinding.xml |

### Automatic tool change (hitching): analysis

You asked for this: a free tractor driving to a free trailer or tool and coupling it.

- **The hitch itself is possible**, using the same path a player uses:
  `AttacherJoints.updateVehiclesInAttachRange(vehicle, maxDistanceSq, maxAngle)` finds a tool
  in attach range, then `vehicle:attachImplementFromInfo(info)` attaches it.
  `detachImplementByObject` unhitches [src].
- **Getting into range is the hard part.** Attach range is about a metre at the right angle.
  The vanilla drive-to task approaches *forwards* to a pose. The tractor's hitch is at the
  rear, so it would have to reverse the last few metres, and vanilla GoTo has no precise
  reversing manoeuvre.
- **Options for the next milestone:**
  1. **Assisted hitch (recommended first):** Farm Agent parks the tractor 3–5 m in front of the
     tool, aligned. When the tool is within a small radius (configurable, e.g. 4 m) it calls
     the vanilla attach with that info, like a quick-hitch. The tool may jump slightly; that is
     a gameplay cheat the player opts into.
  2. **Own reversing controller:** Farm Agent steers the last few metres itself. Possible,
     but it's exactly the low-level driving this design avoids.
  3. **Player in the loop:** Farm Agent says which tractor and tool to couple and where. You
     hitch, and it carries on automatically.
- Once hitching exists, the brain can match work to *uncoupled* tools as well, for example:
  "field 3 needs cultivating; the cultivator is in the yard; Fendt is free → couple, work,
  park, uncouple".

### Roadmap: what else can be automated

| Next | What | Feasibility |
|---|---|---|
| Sell / store decisions | Deliver to the best-paying sell point instead of the silo (station prices, distance). | Station + price APIs exist; the Deliver job already supports any unloading station. |
| Silo-to-market hauling | Vanilla **LOAD_AND_DELIVER** job: load at your silo, sell at a station. | Vanilla job type, same adapter pattern. |
| Grass chain | Mow → ted → windrow → bale (all vanilla field work), then collect bales with Courseplay's `BALE_FINDER_CP`. | Mow/ted/rake/bale = FIELDWORK; bale collection needs Courseplay. |
| Mulch / roll / weed | Mulcher, roller, weeder as further operations (stubble shred level, roller level, weed state). | Same pattern as cultivate. |
| Herbicide | Sprayer with herbicide when `weedState > 0`. | Needs weed-state semantics verified first. |
| Rain-aware harvesting | Prioritise fields that finish before rain (weather forecast). | Weather object in `g_currentMission.environment.weather`. |
| Refuel / repair runs | Send a low-fuel or damaged machine to the farm when idle. | GoTo exists; refuelling itself = "helper buys fuel" or a station. |
| Crop choice | Pick the crop to plant by expected profit (price × yield − inputs, season). | Needs the economy layer (Milestone 3). |
| Animals | Feed / straw / water checks with alerts first, transport later. | Husbandry specs are readable; automated feeding needs tool + trigger work. |
| Courseplay mode | Optional: drive harvest + unloading with Courseplay jobs when installed (better unloading than the vanilla pipe rendezvous). | Courseplay registers its jobs in the same job system [CP]. |

### Milestone 2 limitations

- One machine per field at a time. Lime then plow then seed on the same field happen in
  successive rounds (autopilot / repeated commands), not at the same time.
- A rig's operation comes from its tools: seeder present → it only plants (a
  cultivator+seeder combo is not used just to cultivate); a spreader that holds lime → lime.
- Manure and slurry spreaders count as fertilizing; their refilling depends on the game's
  manure / slurry source settings.
- No hitching or unhitching yet (see above). Tools must already be attached.
- Replanting without a remembered harvest uses the farm's main crop that can be sown now
  (Milestone 3).
- Still unproven in the real game: rendezvous precision with the new geometry, how
  `getIsPlantableInPeriod` and field ground types read on your map, and the menu dialog.

## Milestone 3 additions

### Parking after work
The vanilla AI worker leaves its machine where the job ended. `FATaskManager` now runs a
parking step every tick, including when no objective is running:

- **Trigger.** A field or logistics task ends as DONE or FAILED. CANCELLED (the player) does
  not trigger it. Only machines Farm Agent drove in this session (`movedByAgent`) are moved.
- **Grace period.** There are 5 s for new work to claim the machine. A request is dropped when
  a task reserves the machine, when the player drives it, when another worker is running on
  it, or when it already stands outside every owned field.
- **Combines.** A combine with grain waits, up to 15 min, while a logistics task still serves
  it. That includes while it is reserved for its final unload. The pipe is folded
  (`setPipeState(1)`, the same call the vanilla AI uses) before it drives off.
- **Target.** The first choice is the machine's home: the spot outside the fields where it
  stood when Farm Agent first started a job on it. Home is stored per `uniqueId` in the farm
  memory and is updated whenever the player has moved the machine since. The fallback is
  `FAGeometry.getStandbyPoint` at 25, 45 or 70 m outside the field edge. That point must not
  lie inside another owned field or within 12 m of another park target. If home cannot be
  reached, the machine falls back to the field edge.
- **Execution.** A vanilla GoTo, with the AI worker limit respected. A machine that is being
  parked counts as free in the farm state. Any job start (`noteJobStart`) first cancels its
  park drive, and the stop is unregistered before `stopJob`, because the stop event is
  synchronous. A park drive is abandoned after 10 min. "Stop everything" also cancels parking.
- **Avoiding collisions.** Field work on a field waits while a machine that is still to be
  parked stands inside it.

### Autopilot loop
`FarmAgent:onWorkFreed()` runs whenever a task ends or a park drive ends. It moves the next
autopilot round to 2 s later. Each round plans every free machine and every untouched field
independently. Plowing is planned only when a plow rig is free and plowing is enabled;
otherwise the field is cultivated. Fertilizing and liming are player settings stored in the
farm memory.

### Milestone 3 limitations
- The home spot is wherever the machine stood. If that is on a road, it parks on the road.
  Move it to a yard once, and Farm Agent remembers the new spot.
- The field-edge fallback is a point on the far side of the nearest edge. It can be in a
  hedge or a ditch, in which case the GoTo fails and the machine stays put (logged).
- Vanilla GoTo pathfinding with wide implements on narrow roads is untested.
