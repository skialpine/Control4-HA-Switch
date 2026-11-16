# Current three-repository audit: 2026-11-15

The current implementation has **0 Critical, 0 High, 4 Medium and 5 Low findings**. The Office LED feedback fix is confirmed live and is covered by serialization regressions. The most useful next correction is LED readback recovery: an interrupted read can prevent the existing polling mechanism from recovering missing or stale confirmation.

Scope: uncommitted changes, including new source/tests/docs, in `Control4-HA-Switch` (HEAD `f55526b`), `Control4-HA-Coordinator` (`dccd545`) and `HA-Gesture-Bridge` (`16ec8b2`). Changed/new source and test files contain approximately 26,365 lines, including whole modified files but excluding unchanged vendored code. Changed functions and their relevant callers were reviewed; this is not a review of every unchanged upstream function.

The audit used independent C4 runtime, HA setup, HA LED and test reviewers, followed by verification and a reuse sweep. No in-scope AGENTS.md or CLAUDE.md was found. README, development, installation, compatibility, contract and contribution requirements were used as criteria. No runtime code, configuration, hardware settings or live installations were changed by this audit.

Validation, offline:

| Scope | Result |
|---|---|
| C4, with HA/Coordinator/Light Group checkout variables enabled | 82 passed, 1 skipped, 8.91s |
| HA, with actual C4 consumers enabled | 401 passed, 9.17s |
| Coordinator discovery, Lua and LuaJIT | 26 tests passed per runtime |
| Coordinator original-family compatibility, Lua and LuaJIT | 11 original drivers; 265 assertions passed per runtime |
| Coordinator transport/security, Lua and LuaJIT | 75 assertions passed per runtime |

The C4 skip is the external Light Group implementation under the local newer Lua parser; its LuaJIT boundary ran. Dependency deprecation warnings remain, with no test failures. Coordinator has Lua suites rather than a standalone pytest suite. The slowest C4 test was the actual HA LED roundtrip at 1.43s; the slowest HA test was the existing inactivity case at 0.15s. These results do not establish physical qualification of additional models or every Composer/Controller version.

## 1. Architecture & modularity

| ID | Severity | Location / function | Finding and normal-use trigger | Effort |
|---|---|---|---|---|
| M1 | Medium | `Control4-HA-Switch/driver.xml:34`; `commands.lua:26`; `module/button_link.lua:10` | Switch offers **Control Connected C4 Light**, but forwards using original provider bindings 200–202. Standard C4 lights/groups also provide their light-control Button Links, so Composer cannot connect this advertised path to them. Only Dimmer supplies consumer links 203–205. Selecting the Switch mode therefore promises an external-light connection route that Switch does not provide. | S |
| M2 | Medium | `HA-Gesture-Bridge/custom_components/ha_gesture_bridge/gesture_profiles.py:21`; `device_discovery.py:131`, `_native_buttons` | Provider-independent normalization maps Hue `short_release` to release and leaves `initial_press` custom. A normal Hue short tap never becomes `press_1`, so it does not drive a connected C4 light. Hue Tap Switch's initial-press-only vocabulary also has no normalized click. | M |

M1 is partly acknowledged by `module/operation_mode.lua:23`, which recommends Dimmer, but the selectable mode and Switch's embedded documentation still advertise the route. Removing this new Switch-only mode does not require changing its original proxy, relay, on/off programming or provider bindings.

M2 was reproduced offline through actual HA registries and `discover_device → build_config → NativeControlConfig.parse`. HA 2026.11.1's installed `components/hue/const.py:48–55` declares `initial_press`, `repeat`, `short_release`, `long_press`, `long_release`; line 65 declares Hue Tap Switch's override. The resulting bridge definitions were custom, custom, release, hold_start, release, with no single tap. C4 `module/button_link.lua:212` correctly requires normalized press/count 1 for a click. This is a missing contextual profile, not a reason to fabricate multi-taps or globally reinterpret every initial press.

Good patterns to retain: shared gesture/LED/discovery modules, separate fresh Dimmer identity, original Switch topology, conservative capability-derived controls, and independent hardware behavior versus saved LED colors. No Coordinator family-API regression was found in the reviewed changes and the original-family suite passed.

## 2. Security & error handling

| ID | Severity | Location / function | Finding and normal-use trigger | Effort |
|---|---|---|---|---|
| M3 | Medium | `HA-Gesture-Bridge/custom_components/ha_gesture_bridge/zwave_parameters.py:157–166`, `_read`; `zwave_indicator.py:205`, `_refresh`; `zwave_indicator.py:277`, `_read` | A transient LED readback failure can leave a nonempty confirmation that the existing poll treats as complete. The profile backend commits partial mode-only confirmation in `finally`; the standard backend can retain its previous confirmation when Get raises. Neither state causes the five-second missing-confirmation poll to retry. | S |

Verified profile reproduction: mode Get returned 3, then color Get raised `ServiceValidationError`. The actual class retained `{'status': {'mode': 3}}`; three `_refresh` calls scheduled zero reads. Color/brightness remain unknown until a separate node event or explicit LED action occurs. This can happen during startup/reconnect or post-command readback.

A separate probe of the actual standard-indicator `_read` confirmed that a failed Get retained an old `always_off`/black confirmation, and the poll's missing-confirmation predicate was false. After a successful write followed by a failed readback, this can leave old feedback displayed until another event arrives. These share one recovery fix and are counted once.

No additional security defect was verified. Preserve credential redaction, discovery projection and byte limits, generation guards, TLS verification, diagnostic allowlists, schema/owner rechecks after awaits, and raw hardware readback. The recent Director parser now accepts actual `"False"`/`"True"` forms, booleans and 0/1, while rejecting unknown values rather than treating them as Off.

## 3. Performance & scalability

| ID | Severity | Location / function | Finding and measured trigger | Effort |
|---|---|---|---|---|
| M4 | Medium | `Control4-HA-Switch/module/catalog_enrichment.lua:74,106`, `_request` / `_complete`; `Control4-HA-Coordinator/driver.lua:82`, discovery fetch | Every optional catalog names page starts a fresh `get_states` request. Projection bounds the C4 reply only after the entire HA state response has crossed the WebSocket and been decoded again. A large catalog repeatedly retransmits its own full catalog and all page attributes. | M/L |

An offline probe reused the existing real-HA 1,400-row transport fixture: **18 names pages, 19 `get_states` requests for names alone**. Even the fixture containing only the catalog sensor produced a **745,803-byte** compact state response, yielding **14,170,257 bytes** across those 19 reads. A real response also includes the other HA states, so this is a lower bound, excluding initial native discovery and registry traffic. The projection and packet-size checks remain correct; this finding concerns amplification before projection.

Evaluate bounded snapshot reuse or a paged catalog transport that does not refetch the full native snapshot for each attribute page. Retain cancellation, query/owner correlation, freshness and memory limits. This needs a design and controller measurement rather than an arbitrary cache lifetime. No live gesture-delay measurement is attributed to this issue.

Other resource limits, cleanup, cached native publications and test timings were reasonable in the reviewed paths. No speculative race was promoted to a finding.

## 4. Readability & maintainability

| ID | Severity | Location | Finding / recommendation | Effort |
|---|---|---|---|---|
| L1 | Low `simplify` | `Control4-HA-Switch/module/leds.lua:118,125,210,303,315` | `states` is written and cleared but never read by runtime code. Only one test asserts that it clears. Remove the field and its write-only bookkeeping; retain `bound_follow`, saved preferences and confirmed metadata. | S |
| L2 | Low | `Control4-HA-Switch/docs/dimmer.md:19` | “LED colors … are not claimed” contradicts the implemented native/custom LED commands, property color pickers and live-qualified Office behavior. Describe indicator support and link to `leds.md`; keep unsupported load-color/backlight/auto-off features distinct. | S |
| L3 | Low `simplify` | `HA-Gesture-Bridge/custom_components/ha_gesture_bridge/event.py:134–142`; `sensor.py:59–75` | Light capability vocabulary and projection validation are repeated. Share the static vocabulary/common validation when these files are next touched, preserving the event snapshot's additional brightness field and any intentional input-type differences. | S |

The reuse sweep also checked new property conversion, BOOL parsing, JSON guards and channel-choice helpers. RGB property conversion belongs at the Composer boundary, whereas palette mapping remains in the shared LED controller. Cross-language validation on each side of the HA/C4 contract is necessary and is not classified as duplication debt.

## 5. Test simplification

| ID | Severity | Location | Finding / recommendation | Effort |
|---|---|---|---|---|
| L4 | Low | `Control4-HA-Switch/.github/workflows/test.yml:20`; `HA-Gesture-Bridge/.github/workflows/test.yml:14` | Checked-in CI runs plain pytest without sibling checkouts or the checkout variables, so the actual multi-repo LED/catalog/package/consumer checks skip. HA CI also lacks Lua. Add one integration job using explicit compatible revisions and the existing opt-in variables; keep independent local testing optional. Current full local boundary results pass, so this is coverage debt rather than a current runtime failure. | M |
| L5 | Low `simplify` | `Control4-HA-Switch/tests/controller/test_switch_driver.lua:1075`; `tests/controller/test_dimmer_driver.lua:1176` | The color-picker and following multi-indicator scenarios are copied almost verbatim. Extract shared scenarios parameterized by each existing driver setup adapter, while retaining separate actual entrypoint and native-proxy checks. | S |

Add missing behavior regressions with M2 and M3: actual Hue short/long/Tap Switch vocabularies, and one interrupted LED Get followed by recovery on the existing poll without an LED write. These are not additional findings. Keep the 14 accepted Director BOOL forms, invalid-state rejection and wrong-source tests added for the live feedback failure.

The Group harness transports Lua values directly; it verifies actual group handlers but does not emulate Director serialization. Existing documentation correctly identifies that transport as simulated. Most time-sensitive tests use fake clocks; the small 150ms inactivity sleep was not an observed flake and is not a separate finding.

## 6. Prioritised action plan

| # | Severity | Item | Effort | Impact/effort |
|---|---|---|---|---|
| 1 | Medium | M3: invalidate interrupted LED confirmation so the existing poll can recover | S | High |
| 2 | Medium | M1: stop offering Switch's unsupported standard-light connection mode | S | High |
| 3 | Medium | M2: normalize Hue gestures with provider/vocabulary context | M | High |
| 4 | Medium | M4: reduce repeated full-state transfers for large catalogs | M/L | Medium; measure on controller |
| 5 | Low | L2: correct obsolete Dimmer LED documentation | S | High |
| 6 | Low | L4: run pinned multi-repository checks in CI | M | High |
| 7 | Low `simplify` | L1: remove write-only LED state | S | Medium |
| 8 | Low `simplify` | L5: share property-picker test scenarios | S | Medium |
| 9 | Low `simplify` | L3: share static light capability vocabulary/projection | S | Medium |

### Minimal corrections without new runtime machinery

**M3 — `ZWaveParameterLEDController._read`, `zwave_parameters.py:157`.** Clear the temporary partial result on a transport/ownership validation failure, then let the existing owner-guarded `finally` publish empty confirmation. The existing poll can retry. Simply removing `finally` is insufficient when an older complete confirmation already exists.

```python
        try:
            for role, schema, mapping in settings:
                response = await self._invoke(channel, node, "get", schema.parameter)
                if type(response) is int and response in mapping:
                    confirmed[role] = mapping[response]
        except ServiceValidationError:
            confirmed.clear()
            raise
        finally:
            if (not self._closed and self._node is node
                    and _resolve_node(self.hass, self.device_id) is node):
                self._confirmed[channel.id] = confirmed
                self._notify()
```

The standard-indicator `_read` at `zwave_indicator.py:277` likewise needs invalidation when its awaited Get fails, rather than retaining a nonempty previous confirmation:

```python
        try:
            response = await self._invoke(
                channel, node, "get", *([] if channel.legacy_id else [channel.indicator])
            )
        except ServiceValidationError:
            if self._node is node:
                self._confirmed.pop(channel.id, None)
                self._notify()
            raise
```

This reuses the current poll; it adds no state, lock, timer or retry policy. Tests should cover both initially empty and previously complete confirmation.

**M1 — Switch Operation Mode, `driver.xml:34`.** Remove only the newly advertised connected-light option from Switch, retaining it in Dimmer. Preserve all original connections and released on/off commands. Retire the unreachable Switch-only forwarding branch and its new `Button Action` command in the same cleanup; they are absent from original Switch 106.

```xml
<items>
  <item>Control HA Device</item>
  <item>Control HA Device with Button Events</item>
  <item>Programming Events Only</item>
</items>
```

**M2 — `_native_buttons`, `device_discovery.py:128`.** Select definitions with provider and advertised vocabulary context, rather than globally changing initial-press semantics. The following fits inside the existing validated-action branch; it needs no runtime edge counting or timeout:

```python
                definition = action_definition(action)
                if entry.platform == "hue":
                    tap_only = len(event_types) == 1 and event_types[0] == "initial_press"
                    if action == "short_release" or (action == "initial_press" and tap_only):
                        definition = {"kind": "press", "press_count": 1, "label": "Single tap"}
                    elif action == "repeat":
                        definition = {"kind": "hold_repeat", "label": "Hold repeat"}
                actions[action] = definition
```

A provider-aware helper/profile is preferable when extending this to more integrations. Preserve unknown events as custom, and keep a Hue dimmer's initial press separate from its completed short tap so a hold does not also click.

### Landing batches

1. **C4 consumer batch:** M1, corresponding Switch tests/docs, L2 and L1; fold L5 into the same LED-test cleanup. Retain original Switch compatibility checks, then run the actual C4/Coordinator/Group boundaries. This batch does not require changing Coordinator's legacy API.
2. **HA LED backend batch:** M3 and its transient-read regressions in parameter and standard-indicator tests. No new retry mechanism is needed.
3. **HA source-profile batch:** M2 with real HA vocabulary fixtures. Keep L3 for a later change already touching the two projection files; do not expand this batch just to move constants.
4. **CI batch:** L4, using pinned compatible sibling revisions and explicit boundary environments.
5. **Discovery performance batch:** M4, separately designed and measured, retaining existing response/resource limits and family compatibility.

These batches mostly touch different runtime files; simplification-only items belong with the batch already editing those files. Re-run the appropriate suites before packaging. No fixes, deployment, publishing, commits or pushes were performed as part of this report.
