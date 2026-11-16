"""Build the actual HA Switch driver; never deploy or package proof drivers."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE_REVISION = "7fc2ac9f758dd137e8f6ef8fec4a9fd6a066a392"
PACKAGE_FILES = (
    "driver.xml",
    "commands.lua",
    "Control4-HA-Base/driver.lua",
    "Control4-HA-Base/helpers.lua",
    "Control4-HA-Base/module/json.lua",
    "module/json.lua",
    "module/gestures.lua",
    "module/gesture_presentation.lua",
    "module/discovery.lua",
    "module/discovery_choices.lua",
    "module/catalog_enrichment.lua",
    "module/family_capabilities.lua",
    "module/load_conditions.lua",
    "module/button_link.lua",
    "module/operation_mode.lua",
    "module/rfc3339.lua",
    "module/leds.lua",
    "module/capability_summary.lua",
    "module/property_screen.lua",
    "module/state_subscription.lua",
    "www/documentation/index.html",
)


def package_sources(root: Path = ROOT) -> dict[str, bytes]:
    """Read the explicit runtime inventory after verifying the base pin."""
    gitlink = subprocess.check_output(
        ["git", "ls-tree", "HEAD", "Control4-HA-Base"], cwd=root, text=True
    ).split()
    base = root / "Control4-HA-Base"
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=base, text=True
    ).strip()
    if len(gitlink) < 3 or gitlink[2] != BASE_REVISION or revision != BASE_REVISION:
        raise ValueError("Initialize the required pinned base with git submodule update --init --recursive")
    files = {}
    for name in PACKAGE_FILES:
        source = root / name
        if not source.is_file():
            raise ValueError(f"Required package source is missing: {name}")
        content = source.read_bytes()
        if name.startswith("Control4-HA-Base/"):
            relative = name.removeprefix("Control4-HA-Base/")
            pinned = subprocess.check_output(["git", "show", f"{BASE_REVISION}:{relative}"], cwd=base)
            if content != pinned:
                raise ValueError(f"Required pinned base source has local modifications: {name}")
        files[name] = content
    xml = ET.fromstring(files["driver.xml"])
    script = xml.find("./config/script")
    if script is None or script.get("file") not in files:
        raise ValueError("The driver entry point is missing from the package")
    if xml.findtext("name") != "HA Switch" or xml.findtext("model") != "HA Switch":
        raise ValueError("The package must retain the installed HA Switch identity")
    if xml.findtext("proxy") != "other":
        raise ValueError("The compatible Switch package must retain its existing other proxy")
    # Director creates dependent proxy devices only on initial installation.
    # Adding/removing proxy declarations during an update is unsupported and
    # can corrupt existing project bindings (DriverWorks Fundamentals).
    if len(xml.findall("proxy")) != 1 or xml.find("proxies") is not None or xml.findtext("combo") != "true":
        raise ValueError("An in-place Switch update must preserve the original combo/proxy topology")
    return files


def build(target: Path | None = None, root: Path = ROOT) -> str:
    """Write a deterministic c4z atomically and return its SHA-256."""
    target = target or root / "dist/HA.Switch.c4z"
    files = package_sources(root)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, suffix=".c4z", delete=False) as staging:
            temporary = Path(staging.name)
        with zipfile.ZipFile(temporary, "w") as output:
            for name, content in sorted(files.items()):
                info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                output.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        with zipfile.ZipFile(temporary) as result:
            if result.testzip() is not None or set(result.namelist()) != set(PACKAGE_FILES):
                raise ValueError("Switch archive validation failed")
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        temporary.replace(target)
        temporary = None
        return digest
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/HA.Switch.c4z")
    args = parser.parse_args()
    digest = build(args.output)
    print(f"{args.output}  sha256={digest}")


if __name__ == "__main__":
    main()
