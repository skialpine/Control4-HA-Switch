# User-facing Low issue cleanup audit: 2026-11-15

**No new Critical, High, Medium or Low findings in the cleanup.** Switch no longer exposes tracking-color settings that it cannot apply, and the LED documentation now distinguishes Switch's immediate controls from Dimmer's working bound-device tracking. The previously reported Medium functional findings remain open; this cleanup does not claim to resolve them.

Scope: the eight-file change made for this request, compared with an exact pre-edit source snapshot: **38 lines added, 104 removed**. Reviewed the changed functions in full, their lifecycle/diagnostic callers, both driver schemas, relevant actual-entrypoint tests and documentation. The small change was reviewed directly, following audit-code's small-diff method. No AGENTS.md or CLAUDE.md applies in this scope; existing installation and development requirements remain the criteria.

Files: `commands.lua`, `driver.xml`, `module/property_screen.lua`, `docs/leds.md`, `docs/dimmer.md`, `www/documentation/index.html`, `tests/controller/test_switch_driver.lua`, `tests/test_switch_package.py`.

Validation: **82 C4 tests passed, one external-parser check skipped, 8.35s**, with HA, Coordinator and Light Group checkout variables enabled. Both Lua runtimes exercised the actual driver entrypoints. The optional HA service roundtrip, packaged discovery and original Switch compatibility checks ran. The HA integration and Coordinator implementation were not changed. No live HA/controller settings or hardware were changed during this cleanup or audit.

## 1. Architecture & modularity

Nothing new found.

Closed follow-up F1: removed Switch's LED On Color, LED Off Color and tracking Indicator properties, their callbacks, and the two new tracking-color programming commands. Removed the unused Switch color-rendering calls. Immediate Current Color, All Colors, Brightness and explicit Behavior commands remain, including per-indicator command choices.

Dimmer retains its On/Off color pickers, indicator selection, native/custom LED commands and Follow Bound Device implementation. Shared advanced-property rendering and diagnostics now touch tracking-color fields only for the driver that declares feedback support. No new feature flags, state machines or migration paths were introduced.

Original Switch proxy, connection identities, entity selection and released on/off programming remain unchanged. Existing persisted LED preference data is retained rather than erased.

## 2. Security & error handling

Nothing new found.

The cleanup adds no transport or hardware-write path. Retired commands have no handlers or parameter choices; attempts to call them cannot issue an HA service request. Basic/advanced setup no longer addresses undeclared Switch color properties. Current-color requests still preserve the hardware behavior field, and existing readiness/ownership checks remain in force.

The Director BOOL correction and unknown/wrong-source rejection remain covered by Dimmer's unchanged tests.

## 3. Performance & scalability

Nothing new found.

Switch performs less property-rendering work. Dimmer keeps its existing property caching and behavior. No new reads, locks, timers, retries or subscriptions were added. The slowest check was the real-HA catalog transport at 1.20s; the actual LED roundtrip took 1.05s in Lua and 1.03s in LuaJIT.

## 4. Readability & maintainability

Nothing new found.

Closed original L2: `docs/dimmer.md` no longer says indicator LED colors are unsupported. The shared LED guide and Switch's embedded Documentation tab now identify Dimmer-only tracking preferences explicitly and describe the Switch controls that actually act on an indicator.

The reuse sweep found no replacement copies of the retired Switch tracking implementation. Palette mapping and persistence remain shared; the working Dimmer color conversion/rendering stays in the existing shared screen module.

## 5. Test simplification

Nothing new found.

The unsupported Switch picker scenarios were replaced by a regression checking the absence of tracking properties/commands, no calls to undeclared property attributes, retained saved data, and working immediate color control. Dimmer's actual picker/palette/multiple-indicator tests remain. Consequently, the previously duplicated picker scenarios (original L5) no longer need a shared scenario helper: only the driver supporting the feature runs them.

Package tests verify the retired UI fields and commands are absent while the original connection/default/programming contracts remain. Full boundary checks pass.

## 6. Prioritised action plan

No further correction is required for the reviewed cleanup. Build and deliver Switch 107 and Dimmer 1 with updated checksums; Coordinator 114 remains unchanged. No HA update or restart is needed.

The earlier Medium findings remain separate work:

| Severity | Existing item | Effort |
|---|---|---|
| Medium | Recover missing/stale LED confirmation after interrupted Z-Wave reads | S |
| Medium | Remove Switch's unsupported standard connected-light mode | S |
| Medium | Normalize Hue taps using provider/vocabulary context | M |
| Medium | Reduce repeated full-state transfers for large catalog discovery | M/L |

Existing internal-only Low findings also remain: write-only LED state, duplicated static light-capability validation, cross-repository CI coverage, and the model-encoding test's production-derived expectation. Their details and functional fix snippets are in the [first audit](audit-current-2026-11-15.md) and [follow-up](audit-followup-2026-11-15.md).

Land this UI/documentation correction as one C4 batch. Keep the HA backend, source-profile, discovery-performance and CI batches separate as previously described; fold simplification-only items into batches already touching their files. No commits, pushes, publishing or live deployment were performed.
