# Native HA Light

HA Light is a fresh-install `light_v2` driver, version 1. HA Switch remains the compatible on/off consumer. The Coordinator remains compatible with existing family drivers. Both consumers reuse the same discovery, capability, gesture and Button Link modules.

## Load behavior

In Direct mode, select `light.*` for brightness. Metadata determines whether native Set Level and Ramp are supported. A zero-percent target calls `turn_off`; nonzero targets call `turn_on` with 0–255 brightness. Positive ramp durations become HA transition seconds only when transition support is advertised. Registered HA switches also appear in Select Device and work as native On/Off lights in Navigator, without another relay-to-light driver. Brightness controls are disabled for them. Manually selected input_boolean helpers also support On/Off/Toggle.

The driver sends native brightness feedback only from confirmed HA state. An off state reports zero; an on/off-only load reports 100 when on. A dimmable light that is on without valid brightness remains unready rather than assuming full brightness. Capability and brightness notifications are cached to avoid repeatedly resetting native settings. SYNCHRONIZE explicitly resends state.

Control4 may send native On/Off commands as level targets. For a binary switch or a confirmed on/off-only light, zero calls `turn_off` and any valid positive target calls `turn_on`, without brightness or transition fields. Timed ramps remain unsupported for binary devices. Missing or malformed HA light capabilities do not authorize this binary conversion.

Control HA Device with Button Events uses the same logic on an explicitly linked load. A light-linked aggregate requires bridge contract 1.1 with typed `supported_color_modes`, `supported_features` and optional `brightness`. Version 1.0 switch/input_boolean aggregates remain valid. Changing linked-load brightness updates metadata only; gesture identity, sequence and timestamp stay unchanged.

## Programming

The native proxy supplies its lighting Commands, Conditionals and Loops. Top/Bottom/Toggle single, double and triple taps map to native button action notifications. Explicit hold-start and release map to native pushed/released actions. A completed tap does not fabricate a physical push/release pair. Custom actions, additional buttons, higher counts and hold repeats remain separately allocated custom events.

Native programmatic button commands acknowledge successful logical actions so the proxy can track its button state. They do not increment physical Gesture Count. Continuous HA raise/lower/stop is not implemented without a verified backend; unsupported press/hold paths are rejected. Control Connected C4 Light mode instead forwards logical holds/releases to the connected C4 light, which implements its own dim/stop behavior.

Supported indicator LEDs expose color, brightness and behavior controls through HA Gesture Bridge, including On/Off tracking colors for a connected C4 light. See [indicator LED setup](leds.md). Backlight, auto-off, load color lighting, Advanced Lighting Scenes and load groups are not implemented. DeviceSide has not been changed or qualified as a backend.

Programming Events Only and Control Connected C4 Light modes do not control an HA load. In connected-C4 mode, the app tile mirrors the selected C4 target: On/Off, brightness, dimming capability and default On preset. Native load conditions use that target feedback and are hidden when no readable target exists. Physical gesture readiness is separate from app target readiness. Native condition visibility needs Control4 OS 4.2.1 or newer; older UI behavior still requires live qualification.

## Controller connections

**App Control Link** selects the Top, Bottom or Toggle Controller Link whose light the app tile controls (default Top). **Connected Light** shows the resolved target name. Physical paddles retain their individual connections, including when they control different lights. The target can be an ordinary Light V2 driver or a Light Group; no HA export is required. A dimmer target enables the slider and a binary target exposes On/Off only. Commands go to the target proxy; variable listeners return its actual state and On preset without optimistic brightness or HA load calls. App control continues locally if HA is disconnected; physical gestures still require HA. Missing, ambiguous and self targets are blocked. Color controls remain on the target light.

Navigator's native On action identifies the On/Previous On brightness preset. The driver forwards that action as logical On so the connected target applies its current On mode, including a nighttime brightness limit. An explicit slider percentage remains that exact percentage; it is never guessed to be an On action because its number matches a preset.

Select a device in **Actions > Select Device**. In every operation mode, a physical switch's gesture control replaces its ordinary relay/light entry when HA's optional catalog reports a preferred representation. Devices without a gesture control remain ordinary switch/dimmer choices. Equivalent non-inverted switch-as-light wrappers still consolidate. Separate independently addressable endpoints, multiple controls for one device and unproven associations stay separate rather than guessing. Saved Entity IDs and modes are never changed merely by discovery.

Selecting a gesture-enabled device automatically chooses **Control Connected C4 Light** when an external Controller Link is bound. Without that connection it uses the control's linked HA load, or **Programming Events Only** when none is linked. Selecting an ordinary device chooses **Control HA Device**. Device selection establishes a fresh default; you can change Operation Mode afterward and that manual choice survives reloads/restarts. Connecting an external Controller Link also selects controller mode unless manually overridden. Existing connections are detected at startup. Disconnecting links leaves the mode unchanged; self-connections do not activate it.

Source association is discovery metadata, separate from the controlled HA load: a gesture-only control does not gain permission to command its physical relay. HA chooses preferred entities using its registry and exports exact aliases. C4 checks that the preferred target exists in native discovery; it does not infer physical source relationships again. Without a usable catalog, ordinary native switch/light choices and explicit gesture selection remain available. Both paths avoid automatic whole-registry requests.

In this mode, use **Top Controller Link** (203), **Bottom
Controller Link** (204) and **Toggle Controller Link** (205). These are
consumer-side `BUTTON_LINK` connections and appear under **Control Inputs** in
Composer. The target light/group provides lighting control through its output;
the HA Light consumes that control and sends `DO_PUSH`, `DO_CLICK` and
`DO_RELEASE` commands back across the connection. Composer's input/output role
does not restrict every message to that direction.

For Light Group, connect Top Controller Link to **On Button Link** (300), Bottom
Controller Link to **Off Button Link** (302), and an actual toggle source's
Toggle Controller Link to **Toggle Button Link** (301). The group already owns
click/hold/release handling and dim/stop execution. Its HA light export and
DeviceSide are not required for this route.

The existing Top/Bottom/Toggle **Button Link** provider connections (200–202)
remain available for another keypad/controller to operate this driver's own HA
load in Direct or Gesture Bridge mode. Their identities and roles are retained;
they are not the controller links used to drive a separate C4 light. This
consumer-connection addition applies only to HA Light; HA Switch is unchanged.

## Qualification still required

For testing, set **Properties > Debug Mode = On**, then open the **Lua** tab.
Lines prefixed `HA Light` show the selected entity/mode, primary HA event
summary, decoder acceptance/rejection reason, received native commands,
forwarded controller binding/command, and binding/source cleanup. This helps
distinguish a missing HA event from a rejected gesture or a forwarded command.
The trace prints allowlisted fields rather than raw HA JSON, credentials or
unrelated entity payloads. Debug Mode defaults to **Off**; turn it off after
testing. Status and gesture properties continue working while logging is off.

Add a new instance and verify its native Composer UI, standard/custom gestures, capability changes, physical dimming and timed transitions. Check If/While behavior during availability loss, native programmatic buttons without feedback loops, saved programming after reload, and Button Links with the actual target light. Automated entry-point tests cannot establish how a real controller renders or schedules native proxy messages.

[Installation and selection](installation.md) explains the separate package identities. [Smart-switch setup](smart-switch-setup.md) explains relay decoupling and connections.

## Live controller evidence

On November 15, the user confirmed physical top/bottom single-tap and hold/release control of the connected C4 light, and bottom double-tap Composer programming. See [transport evidence](transport-proof.md). Other qualification remains open. Debug lines now include local millisecond timestamps and receive-to-forward timing; these measure C4 driver processing only.

Receive traces include `received_utc` at one-second resolution, plus local millisecond timestamps. Compare UTC times only after checking HA/controller clock synchronization. The processing timer excludes time before the C4 callback, including switch classification and HA/network transport. A 1–2 second physical pause remains under investigation; changing the target fade duration cannot establish its cause.

## Opt-in acknowledgment timing

Set **Debug Mode = On** and **Latency Diagnostics = On** to acknowledge freshly
accepted events when HA Gesture Bridge 0.1.1 or newer advertises acknowledgment
support. Both settings default Off; ordinary use sends no diagnostic traffic.
Snapshots, duplicates and rejected inputs are never acknowledged. Older bridge
versions continue working and receive no unsupported service call.

C4 records receive, processing-complete and (when sent) Controller Link forwarding
UTC epoch timestamps. Local processing uses the monotonic tick clock when
available. HA measures publication-to-ack return on its own monotonic clock and
exposes bounded samples through integration diagnostics under
`latency.latest_latency_samples`, including HA publish/ack UTC timestamps and
the supplied C4 timestamps. These timestamps correlate the logs; they are not
assumed synchronized. See the [Control4 timer API](https://snap-one.github.io/docs-driverworks-api/#gettime).

Round-trip time is an upper bound on forward delivery for that event, not an
exact one-way measurement; the return path may differ. The clock-dependent
`ha_to_driver_ms` estimate must not be interpreted as latency before verifying
clock alignment. No timing here measures mechanical click to scene report, or
C4 forwarding to physical light response. Turn both diagnostics settings Off
after testing. No Coordinator update or HA load command is needed for an ack.

## Selected-state recovery

On startup, source selection, Coordinator attachment and HA reconnection, the driver waits for a fresh snapshot of its selected entity before accepting physical gestures. A missing response retries only that entity, at five-second intervals with at most five attempts. A valid snapshot ends retries without replaying the stored gesture. With a current Coordinator, live event subscription must also be acknowledged: a successful state read alone cannot hide a failed subscription. The state and acknowledgment can arrive in either order. Older Coordinators retain their selected-state behavior. Healthy operation does not poll state or rebuild discovery. While waiting, Status explains whether state or subscription is missing. Coordinator diagnostics report selected-state requests separately from entity discovery.
