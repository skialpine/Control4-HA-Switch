# Install the Control4 drivers

This repository contains two consumer drivers. The shared Coordinator is built in its sibling repository.

| Package | Version | Use |
| --- | --- | --- |
| `HA.Coordinator.c4z` | 114 | Shared HA connection and discovery; retains the existing family APIs. |
| `HA.Switch.c4z` | 107 | Existing on/off Switch with improved selection, gestures and original incoming keypad links. |
| `HA.Light.c4z` | 1 | New native Light V2 driver for brightness, timed ramps and native lighting programming. |

Install the Coordinator and the consumer driver(s) needed. There are no separate proof, discovery or gesture drivers. Native discovery and ordinary direct control work without the optional HA companion.

## Rename an existing HA Dimmer

HA Light was previously named HA Dimmer. Composer requires matching package filenames for in-place updates, so install `HA.Light.c4z` as a new device and recreate the old Dimmer's settings, connections and programming. Subsequent HA Light updates use **Update Driver** with `HA.Light.c4z`. This package is our version 1 driver; it is not an update package for the upstream HA Light version 106.

## Update an existing Switch

Update its driver in place. Preserve its Device Link, Relay 1, Top/Bottom/Toggle Button Links, Entity ID and programming. Switch retains its original `other` proxy, identity, Turn On and Turn Off commands, and default Control HA Device mode. Existing installations are not converted to Light.

Switch keeps on/off/toggle, device selection, normalized gestures and confirmed Is On/Is Off conditions/While loops. The development-only Set Level, Ramp To Level, Light Action and Light level conditional have moved to Light. Those were not in the original released Switch 106. The unsupported beta connected-light mode and its Button Action command have also been removed from Switch; use HA Light for external C4-light control. A saved beta mode fails closed with a Light setup message until a supported mode is explicitly selected. A pre-split development package is retained locally for rollback; beta programming using those removed commands must be recreated on Light.

Known dimmable lights are omitted from new Switch discovery choices. Saved/manual Entity IDs are never silently changed. On/off-only light wrappers remain supported. Switch has no brightness or ramp command.

## Add the native Light

**Add HA Light as a new device in Composer. Do not use it to update or replace an existing HA Switch.** Connect its Device Link to HA Coordinator. Its distinct Light V2 proxy is created on first installation; saved Switch programming is not transferred automatically.

Select a normal HA light in Control HA Device mode for brightness and timed transitions. The driver derives dimming from `supported_color_modes` and timed ramps from HA's transition feature. A normal switch or on/off-only light exposes on/off behavior conservatively. Confirmed HA feedback supplies the current level; sending a command does not fabricate a new confirmed level.

Light supplies the native light proxy for Commands, Conditionals, Loops and standard paddle events. Indicator LED commands require explicitly configured companion channels. Other controls require the selected device's reported capabilities. Exact Composer rendering, button acknowledgments and loop behavior still require live controller qualification. See [Light behavior](light.md).

## Select a device

1. Follow **Device Setup** in Properties: open **Actions > Select Device**, then click **…** beside Device. Composer's outer Device field shows the selection; the searchable list opens through **…**.
2. Search/filter, select a result and confirm both dialogs. The first request waits for discovery. **Refresh Entities** explicitly reloads discovery and state.
3. Confirm **Selected Device**, **Status** and the capability summaries below. Selected Device shows the known friendly name, or the exact ID when no name is available. **Actions > Show Advanced Properties** reveals **Entity ID** for manual entry and the fallback **Entity Selection** dropdown.

Discovery uses Coordinator 114's authenticated HA connection. Older coordinators retain manual direct control; update the Coordinator for the picker. Missing companion/registry data falls back to native HA choices. Errors never silently select a different target.

The Coordinator connects automatically after initialization and retries after an HA restart. Its 30-second watchdog also repeats connection status so a consumer that misses recovery during a reload can resynchronize automatically. Recovery requests fresh state and does not replay the last physical press. Normal use does not require the Connect action.

The picker consolidates one validated aggregate with its linked physical load. A non-inverted `switch_as_x` wrapper can also consolidate with its exact registry source switch. Names and shared device IDs alone do not prove equivalence. Separate groups/channels and ambiguous mappings remain separate. Refreshing does not rewrite a saved selection.

## Properties and support diagnostics

The default Properties screen shows setup, operation mode, selected device, status, capability summaries and the **Debug Mode** logging toggle. Short mode descriptions explain the current choice. Current gesture snapshots and accepted events show **Ready**; direct HA feedback shows **On** or **Off**. Errors retain their explanatory status.

**Actions > Show Advanced Properties** reveals manual Entity ID, fallback selection, catalog configuration, discovery status, gesture counters and driver version. Light also exposes Latency Diagnostics and LED Feedback Source here. **Hide Advanced Properties** restores the compact screen. Hiding properties preserves all values and programming; the driver starts with the compact layout after a reload.

Open the **Lua** tab and run **Actions > Print Diagnostics** for a one-time support report, including hidden settings, detailed status, confirmed state and connection/readiness flags. It works with Debug Mode Off and sends no load commands, refresh requests or full HA event payloads. Enable ongoing logging with the visible **Debug Mode** toggle. Optional Latency Diagnostics remains under advanced properties.

## Read the device capabilities

Both drivers show these read-only properties from the current selected entity:

| Property | Without HA Gesture Bridge | With HA Gesture Bridge |
| --- | --- | --- |
| Selected Capabilities | Reported on/off and toggle; Light also shows level and timed ramp when supported. | The explicitly linked HA load's supported controls. Events-only mode has no load control; connected-C4 mode displays the selected C4 target's On/Off and dimming capabilities. |
| Button Capabilities | Explains that button events require HA Gesture Bridge. | Groups the actual declared gestures by button, such as Top & Bottom: 1–5 taps, hold, release. Unavailable sources are marked. |
| LED Status | Not exposed/configured. | Actual configured channels and their color, on/off and brightness support. |

These summaries describe features exposed to the driver, not every feature in the manufacturer's hardware. Waiting, unavailable and unconfigured states are distinct. Neither a friendly name nor a catalog entry authorizes a gesture, load or LED command.

## Optional gestures and controller modes

The optional [HA Gesture Bridge](https://github.com/skialpine/HA-Gesture-Bridge) normalizes configured source events. It lives in a separate repository derived from [DeviceSide/DeviceSide](https://github.com/DeviceSide/DeviceSide), with independent Marketplace metadata, source adapters and UI setup. DeviceSide remains optional for supported execution backends; it does not supply this gesture normalization.

The first three modes are available in both consumers. Connected-light control is available only in HA Light:

| Mode | Selected entity | Behavior |
| --- | --- | --- |
| Control HA Device | Normal HA load | Confirmed load feedback and supported commands. |
| Control HA Device with Button Events | Aggregate `event.*` | Declared gestures plus supported commands for its explicitly linked HA load. |
| Programming Events Only | Aggregate `event.*` | Gestures; all HA load commands blocked. |
| Control Connected C4 Light (Light only) | Aggregate `event.*` | Singles/holds/releases operate an existing C4 light through Button Links; all HA load commands blocked. |

The original bridge 1.0 supports switch/input_boolean loads. Bridge 1.1 additionally carries typed light capabilities and brightness so one Light instance can receive paddle gestures and control its linked HA dimmable light. Update the HA component to use that extension. A snapshot changes load feedback without firing or replaying a gesture.

For smart bulbs or another light already represented in C4, use [smart-switch setup](smart-switch-setup.md). Decouple the physical relay using the manufacturer's settings; bind HA Light's new Top/Bottom/Toggle **Controller Link** inputs (203–205) to the existing C4 light's provider outputs. Its driver owns the target load and brightness. The controller does not infer that light's state from the wall switch relay. The old Button Link providers (200–202) are retained for incoming keypad control of the HA load. Only Light offers this route. Switch's original provider connections remain for incoming keypad control of its own HA load.

Switch uses custom gesture entries with familiar source-supported names such as Top Double Tap. Light maps supported Top/Bottom/Toggle taps, hold-start and releases to native proxy events; higher counts, custom actions and other buttons retain separate dynamic events. Initial state, snapshots and reconnects never replay historical gestures. Gesture Count measures delivered physical-source gestures, not software button commands.

In HA Light's connected-light mode, single taps forward logical push/click, holds start a tracked logical press, and releases stop it. A source must report release before held output is allowed. Multi-taps remain separate programming events and do not also send repeated load clicks. Switch receives gestures for programming but never forwards them to an external light.

Switch Is On/Is Off conditions and loops read confirmed available Direct/bridge feedback only; unknown state and event-only modes evaluate false. Use the target light's own tests in controller mode. Include a Delay when waiting in a loop.

## Build and qualification

```sh
python3 tools/build_switch.py
python3 tools/build_light.py
# In ../Control4-HA-Coordinator:
python3 tools/build_driver.py
```

Outputs are `dist/HA.Switch.c4z`, `dist/HA.Light.c4z`, and the Coordinator repository's `dist/HA.Coordinator.c4z`. Builds are deterministic and runtime-only. Switch uses the pinned clean Base; Light is standalone. Versions stay 107/1/114 throughout development reloads.

Automated tests cover actual Lua entry points, typed bridge/discovery transport, mixed original consumers, capability changes and package inventories. These are development packages awaiting Composer/hardware qualification. No controller driver, HA restart or physical relay setting is changed by building them.

## Composer Documentation tab

Both packages embed a standalone Documentation tab with mode descriptions, selection steps, connection guidance, supported programming, troubleshooting and links to the optional companion. The read-only Mode Description property also explains the selected mode. Operation Mode contains three descriptive Switch choices and a fourth connected-light choice in Light; no legacy dropdown entries or mode-migration machinery are included.

## Optional indicator LEDs

Both drivers support explicit companion indicator mappings. Light adds native LED commands and opt-in connected-light feedback; Switch adds LED programming commands without changing its proxy. See [LED setup and limitations](leds.md).
