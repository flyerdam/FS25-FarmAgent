"""Runs Farm Agent's Lua tests under Lua 5.1 (the Lua dialect FS25 uses) via lupa.

    pip install lupa
    python tests/run_tests.py

1. Syntax-checks every .lua file in the mod.
2. Loads the pure modules (no game API) plus mocks and runs tests/lua/test_*.lua.
"""
import pathlib
import sys
import tempfile

import lupa.lua51 as lua51

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / "FS25_FarmAgent"
TESTS = ROOT / "tests" / "lua"

# Modules loaded for unit tests, in dependency order. FAGameAdapter / FAJobAdapter are
# replaced by mocks inside the tests that need them.
PURE_MODULES = [
    "scripts/util/FALog.lua",
    "scripts/util/FAJson.lua",
    "scripts/util/FAGeometry.lua",
    "scripts/plan/FALogistics.lua",
    "scripts/state/FAMemory.lua",
    "scripts/state/FAFieldScanner.lua",
    "scripts/plan/FAIntent.lua",
    "scripts/plan/FAPlanner.lua",
    "scripts/plan/FABrain.lua",
    "scripts/plan/FAValidator.lua",
    "scripts/exec/FATaskManager.lua",
    "scripts/bridge/FABridge.lua",
]


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def syntax_check(lua) -> int:
    failures = 0
    check = lua.eval("function(src, name) local f, e = loadstring(src, name) if f then return nil end return e end")
    for path in sorted(MOD.rglob("*.lua")):
        rel = path.relative_to(ROOT)
        err = check(read(path), "@" + str(rel))
        if err is not None:
            failures += 1
            print(f"SYNTAX FAIL {rel}: {err}")
        else:
            print(f"syntax ok   {rel}")
    return failures


def run_unit_tests() -> int:
    total_failures = 0
    tmp = tempfile.mkdtemp(prefix="farmagent_test_")
    for test_file in sorted(TESTS.glob("test_*.lua")):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(read(TESTS / "testlib.lua"))
        lua.globals().TEST_TMP = tmp.replace("\\", "/")
        lua.globals().MOD_ROOT = MOD.as_posix()
        lua.execute("FALOG_SILENT = true")
        for module in PURE_MODULES:
            lua.execute(read(MOD / module))
        lua.execute("FALog.sink = function(line) if not FALOG_SILENT then print(line) end end")
        lua.execute(read(test_file))
        passed, failed, messages = lua.eval("T.summary()")
        for msg in messages.values():
            print("  " + msg)
        print(f"{test_file.name}: {passed} passed, {failed} failed")
        total_failures += failed
    return total_failures


def main() -> int:
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    print(lua.eval("_VERSION"))
    failures = syntax_check(lua)
    failures += run_unit_tests()
    print("ALL TESTS PASSED" if failures == 0 else f"{failures} FAILURE(S)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
