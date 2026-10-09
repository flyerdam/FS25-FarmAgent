"""Farm Agent companion: Claude as the language/strategy layer for the FS25_FarmAgent mod.

The mod cannot make network calls, so it exchanges files with this process:

    state.json     mod -> companion   farm state model, tasks, decision log
    requests.json  mod -> companion   what the player typed (Alt+J), tagged with a game session id
    commands.xml   companion -> mod   heartbeat + structured commands, as JSON inside
                                      <farmAgent><payload>...</payload></farmAgent>

commands.xml is XML because FS25 only lets mods open files with io in write mode; the mod
reads it through the engine's XML API.

Claude reads farm state through read-only tools and answers with exactly one structured
command. It never sends code; the in-game validator checks every command against live
game state before anything moves.

    pip install -r requirements.txt
    python farm_agent_companion.py                 # run alongside the game
    python farm_agent_companion.py --dry-run "Harvest all ready wheat fields"
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import pathlib
import sys
import time
import xml.etree.ElementTree as ET
from typing import Any, Callable

import anthropic

MODEL = "claude-opus-5-5"
FALLBACK_BETA = "server-side-fallback-2026-07-01"
MAX_TOOL_ROUNDS = 8
HEARTBEAT_SECONDS = 2.0
POLL_SECONDS = 1.0
KEEP_COMMANDS = 50

log = logging.getLogger("farm_agent")


def default_bridge_dir() -> pathlib.Path:
    """modSettings/FS25_FarmAgent under the FS25 profile (handles OneDrive-redirected Documents)."""
    candidates = [
        pathlib.Path.home() / "Documents" / "My Games" / "FarmingSimulator2025",
        pathlib.Path.home() / "OneDrive" / "Documents" / "My Games" / "FarmingSimulator2025",
    ]
    for profile in candidates:
        if profile.exists():
            return profile / "modSettings" / "FS25_FarmAgent"
    return candidates[0] / "modSettings" / "FS25_FarmAgent"


# --------------------------------------------------------------------------------------
# Bridge files
# --------------------------------------------------------------------------------------

class Bridge:
    def __init__(self, directory: pathlib.Path):
        self.dir = directory
        self.dir.mkdir(parents=True, exist_ok=True)
        data = self.read_commands()
        self.commands: list[dict] = list(data.get("commands") or [])
        self.heartbeat: int = int(data.get("heartbeat") or 0)
        # Command ids must keep increasing across companion restarts: the mod ignores ids
        # it has already seen.
        self.next_id = max([c.get("id", 0) for c in self.commands] + [0]) + 1
        companion_state = self.read_json("companion_state.json") or {}
        # Request ids restart every game session, so they are tracked as "session:id".
        self.processed: set[str] = set(companion_state.get("processedRequests") or [])

    def read_json(self, name: str) -> Any:
        path = self.dir / name
        for _ in range(3):
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                return None
            except (json.JSONDecodeError, UnicodeDecodeError):
                time.sleep(0.1)  # the game may be mid-write
        return None

    def write_json(self, name: str, data: Any) -> None:
        path = self.dir / name
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)  # atomic, so the mod never reads half a file

    def read_commands(self) -> dict:
        try:
            root = ET.parse(self.dir / "commands.xml").getroot()
            return json.loads(root.findtext("payload") or "{}")
        except (FileNotFoundError, ET.ParseError, json.JSONDecodeError):
            return {}

    def flush_commands(self) -> None:
        payload = json.dumps({"heartbeat": self.heartbeat, "commands": self.commands[-KEEP_COMMANDS:]}, ensure_ascii=False)
        root = ET.Element("farmAgent")
        ET.SubElement(root, "payload").text = payload
        path = self.dir / "commands.xml"
        tmp = path.with_suffix(".tmp")
        ET.ElementTree(root).write(tmp, encoding="utf-8", xml_declaration=True)
        os.replace(tmp, path)  # atomic, so the game never reads half a file

    def beat(self) -> None:
        self.heartbeat += 1
        self.flush_commands()

    def send(self, command: dict) -> dict:
        command = {"id": self.next_id, **command}
        self.next_id += 1
        self.commands.append(command)
        self.flush_commands()
        return command

    def mark_processed(self, request: dict) -> None:
        self.processed.add(f"{request.get('session')}:{request.get('id')}")
        self.write_json("companion_state.json", {"processedRequests": sorted(self.processed)[-200:]})

    def pending_requests(self) -> list[dict]:
        data = self.read_json("requests.json") or {}
        session = data.get("session")
        pending = []
        for r in data.get("requests") or []:
            r = {**r, "session": session}
            if f"{session}:{r.get('id')}" in self.processed:
                continue
            if r.get("status") == "SENT":
                pending.append(r)
            else:
                # Answered elsewhere or timed out to the in-game parser: never act on it late.
                self.mark_processed(r)
        return pending

    def state(self) -> dict:
        return self.read_json("state.json") or {}


# --------------------------------------------------------------------------------------
# Tools Claude can use
# --------------------------------------------------------------------------------------

def nullable(schema: dict) -> dict:
    return {"anyOf": [schema, {"type": "null"}]}


SAY = {"type": "string", "description": "One short sentence shown to the player in game."}

TOOLS: list[dict] = [
    {
        "name": "get_farm_state",
        "description": (
            "Current farm state from the game: owned fields (id, crop, state, readyFraction = share of the field "
            "that is harvestable), vehicles (combines with the crops their header can cut, tractor+trailer units, "
            "fuel, whether an AI worker is active), unloading stations, running Farm Agent tasks and items needing "
            "the player's attention. Call this before deciding anything that depends on the farm."
        ),
        "input_schema": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        "strict": True,
    },
    {
        "name": "submit_objective",
        "description": (
            "Hand Farm Agent a harvest objective; it scans fields, assigns combines and trailers, and runs vanilla "
            "AI workers. crop = FS25 fruit type name (WHEAT, BARLEY, OAT, CANOLA, MAIZE, SUNFLOWER, SOYBEAN, SORGHUM, "
            "RICE...), \"ALL\" for every ready crop (Farm Agent's built-in brain ranks crops and matches combines "
            "to fields their header can cut), or null when field_ids are given and the crop should be whatever is "
            "ready there. field_ids = null for all ready fields."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "crop": nullable({"type": "string"}),
                "field_ids": nullable({"type": "array", "items": {"type": "integer"}}),
                "say": SAY,
            },
            "required": ["crop", "field_ids", "say"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "submit_field_work",
        "description": (
            "Hand Farm Agent tool work, run by vanilla AI workers on tractors with the matching tool attached. "
            "op: CULTIVATE, PLOW, PREPARE (plow where the plow counter needs it, else cultivate), SEED (crop = FS25 "
            "fruit name, or \"REPLANT\" = the crop last harvested on each field), FERTILIZE, LIME, or ALL (everything "
            "the farm needs now, including harvests). field_ids = null for every field that needs it. Planting is "
            "only possible for crops in season; Farm Agent checks seeders, supplies and season itself."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "op": {"type": "string", "enum": ["CULTIVATE", "PLOW", "PREPARE", "SEED", "FERTILIZE", "LIME", "ALL"]},
                "crop": nullable({"type": "string"}),
                "field_ids": nullable({"type": "array", "items": {"type": "integer"}}),
                "say": SAY,
            },
            "required": ["op", "crop", "field_ids", "say"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "submit_tasks",
        "description": (
            "Hand Farm Agent an explicit task list instead of letting it plan, e.g. when the player restricts which "
            "machines to use. HARVEST_FIELD needs field_id and vehicle_id (a combine). UNLOAD_COMBINE needs "
            "combine_id, vehicle_id (tractor with trailer) and station_id. Use only ids from get_farm_state; every "
            "task is validated in game and invalid ones are dropped."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "crop": {"type": "string"},
                "tasks": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "action": {"type": "string", "enum": ["HARVEST_FIELD", "UNLOAD_COMBINE"]},
                            "field_id": nullable({"type": "integer"}),
                            "vehicle_id": nullable({"type": "integer"}),
                            "combine_id": nullable({"type": "integer"}),
                            "station_id": nullable({"type": "integer"}),
                        },
                        "required": ["action", "field_id", "vehicle_id", "combine_id", "station_id"],
                        "additionalProperties": False,
                    },
                },
                "say": SAY,
            },
            "required": ["crop", "tasks", "say"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "control",
        "description": (
            "Stop all agent work, pause dispatching, resume (also retries escalated tasks), report status, or switch "
            "the autopilot on/off. Autopilot = 'take care of the farm': every minute idle combines get the best ready "
            "field they can harvest, and workers the player stopped are taken back after the player has left them."
        ),
        "input_schema": {
            "type": "object",
            "properties": {"op": {"type": "string", "enum": ["STOP_ALL", "PAUSE", "RESUME", "STATUS", "AUTOPILOT_ON", "AUTOPILOT_OFF"]}, "say": SAY},
            "required": ["op", "say"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "reply",
        "description": "Answer the player without starting work: questions about the farm, or requests Milestone 1 cannot do.",
        "input_schema": {
            "type": "object",
            "properties": {"say": SAY},
            "required": ["say"],
            "additionalProperties": False,
        },
        "strict": True,
    },
]

TERMINAL_TOOLS = {"submit_objective", "submit_field_work", "submit_tasks", "control", "reply"}

SYSTEM_PROMPT = """You are the language and planning front-end of Farm Agent, an AI farm manager mod for Farming Simulator 25.

The player types a request in game. Turn it into exactly one Farm Agent command by calling one of: submit_objective, submit_tasks, control, reply. Farm Agent's in-game executor then plans, validates and supervises the game's own AI workers; you never drive vehicles or write code.

What Farm Agent can do in this milestone:
- Harvest: all ready fields of one crop, every ready crop (crop "ALL"), or specific fields, with combines plus tractor+trailer transport to a silo or sell point.
- Field work with tools already attached to tractors (submit_field_work): cultivate, plow, prepare (plow or cultivate as needed), plant a crop (or replant the last crop), fertilize, lime, or ALL field work the farm needs.
- Autopilot ("take care of the farm", "keep the combines busy"): control AUTOPILOT_ON / AUTOPILOT_OFF. It harvests, prepares, plants (replant) and fertilizes as fields need it.
- Control: stop all agent work, pause, resume (retries tasks waiting for the player), status.
New work is added next to running work. Not available yet: selling, buying, attaching tools, mowing/grass, bales, animals, money targets - for those, call reply and say what is supported, briefly.

Ground every decision in get_farm_state; never invent field, vehicle or station ids. If the request names a crop, check that some owned field actually has it ready; if none does, use reply to say so instead of submitting. Prefer submit_objective; use submit_tasks only when the player restricts which machines or fields to use in a way an objective cannot express. Keep "say" to one short sentence."""


def summarize_state(state: dict) -> dict:
    """Compact view of state.json for the model (drops the raw log)."""
    farm = state.get("farm") or {}
    return {
        "phase": state.get("phase"),
        "goal": state.get("goal"),
        "paused": state.get("paused"),
        "autopilot": state.get("autopilot"),
        "objectiveStatus": state.get("objectiveStatus"),
        "gameTime": state.get("gameTime"),
        "money": farm.get("money"),
        "fields": [
            {k: f.get(k) for k in ("id", "name", "areaHa", "crop", "state", "readyFraction", "readyByCrop", "urgent", "soil", "lastCrop")}
            for f in farm.get("fields") or []
        ],
        "vehicles": [
            {k: v.get(k) for k in ("id", "name", "kind", "aiActive", "isEntered", "fuel", "damage", "combine", "trailers", "ops", "tools", "canFieldWork")}
            for v in farm.get("vehicles") or []
            if v.get("kind") in ("COMBINE", "TRANSPORT", "TOOL")
        ],
        "plantableNow": sorted((farm.get("plantable") or {}).keys()),
        "helperBuys": farm.get("helpers"),
        "stations": farm.get("stations") or [],
        "tasks": state.get("tasks") or [],
        "attention": state.get("attention") or [],
        "aiWorkers": farm.get("ai"),
        "note": "fields/vehicles were refreshed by the game within the last minute; empty lists mean the game has not published a scan yet.",
    }


def to_command(name: str, args: dict) -> dict:
    """Maps a terminal tool call to the mod's command format (see FarmAgent:onBridgeCommand)."""
    say = str(args.get("say") or "")
    if name == "submit_objective":
        crop = args.get("crop")
        field_ids = args.get("field_ids")
        if crop is None and not field_ids:
            raise ValueError("submit_objective needs a crop or field_ids")
        return {"type": "objective", "say": say, "objective": {
            "type": "HARVEST_READY_FIELDS",
            "crop": crop.upper() if isinstance(crop, str) else None,
            "fieldIds": [int(i) for i in field_ids] if field_ids else None,
        }}
    if name == "submit_field_work":
        op = args["op"]
        field_ids = args.get("field_ids")
        if op == "ALL":
            return {"type": "objective", "say": say, "objective": {"type": "FARM_WORK"}}
        crop = args.get("crop")
        if op == "SEED" and not crop:
            crop = "REPLANT"
        return {"type": "objective", "say": say, "objective": {
            "type": "FIELD_WORK", "op": op,
            "crop": crop.upper() if isinstance(crop, str) else None,
            "fieldIds": [int(i) for i in field_ids] if field_ids else None,
        }}
    if name == "submit_tasks":
        tasks = []
        for t in args.get("tasks") or []:
            tasks.append({
                "action": t["action"],
                "fieldId": t.get("field_id"),
                "vehicleId": t.get("vehicle_id"),
                "combineId": t.get("combine_id"),
                "stationId": t.get("station_id"),
            })
        if not tasks:
            raise ValueError("submit_tasks needs at least one task")
        return {"type": "tasks", "say": say, "tasks": tasks,
                "objective": {"type": "HARVEST_READY_FIELDS", "crop": str(args["crop"]).upper(), "fieldIds": None}}
    if name == "control":
        return {"type": "control", "op": args["op"], "say": say}
    if name == "reply":
        return {"type": "reply", "say": say}
    raise ValueError(f"unknown tool {name}")


# --------------------------------------------------------------------------------------
# Claude loop
# --------------------------------------------------------------------------------------

class Translator:
    def __init__(self, client: anthropic.Anthropic, model: str, effort: str):
        self.client = client
        self.model = model
        self.effort = effort

    def translate(self, text: str, get_state: Callable[[], dict]) -> dict:
        messages: list[dict] = [{"role": "user", "content": f"Player request: {text}"}]
        for _ in range(MAX_TOOL_ROUNDS):
            response = self.client.beta.messages.create(
                model=self.model,
                max_tokens=16000,
                system=SYSTEM_PROMPT,
                tools=TOOLS,
                messages=messages,
                output_config={"effort": self.effort},
                betas=[FALLBACK_BETA],
                fallbacks="default",
            )
            if response.stop_reason == "refusal":
                return {"type": "reply", "say": "I can't help with that request."}

            tool_uses = [b for b in response.content if b.type == "tool_use"]
            tool_results = []
            for block in tool_uses:
                if block.name in TERMINAL_TOOLS:
                    try:
                        # First valid terminal call ends the conversation; nothing is sent back.
                        return to_command(block.name, dict(block.input))
                    except (KeyError, ValueError, TypeError) as exc:
                        log.warning("Invalid %s input %s: %s", block.name, block.input, exc)
                        tool_results.append({"type": "tool_result", "tool_use_id": block.id, "is_error": True,
                                             "content": f"Invalid input: {exc}. Call the tool again with valid input."})
                elif block.name == "get_farm_state":
                    content = json.dumps(summarize_state(get_state()))
                    tool_results.append({"type": "tool_result", "tool_use_id": block.id, "content": content})
                else:
                    tool_results.append({"type": "tool_result", "tool_use_id": block.id, "is_error": True,
                                         "content": f"Unknown tool {block.name}"})

            if not tool_uses:
                if response.stop_reason == "max_tokens":
                    return {"type": "reply", "say": "Sorry, I could not finish thinking about that - please rephrase."}
                text_out = " ".join(b.text for b in response.content if b.type == "text").strip()
                return {"type": "reply", "say": text_out or "I'm not sure what to do with that."}

            messages.append({"role": "assistant", "content": response.content})
            messages.append({"role": "user", "content": tool_results})
        return {"type": "reply", "say": "I could not settle on a plan for that request."}


# --------------------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------------------

def handle_request(bridge: Bridge, translate: Callable[[str, Callable[[], dict]], dict], request: dict) -> dict:
    request_id = request["id"]
    log.info("Request #%s: %s", request_id, request["text"])
    try:
        command = translate(request["text"], bridge.state)
    except anthropic.APIConnectionError:
        log.error("Network error talking to Claude; the game will fall back to its local parser.")
        command = {"type": "reply", "say": "Claude is unreachable right now; using the local parser."}
    except anthropic.RateLimitError:
        log.error("Rate limited; the game will fall back to its local parser.")
        command = {"type": "reply", "say": "Claude is rate limited right now; try again in a minute."}
    except anthropic.APIStatusError as exc:
        log.error("Claude API error %s: %s", exc.status_code, exc.message)
        command = {"type": "reply", "say": f"Claude API error ({exc.status_code})."}
    sent = bridge.send({"requestId": request_id, "session": request.get("session"), **command})
    bridge.mark_processed(request)
    log.info("-> command #%s %s", sent["id"], json.dumps({k: v for k, v in sent.items() if k != "id"}))
    return sent


def run(bridge: Bridge, translator: Translator) -> None:
    log.info("Bridge folder: %s", bridge.dir)
    log.info("Waiting for requests (press Alt+J in game). Ctrl+C to quit.")
    last_beat = 0.0
    last_result_id = 0
    while True:
        now = time.monotonic()
        if now - last_beat >= HEARTBEAT_SECONDS:
            bridge.beat()
            last_beat = now
        for request in bridge.pending_requests():
            handle_request(bridge, translator.translate, request)
            bridge.beat()
        for result in (bridge.state().get("commandResults") or []):
            if result.get("commandId", 0) > last_result_id:
                last_result_id = result["commandId"]
                log.info("Game: command #%s %s - %s", result["commandId"], "OK" if result.get("ok") else "REJECTED", result.get("message"))
        time.sleep(POLL_SECONDS)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bridge-dir", type=pathlib.Path, default=default_bridge_dir())
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    parser.add_argument("--dry-run", metavar="TEXT", help="translate TEXT against the current state.json and print the command without sending it")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

    translator = Translator(anthropic.Anthropic(), args.model, args.effort)
    bridge = Bridge(args.bridge_dir)
    if args.dry_run:
        print(json.dumps(translator.translate(args.dry_run, bridge.state), indent=2))
        return 0
    try:
        run(bridge, translator)
    except KeyboardInterrupt:
        log.info("Companion stopped; the game falls back to its local parser.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
