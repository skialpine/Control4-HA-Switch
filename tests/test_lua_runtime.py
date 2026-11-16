"""Run local Lua regressions in fresh processes, without HA or Director."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest

from tools.build_switch import ROOT


LOCAL_SUITES = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "tests/lua").glob("test_*.lua")) + [
    "tests/controller/test_switch_driver.lua",
    "tests/controller/test_dimmer_driver.lua",
]


@pytest.fixture(params=["lua", "luajit"])
def lua_runtime(request):
    executable = shutil.which(request.param)
    if executable is None:
        pytest.skip(f"Install {request.param} for Lua runtime regressions")
    return executable


def run_suite(executable, script, *args):
    result = subprocess.run([executable, script, *args], cwd=ROOT,
        capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("script", LOCAL_SUITES)
def test_local_lua_runtime(lua_runtime, script):
    run_suite(lua_runtime, script)


def test_dimmer_coordinator_boundary(lua_runtime):
    configured = os.environ.get("C4_HA_COORDINATOR_CHECKOUT")
    if not configured:
        pytest.skip("Set C4_HA_COORDINATOR_CHECKOUT for the actual Coordinator boundary")
    coordinator = Path(configured).resolve()
    assert (coordinator / "driver.lua").is_file()
    run_suite(lua_runtime, "tests/controller/test_dimmer_coordinator.lua", str(coordinator))
