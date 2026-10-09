# Farm Agent: Milestone 3

An experimental FS25 mod that turns goals into supervised work by the game's own AI workers.
**Farm Agent is the brain; FS25's AI workers are the hands.** It never steers a vehicle: it
starts and stops vanilla FIELDWORK / GoTo / Deliver jobs, watches them, measures the fields
itself, and asks you when it can't fix something.

There's no AI model inside the game. `FABrain` is a rule-and-scoring decision maker; it's
deterministic, needs no internet, and writes every decision to the LOG panel with its reason.
Claude (optional companion) only translates free-form text into the same commands.

## What it can do (Alt+J opens the menu)

| Menu button / command | What happens |
|---|---|
| **Harvest all ready crops** / `harvest the wheat` / `harvest field 12` | Ranks ready crops (ready area; a crop about to wither goes first). Each combine gets fields its header can cut. Tractor+trailer units unload under the pipe and deliver to your silo. |
| **Prepare harvested fields** / `prepare fields` / `plow` / `cultivate` | For stubble fields: **plow** where the plow counter asks for it, otherwise **cultivate**. Uses tractors with a plow or cultivator attached. |
| **Plant a crop...** / `plant wheat` / `plant barley on field 3` | Sows prepared fields. The list only offers crops in season that one of your seeders can sow. |
| **Replant the last crop** / `plant` | Sows each prepared field with the crop Farm Agent last harvested there (farm memory). |
| **Fertilize growing crops** / `fertilize` | Sprayers or spreaders on growing crops below max fertilizer. |
| **Spread lime where needed** / `lime` | Lime spreaders on fields whose lime level is 0. |
| **Do all field work the farm needs now** / `do all field work` | Harvest, fertilize, lime, plow/cultivate and plant, one machine per field at a time. |
| **Autopilot** / `take care of the farm` | An endless loop: every 30 s, and 2 s after any machine becomes free, every idle machine gets the most useful job it can do **now** (all of the above). Fields are handled independently, so field 2 is planted while field 1 is still being harvested. A worker you stopped is taken back once you've left that vehicle for 60 s. |
| **Auto fertilizing: ON/OFF**, **Auto liming: ON/OFF** | Skip fertilizing or liming in "all field work" and the autopilot. Stubble that only needed lime is simply cultivated. Saved per savegame. |
| **Autopilot planting: <crop> / Replant / OFF** | What the autopilot sows. Replant = the field's last crop. If that crop is out of season, or unknown, it uses the farm's main crop that can be sown now. |
| **Pause / Stop everything / Type a command...** | As before. Alt+L pauses, or hands back work that's waiting on you. |

New commands are **added** next to running work, using only idle machines and untouched
fields. "Stop everything" clears the board.

What Farm Agent checks before any job: the right tool for the job, a seeder that can sow the
crop, the planting season, supplies (empty seeder or sprayer → only if the game's "helper buys
seeds / fertilizer" setting is on), never tilling grassland, and never a vehicle you're
**driving** (sitting in a parked one is fine).

Every job is verified by re-sampling the field: harvested ≤ 3 % standing; other jobs ≤ 5 %
left (cultivated, plowed, sown, fertilized, limed).

### New in Milestone 3

| You asked for | What it does now |
|---|---|
| Machines left on the field block the next worker | After a job ends (done or failed), Farm Agent waits 5 s, in case new work takes the machine, then drives it with a vanilla GoTo **back to where you had parked it** before Farm Agent first used it. If there's no such spot, or it can't be reached, it parks just **outside the field**, never inside another field. A combine waits for its trailer to take the last grain, and folds its pipe first. New field work on that field waits until the machine has left. Farm Agent only moves machines it drove itself. |
| Skip fertilizing / liming | Menu toggles (see above). |
| Endless autopilot, not "in order" | Each round looks at every free machine and every field separately (busy fields and machines are skipped), and re-runs as soon as something becomes free. |
| Check what can be done now (seasons on or off) | Planting uses the game's own season check (`getIsPlantableInPeriod` with the savegame's growth mode, the same call the vanilla seeder makes). With seasons off everything is plantable, so nothing is blocked. Seeders that may plant outside the season are honoured. |
| No free plow → cultivate | Plowing is only planned when a plow rig is free right now; otherwise the stubble is cultivated. The same applies when plowing is switched off. |

### Fixes from the first in-game test

| You saw | Cause | Fix |
|---|---|---|
| Tractor rams the combine | Target computed while the pipe was still unfolding (pipe end next to the body) | Waits for the pipe to be **fully** unfolded. Learns each combine's pipe position once and remembers it. Checks clearance to body **and header** and shifts the trailer out if needed. Slow (5 km/h) straight final approach. |
| Endless "has not moved for 90 s" | Stall counter reset on every retry | Counts across retries and escalates on the 2nd stall. Every unloading leg also has a deadline. |
| Long wait when the tank had too little grain | LOADING only ended once loading had started | Ends at once when nothing is left to load, or when the combine drives on. |
| Combine sent to the next field mid-unload | Combine wasn't reserved while being unloaded | The combine belongs to its trailer until the unload is over. A combine with another crop in its tank is never given a different crop. |
| Trailer far away when the combine fills up | — | At 70 % tank the trailer moves to the field edge. |

Design details, the full API mapping and limitations are in [docs/FEASIBILITY.md](docs/FEASIBILITY.md).

```
FarmAgent/
  FS25_FarmAgent/         the mod (zip this folder's contents)
    modDesc.xml
    scripts/FarmAgentLoader.lua  entry point
    scripts/FarmAgent.lua        wiring: input, console, objective -> plan -> execute
    scripts/state/               FAGameAdapter (only game reader), FAFieldScanner (crop + soil), FAFarmState, FAMemory
    scripts/plan/                FAIntent, FAPlanner, FABrain (built-in brain), FALogistics (pipe geometry), FAValidator (pure Lua)
    scripts/exec/                FAJobAdapter (only game writer), FATaskManager (supervisor)
    scripts/bridge/FABridge.lua  file link to the Claude companion
    scripts/ui/FAHud.lua         in-game panel
  companion/              Claude companion (Python)
  tests/                  Lua 5.1 + Python tests (no game needed)
  tools/build.py          builds dist/FS25_FarmAgent.zip, optional --install
```

---

## E. Install and test

### 1. Build and install the mod

```bash
python tools/build.py --install
```

This writes `dist/FS25_FarmAgent.zip` and copies it to
`Documents\My Games\FarmingSimulator2025\mods\`. Without `--install`, copy the zip there
yourself. Don't unzip it.

### 2. (Recommended) Enable the developer console

In `Documents\My Games\FarmingSimulator2025\game.xml`, change
`<controls>false</controls>` to `<controls>true</controls>` inside `<development>`. The console
key (left of `1`) then accepts the `fa*` commands below, and errors show up live.

### 3. Prepare a test savegame

Use a career save on a map you know, or a new one. You need:

- At least one **owned** field with **wheat ready to harvest**. On a new save, the cheat-free
  way is to wait for harvest season. For a quick test, any owned field with a ripe crop works.
- A **combine with a wheat-capable header attached**, parked anywhere.
- *(For the transport test)* a **tractor with a grain trailer attached**, AI-capable (any
  standard tractor).
- A silo or sell point that accepts wheat. The farm silo is preferred.
- *Settings → Game Settings*: AI worker limit of at least 2, and *Helper buys fuel* on (your
  savegame1 already has it).

Enable **Farm Agent (Milestone 1)** in the mod list when loading the save.

### 4. Smoke test (no AI work started)

1. After loading, the game log (`log.txt`) should contain
   `[FarmAgent] ... Farm Agent Milestone 1 loaded.`
2. You should see the **FARM AGENT** panel at the top left. **Alt+K** cycles
   STATUS → PLAN → LOG → hidden.
3. Console: `faScan`. The console/log prints every owned field (crop, state, ready %, sample
   count) and your combines and transport units, with `fieldwork=true/false` etc.
   **Send me this output.** It is the first real check of the field and vehicle adapters.

### 5. Harvest test (local parser, no Claude)

1. Press **Alt+J** and type `Harvest all ready wheat fields`, then OK.
   (Or console: `faCommand harvest all ready wheat fields`.)
2. Expected in the LOG view (Alt+K twice):
   - `Scanning N owned field(s) for Wheat.`
   - Decisions: `Field 12: Wheat 96% ready (8.4 ha) -> <combine> (420 m away).`
   - `Started AI worker: <combine> -> harvest field 12.`
3. The combine's helper drives to the field edge nearest it and starts harvesting. The STATUS
   view shows a progress bar that updates about every 20 s.
4. **Tank full:** the combine stops with its pipe out (vanilla behaviour).
   - With a transport unit, the log shows `Sending <tractor> under the pipe of <combine>`, then
     `arrived`, then `<combine> is unloading into <tractor>`. After that the trailer either
     moves off the crop or goes to deliver.
   - Without a transport unit, an ATTENTION line asks you to unload it.
5. **Completion:** `AI worker reports field 12 finished; verifying.`, then
   `Field 12 harvested (verified, 1% left standing).`, then the final unload and delivery, then
   `Objective complete: ...`.

### 6. Recovery and override tests

| Test | How | Expected |
|---|---|---|
| Player override | Stop the combine's helper yourself (H key / AI menu) | Task shows `PAUSED_BY_PLAYER`; Farm Agent does **not** restart it. Alt+J `resume` hands it back. |
| Stall | Park another vehicle right in front of the working combine | After ~45 s: `Investigating`, `Checks: ... blocked by <vehicle>`, `Recovery attempt 1/2`. After 2 failures: ATTENTION + escalation. |
| Pause | Alt+L | `[PAUSED]` in the header. Running workers continue, nothing new starts. Alt+L again resumes. |
| Stop all | Alt+End, or type `stop everything` | Every Farm Agent worker stops; tasks `CANCELLED`. |
| Rain | Harvest when rain starts | `WAITING_RAIN` / `WAITING_WEATHER`, resumes when dry. |

### 7. With Claude (optional)

```bash
pip install -r companion/requirements.txt
```

```bash
python companion/farm_agent_companion.py
```

Credentials come from `ANTHROPIC_API_KEY` or an `ant auth login` profile. The companion uses
`claude-opus-5-5` with server-side refusal fallback (`fallbacks: "default"`) enabled.

- Start it before or after the game. The panel shows `Claude: connected`.
- Alt+J now goes to Claude, which reads the published farm state with a tool, then submits a
  structured objective or task list. Try `Harvest the corn`, `harvest field 12 only`,
  `harvest wheat but use only the Case combine`, or `make me money` (should reply that only
  harvesting is supported).
- Stop, pause and resume are always handled in game, even with Claude connected.
- If the companion is offline or doesn't answer within 90 s, the in-game parser takes over.
- Try the translation without the game:

```bash
python companion/farm_agent_companion.py --dry-run "Harvest all ready wheat fields"
```

Bridge files live in `Documents\My Games\FarmingSimulator2025\modSettings\FS25_FarmAgent\`.
`state.json` is the Farm State Model; open it to see exactly what Claude sees.

### 8. What to send back after testing

- `log.txt` lines containing `[FarmAgent]`, plus any Lua errors around them.
- The `faScan` output.
- `modSettings/FS25_FarmAgent/state.json` from mid-harvest.
- Whether the trailer got under the pipe on the first try, or how far off it was.

---

## Running the tests (no game needed)

```bash
pip install lupa anthropic
```

```bash
python tests/run_tests.py
```

```bash
python tests/test_companion.py
```

`run_tests.py` syntax-checks every mod file under **Lua 5.1** and runs unit tests: JSON,
geometry, intent, scanner, planner, validator and bridge. It also runs a simulated world for
the task manager covering harvest verification, the stall → restart → reposition → escalate
ladder, player override, full-tank waits, the full unload/standby/deliver loop and pipe
correction.

It also runs a **headless boot**: the real `FarmAgentLoader.lua` runs against a fake engine
built only from the documented API names. The test loads the mod, runs `faScan`, sends
Alt+J "Harvest all ready wheat fields", starts field work, sends the trailer under the pipe,
delivers, verifies, and stops everything. That catches wiring bugs, but it can't prove the
real engine behaves like the fake.

`test_companion.py` exercises the Claude tool loop with a fake client (no API calls) and
checks that the real Lua bridge decodes what the companion writes.
