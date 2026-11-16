-- Run from the repository root: luajit tests/lua/test_gestures.lua [suite.json]
local JSON = require("module.json")
local Gestures = require("module.gestures")
local assertions, fired_total = 0, 0

local function check(value, message)
    assertions = assertions + 1
    assert(value, message)
end

local function clone(value)
    return JSON:decode(JSON:encode(value))
end

local function load_json(path)
    local file = assert(io.open(path, "r"))
    local value = JSON:decode(file:read("*a"))
    file:close()
    return value
end

local function boundary()
    local c4 = {events={}, fired={}, registrations=0}
    function c4:AddEvent(id, name, description, order)
        self.events[id] = {name=name, description=description, order=order}
        self.registrations = self.registrations + 1
        return true
    end
    function c4:FireEventByID(id)
        check(self.events[id] ~= nil, "fired event must have been registered")
        self.fired[#self.fired + 1] = id
    end
    function c4:SendToProxy() error("Decoder must not send load commands") end
    return c4
end

local function deliver(consumer, state, delivery)
    if delivery == "state" then
        return consumer:consume_proxy("RECEIEVE_STATE", {response=JSON:encode(state)})
    end
    return consumer:consume_proxy("RECEIEVE_EVENT", {data=JSON:encode({event={data={new_state=state}}})})
end

local suite_path = arg[1] or "tests/fixtures/gestures/v1.json"
local suite = load_json(suite_path)
local c4 = boundary()
local consumer = Gestures.new({entity_id=suite.entity_id, c4=c4})
consumer:start()
for _, case in ipairs(suite.cases) do
    local before = #c4.fired
    local fired, reason, event_key = deliver(consumer, case.state, case.delivery)
    check(fired == (case.expected_event ~= nil), case.name .. ": unexpected fired result (" .. tostring(reason) .. ")")
    check(#c4.fired - before == (case.expected_event and 1 or 0), case.name .. ": incorrect C4 side effects")
    if case.expected_event then
        check(event_key == case.expected_event, case.name .. ": wrong button/gesture")
        fired_total = fired_total + 1
    end
end
print(string.format("Shared suite: %d states, %d fired gestures", #suite.cases, fired_total))

-- In addition to optional HA-produced suites, always exercise the canonical
-- suite's invalid and lifecycle edges using its stable baseline examples.
local canonical = load_json("tests/fixtures/gestures/v1.json")
local initial, live = canonical.cases[1].state, canonical.cases[2].state
local invalid = {
    {"unsupported major", function(s) s.attributes.bridge_contract_version = "2.0" end},
    {"bad version syntax", function(s) s.attributes.bridge_contract_version = "1.0suffix" end},
    {"missing attributes", function(s) s.attributes = nil end},
    {"boolean sequence", function(s) s.attributes.gesture_sequence = true end},
    {"fractional sequence", function(s) s.attributes.gesture_sequence = 1.5 end},
    {"unsafe sequence", function(s) s.attributes.gesture_sequence = 9007199254740992 end},
    {"inconsistent event id", function(s) s.attributes.gesture_event_id = "session-a:2" end},
    {"restored live", function(s) s.attributes.bridge_session_id = "session-b" end},
    {"missing sequence", function(s) s.attributes.gesture_sequence = nil end},
    {"bad press count", function(s) s.attributes.press_count = 3 end},
    {"unknown button", function(s) s.attributes.button_id = "other" end},
    {"unknown kind", function(s) s.attributes.event_type = "double" end},
    {"bad source status", function(s) s.attributes.bridge_sources[1].ready = "yes" end},
    {"duplicate source", function(s) s.attributes.bridge_sources[2] = clone(s.attributes.bridge_sources[1]) end},
    {"duplicate button", function(s) s.attributes.bridge_buttons[2] = clone(s.attributes.bridge_buttons[1]) end},
    {"duplicate gesture", function(s) s.attributes.bridge_buttons[1].gestures[10] = clone(s.attributes.bridge_buttons[1].gestures[1]) end},
    {"bad capability count", function(s) s.attributes.bridge_buttons[1].gestures[2].press_count = 3 end},
    {"sparse gestures", function(s) s.attributes.bridge_buttons[1].gestures[2] = nil end},
    {"wrong load domain", function(s) s.attributes.bridge_load.domain = "input_boolean" end},
    {"unavailable load claimed ready", function(s) s.attributes.bridge_load.state = "unavailable" end},
    {"bad calendar date", function(s) s.last_updated = "2026-02-30T20:00:01+00:00" end},
    {"missing timezone", function(s) s.last_updated = "2026-11-14T20:00:01" end},
    {"bad occurrence", function(s) s.attributes.gesture_occurred_at = "yesterday" end},
    {"bad last event time", function(s) s.state = "yesterday" end},
    {"live unavailable", function(s) s.state = "unavailable" end},
}
for _, entry in ipairs(invalid) do
    local bad, stub = clone(live), boundary()
    local decoder = Gestures.new({entity_id=canonical.entity_id, c4=stub})
    decoder:start()
    deliver(decoder, initial, "state")
    local registrations = stub.registrations
    entry[2](bad)
    local ok, fired, reason = pcall(deliver, decoder, bad, "event")
    check(ok and not fired, entry[1] .. ": must reject without throwing (" .. tostring(reason) .. ")")
    check(#stub.fired == 0, entry[1] .. ": fired a scene")
    check(stub.registrations == registrations, entry[1] .. ": mutated C4 registrations before validation")
    check(decoder.last_state == nil, entry[1] .. ": stale metadata remained usable")
    check(deliver(decoder, live, "event") == true, entry[1] .. ": valid subsequent event could not recover")
end

local stub = boundary()
local decoder = Gestures.new({entity_id=canonical.entity_id, c4=stub})
check(not deliver(decoder, initial, "state"), "pre-init snapshot must not fire")
check(stub.registrations == 0 and not decoder.ready, "must not register before late init")
check(decoder:start() and decoder.ready, "late init must register cached capabilities")
check(deliver(decoder, live, "event"), "first live event after readiness must fire")
local event_id = stub.fired[1]
local renamed = clone(live)
renamed.last_updated = "2026-11-14T20:00:02.000Z"
renamed.attributes.bridge_update_kind = "snapshot"
renamed.attributes.bridge_buttons[1].label = "Upper"
check(not deliver(decoder, renamed, "event"), "rename snapshot must not fire")
check(stub.events[event_id].name == "Upper Double Tap", "same ID must receive changed label")
local next_press = clone(live)
next_press.state, next_press.last_updated = "2026-11-14T20:00:03Z", "2026-11-14T20:00:03Z"
next_press.attributes.gesture_sequence, next_press.attributes.gesture_event_id = 2, "session-a:2"
check(deliver(decoder, next_press, "event"), "new identical gesture must fire")
check(stub.fired[2] == event_id, "label change must preserve allocated ID")
local stale_invalid = clone(initial)
stale_invalid.attributes.bridge_contract_version = "2.0"
local previous_state = decoder.last_state
check(not deliver(decoder, stale_invalid, "state"), "stale incompatible snapshot must not fire")
check(decoder.ready and decoder.last_state == previous_state, "stale invalid snapshot cannot disable or replace newer accepted metadata")
local placeholder = {entity_id=canonical.entity_id, state="unavailable", attributes={restored=true}, last_updated=initial.last_updated}
local placeholder_fired, placeholder_reason = deliver(decoder, placeholder, "state")
check(not placeholder_fired and placeholder_reason == "stale_state", "delayed unavailable REST placeholder must be ignored as stale")
check(decoder.ready and decoder.last_state == previous_state, "stale unavailable placeholder cannot clear newer metadata or readiness")
placeholder.last_updated = "2026-11-14T20:00:04Z"
placeholder_fired, placeholder_reason = deliver(decoder, placeholder, "state")
check(not placeholder_fired and placeholder_reason == "source_unavailable", "current unavailable placeholder must report source unavailability")
check(not decoder.ready and decoder.last_state == nil, "current unavailable placeholder must clear readiness and accepted metadata")
decoder:set_entity_id("event.other")
check(not decoder.ready and decoder.last_state == nil, "source change must clear transient metadata")
check(not deliver(decoder, live, "event"), "old source must be ignored after selection changes")
check(not decoder:consume_proxy("RECEIEVE_EVENT", {data="{bad"}), "invalid JSON must be rejected")
check(not decoder:consume_proxy("RECEIEVE_EVENT", {data='{"event":{}}'}), "incomplete wrapper must be rejected")
check(not decoder:consume_proxy("RECEIEVE_STATE", {response="null"}), "null state must be rejected")
check(not decoder:consume_proxy("RECEIEVE_STATE", {response=JSON:encode(initial) .. " {}"}), "multiple top-level values must be rejected")
check(not decoder:consume_proxy("RECEIEVE_STATE", {response=JSON:encode(initial) .. " garbage"}), "trailing text must be rejected")
check(not decoder:consume_proxy("RECEIEVE_STATE", {response='{"bad":"\\q"}'}), "invalid string escape must be rejected")
check(not decoder:consume_proxy("RECEIEVE_STATE", {response='{"bad":"line\nbreak"}'}), "unescaped string newline must be rejected")
local unavailable, unavailable_reason = decoder:consume({entity_id="event.other", state="unavailable", attributes={restored=true}}, "event")
check(not unavailable and unavailable_reason == "source_unavailable", "HA unavailable placeholder must be not ready without trusting missing attributes")
check(not decoder.ready and decoder.last_state == nil, "unavailable placeholder must not expose stale metadata")
decoder:start()
check(not decoder.ready, "repeated start cannot revive metadata cleared by rejection")

-- A newer unavailable response must win over an earlier in-flight live event.
local recovery_stub = boundary()
local recovery_decoder = Gestures.new({entity_id=canonical.entity_id, c4=recovery_stub})
recovery_decoder:start()
deliver(recovery_decoder, initial, "state")
local lost = {entity_id=canonical.entity_id, state="unavailable", attributes={restored=true},
    last_updated="2026-11-14T20:00:02Z"}
check(not deliver(recovery_decoder, lost, "state") and not recovery_decoder.ready,
    "current unavailable response must clear readiness")
local delayed_fired, delayed_reason = deliver(recovery_decoder, live, "event")
check(not delayed_fired and delayed_reason == "stale_state", "older in-flight gesture cannot undo availability loss")
check(not recovery_decoder.ready and recovery_decoder.last_state == nil and #recovery_stub.fired == 0,
    "delayed gesture cannot restore command metadata or fire after availability loss")
local recovered = clone(initial)
recovered.last_updated = "2026-11-14T20:00:03Z"
check(not deliver(recovery_decoder, recovered, "state") and recovery_decoder.ready,
    "new valid snapshot must recover readiness without replay")
local fresh = clone(live)
fresh.state, fresh.last_updated = "2026-11-14T20:00:04Z", "2026-11-14T20:00:04Z"
check(deliver(recovery_decoder, fresh, "event"), "first fresh event after availability recovery must fire")

-- Missing live events are diagnostic, never an instruction to replay history.
local gap_stub = boundary()
local gap_decoder = Gestures.new({entity_id=canonical.entity_id, c4=gap_stub})
gap_decoder:start()
deliver(gap_decoder, initial, "state")
deliver(gap_decoder, live, "event")
local gap = clone(live)
gap.state, gap.last_updated = "2026-11-14T20:00:04Z", "2026-11-14T20:00:04Z"
gap.attributes.gesture_sequence, gap.attributes.gesture_event_id = 4, "session-a:4"
local gap_fired, gap_reason = deliver(gap_decoder, gap, "event")
check(gap_fired and gap_reason == "fired_with_sequence_gap", "jump from sequence 1 to 4 must report missing live events")
check(gap_decoder.last_sequence == 4 and #gap_stub.fired == 2, "sequence gap must fire only the received gesture")
check(not deliver(gap_decoder, gap, "event") and #gap_stub.fired == 2, "duplicate gap event must not fire twice")
local unseen = clone(gap)
unseen.last_updated = "2026-11-14T20:00:06Z"
unseen.attributes.bridge_update_kind = "snapshot"
unseen.attributes.gesture_sequence, unseen.attributes.gesture_event_id = 6, "session-a:6"
check(not deliver(gap_decoder, unseen, "state") and gap_decoder.last_sequence == 6 and #gap_stub.fired == 2,
    "refresh containing an unseen offline event must establish a baseline without replay")
local after_refresh = clone(gap)
after_refresh.state, after_refresh.last_updated = "2026-11-14T20:00:07Z", "2026-11-14T20:00:07Z"
after_refresh.attributes.gesture_sequence, after_refresh.attributes.gesture_event_id = 7, "session-a:7"
local refresh_fired, refresh_reason = deliver(gap_decoder, after_refresh, "event")
check(refresh_fired and refresh_reason == "fired" and #gap_stub.fired == 3,
    "first fresh event after a missed-event snapshot must fire without a false gap")

-- A retired session stays retired even if an old payload has a later revision.
local restarted = clone(after_refresh)
restarted.last_updated = "2026-11-14T20:00:08Z"
restarted.attributes.bridge_session_id, restarted.attributes.bridge_update_kind = "session-b", "snapshot"
check(not deliver(gap_decoder, restarted, "state") and gap_decoder.current_session == "session-b",
    "restored history must initialize a new producer session without replay")
local retired = clone(after_refresh)
retired.last_updated = "2026-11-14T20:00:09Z"
local retired_fired, retired_reason = deliver(gap_decoder, retired, "event")
check(not retired_fired and retired_reason == "retired_session" and #gap_stub.fired == 3,
    "later transport revision must not reactivate a retired producer session")
check(gap_decoder.current_session == "session-b" and gap_decoder.last_state.attributes.bridge_session_id == "session-b",
    "retired session cannot replace current command metadata")
local new_session_press = clone(live)
new_session_press.state, new_session_press.last_updated = "2026-11-14T20:00:10Z", "2026-11-14T20:00:10Z"
new_session_press.attributes.bridge_session_id, new_session_press.attributes.gesture_session_id = "session-b", "session-b"
new_session_press.attributes.gesture_event_id = "session-b:1"
check(deliver(gap_decoder, new_session_press, "event") and gap_decoder.last_sequence == 1,
    "first fresh sequence in the new producer session must fire")

-- Equivalent RFC3339 offsets must compare correctly across a producer restart.
local offset_stub = boundary()
local offset_decoder = Gestures.new({entity_id=canonical.entity_id, c4=offset_stub})
offset_decoder:start()
deliver(offset_decoder, initial, "state")
local with_offset = clone(live)
with_offset.last_updated = "2026-11-14T13:00:01.000-07:00"
check(deliver(offset_decoder, with_offset, "event"), "RFC3339 offset must be accepted")
local old_offset = clone(initial)
old_offset.last_updated = "2026-11-14T20:00:00Z"
check(not deliver(offset_decoder, old_offset, "state"), "older UTC snapshot must not overwrite an offset revision")

local failed = boundary()
function failed:AddEvent() return false end
local failed_decoder = Gestures.new({entity_id=canonical.entity_id, c4=failed})
failed_decoder:start()
check(not deliver(failed_decoder, live, "event"), "registration failure must not fire")
check(not failed_decoder.ready and #failed.fired == 0, "registration failure must leave consumer not ready")

local unicode_stub = boundary()
local unicode_decoder = Gestures.new({entity_id=canonical.entity_id, c4=unicode_stub})
unicode_decoder:start()
local unicode_state = clone(initial)
unicode_state.attributes.bridge_buttons[1].label = string.rep("é", 128)
check(not deliver(unicode_decoder, unicode_state, "state") and unicode_decoder.ready, "Unicode label limit counts characters rather than UTF-8 bytes")

-- Match native lighting labels and display order without changing allocation
-- order, declaring unsupported Push/Level events, or deriving releases.
local presentation_stub, presentation_state = boundary(), clone(initial)
local top_button = presentation_state.attributes.bridge_buttons[1]
local bottom_button = clone(top_button)
bottom_button.id, bottom_button.label = "bottom", "Bottom"
presentation_state.attributes.bridge_buttons = {bottom_button, top_button}
local presentation_decoder = Gestures.new({entity_id=canonical.entity_id,c4=presentation_stub})
presentation_decoder:start()
check(not deliver(presentation_decoder,presentation_state,"state") and presentation_decoder.ready,"presentation snapshot must register without firing")
local prefix = presentation_state.attributes.bridge_control_id .. "/"
local allocations = presentation_decoder.allocations
check(allocations[prefix .. "bottom/press_1"] == 1000,"presentation sorting must preserve declaration-order ID allocation")
check(allocations[prefix .. "top/press_1"] == 1000 + #bottom_button.gestures,"top ID allocation must retain its original declaration position")
local displayed = {}
for _,event in pairs(presentation_stub.events) do
    check(displayed[event.order] == nil,"display orders must be unique")
    displayed[event.order] = event.name
    check(not event.name:find("Pushed") and not event.name:find("Level Changes"),"must not invent push or load-level capabilities")
end
local expected_display = {"Top Button Released","Bottom Button Released","Top Single Tap","Top Double Tap","Top Triple Tap","Top 4 Taps","Top 5 Taps",
    "Bottom Single Tap","Bottom Double Tap","Bottom Triple Tap","Bottom 4 Taps","Bottom 5 Taps","Top Hold Start","Bottom Hold Start",
    "Top Hold Repeat","Bottom Hold Repeat","Top Movie Scene","Bottom Movie Scene"}
for order,name in ipairs(expected_display) do check(displayed[order] == name,"wrong C4 display label/order at " .. order) end
local stable_id = allocations[prefix .. "top/press_2"]
local changed_presentation = clone(presentation_state)
changed_presentation.last_updated = "2026-11-14T20:00:02Z"
changed_presentation.attributes.bridge_buttons = {changed_presentation.attributes.bridge_buttons[2],changed_presentation.attributes.bridge_buttons[1]}
changed_presentation.attributes.bridge_buttons[1].label = "Upper Paddle"
local gestures = changed_presentation.attributes.bridge_buttons[1].gestures
gestures[1],gestures[2] = gestures[2],gestures[1]
check(not deliver(presentation_decoder,changed_presentation,"state"),"presentation edits must not fire an event")
check(allocations[prefix .. "top/press_2"] == stable_id,"rename and declaration reorder must preserve existing event ID")
check(presentation_stub.events[stable_id].name == "Upper Paddle Double Tap","rename must update the same C4 event")
check(presentation_stub.events[stable_id].order == 4,"renaming must retain top/bottom semantic ordering")

print(string.format("Lua decoder checks passed: %d assertions, %d malformed cases", assertions, #invalid))
