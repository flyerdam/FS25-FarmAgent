"""Offline tests for the companion: no network. A fake Claude client scripts the tool calls,
and the real Lua FABridge (under Lua 5.1 via lupa) reads what the companion wrote.

    python tests/test_companion.py
"""
import json
import pathlib
import sys
import tempfile
import types

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "companion"))

import farm_agent_companion as fac  # noqa: E402
import lupa.lua51 as lua51  # noqa: E402


def block(**kw):
    return types.SimpleNamespace(**kw)


class FakeMessages:
    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        return self.script.pop(0)


class FakeClient:
    def __init__(self, script):
        self.beta = types.SimpleNamespace(messages=FakeMessages(script))


STATE = {
    "phase": "IDLE",
    "farm": {
        "fields": [{"id": 12, "name": "12", "areaHa": 8.4, "crop": "WHEAT", "state": "READY_TO_HARVEST", "readyFraction": 0.97, "labelX": 1}],
        "vehicles": [{"id": 21, "name": "Case IH", "kind": "COMBINE", "aiActive": False, "combine": {"headerCrops": ["WHEAT"]}}],
        "stations": [],
    },
    "log": [{"text": "noise that should not reach the model"}],
}

failures = 0


def check(cond, what):
    global failures
    if cond:
        print("ok   ", what)
    else:
        failures += 1
        print("FAIL ", what)


def test_translator_tool_loop():
    script = [
        block(stop_reason="tool_use", content=[block(type="tool_use", id="t1", name="get_farm_state", input={})]),
        block(stop_reason="tool_use", content=[block(type="tool_use", id="t2", name="submit_objective",
                                                     input={"crop": "wheat", "field_ids": None, "say": "Harvesting field 12."})]),
    ]
    client = FakeClient(script)
    command = fac.Translator(client, fac.MODEL, "medium").translate("Harvest all ready wheat fields", lambda: STATE)
    check(command == {"type": "objective", "say": "Harvesting field 12.",
                      "objective": {"type": "HARVEST_READY_FIELDS", "crop": "WHEAT", "fieldIds": None}}, "objective command built")
    first = client.beta.messages.calls[0]
    check(first["model"] == "claude-opus-5-5" and first["fallbacks"] == "default"
          and fac.FALLBACK_BETA in first["betas"] and first["output_config"] == {"effort": "medium"}, "request parameters")
    second = client.beta.messages.calls[1]["messages"]
    tool_result = second[-1]["content"][0]
    check(tool_result["tool_use_id"] == "t1" and "noise" not in tool_result["content"]
          and '"readyFraction": 0.97' in tool_result["content"], "state tool result is the compact summary")
    check(all(t.get("strict") for t in fac.TOOLS), "all tools strict")


def test_translator_invalid_then_reply():
    script = [
        block(stop_reason="tool_use", content=[block(type="tool_use", id="a", name="submit_objective",
                                                     input={"crop": None, "field_ids": None, "say": "?"})]),
        block(stop_reason="end_turn", content=[block(type="text", text="I can only harvest in this milestone.")]),
    ]
    client = FakeClient(script)
    command = fac.Translator(client, fac.MODEL, "medium").translate("make money", lambda: STATE)
    retry = client.beta.messages.calls[1]["messages"][-1]["content"][0]
    check(retry["is_error"] is True, "invalid terminal input returned as tool error")
    check(command == {"type": "reply", "say": "I can only harvest in this milestone."}, "plain text becomes a reply")


def test_refusal():
    client = FakeClient([block(stop_reason="refusal", content=[])])
    command = fac.Translator(client, fac.MODEL, "medium").translate("x", lambda: STATE)
    check(command["type"] == "reply", "refusal handled before reading content")


def test_bridge_round_trip_with_lua():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="farmagent_companion_"))
    old = fac.Bridge(tmp)  # an earlier companion run left command #7 behind
    old.send({"type": "reply", "say": "old & <done>"})
    old.next_id = 7
    old.commands = [{"id": 7, "type": "reply"}]
    old.flush_commands()
    (tmp / "requests.json").write_text(json.dumps({"session": "S1", "requests": [
        {"id": 1, "text": "old", "status": "TIMED_OUT"},
        {"id": 2, "text": "Harvest all ready wheat fields", "status": "SENT"}]}))

    bridge = fac.Bridge(tmp)
    check(bridge.next_id == 8, "command ids continue after previous companion run (read back from commands.xml)")
    pending = bridge.pending_requests()
    check([r["id"] for r in pending] == [2], "only SENT requests are pending; timed-out ones are skipped")

    translate = lambda text, get_state: {"type": "objective", "say": "ok",
                                         "objective": {"type": "HARVEST_READY_FIELDS", "crop": "WHEAT", "fieldIds": None}}
    sent = fac.handle_request(bridge, translate, pending[0])
    check(sent["id"] == 8 and sent["requestId"] == 2 and sent["session"] == "S1", "command carries id, request id and session")
    check(fac.Bridge(tmp).pending_requests() == [], "processed requests survive a companion restart")

    (tmp / "requests.json").write_text(json.dumps({"session": "S2", "requests": [
        {"id": 2, "text": "new game session, same number", "status": "SENT"}]}))
    check([r["text"] for r in fac.Bridge(tmp).pending_requests()] == ["new game session, same number"],
          "request #2 of a new game session is not mistaken for the old #2")
    (tmp / "requests.json").write_text(json.dumps({"session": "S1", "requests": [
        {"id": 2, "text": "x", "status": "SENT"}]}))

    # The real Lua bridge reads what Python wrote, under the FS25 io sandbox (testlib).
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute((ROOT / "tests" / "lua" / "testlib.lua").read_text(encoding="utf-8"))
    mod = ROOT / "FS25_FarmAgent" / "scripts"
    for f in ["util/FALog.lua", "util/FAJson.lua", "bridge/FABridge.lua"]:
        lua.execute((mod / f).read_text(encoding="utf-8"))
    lua.execute("FALog.sink = function() end; createFolder = function() end")
    received = lua.execute(f"""
        local bridge = FABridge.new("{tmp.as_posix()}/")
        bridge.sessionId = "S1"
        bridge.lastCommandId = 7
        bridge.requests = {{ {{ id = 2, text = "x", status = "SENT", sentAt = 0 }} }}
        local got = {{}}
        bridge:update(1000, {{
            onCommand = function(cmd) table.insert(got, cmd) end,
            onRequestTimeout = function() end,
            buildState = function() return {{}} end,
        }})
        local c = got[1]
        return #got, c.type, c.objective.crop, tostring(c.objective.fieldIds), c.requestId, bridge:getRequest(2).status, FS_IO_VIOLATIONS
    """)
    check(tuple(received) == (1, "objective", "WHEAT", "nil", 2, "ANSWERED", 0), f"Lua bridge decoded companion command {tuple(received)}")


def test_field_work_commands():
    c = fac.to_command("submit_field_work", {"op": "SEED", "crop": "barley", "field_ids": [3], "say": "Planting barley."})
    check(c["objective"] == {"type": "FIELD_WORK", "op": "SEED", "crop": "BARLEY", "fieldIds": [3]}, "plant command")
    c = fac.to_command("submit_field_work", {"op": "SEED", "crop": None, "field_ids": None, "say": "x"})
    check(c["objective"]["crop"] == "REPLANT", "plant without crop = replant")
    c = fac.to_command("submit_field_work", {"op": "ALL", "crop": None, "field_ids": None, "say": "x"})
    check(c["objective"] == {"type": "FARM_WORK"}, "all field work")
    check(any(t["name"] == "submit_field_work" for t in fac.TOOLS), "tool offered to Claude")


for test in [test_translator_tool_loop, test_translator_invalid_then_reply, test_refusal, test_bridge_round_trip_with_lua, test_field_work_commands]:
    test()
print("ALL COMPANION TESTS PASSED" if failures == 0 else f"{failures} FAILURE(S)")
sys.exit(1 if failures else 0)
