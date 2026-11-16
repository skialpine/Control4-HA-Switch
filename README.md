# Home Assistant Switch and Light for Control4

This repository provides two drivers:

- **HA Switch 107** preserves the original Switch identity and on/off interfaces, with improved device selection, optional gestures and the original incoming keypad Button Links.
- **HA Light 1** is a new native Light V2 driver for capability-derived brightness, timed transitions and native lighting programming. Add it as a new device; it does not replace an installed Switch.

Both use [HA Coordinator](https://github.com/bphillips09/Control4-HA-Coordinator). Coordinator 114 adds generic discovery while preserving the original family APIs. Native discovery and direct control work without an HA companion. Optional normalized gestures are implemented by the development HA Gesture Bridge; it now lives in the independent [HA Gesture Bridge repository](https://github.com/skialpine/HA-Gesture-Bridge), derived from upstream [DeviceSide/DeviceSide](https://github.com/DeviceSide/DeviceSide).

See [installation](docs/installation.md), [Light behavior](docs/light.md), [smart-switch setup](docs/smart-switch-setup.md), and [development/tests](docs/development.md). These development packages require live Composer and hardware qualification.

Both drivers also support [explicit indicator LED mappings](docs/leds.md) through the optional companion. Light offers native LED commands and opt-in state feedback from a connected C4 light. Unsupported physical features send no command. See the [three-repository audit and fixes](docs/audit-2026-11-15.md) for the reviewed baseline.

Build from a recursive checkout with the clean pinned Base submodule:

```sh
python3 tools/build_switch.py
python3 tools/build_light.py
```

The runtime-only packages are written under `dist/`. Switch uses the pinned Base; Light is standalone. Existing Switch upgrades retain their original proxy and connections. Unreleased beta brightness/ramp additions now belong to Light.
