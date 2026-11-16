"""Actual built drivers consume the companion's exported HA catalog through Coordinator."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

import pytest

from tools.build_light import build as build_light
from tools.build_switch import ROOT, build as build_switch


@pytest.fixture(scope="module")
def discovery_packages(tmp_path_factory):
    configured = os.environ.get("C4_HA_COORDINATOR_CHECKOUT")
    if not configured:
        pytest.skip("Set C4_HA_COORDINATOR_CHECKOUT for packaged cross-repository discovery checks")
    coordinator = Path(configured).resolve()
    assert (coordinator / "tools/build_driver.py").is_file()
    subprocess.run([sys.executable, "tools/build_driver.py"], cwd=coordinator,
        check=True, capture_output=True, text=True, timeout=15)
    folder = tmp_path_factory.mktemp("discovery-packages")
    switch, dimmer = folder / "HA.Switch.c4z", folder / "HA.Light.c4z"
    build_switch(switch)
    build_light(dimmer)
    roots = []
    for name, archive in (("coordinator", coordinator / "dist/HA.Coordinator.c4z"),
                          ("switch", switch), ("dimmer", dimmer)):
        target = folder / name
        with zipfile.ZipFile(archive) as package:
            assert "module/discovery.lua" in package.namelist()
            if name != "coordinator":
                assert "module/catalog_enrichment.lua" in package.namelist()
            package.extractall(target)
        roots.append(target)
    return roots


@pytest.mark.parametrize("runtime", ["lua", "luajit"])
def test_packaged_discovery_with_exported_ha_catalog(discovery_packages, runtime):
    executable = shutil.which(runtime)
    if executable is None:
        pytest.skip(f"Install {runtime} for packaged discovery checks")
    result = subprocess.run([executable, "tests/controller/test_packaged_catalog.lua",
        *map(str, discovery_packages), str(ROOT / "tests/fixtures/discovery/ha-catalog-v1.json")],
        cwd=ROOT, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "packaged catalog checks passed" in result.stdout
