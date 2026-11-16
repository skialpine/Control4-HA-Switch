# LED fixes follow-up audit: 2026-11-15

**No new Critical, High or Medium findings; two additional Low findings.** The Director BOOL fix and Dimmer color-picker behavior remain sound in the reviewed paths. The previous audit's proposed corrections have not been applied, so its existing functional findings remain open.

Target: the current LED/property/feedback changes in `Control4-HA-Switch` (HEAD `f55526b`, including new Dimmer/shared files) and the corresponding HA LED implementation/tests in `HA-Gesture-Bridge` (HEAD `16ec8b2`). Coordinator is unchanged since the preceding review and was not subjected to a second full source audit. Its actual boundary was exercised by the C4 tests. This is a focused second review, not a claim that fixes from the first report have landed.

Independent reviewers read the C4 runtime, HA LED backend and related tests, followed by a verification/reuse sweep. No AGENTS.md or CLAUDE.md was found in either scope. README, contribution and LED/development guidance were used as criteria. No runtime code, configuration, packages or hardware settings were changed.

| Check | Result |
|---|---|
| C4 suite with HA, Coordinator and Group boundary variables | 82 passed, 1 external-parser skip; 8.98s |
| HA suite with actual C4 consumer checks | 401 passed; 9.14s |
| Focused HA LED/profile/Indicator suite | 130 passed; 2.89s |
| LuaJIT LED / actual Switch / actual Dimmer | 471 / 1,405 / 1,360 assertions passed |
| Independent test-strength probe | Swapped ZEN78 follow/inverted values in memory; all eight “correct device encoding” cases still passed |

The mutation probe modified only the Python process's imported objects. It did not edit a profile file or change any device. Dependency deprecation warnings remain; no tests failed on the unmodified implementation.

## 1. Architecture & modularity

| ID | Severity | Location / function | New finding | Effort |
|---|---|---|---|---|
| F1 | Low | `Control4-HA-Switch/commands.lua:97,103,123–124`; `driver.xml:107–108` | Switch exposes saved LED On/Off colors with no runtime consumer capable of applying them. A user can save red/green tracking colors, but those values cannot affect its indicator in any supported Switch mode. | S |

Verification: Switch always calls `control:set_bound_follow(false)` in `update_led_behavior_ui`. It has no `MATCH_LED_STATE` handler, `match` call or native LED preference notification callback. `set_all` writes its supplied argument and overwrites the preferences; it does not apply previously saved On/Off values. These fields therefore store/display unused settings. The documentation says they do not write immediately, but Switch offers no tracking policy that could apply them later.

This is distinct from the already-reported unsupported Switch connected-light mode. Prefer hiding/omitting Switch's new On/Off tracking settings and corresponding new commands until a supported consumer exists. Retain immediate color, brightness and explicit hardware behavior commands. Dimmer's functioning On/Off properties and tracking policy should remain.

Good: both drivers still share validation, palette mapping and persistence; separate proxy entrypoints preserve the original Switch installation contract.

## 2. Security & error handling

Nothing new found. The actual live `"False"` form is accepted, unknown state remains distinct from Off, and wrong-source feedback cannot request an LED change. Hardware requests remain gated by current source/transport metadata and explicit policy. Rendering and saving color preferences do not change hardware behavior.

The previous Medium readback-recovery finding is unchanged: `zwave_parameters.py:157–166` publishes partial confirmation after a later Get fails; `zwave_indicator.py:277–295` can retain old confirmation after a failed Get. `_refresh` at `zwave_indicator.py:205` retries only absent/empty confirmation. Keep the existing polling mechanism and invalidate interrupted confirmation; no new timer or retry policy is justified.

## 3. Performance & scalability

Nothing new found in the recent LED corrections. Property-list/visibility caching avoids redundant Composer updates, topologies are bounded, and close/unload paths retire subscriptions and background work.

The previous large-catalog full-state-fetch amplification finding remains outside this focused LED review. It has not been corrected; its prior measured evidence and design recommendation remain in the [first report](audit-current-2026-11-15.md).

## 4. Readability & maintainability

Nothing new beyond F1's unused exposed settings. Previously identified write-only LED `states` bookkeeping and outdated “LED colors … are not claimed” wording remain unchanged. The shared RGB conversion belongs at the Composer boundary; palette mapping remains appropriately centralized in `module/leds.lua`.

No additional locks, persistent state or compatibility machinery are recommended.

## 5. Test simplification

| ID | Severity | Location / function | New finding | Effort |
|---|---|---|---|---|
| F2 | Low | `HA-Gesture-Bridge/tests/gesture_bridge/test_led_profiles.py:420–427`, `test_behavior_only_changes_exact_mode_parameter_with_correct_device_encoding` | The expected device encoding is derived from the same production profile fields used to create and interpret the request. An incorrect follow/inverted declaration can therefore make both implementation and expectation wrong together. | S |

The test currently computes:

```python
expected = {
    "follow_load": definition.follow_load_value,
    "follow_load_inverted": definition.follow_load_inverted_value,
    "always_on": definition.on_value,
    "always_off": definition.off_value,
}[behavior]
```

The audit swapped ZEN78's follow/inverted fields in memory and ran the actual test through HA services: **eight cases passed despite the wrong declarations**. This is a test-strength defect, not evidence that the checked-in encodings are currently wrong.

Use independently reviewed expected model values: ZEN76 follow/inverted **1/0**, ZEN78 **0/1**, and on/off **3/2**. Keep the actual HA service invocation, unaffected-parameter assertions and confirmed feedback checks. The existing ZEN76 color-only behavior test already uses independent numeric expectations; extend that approach to the model-specific behavior test.

The previous duplicated color-picker scenarios, opt-in cross-repository CI gap and missing transient-read/Hue vocabulary regressions remain open. They are not counted again as new findings. Keep the fourteen Director BOOL cases and invalid-state/wrong-source rejection tests.

## 6. Prioritised action plan

| # | Severity | Item | Effort | Impact/effort |
|---|---|---|---|---|
| 1 | Medium, existing | Correct LED readback recovery using the current poll | S | High |
| 2 | Medium, existing | Remove Switch's unsupported standard-light connection mode | S | High |
| 3 | Medium, existing | Add contextual Hue tap/hold normalization | M | High |
| 4 | Low, new | F1: hide unused Switch On/Off tracking settings/commands | S | High |
| 5 | Low, new | F2: use independent model-encoding expectations | S | High |

The earlier discovery performance and Low findings remain recorded in the first report. No new Critical/High/Medium fix snippet is necessary here; the first report contains the applicable functional corrections.

Land F1 with the Switch mode/UI cleanup, preserving original proxy/binding identities and released on/off programming. Land F2 with the HA LED recovery regression, keeping its expected numbers independent of production declarations. These batches touch separate runtime/test areas. Fold the earlier `simplify` items into batches already touching their files, then rerun the applicable full boundary suites. Do not describe the first audit's issues as fixed until those changes and their regressions actually land.
