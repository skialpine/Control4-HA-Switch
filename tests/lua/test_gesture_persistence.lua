-- Stable event IDs must survive real decoder recreation, rename and source loss.
local JSON=require("module.json")
local Gestures=require("module.gestures")
local file=assert(io.open("tests/fixtures/gestures/v1.json","r"))
local suite=JSON:decode(file:read("*a")); file:close()
local function clone(v) return JSON:decode(JSON:encode(v)) end
local initial=clone(suite.cases[1].state)
local function boundary()
    local c={events={},fired={}}
    function c:AddEvent(id,name,description,order) self.events[id]={name=name,order=order}; return true end
    function c:FireEventByID(id) self.fired[#self.fired+1]=id end
    return c
end
local function consumer(store,state)
    local c=boundary(); local decoder=Gestures.new({entity_id=suite.entity_id,c4=c,event_store=store})
    decoder:start(); decoder:consume(state or initial,"state")
    return decoder,c
end
local store={}
local first=consumer(store)
assert(store.version==1 and store.next_event_id>1000)
local original=clone(store.allocations)
local next_id=store.next_event_id
-- JSON roundtrip simulates Director persisting/reloading the plain Lua data.
store=clone(store)
local changed=clone(initial)
changed.attributes.bridge_buttons[1].label="Upper"
local gestures=changed.attributes.bridge_buttons[1].gestures
local reversed={}; for i=#gestures,1,-1 do reversed[#reversed+1]=gestures[i] end
changed.attributes.bridge_buttons[1].gestures=reversed
local reloaded,c=consumer(store,changed)
for key,id in pairs(original) do assert(store.allocations[key]==id and c.events[id],"Reload must preserve every event ID") end
assert(store.next_event_id==next_id)
local removed=clone(changed)
table.remove(removed.attributes.bridge_buttons[1].gestures,1)
consumer(store,removed)
for key,id in pairs(original) do assert(store.allocations[key]==id,"Temporary capability loss must retain allocations") end
consumer(store,initial)
assert(store.next_event_id==next_id)

-- Another control and later capabilities must allocate fresh IDs, never recycle.
local other=clone(initial); other.attributes.bridge_control_id="another_control"
local second=consumer(store,other)
assert(store.next_event_id>next_id)
for key,id in pairs(original) do assert(store.allocations[key]==id) end
local custom=clone(other)
custom.attributes.bridge_buttons[1].gestures[#custom.attributes.bridge_buttons[1].gestures+1]={id="scene_party",kind="custom",label="Party"}
consumer(store,custom)
assert(store.allocations['another_control/top/scene_party']>=next_id)

-- Corrupted stores fail closed and remain untouched instead of reusing IDs.
for _,broken in ipairs({
    {version=2,allocations={},next_event_id=1000},
    {version=1,allocations={['ctrl/top/press_2']=1000},next_event_id=1000},
    {version=1,allocations={['ctrl/top/press_2']=1000,['ctrl/top/press_3']=1000},next_event_id=1001},
    {version=1,allocations={bad=1000},next_event_id=1001},
    {version=1,allocations={},next_event_id=999},
}) do
    local before=JSON:encode(broken)
    local d,b=consumer(broken)
    assert(d.status=='invalid_event_store' and not d.ready and next(b.events)==nil)
    assert(JSON:encode(broken)==before)
    assert(#b.fired==0)
end
local exhausted={version=1,allocations={},next_event_id=65536}
local d,b=consumer(exhausted)
assert(d.status=='event_id_exhausted' and #b.fired==0 and next(b.events)==nil)
print('Gesture persistence passed: reload, reorder, inactive allocations, new controls, corruption, exhaustion')
