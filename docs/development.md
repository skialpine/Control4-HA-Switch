# Control4 driver development

This checkout owns HA Switch 107, native HA Light 1, their shared Lua modules, deterministic C4 packaging and consumer contract fixtures. The independent [HA Gesture Bridge](https://github.com/skialpine/HA-Gesture-Bridge) owns HA implementation, UI setup, source adapters, producer tests and Marketplace packaging. Its sibling checkout is `../HA-Gesture-Bridge`.

## Consumer checks

```sh
python3 -m pip install -r requirements-test.txt
python3 -m pytest -q
python3 tools/build_switch.py
python3 tools/build_light.py
```

Install Lua and LuaJIT to run both runtime variants. Pytest runs every local
`tests/lua/test_*.lua` suite and the full Switch/Light entry-point harnesses in
fresh subprocesses. Missing runtimes are reported as skips. CI installs Lua 5.4
and LuaJIT and runs the same checks and deterministic package builders.
Initialize the clean pinned Base submodule for Switch. Light is standalone;
ordinary Lua and C4 package checks require neither HA nor DeviceSide.

The actual Coordinator boundary is optional and uses an explicitly configured
checkout, with no network access:

```sh
C4_HA_COORDINATOR_CHECKOUT=../Control4-HA-Coordinator python3 -m pytest -q tests/test_lua_runtime.py
```

This also exercises `test_dimmer_coordinator.lua` against that checkout. The
Lua harness can still be invoked directly with the checkout as its first path
argument.

For the packaged discovery boundary, run:

```sh
C4_HA_COORDINATOR_CHECKOUT=../Control4-HA-Coordinator python3 -m pytest -q tests/test_discovery_packages.py
```

This builds/extracts Coordinator, Switch and Light and loads their actual
runtime files in isolated Lua environments. The committed HA export contains
66 states and 64 catalog rows, including real aggregate/sensor publications.
It verifies typed catalog records, pagination without truncation, exact-ID
enrichment, retained selections, companion removal and no secondary state
subscriptions or load commands. Lua and LuaJIT run the same cases.

Regenerate the portable artifact from the companion checkout:

```sh
.venv/bin/python -m tools.generate_catalog_fixtures --output ../Control4-HA-Switch/tests/fixtures/discovery/ha-catalog-v1.json
```

Its producer regression compares against the exported artifact when
`C4_HA_SWITCH_CHECKOUT` is set; ordinary consumer checks need no HA runtime.

To exercise HA Light's consumer Controller Links against the separate Light
Group implementation, run:

```sh
C4_GROUP_LIGHTING_CHECKOUT=../../control4-group-lighting python3 -m pytest -q tests/test_dimmer_group_links.py
```

This validates the actual XML connection roles and forwards clicks/holds/releases
from the actual Light entry point into the group's light model and member
adapter. Timers, Director transport and physical members are simulated. The
group runs in Lua 5.1/LuaJIT; the local Lua 5.5 boundary is explicitly skipped
because the external group's source does not compile under that parser.
Standalone Light entry-point tests still run in both Lua and LuaJIT. No group
implementation is copied into or shipped with HA Light.

## Real producer boundary checks

Run the independent companion suite in its own checkout with `C4_HA_SWITCH_CHECKOUT` explicitly pointing here. Its HA tests generate actual EventEntity publications and invoke this checkout's Lua decoder/Switch/Light harnesses. Without that variable, the companion runs its HA-only suite independently. Exported versioned consumer fixtures remain under `tests/fixtures/gestures`.

No HA implementation belongs in this repository's commits. Temporary migration rollback files are under ignored `dist/pre-separation-ha`. The companion preserves `ha_gesture_bridge`, control/button/gesture IDs, entity registry unique IDs and contracts 1.0/1.1. See [installation](installation.md) for driver modes and the independent companion README for HA setup/import.

Local tests do not establish native Composer or hardware qualification. The user has now confirmed live Light single taps and hold/release light control, plus bottom double-tap programming. See [transport evidence](transport-proof.md) for the exact scope and latency limits. Other gestures, loop behavior, recovery, Switch upgrades and Zigbee still require qualification.

## Shared incoming-message boundary

Switch and Light both use `module.gestures.parse_proxy` to decode each incoming
HA state/event exactly once for routing and consumption. `consume_parsed` keeps
gesture syntax, null handling and semantic validation in the same shared module;
legacy `consume_proxy` delegates to that path. Neither entry point has its own
JSON event unwrap/gesture reparse. Direct load mode retains its existing parsing
semantics. The proxy-specific commands, state presentation, relay/native light
notifications and connection maps remain in the respective entry points.

The shared parser retains an owned prefix state on strict JSON syntax failure
so malformed input can still cancel that control's unsafe held output. Messages
with another entity ID or no established owner do not alter its output. Actual
entry-point regressions count JSON decoder calls and test both kinds of failure,
alongside snapshot/session/null/reentrant-action checks. This removes duplicated
work; measured hardware improvement still requires the next live sample.

## LED service roundtrip

The shared `module/leds.lua` owns indicator metadata validation, palette mapping,
saved preferences and confirmed feedback for both entry points. It never infers
LEDs from a relay or treats a queued service as hardware confirmation.

For the optional actual HA → Light → HA service → confirmed feedback test:

```sh
HA_GESTURE_BRIDGE_CHECKOUT=../HA-Gesture-Bridge .venv/bin/python -m pytest -q tests/test_led_boundary.py
```

The companion checkout needs its own prepared `.venv` (or set
`HA_GESTURE_BRIDGE_PYTHON`). Both Lua runtimes use actual HA select/number/event
entities and services, with only the physical device boundary stubbed. No network
or installed HA instance is used. This proves the wire path, not physical LED
qualification; see [LED setup](leds.md).
