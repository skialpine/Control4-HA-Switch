"""Build the new native Light V2 driver as a separate installation package."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SHARED_FILES = (
    "module/json.lua",
    "module/discovery.lua",
    "module/discovery_choices.lua",
    "module/catalog_enrichment.lua",
    "module/family_capabilities.lua",
    "module/gesture_presentation.lua",
    "module/gestures.lua",
    "module/button_link.lua",
    "module/operation_mode.lua",
    "module/rfc3339.lua",
    "module/leds.lua",
    "module/capability_summary.lua",
    "module/property_screen.lua",
    "module/connected_light.lua",
    "module/state_subscription.lua",
)


def package_sources(root: Path = ROOT) -> dict[str, bytes]:
    sources = {"driver.xml": root / "light/driver.xml"}
    sources["www/documentation/index.html"] = root / "light/www/documentation/index.html"
    sources.update({name: root / name for name in SHARED_FILES})
    sources.update({path.relative_to(root).as_posix(): path for path in (root / "light").glob("*.lua")})
    files = {name: path.read_bytes() for name, path in sources.items()}
    xml = ET.fromstring(files["driver.xml"])
    if xml.findtext("name") != "HA Light" or xml.findtext("model") != "HA Light":
        raise ValueError("Light must have a distinct installation identity")
    if xml.findtext("version") != "1" or xml.findtext("combo", "false").lower() != "false":
        raise ValueError("Light is a new native-proxy driver, version 1")
    proxies = xml.findall("./proxies/proxy") + xml.findall("./proxy")
    if len(proxies) != 1 or proxies[0].text.strip().lower() != "light_v2":
        raise ValueError("Light must declare one native Light V2 proxy")
    if xml.find("replaces") is not None:
        raise ValueError("Light must not replace or obsolete the installed Switch")
    entry = xml.find("./config/script")
    if entry is None or entry.get("file") not in files:
        raise ValueError("Light entry point is missing from its package")
    for name, content in files.items():
        if name.endswith(".lua"):
            for dependency in re.findall(r"\brequire\s*\(?\s*['\"]((?:module|dimmer)\.[\w.]+)['\"]", content.decode()):
                if dependency.replace(".", "/") + ".lua" not in files:
                    raise ValueError(f"Missing dependency {dependency} from {name}")
    return files


def build(target: Path | None = None, root: Path = ROOT) -> str:
    target = target or root / "dist/HA.Light.c4z"
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
        with zipfile.ZipFile(temporary) as package:
            if package.testzip() is not None or set(package.namelist()) != set(files):
                raise ValueError("Light package validation failed")
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        temporary.replace(target)
        temporary = None
        return digest
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/HA.Light.c4z")
    args = parser.parse_args()
    print(f"{args.output}  sha256={build(args.output)}")


if __name__ == "__main__":
    main()
