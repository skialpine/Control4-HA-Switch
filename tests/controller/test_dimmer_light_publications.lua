-- Real HA-produced 1.1 states -> actual native Dimmer entry points.
-- Only Director boundaries are stubs. Pass the producer suite path as arg[1].
local Discovery=require('module.discovery')
local Family=require('module.family_capabilities')
local Codec=Discovery.new_codec()
local file=assert(io.open(assert(arg[1],'Producer fixture path required'),'r'))
local suite=Codec:decode(file:read('*a')); file:close()
local assertions,sent,custom_fires=0,{},0
local function check(value,message) assertions=assertions+1; assert(value,message or ('assertion '..assertions)) end
local function eq(actual,expected,message) check(actual==expected,(message or '')..' expected '..tostring(expected)..', got '..tostring(actual)) end
local function messages(binding,command)
    local result={}
    for _,message in ipairs(sent) do
        if message.binding==binding and message.command==command then result[#result+1]=message end
    end
    return result
end
local function latest(binding,command) local list=messages(binding,command); return list[#list] end
local function services() return messages(999,'HA_CALL_SERVICE') end
Properties={['Entity ID']=suite.entity_id,['Operation Mode']='Control HA Device with Button Events',
    ['Entity Selection']='Manual Entity ID',['Debug Mode']='Off'}
PersistData={}
C4={}
function C4:GetDeviceID() return 991 end
function C4:GetTime() return 100000 end
function C4:UpdateProperty(key,value) Properties[key]=value end
function C4:UpdatePropertyList() end
function C4:SetTimer() return {Cancel=function() end} end
function C4:AddEvent() return true end
function C4:FireEventByID() custom_fires=custom_fires+1 end
function C4:SendToProxy(binding,command,params,kind)
    if binding==5001 then eq(kind,'NOTIFY','Native UI traffic must be notifications')
    else
        eq(binding,999,'Only the existing HA_DEVICE connection can issue HA commands')
        check(command=='HA_GET_STATE' or command=='HA_GET_ENTITIES' or command=='HA_CALL_SERVICE' or command=='HA_RELEASE_STATES')
    end
    sent[#sent+1]={binding=binding,command=command,params=params or {},kind=kind}
end
dofile('light/driver.lua')
OnDriverInit(); eq(#sent,0)
OnDriverLateInit(); eq(#services(),0,'Initialization must not operate the light')
local native_taps=0
for _,publication in ipairs(suite.cases) do
    local name=publication.name
    local before_services,before_buttons,before_levels=#services(),#messages(5001,'BUTTON_ACTION'),#messages(5001,'LIGHT_BRIGHTNESS_CHANGED')
    local previous_level=latest(5001,'LIGHT_BRIGHTNESS_CHANGED')
    previous_level=previous_level and previous_level.params.LIGHT_BRIGHTNESS_CURRENT
    local previous_online=latest(5001,'ONLINE_CHANGED')
    previous_online=previous_online and previous_online.params.STATE
    local raw=publication.delivery=='state' and Codec:encode(publication.state) or
        Codec:encode({event={data={new_state=publication.state}}})
    ReceivedFromProxy(999,publication.delivery=='state' and 'RECEIEVE_STATE' or 'RECEIEVE_EVENT',
        publication.delivery=='state' and {response=raw} or {data=raw})
    eq(#services(),before_services,name..': publications never send load services')
    if type(publication.expected_event)=='string' then
        native_taps=native_taps+1
        eq(publication.expected_event,'top/press_2','This producer config declares its existing top double tap')
        local tap=latest(5001,'BUTTON_ACTION')
        eq(tap.params.BUTTON_ID,0); eq(tap.params.ACTION,3)
        eq(#messages(5001,'BUTTON_ACTION'),before_buttons+1,name..': one native event for one real press')
    else eq(#messages(5001,'BUTTON_ACTION'),before_buttons,name..': snapshot cannot replay a native event') end
    eq(custom_fires,0,'Native-supported gestures must not duplicate a custom event')
    local load=publication.state.attributes.bridge_load
    check(type(load)=='table' and load.domain=='light' and load.entity_id~=suite.entity_id)
    local facts=Family.classify(load)
    local available=load.available and (load.state=='on' or load.state=='off')
    local expected_level
    if available then
        if load.state=='off' then expected_level=0
        elseif facts.capabilities.set_level then expected_level=load.attributes.brightness*100/255
        else expected_level=100 end
    end
    eq(latest(5001,'ONLINE_CHANGED').params.STATE,expected_level~=nil,name..': current load availability')
    eq(latest(5001,'DYNAMIC_CAPABILITIES_CHANGED').params.set_level,
        available and facts.capabilities.set_level or false,name..': current brightness capability')
    if expected_level~=nil then
        if previous_level~=expected_level or not previous_online then
            check(#messages(5001,'LIGHT_BRIGHTNESS_CHANGED')>before_levels,name..': changed light snapshot updates native brightness')
        end
        check(math.abs(latest(5001,'LIGHT_BRIGHTNESS_CHANGED').params.LIGHT_BRIGHTNESS_CURRENT-expected_level)<0.000001)
    else eq(#messages(5001,'LIGHT_BRIGHTNESS_CHANGED'),before_levels,name..': unavailable is not an invented zero level') end
    -- Execute a real native UI command after observing each snapshot. A valid
    -- aggregate routes its explicitly linked light; unavailable metadata blocks.
    local count=#services()
    ReceivedFromProxy(5001,'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET='75'})
    eq(#services(),count+(available and facts.capabilities.set_level and 1 or 0))
    if available and facts.capabilities.set_level then
        local request=Codec:decode(latest(999,'HA_CALL_SERVICE').params.JSON)
        eq(request.domain,'light'); eq(request.service,'turn_on'); eq(request.target.entity_id,load.entity_id)
        eq(request.service_data.brightness,191); eq(request.service_data.transition,nil)
        ReceivedFromProxy(5001,'RAMP_TO_LEVEL',{LEVEL='50',RATE='1500'})
        request=Codec:decode(latest(999,'HA_CALL_SERVICE').params.JSON)
        eq(request.target.entity_id,load.entity_id); eq(request.service_data.brightness,128)
        eq(request.service_data.transition,1.5)
    end
    eq(Properties['Entity ID'],suite.entity_id,'Commands must retain the primary aggregate subscription')
    eq(Properties['Operation Mode'],'Control HA Device with Button Events')
end
eq(#messages(5001,'BUTTON_ACTION'),native_taps)
OnDriverDestroyed()
print('Real HA light publications -> native Dimmer: '..#suite.cases..' states, '..assertions..' assertions passed')
