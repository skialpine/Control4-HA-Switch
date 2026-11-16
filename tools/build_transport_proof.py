"""Build isolated proof artifacts; does not install or modify a live system."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def archive(target: Path, files: dict[str, Path]) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as output:
        for name, source in sorted(files.items()):
            if not source.is_file():
                raise SystemExit(f"Required source is missing: {source.relative_to(ROOT)}")
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            output.writestr(info, source.read_bytes())
    with zipfile.ZipFile(target) as result:
        if result.testzip() is not None:
            raise SystemExit("Proof archive validation failed")
        if target.suffix == ".c4z":
            xml = ET.fromstring(result.read("driver.xml"))
            script = xml.find("./config/script").attrib["file"]
            assert script in result.namelist()
            assert {"commands.lua", "module/json.lua"} <= set(result.namelist())
    print(f"{target.relative_to(ROOT)}  sha256={hashlib.sha256(target.read_bytes()).hexdigest()}")


def main() -> None:
    pinned = subprocess.check_output(["git", "ls-tree", "HEAD", "Control4-HA-Base"], cwd=ROOT, text=True).split()[2]
    current = subprocess.check_output(["git", "-C", str(ROOT / "Control4-HA-Base"), "rev-parse", "HEAD"], text=True).strip()
    if pinned != current:
        raise SystemExit("Initialize the pinned base with git submodule update --init --recursive")
    base_files = {str(path.relative_to(ROOT)): path for path in (ROOT / "Control4-HA-Base").rglob("*.lua")}
    proof_files = {
        "driver.xml": ROOT / "tools/transport-proof/driver.xml",
        "commands.lua": ROOT / "tools/transport-proof/commands.lua",
        "module/json.lua": ROOT / "module/json.lua",
        "module/gestures.lua": ROOT / "module/gestures.lua",
        "module/rfc3339.lua": ROOT / "module/rfc3339.lua",
        "module/gesture_presentation.lua": ROOT / "module/gesture_presentation.lua",
        **base_files,
    }
    archive(ROOT / "dist/HA.Gesture.Transport.Proof.c4z", proof_files)



if __name__ == "__main__":
    main()
