"""Package the read-only family discovery proof; never deploys to a controller."""

from pathlib import Path
import subprocess

from tools.build_transport_proof import archive

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    pinned = subprocess.check_output(["git", "ls-tree", "HEAD", "Control4-HA-Base"], cwd=ROOT, text=True).split()[2]
    current = subprocess.check_output(["git", "-C", str(ROOT / "Control4-HA-Base"), "rev-parse", "HEAD"], text=True).strip()
    if pinned != current:
        raise SystemExit("Initialize the pinned base with git submodule update --init --recursive")
    files = {p.relative_to(ROOT).as_posix(): p for p in (ROOT / "Control4-HA-Base").rglob("*.lua")}
    files.update({
        "driver.xml": ROOT / "tools/discovery-proof/driver.xml",
        "commands.lua": ROOT / "tools/discovery-proof/commands.lua",
        "module/json.lua": ROOT / "module/json.lua",
        "module/discovery.lua": ROOT / "module/discovery.lua",
        "module/family_capabilities.lua": ROOT / "module/family_capabilities.lua",
    })
    archive(ROOT / "dist/HA.Entity.Discovery.Proof.c4z", files)


if __name__ == "__main__":
    main()
