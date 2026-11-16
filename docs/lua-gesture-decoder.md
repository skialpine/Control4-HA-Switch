# Shared Lua gesture decoder

The decoder does not operate a load, pair devices, or implement a dimming loop.
The Switch driver passes a per-instance `PersistData` allocation store so
programming IDs survive reloads, labels, ordering changes, and temporary loss of
capabilities. Local persistence checks pass; actual Composer upgrade and restart
qualification remains pending.

## Driver interface

```lua
local Gestures = require("module.gestures")
local consumer = Gestures.new({
    entity_id = Properties["Entity ID"],
    c4 = C4,
    event_store = PersistData.GestureEventIDs,
    on_status = function(reason) C4:UpdateProperty("Status", reason) end
})

-- Call after late initialization, never from OnDriverInit.
consumer:start()

-- ReceivedFromProxy handlers forward the original coordinator parameters.
local fired, reason, gesture_key = consumer:consume_proxy(strCommand, tParams)
```

- `start()` enables dynamic `C4:AddEvent` registration. Earlier received metadata
  is cached and baselined; a cached press is never fired on start.
- `set_entity_id(id)` changes the selected source and clears readiness, accepted
  state, and sequencing. Allocated event IDs are never recycled.
- `consume(state, delivery)` accepts a decoded HA state and delivery `state`
  (initial REST response) or `event` (live subscription update).
- `consume_proxy(command, params)` recognizes the stock coordinator's deliberately
  spelled `RECEIEVE_STATE` (`params.response`) and `RECEIEVE_EVENT` (`params.data`,
  containing `event.data.new_state`). Invalid JSON and wrappers are rejected.
- Returns are `fired_boolean, reason_string, gesture_key`. The third value is
  present only for a fire and is `button_id/gesture_id`, for example `top/press_2`.
- `ready` indicates that valid metadata and C4 event registration are available.
  `last_state` contains only accepted metadata and is cleared on malformed input
  or a selected-source change. It does not move backwards for delayed snapshots.

Initialize `PersistData.GestureEventIDs` to an empty table only when it is absent.
The store becomes `{version=1, allocations={...}, next_event_id=1000}`. Allocation
keys combine control, button, and gesture identity; IDs use the reserved range
1000–65535. New IDs are reserved in the store before registration and remain
reserved after registration failure or capability loss. Renaming and reordering
do not allocate replacements. Corrupted/unsupported stores fail closed with
`invalid_event_store`, and exhaustion reports `event_id_exhausted`; neither case
silently resets the map or reassigns existing Composer programming. No store
means in-memory operation for isolated consumers; the production Switch supplies
the persistent store. The ordinary Direct control path remains independent.

The consumer validates the contract major version, IDs, dense capability/source
arrays, declared actions, press counts, load target/domain consistency, RFC3339
timestamps, and session/sequence/event-ID consistency. Additive version 1 minor
attributes are allowed. The existing JSON library maps both null and missing
object values to Lua nil; a nil `bridge_load` therefore means no load target.
The proxy boundary checks for one complete JSON object and valid string syntax
before using the bundled decoder, which otherwise tolerates trailing input.
HA's unavailable registry placeholders are treated as not ready without trusting
their missing bridge metadata.

Only valid live, current-session gesture updates can fire. Initial REST responses,
snapshot-only revisions, restored history, unrelated entities, duplicates, and
older sequences do not fire. A snapshot with a previously unseen current-session
sequence establishes a baseline rather than requesting an offline replay.
Revisions use timezone-independent RFC3339 comparison, including fractional
seconds and offsets. Seen producer sessions are retired when replaced.

An authoritative unavailable placeholder also advances the accepted revision
watermark before clearing readiness. An older live update still in flight cannot
restore metadata or fire after that loss. A newer valid snapshot restores
readiness without replay; the next fresh gesture remains processable. A retired
producer session cannot return even in a payload carrying a later revision.

A sequence jump fires only the newly received live gesture and reports
`fired_with_sequence_gap`. There is no reconstruction of the missing presses.
A refresh containing an unseen current-session occurrence raises the sequence
baseline without firing it; the next consecutive live gesture reports `fired`.

The callback receives status reasons such as `waiting_for_state`, `snapshot`,
`fired`, `fired_with_sequence_gap`, `invalid_gesture`, or `unsupported_contract`.
No status callback is required. C4 registration/fire errors prevent a successful
fire result; registration IDs already allocated are retained for later retries.

## Composer event presentation

The pure `module/gesture_presentation.lua` helper provides the familiar lighting
names where the contract supports the same meaning: `Top Single Tap`, `Top Double
Tap`, `Top Triple Tap`, and the corresponding Bottom names. Higher counts remain
available as `Top 4 Taps`, `Top 5 Taps`, and so on. A declared `release` becomes
`Top Button Released`. Button labels remain as supplied, so a different button
can display `Patio Double Tap`; identities remain `button_id/gesture_id`.

Explicitly supplied Push/Release entries appear first, grouped by button, followed
by taps in increasing count; Top precedes Bottom, followed by other button IDs.
Hold-start, hold-repeat, and other custom entries
retain their source gesture labels after these familiar options. Display order
is passed explicitly to `C4:AddEvent` and is independent of numeric ID allocation,
which retains contract declaration order and existing instance allocations.
Renaming or reordering capabilities therefore preserves existing event IDs.

This changes dynamic event names and order. It does not turn the event consumer
into a native lighting proxy. A hold-start is not an initial button-down event,
and a completed tap is not a physical push/release sequence. The consumer does
not fabricate `Button Pushed`, releases, or `Level Changes`; a custom source can
explicitly name its own genuine action. Native level events require load-state
tracking by a switch/dimmer driver. Native lighting proxy notifications and their
load-control behavior need separate integration and controller verification.

## Run the boundary harness

From the repository root:

```sh
luajit tests/lua/test_gestures.lua
lua tests/lua/test_gestures.lua
luajit tests/lua/test_gesture_presentation.lua
lua tests/lua/test_gesture_presentation.lua
```

The harness runs the shared version 1 fixture sequence through the actual JSON
decoder and proxy entry point, stubbing only C4's registration/fire boundary.
It also tests malformed inputs, initialization, label updates, source changes,
timestamp offsets, and failed C4 registration. `SendToProxy` deliberately fails
if called, so load side effects cannot pass unnoticed.

Explicit lifecycle cases also cover newer availability loss beating delayed
live input, exact sequence-gap diagnostics, refresh after missed events, retired
sessions with later revisions, and first fresh events after recovery/restart.

Pass another suite file to run HA-produced states through the same decoder:

```sh
luajit tests/lua/test_gestures.lua /path/to/ha-produced-suite.json
```

Its shape is `{entity_id, cases}`. Each case contains `name`, `delivery`, a full HA
`state`, and `expected_event` (null or `button_id/gesture_id`). The canonical
malformed-input checks also run for every invocation. A failed assertion exits
nonzero; success prints the state/fire counts and assertion count.
