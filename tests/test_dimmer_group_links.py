"""Optional actual-driver boundary check for the separate C4 Light Group checkout."""

import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

import pytest

from tools.build_light import ROOT


@pytest.mark.parametrize("runtime", ["lua", "luajit"])
def test_dimmer_controller_links_drive_actual_group(runtime):
    configured = os.environ.get("C4_GROUP_LIGHTING_CHECKOUT")
    if not configured:
        pytest.skip("Set C4_GROUP_LIGHTING_CHECKOUT for the actual Light Group boundary")
    group = Path(configured).resolve()
    executable = shutil.which(runtime)
    if executable is None:
        pytest.skip(f"Install {runtime} for the Light Group boundary")
    version = subprocess.run([executable, "-e", "print(_VERSION)"],
        capture_output=True, text=True, check=True, timeout=5).stdout.strip()
    if version != "Lua 5.1":
        pytest.skip(f"The external Light Group targets Lua 5.1/LuaJIT; {runtime} reports {version}")
    assert (group / "src/lib/light.lua").is_file()
    ours = {int(item.findtext("id")): item for item in ET.parse(ROOT / "light/driver.xml").findall("./connections/connection")}
    theirs = {int(item.findtext("id")): item for item in ET.parse(group / "drivers/light_group/driver.xml").findall("./connections/connection")}
    for source, target in ((203, 300), (204, 302), (205, 301)):
        # Director cannot connect two providers. Validate the real declarations
        # before the fake transport connects the two actual Lua implementations.
        assert ours[source].findtext("consumer").lower() == "true"
        assert theirs[target].findtext("consumer").lower() == "false"
        for connection in (ours[source], theirs[target]):
            assert connection.findtext("type") == "1"
            assert connection.findtext("./classes/class/classname") == "BUTTON_LINK"
    for original in (200, 201, 202):
        assert ours[original].findtext("consumer").lower() == "false"
    result = subprocess.run([executable, "tests/controller/test_dimmer_group_links.lua", str(group)],
        cwd=ROOT, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "actual Dimmer/Light Group links passed" in result.stdout
