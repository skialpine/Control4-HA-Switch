# Functional fixes follow-up audit: 2026-11-15

The follow-up review found **0 Critical, 0 High and 0 Medium issues remaining** in the reviewed changes across Switch/Dimmer, Coordinator and HA Gesture Bridge. All four Medium findings from the earlier audit are resolved. A timeout-budget defect discovered while reviewing the new catalog transport was also fixed and re-reviewed before packaging.

Scope: the corrections following `audit-current-2026-11-15.md` and `audit-followup-2026-11-15.md`, including changed functions, callers, package contents and boundary tests. Independent reviewers covered C4 behavior, HA profiles/LED recovery, Coordinator transport and tests; their findings were verified against source. No in-scope AGENTS.md or CLAUDE.md applies. Original Switch compatibility, Coordinator family compatibility, optional integration support and fixed development version numbers remain audit criteria.

Offline validation:

| Scope | Result |
|---|---|
| C4 with HA, Coordinator and Light Group checkouts enabled | 82 passed, 1 skipped; 8.19s |
| HA with actual C4 consumer checks enabled | 414 passed; 8.84s |
| Coordinator discovery, Lua and LuaJIT | 26 tests per runtime |
| Coordinator original-family compatibility, Lua and LuaJIT | 11 original drivers; 265 assertions per runtime |
| Coordinator transport/security, Lua and LuaJIT | 110 assertions per runtime |
| Final catalog checks after tightening byte-accounting assertions | 4 passed; 4.01s |

The C4 skip concerns the external Light Group source under the newer local Lua parser; the actual LuaJIT group boundary passed. These results do not qualify every hardware model or Composer version. Versions remain Switch 107, Dimmer 1, Coordinator 114 and HA 0.1.2.

## 1. Architecture & modularity

No Medium-or-higher findings remain.

Closed M1: Switch offers only its three supported modes. Its original Relay 1, provider Button Links, incoming keypad commands and released on/off programming remain intact. The unsupported external-light forwarding branch and its new programming command were removed. A retired beta mode fails closed with guidance to use Dimmer rather than silently changing what controls the load. Dimmer retains its consumer Controller Links and connected-light mode.

Closed M2: `HA-Gesture-Bridge/custom_components/ha_gesture_bridge/gesture_profiles.py:63`, `native_action_definition`, uses the provider and advertised vocabulary to normalize Hue short taps and Tap Switch presses. Hold repeat is recognized only alongside the corresponding hold/release vocabulary. Unknown/non-Hue actions retain their previous semantics. Registry-to-publication tests cover short taps, holds, Tap Switch and rotary inputs. Existing saved Hue mappings adopt this profile when explicitly reconfigured; no control identities are rewritten automatically.

The reuse sweep retained shared gesture/LED modules and extracted common API URL, authentication and TLS options for Coordinator's existing and new HTTP paths.

## 2. Security & error handling

No Medium-or-higher findings remain.

Closed M3: `zwave_indicator.py:240`, `_publish_confirmation`, guards publication against shutdown, node replacement and stale controller ownership. Both `zwave_indicator.py:286` and `zwave_parameters.py:149` invalidate incomplete or failed confirmation. The existing poll then recovers missing readback without adding another timer, retry policy or hardware write. Tests cover initial and previously complete confirmation, partial mode/color reads, malformed reports and retired owners.

Coordinator's projected read uses a fixed template with entity IDs and attribute names passed as JSON variables, not interpolated code. Existing credentials/TLS settings are reused; redirects abort; canceled requests and stale connection generations cannot publish. Unsupported or non-admin template access falls back to the original authenticated WebSocket discovery path. Legacy state broadcasts and service interfaces are unchanged.

## 3. Performance & scalability

No Medium-or-higher findings remain in the reviewed implementation.

Closed M4: `Control4-HA-Coordinator/module/state_projection.lua` and `driver.lua:127` use HA's built-in template endpoint for exact-ID attribute projection when registry enrichment is unnecessary. Broad listings retain the original WebSocket path. The real-HA 1,400-entry fixture transferred **295,099 bytes instead of 14,169,326 bytes** across 19 catalog reads, approximately 48 times less. This measures discovery traffic, not physical click latency.

The first implementation gave the optional HTTP attempt the entire discovery deadline. Follow-up review caught this Medium defect: `driver.lua:151` now limits the optional attempt to three seconds, leaving time for WebSocket fallback inside the existing 15-second request budget. A fake-clock timeout-to-fallback regression passes. Other existing REST requests retain their original timeouts.

Non-admin credentials still work through fallback, with the previous full-state transfer cost. No HA permission expansion or new HA configuration is required.

## 4. Readability & maintainability

Three previously recorded Low items remain; none blocks the requested Medium-and-higher cleanup:

| Severity | Location | Item |
|---|---|---|
| Low `simplify` | `Control4-HA-Switch/module/leds.lua:118,125,210,303,315` | Write-only `states` bookkeeping can be removed when next touching this module. |
| Low `simplify` | `HA-Gesture-Bridge/custom_components/ha_gesture_bridge/event.py:134`; `sensor.py:59` | Static light-capability vocabulary/validation is duplicated. Share it when those projection paths next change. |
| Low | Both repositories' `.github/workflows/test.yml` | Standalone CI omits optional sibling-checkout boundary tests; add a pinned cross-repository integration job when compatible revisions can be published. |

The earlier user-facing Switch color-property and outdated-documentation findings are closed. Switch's embedded Documentation tab no longer advertises external-light forwarding. Dimmer's working bound-device color controls remain.

## 5. Test simplification

No Medium-or-higher findings remain.

The Zooz encoding regression now uses independent literal expectations rather than deriving expected values from production mappings; an in-memory mutation was detected by the relevant cases. Unsupported Switch color-picker scenarios were removed while Dimmer's real entrypoint scenarios remain.

Catalog tests render the actual Coordinator template inside real HA, then pass its output through the bounded Coordinator/C4 consumers. Final review tightened the fixture so names-page requests cannot silently use uncounted full-state fallback. Transport tests cover authorization fallback, cancellation, connection reset, redirects, malformed responses, TLS options and the shortened optional-read deadline.

## 6. Prioritised action plan

| # | Severity | Item | Effort | Impact/effort |
|---|---|---|---|---|
| 1 | Low | Add pinned cross-repository CI coverage when compatible revisions are available | M | High |
| 2 | Low `simplify` | Remove write-only LED state when editing that module | S | Medium |
| 3 | Low `simplify` | Share static HA light-projection vocabulary when editing those paths | S | Medium |

No Medium-or-higher correction remains outstanding in this review. Keep the C4 supported-mode cleanup, HA LED recovery, HA Hue normalization and Coordinator projection changes in cohesive implementation batches; fold simplification-only work into later batches already touching the relevant files. Preserve existing driver instances and bindings when loading packages. No commit, push, PR publication or issue filing was performed by the audit.
