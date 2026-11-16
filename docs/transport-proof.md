> Historical proof procedure: install only the production Coordinator 114,
> Switch 107 and new Dimmer 1 described in [installation.md](installation.md).
> Stock-113/proof packages below are developer references, superseded for live
> qualification. Recorded HA evidence remains valid; the current split and
> expanded source mappings now have live Dimmer evidence recorded below. The stock-113 path remains unverified.

# Stock-coordinator transport proof

The stock-coordinator path is not yet verified on a controller. This file records the known test
target, deliverable proof artifacts, prerequisites, and acceptance procedure.
Local automated results are not physical-device or Composer verification.

## Live Dimmer and connected C4 light — November 15, 2026

CHV now runs HA Gesture Bridge 0.1.0 installed through Marketplace from
`skialpine/HA-Gesture-Bridge` (852f679). The user approved activation by restart.
The old YAML proof was imported into a UI-managed control, expanded to both
paddles, and its YAML removed. The public entity is now
`event.jeffs_office_switch_gestures`; the stable internal unique ID remains
`jeffs_office_gesture_proof`. Both sources advertise counts 1–5, hold and release;
these declarations are not physical verification of every action. No HA load is
linked. Office Lights automation was backed up and disabled with configuration
hash `b39ee976f533f117` unchanged. The physical relay parameters were unchanged.

The user installed Dimmer 1 with Controller Links 203–205 and debug logging
(build SHA256 `294fc91b778e2b68099726d79ac77ce9e2acc8e99127b4dfb06d605fa450ecc1`).
They confirmed the light responds in C4 Button Controller mode (now labelled
**Control Connected C4 Light**). Supplied Composer logs establish:

| Sequence / UTC time | Observation |
| --- | --- |
| 4 / 07:52:52.027 | Bottom single accepted; binding 204 sends DO_PUSH then DO_CLICK. |
| 5 / 07:52:54.574 | Top single accepted; binding 203 sends DO_PUSH then DO_CLICK. |
| 6–7 / 07:52:57.769–07:53:02.163 | Bottom hold and release accepted; binding 204 sends DO_PUSH then DO_RELEASE. |
| 8–9 / 07:53:04.111–07:53:09.804 | Top hold and release accepted; binding 203 sends DO_PUSH then DO_RELEASE. |
| 10–13 / 07:55:11.684–07:55:19.323 | Repeated alternating bottom/top single taps accepted and forwarded. |
| 14–17 / 07:57:21.605–07:57:33.437 | Four separate bottom double taps accepted. The user confirms Composer programming works. No automatic load clicks are forwarded for these multi-taps. |

Bridge session: `8a731139492a44dab2da84414b3643b5`. `MATCH_LED_STATE`
feedback was safely ignored. The old log reason `unmapped_gesture` for the
multi-tap controller output meant programming-event-only, not decoder rejection;
new diagnostics name that explicitly. Exact Director/runtime versions and
bindings were not independently exported in this test. This qualifies only the
observed path; Switch upgrade preservation, triple/4/5 taps, Zigbee, recovery,
conditions/loops and other pending hardware checks remain open.

### Single-tap latency investigation

Recorder history for 07:51:20–07:53:20 UTC compares native source and bridge
`last_updated` on the same HA clock. Across nine live gestures, source-to-bridge
publication took **0.212–0.308 ms**; the five singles that reached controller mode
or preceded it were likewise below 1 ms. This excludes switch classification,
Z-Wave transport, HA-to-C4 delivery and physical target response. The target
light's HA export updates on a roughly five-second cadence in this capture and
cannot measure physical response latency. No end-to-end latency claim follows.
New Dimmer debug lines include `local_ms` and `receive_to_forward_ms` for the
C4-side processing interval; they do not measure network or pre-HA delay.

The Light Group source defaults click fade rates to 500 ms, with persisted
per-direction overrides. That affects fade duration, not necessarily initial
command delivery. The group is unchanged. Zooz's
[ZEN76 parameter 19](https://www.support.getzooz.com/kb/article/549-zen76-s2-on-off-switch-advanced-settings/)
disables multi-taps, holds and releases together; it is unsuitable for preserving
the tested functionality and was left unchanged.

### First clock-independent acknowledgment results

On November 15, the user installed the Dimmer diagnostics build (SHA256
`bfc95372bb12e31f75cf75b4142c1667b53680d5c3422b1fd2f0ca15872b8d1a`).
HA Gesture Bridge 0.1.1 (16ec8b2) was installed through Marketplace and activated
with a separately approved restart. The existing control/entity and both ready
sources were retained; Office Lights remained off. MCP retrieved these samples
from integration diagnostics, correlated with the supplied Composer log:

| Gesture | HA publication UTC | HA ack receipt UTC | HA monotonic round trip | C4 local processing | Clock-dependent arrival estimate |
| --- | --- | --- | --- | --- | --- |
| Bottom single, sequence 1 | 08:24:30.260 | 08:24:30.659 | 399.578 ms | 161 ms | 219 ms |
| Top single, sequence 2 | 08:24:33.003 | 08:24:33.466 | 463.218 ms | 231 ms | 216 ms |

Session: `170060cdc94a4b839a136bf0c64a4d4b`. Both gestures were accepted
and forwarded on their correct Controller Links; both acknowledgments reached
HA. The round-trip values require no HA/C4 clock synchronization and include
C4 processing plus both transport directions. They exclude physical switch
classification and physical light response. The arrival estimates include
unknown clock offset and must not be treated as precise one-way latency.

The user sees a similar 1–2 second pre-response pause on other switches outside
this implementation, making device-side tap classification a plausible source;
this is an observation, not a measured attribution. The baseline also exposed
duplicate JSON decoding in both C4 entry points. The next development build
shares one parsed message between routing and gesture validation. Its regression
checks pass; its physical timing improvement remains to be measured.

## User-selected target

- HA connection: CHV, location `homeassistant-chv`, HA `2026.11.1` on HAOS.
- Physical control: Jeff's Office Switch, Zooz `ZEN76`, reported firmware `3.70.0`,
  Z-Wave node 7.
- Load: `switch.s2_on_off_switch`.
- Upper paddle: `event.s2_on_off_switch_scene_001`.
- Lower paddle: `event.s2_on_off_switch_scene_002`.
- Both native entities advertise `KeyPressed`, `KeyPressed2x` through
  `KeyPressed5x`, `KeyHeldDown`, and `KeyReleased`. This is a reported capability
  list, not confirmation that each gesture was physically tested.
- The queried C4 project contains the Chowmain Home Assistant Gateway
  (`chowmain_homeassistant_gateway.c4z`, version `20261008`). The stock bphillips
  HA Coordinator is not present in that project's queried item inventory.

The HA MCP supplies file deployment, configuration editing, authenticated reads,
and a C4 REST probe. The connected Portainer does not host CHV.

### CHV deployment evidence

On November 14, 2026, the user approved a scoped MCP access expansion, deployment,
and one HA restart. The HA settings UI granted the additional
`custom_components/ha_gesture_bridge` path and YAML `event` key, retaining the
existing `custom_components/c4_probe` access. MCP uploaded the four component
files and added the example's upper-paddle configuration through managed YAML
editing. No existing `event:` entries were present. Configuration validation
passed before the restart.

After the restart, MCP read back `event.jeffs_office_gesture_proof` with:

- Contract version `1.0` and control ID `jeffs_office_gesture_proof`.
- `bridge_update_kind: snapshot`, state `unknown`, and no gesture occurrence.
- Ready, available native source; capabilities `top/press_2` and `top/press_3`.
- Linked load `switch.s2_on_off_switch`, available and reporting `on`.

The live snapshot passed the local v1 JSON Schema and semantic validator. The
native upper-paddle entity still contained its older press timestamp; the new
bridge did not publish that history as a gesture. No load or scene command was
sent by the deployment tools.

The user then physically double- and triple-tapped the upper paddle. Recorder
history, retrieved through MCP, showed the following new publications in the
same producer session (times are America/Denver on November 14, 2026):

| Native event | Bridge gesture | Sequence | Bridge publication time |
| --- | --- | --- | --- |
| `KeyPressed2x` | `top/press_2` | 1 | `19:12:51.599766-07:00` |
| `KeyPressed3x` | `top/press_3` | 2 | `19:12:54.644283-07:00` |

All five recorded bridge publications (three startup snapshots and two live
gestures) passed contract validation. History contained one double press and one
triple press, so repeated identical physical gestures remain unverified. This
confirms native-source-to-bridge delivery in HA; delivery through the stock
coordinator into Composer remains pending.

## Build the proof artifacts

```sh
git submodule update --init --recursive
.venv/bin/python -m tools.build_transport_proof
```

Outputs:

- `dist/HA.Gesture.Transport.Proof.c4z`: isolated counter/event driver, including
  the pinned base and shared decoder. It has no relay and sends no load commands.
- `dist/ha_gesture_bridge-0.1.0.zip`: development HA component, independent of C4.
- `examples/transport-proof.yaml`: initial upper-paddle configuration for the
  user-selected office switch. The full two-paddle/config-flow implementation is
  a later milestone.

## Required access

1. A legitimate CHV configuration deployment path for the new component, such as
   existing HAOS SSH/App/Samba access or an explicitly expanded MCP allowlist, and
   its normal config-check/restart procedure. Do not write through `c4_probe` to
   evade its filesystem restriction.
2. Composer access to add the stock bphillips HA Coordinator and this isolated
   proof driver. The existing Director REST probe does not install drivers.
   Configure the coordinator for CHV with its usual credentials and bind the
   proof driver's Device Link to it. Leave the existing Chowmain setup intact.

## Acceptance procedure

1. Deploy/configure the HA component using the example, confirm the actual
   aggregate entity ID, and assign that ID to the proof driver. The expected
   suggested ID is `event.jeffs_office_gesture_proof`; verify it rather than
   assuming it was not suffixed by HA.
2. Verify the proof driver reads capabilities and an initial snapshot. It must
   register events after late initialization without incrementing Gesture Count.
3. Reset proof counters. Double-tap the upper paddle twice, separately. Gesture
   Count must become 2, with Last Gesture `top/press_2`. Observe the matching
   Composer event for each occurrence.
4. Triple-tap once. Gesture Count must become 3 with `top/press_3`.
5. Observe a normal linked-load on/off update or a permitted isolated snapshot
   test. The snapshot/load metadata must update while Gesture Count stays fixed;
   the last physical press must not replay. Do not use a scene-changing action as
   the proof's event response.
6. Invoke Refresh. The returned initial-state response must not increment Gesture
   Count, even if the aggregate's last update was a live gesture.
7. Reconnect the stock coordinator. Confirm the primary aggregate Entity ID is
   resubscribed. Historical presses must not replay; the first fresh double press
   after readiness must increment the counter once.
8. Record actual coordinator/controller versions, driver ID, observed counts,
   snapshot/gesture markers, and results. The real-controller proof remains
   incomplete until this evidence exists. Broader multi-control/restart/rollback
   tests are required before production release.

## Results

| Check | Result |
| --- | --- |
| HA schema, real EventEntity lifecycle, native-source and HA-to-Lua tests | 58 local pytest checks passed against HA 2026.11.1 |
| Shared Lua suite | LuaJIT and Lua 5.5: 17 states, 9 expected fires, 236 assertions including 25 malformed cases |
| Proof entry points | Both runtimes count 9 expected events and send no load commands |
| CHV component deployment | Deployed through MCP; configuration checked, one approved restart; live snapshot passed contract validation |
| Physical double/triple taps reach HA bridge | Confirmed in recorder history, sequences 1 and 2; both pass contract validation |
| Stock coordinator and proof driver in Composer | Pending installation/access |
| Physical double/triple taps reach Composer | Not run |
| Real coordinator reconnect and load-only update | Not run |

The proof driver allocates event IDs in memory only at this milestone. Persisted
production mappings and the final switch/generic packages are later tracked tasks.
