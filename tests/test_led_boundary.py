"""Optional roundtrip through actual HA entities, service schema, and C4 driver."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest

from tools.build_switch import ROOT


ROUNDTRIP = r'''
import asyncio
import json
from pathlib import Path
import shutil
import subprocess
import sys
from homeassistant import config_entries, loader
from homeassistant.bootstrap import async_load_base_functionality
from homeassistant.core import HomeAssistant
from tools.generate_led_fixture import setup_fixture, state_fixture

async def main():
    lua, root, folder = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    config = folder / "ha"
    shutil.copytree(Path.cwd() / "custom_components/ha_gesture_bridge",
                    config / "custom_components/ha_gesture_bridge",
                    ignore=shutil.ignore_patterns("__pycache__"))
    hass = HomeAssistant(str(config))
    hass.config_entries = config_entries.ConfigEntries(hass, {})
    loader.async_setup(hass)
    assert await async_load_base_functionality(hass)
    initial, commands, confirmed = (folder / name for name in ("initial.json", "commands.json", "confirmed.json"))
    async def run(*extra):
        result = await asyncio.to_thread(subprocess.run,
            [lua, "tests/controller/test_led_boundary.lua", str(initial), str(commands), *extra],
            cwd=root, capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stdout + result.stderr
    try:
        fixture = await setup_fixture(hass)
        initial.write_text(json.dumps(state_fixture(hass, fixture["aggregate"])))
        await run()
        requests = json.loads(commands.read_text())
        assert len(requests) == 3
        for index, request in enumerate(requests):
            await hass.services.async_call(request["domain"], request["service"], request["service_data"], blocking=True)
            if index < 2:
                assert fixture["power"].current_option == "Always on", "Color/brightness changed the LED mode"
        await hass.async_block_till_done()
        assert fixture["calls"] == [(fixture["color"].entity_id, "Green"), (fixture["brightness"].entity_id, 1),
                                   (fixture["power"].entity_id, "Always off")]
        confirmed.write_text(json.dumps(state_fixture(hass, fixture["aggregate"])))
        await run(str(confirmed))
    finally:
        await hass.async_stop(force=True)

asyncio.run(main())
'''


@pytest.mark.parametrize("runtime", ["lua", "luajit"])
def test_actual_ha_led_service_roundtrip(runtime, tmp_path):
    checkout = os.environ.get("HA_GESTURE_BRIDGE_CHECKOUT")
    if not checkout:
        pytest.skip("Set HA_GESTURE_BRIDGE_CHECKOUT for the actual HA LED boundary")
    bridge = Path(checkout).resolve()
    python = Path(os.environ.get("HA_GESTURE_BRIDGE_PYTHON", bridge / ".venv/bin/python"))
    executable = shutil.which(runtime)
    if not executable:
        pytest.skip(f"Install {runtime} for the HA LED boundary")
    assert python.is_file(), "Provide the HA checkout's Python environment"
    assert (bridge / "tools/generate_led_fixture.py").is_file()
    result = subprocess.run([str(python), "-c", ROUNDTRIP, executable, str(ROOT), str(tmp_path)],
        cwd=bridge, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
