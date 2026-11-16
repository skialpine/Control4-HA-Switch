-- Exercise the deployable proof entry points with only the C4 boundary stubbed.
local JSON = require("module.json")
local file = assert(io.open("tests/fixtures/gestures/v1.json", "r"))
local suite = JSON:decode(file:read("*a"))
file:close()

EC, RFP, DRV = {}, {}, {}
Properties = { ["Entity ID"] = suite.entity_id }
local variables, properties, fired = {}, {}, {}
local registrations, refreshes = 0, 0
C4 = {}
function C4:AddVariable(name, value) variables[name] = value end
function C4:SetVariable(name, value) variables[name] = value end
function C4:UpdateProperty(name, value) properties[name] = value end
function C4:AddEvent(id, name, description, order) registrations = registrations + 1; return true end
function C4:FireEventByID(id) fired[#fired + 1] = id end
function C4:SendToProxy() error("Proof driver must not send load commands") end
function EC.REFRESH() refreshes = refreshes + 1 end

dofile("tools/transport-proof/commands.lua")
DRV.OnDriverInit()
assert(variables.GESTURE_COUNT == "0")
assert(registrations == 0)
RFP.RECEIEVE_STATE(999, "RECEIEVE_STATE", {response = JSON:encode(suite.cases[1].state)})
assert(registrations == 0, "Events must not be registered before late init")
DRV.OnDriverLateInit()
assert(refreshes == 1)

local expected = 0
for _, case in ipairs(suite.cases) do
    if case.delivery == "state" then
        RFP.RECEIEVE_STATE(999, "RECEIEVE_STATE", {response = JSON:encode(case.state)})
    else
        RFP.RECEIEVE_EVENT(999, "RECEIEVE_EVENT", {data = JSON:encode({event = {data = {new_state = case.state}}})})
    end
    if case.expected_event then expected = expected + 1 end
    assert(#fired == expected, case.name .. ": unexpected firing count")
    assert(variables.GESTURE_COUNT == tostring(expected), case.name .. ": counter differs from actual events")
end
assert(variables.LAST_GESTURE == "top/press_5")
assert(tonumber(variables.SNAPSHOT_COUNT) > 0)
EC.Reset_Count()
assert(variables.GESTURE_COUNT == "0" and variables.LAST_GESTURE == "")
assert(#fired == expected, "Resetting proof counters must not emit a gesture")
Properties["Entity ID"] = "event.other"
RFP.RECEIEVE_EVENT(999, "RECEIEVE_EVENT", {data = JSON:encode({event = {data = {new_state = suite.cases[2].state}}})})
assert(variables.GESTURE_COUNT == "0", "Old-source data must be ignored after changing Entity ID")
print("Proof driver entry points passed: " .. expected .. " events, no load commands")
