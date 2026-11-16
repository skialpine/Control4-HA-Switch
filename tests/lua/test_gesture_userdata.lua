-- Regression for Director's native userdata-backed C4 API. No global API
-- objects/metatables are altered; only this test's fresh userdata is customized.
local JSON=require('module.json')
local Gestures=require('module.gestures')
local input=assert(io.open('tests/fixtures/gestures/v1.json','r'))
local suite=JSON:decode(input:read('*a')); input:close()
local function copy(value) return JSON:decode(JSON:encode(value)) end
local count=0
local function check(value,message) count=count+1; assert(value,message or ('assertion '..count)) end
local function userdata_object(methods)
    if type(newproxy)=='function' then
        local object=newproxy(true)
        getmetatable(object).__index=methods
        return object,function() end
    end
    local object=assert(io.tmpfile())
    local previous=debug.getmetatable(object)
    debug.setmetatable(object,{__index=methods})
    return object,function()
        debug.setmetatable(object,previous)
        object:close()
    end
end

local calls={added={},fired={},late=false}
local api
local methods={
    AddEvent=function(self,id,name,description,order)
        check(self==api,'Native API userdata must be passed as self')
        check(calls.late,'No registration before late init')
        calls.added[id]={name=name,description=description,order=order}
        return true
    end,
    FireEventByID=function(self,id)
        check(self==api,'Native API userdata must be passed as self')
        calls.fired[#calls.fired+1]=id
    end,
}
local cleanup
api,cleanup=userdata_object(methods)
local ok,err=pcall(function()
    check(type(api)=='userdata')
    local store={}
    local decoder=Gestures.new({entity_id=suite.entity_id,c4=api,event_store=store})
    decoder:consume(copy(suite.cases[1].state),'state')
    check(next(calls.added)==nil and #calls.fired==0)
    calls.late=true
    decoder:start()
    check(decoder.ready and next(calls.added)~=nil)
    local live=copy(suite.cases[2].state)
    local fired=decoder:consume(live,'event')
    check(fired and #calls.fired==1)
    local id=calls.fired[1]
    check(id==store.allocations['fixture-control/top/press_2'])
    check(calls.added[id].name=='Top Double Tap')
    decoder:consume(live,'event'); check(#calls.fired==1)
    -- Recreating the decoder around the same userdata preserves stored IDs.
    local restored=Gestures.new({entity_id=suite.entity_id,c4=api,event_store=store})
    restored:start(); restored:consume(copy(suite.cases[1].state),'state')
    restored:consume(live,'event')
    check(#calls.fired==2 and calls.fired[2]==id)
end)
cleanup()
assert(ok,err)

-- Missing methods fail with precise errors, including userdata with no API.
for _,name in ipairs({'AddEvent','FireEventByID'}) do
    local incomplete={AddEvent=function() return true end,FireEventByID=function() end}
    incomplete[name]=nil
    local object,close=userdata_object(incomplete)
    local accepted,reason=pcall(Gestures.new,{entity_id=suite.entity_id,c4=object})
    close()
    check(not accepted and reason=='C4:'..name..' API is required')
end
for _,object in ipairs({false,42,{}, {AddEvent=true,FireEventByID=function() end}}) do
    local accepted,reason=pcall(Gestures.new,{entity_id=suite.entity_id,c4=object})
    check(not accepted and reason=='C4:AddEvent API is required')
end
print('Gesture native userdata API: '..count..' assertions passed')
