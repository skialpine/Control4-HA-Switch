-- Actual HA Light -> actual Light Group light model/adapter -> member commands.
-- The optional group checkout stays read-only. Only Director/timer/member edges
-- are simulated; no group implementation is copied into this repository.
local root=assert(arg[1],'Pass the explicit control4-group-lighting checkout')
package.path=root..'/test/?.lua;'..root..'/src/?.lua;'..root..'/vendor/?.lua;'..package.path
local assertions=0
local function check(value,message) assertions=assertions+1; assert(value,message or ('assertion '..assertions)) end
local function eq(actual,expected,message) check(actual==expected,(message or '')..' expected '..tostring(expected)..', got '..tostring(actual)) end
local function read(path) local file=assert(io.open(path,'r')); local text=file:read('*a'); file:close(); return text end
local function execute(path,env)
    local chunk,err
    if setfenv then chunk,err=loadstring(read(path),'@'..path); if chunk then setfenv(chunk,env) end
    else chunk,err=load(read(path),'@'..path,'t',env) end
    assert(chunk,err); return chunk()
end
require('c4_shim'); require('c4_local'); require('lib.utils'); require('drivers-common-public.global.handlers')
JSON=require('JSON')
local now=1000000
function C4:GetTime() return now end
-- A clock-aware replacement for the shim's fire-all operation lets a release
-- stop a ramp partway through instead of accidentally finishing every timer.
local timers={}
function C4:SetTimer(ms,callback,repeating)
    local handle={due=now+ms,callback=callback,interval=repeating and ms or nil}
    function handle:Cancel() self.cancelled=true end
    timers[#timers+1]=handle
    return handle
end
local function advance(ms)
    local target=now+ms
    local iterations=0
    while true do
        local next_timer
        for _,timer in ipairs(timers) do
            if not timer.cancelled and timer.due<=target and (not next_timer or timer.due<next_timer.due) then next_timer=timer end
        end
        if not next_timer then break end
        iterations=iterations+1; check(iterations<1000,'Timers must terminate')
        now=next_timer.due
        if next_timer.interval then next_timer.due=now+next_timer.interval else next_timer.cancelled=true end
        next_timer.callback(next_timer,0)
    end
    now=target
end
local devices={}
for _,id in ipairs({101,102}) do
    devices[id]={deviceName='Member '..id,variables={
        ['1000']={name='LIGHT_STATE',value='1'},['1001']={name='LIGHT_LEVEL',value='40'},
        ['6661']={name='DYNAMIC_CAPABILITIES',value='<DynamicCapabilities><dimmer>True</dimmer><supports_target>True</supports_target></DynamicCapabilities>'}}}
end
ShimSetDevices(devices)
function C4:GetDeviceVariable(id,variable) return self:GetVariable(id,variable) end
function C4:GetProxyDevices() return 900 end
local member_commands,group_feedback,outputs={},{},{}
local app_state={[1000]='1',[1001]='40',[1006]='100',
    [6661]='<DynamicCapabilities><dimmer>True</dimmer></DynamicCapabilities>'}
local dimmer
local links={[203]=300,[204]=302,[205]=301}
local configured={[203]=300,[204]=302,[205]=301}
local reverse={[300]=203,[302]=204,[301]=205}
function C4:SendToDevice(id,command,params)
    member_commands[#member_commands+1]={id=id,command=command,params=params or {}}
end
function C4:SendToProxy(binding,command,params,kind)
    if binding==5001 then
        local variable,value
        if command=='LIGHT_BRIGHTNESS_CHANGED' then
            variable,value=1001,tostring(params.LIGHT_BRIGHTNESS_CURRENT)
            app_state[1000]=tonumber(value)>0 and '1' or '0'
            if dimmer then dimmer.OnWatchedVariableChanged(900,1000,app_state[1000]) end
        elseif command=='PRESET_LEVEL' then variable,value=1006,tostring(params) end
        if variable then
            app_state[variable]=value
            if dimmer then dimmer.OnWatchedVariableChanged(900,variable,value) end
        end
    end
    if reverse[binding] then
        group_feedback[#group_feedback+1]={binding=binding,command=command,params=params,kind=kind}
        if dimmer then dimmer.ReceivedFromProxy(reverse[binding],command,params or {}) end
    end
end
local Light=require('lib.light')
local group=require('group.group')
local light=Light.new(group.adapter(),group.profile())
group.attach(light)
light:start()
group.configure({brightnessTracking='Ignore'})
group.setMembers({{id=101,name='Member 101'},{id=102,name='Member 102'}})
advance(300)
local group_handlers=setmetatable({},{__index=function(_,command)
    return function(binding,_,params) return RFP[binding](binding,command,params or {}) end
end})
check(light.online,'Actual group must be online before forwarding presses')

-- Every Dimmer module has its own driver globals, separate from the group.
local env=setmetatable({},{__index=_G}); env._G=env
env.Properties={['Entity ID']='event.group_controller',['Operation Mode']='Control Connected C4 Light',
    ['Entity Selection']='Manual Entity ID',['Debug Mode']='Off',['Discovery Catalog Entity ID']=''}
env.PersistData={}; env.Variables={}
local cache={}
env.require=function(name)
    if cache[name]~=nil then return cache[name] end
    local result=execute(name:gsub('%.','/')..'.lua',env)
    cache[name]=result==nil and true or result
    return cache[name]
end
env.C4={}
function env.C4:GetDeviceID() return 901 end
function env.C4:GetDriverConfigInfo() return '1' end
function env.C4:GetBoundProviderDevice(_,binding) if links[binding] then return 900 end end
function env.C4:GetProxyDevicesById(device) if device==900 then return 900 end end
function env.C4:GetVariable(device,variable) if device==900 then return app_state[variable] end end
function env.C4:RegisterVariableListener() end
function env.C4:UnregisterVariableListener() end
function env.C4:GetDeviceDisplayName() return 'Target Light Group' end
function env.C4:SendToDevice(device,command,params)
    eq(device,900,'App uses the connected group proxy')
    return group_handlers[command](5001,command,params or {})
end
function env.C4:GetTime() return now end
function env.C4:UpdateProperty(name,value) env.Properties[name]=value end
function env.C4:UpdatePropertyList() end
function env.C4:DebugLog() end
function env.C4:SetPropertyAttribs() end
function env.C4:AddEvent() return true end
function env.C4:FireEventByID() end
function env.C4:SetTimer() return {Cancel=function() end} end
function env.C4:SendToProxy(binding,command,params,kind)
    if binding==999 then check(command~='HA_CALL_SERVICE','Controller mode cannot call HA load services'); return end
    if binding==5001 then return end
    check(binding~=200 and binding~=201 and binding~=202,'Forwarding must preserve legacy provider links')
    check(reverse[configured[binding]]==binding,'Unexpected consumer binding')
    eq(kind,'COMMAND','Commands travel from consumer to provider')
    outputs[#outputs+1]={binding=binding,command=command}
    if links[binding] then
        local handler=assert(group_handlers[command],'Actual group handler is missing')
        handler(links[binding],command,params or {},{})
    end
end
execute('light/driver.lua',env)
dimmer=env
env.OnDriverInit(); env.OnDriverLateInit()
local Codec=env.require('module.discovery').new_codec()
local function copy(value) return Codec:decode(Codec:encode(value)) end
local attrs={bridge_contract_version='1.0',bridge_control_id='group-controller',bridge_session_id='group-session',
    bridge_update_kind='snapshot',bridge_load=Codec.null,bridge_buttons={},bridge_sources={}}
for _,button in ipairs({'top','bottom','toggle'}) do
    attrs.bridge_buttons[#attrs.bridge_buttons+1]={id=button,label=button,gestures={
        {id='press_1',kind='press',press_count=1,label='Single Tap'},
        {id='hold_start',kind='hold_start',label='Hold'},
        {id='hold_repeat',kind='hold_repeat',label='Repeat'},
        {id='release',kind='release',label='Release'}}}
    attrs.bridge_sources[#attrs.bridge_sources+1]={id=button,button_id=button,ready=true,availability='available'}
end
local sequence=0
local latest={entity_id=env.Properties['Entity ID'],state='unknown',last_updated='2026-11-15T00:00:00.000Z',attributes=attrs}
local function deliver(state,live)
    return env.ReceivedFromProxy(999,live and 'RECEIEVE_EVENT' or 'RECEIEVE_STATE',live and
        {data=Codec:encode({event={data={new_state=state}}})} or {response=Codec:encode(state)})
end
deliver(latest,false)
eq(#outputs,0,'Initial snapshot is not a press')
local function gesture(button,kind)
    sequence=sequence+1
    latest=copy(latest)
    local stamp=string.format('2026-11-15T00:%02d:%02d.000Z',math.floor(sequence/60),sequence%60)
    latest.state=stamp; latest.last_updated=stamp
    local a=latest.attributes
    a.bridge_update_kind='gesture'; a.event_type=kind; a.button_id=button
    a.gesture_id=kind=='press' and 'press_1' or kind
    a.press_count=kind=='press' and 1 or nil
    a.gesture_session_id='group-session'; a.gesture_sequence=sequence
    a.gesture_event_id='group-session:'..sequence; a.gesture_occurred_at=stamp
    eq(deliver(latest,true),true,'Fresh gesture must be accepted')
end
local function last_member(id)
    for i=#member_commands,1,-1 do if member_commands[i].id==id then return member_commands[i] end end
end
local function set_level(level)
    group_handlers.SET_BRIGHTNESS_TARGET(5001,'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET=level,RATE=0},{})
    advance(50); member_commands={}
end
eq(env.Properties['Connected Light'],'Target Light Group')
eq(env.ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=35}),true)
advance(800)
for _,id in ipairs({101,102}) do eq(last_member(id).params.LEVEL,35,'App slider reaches the actual group members') end
eq(app_state[1001],'35','Actual group feedback returns to the app tile')
set_level(40)
for _,scenario in ipairs({{'top',203,100},{'bottom',204,0},{'toggle',205,100},{'toggle',205,0}}) do
    member_commands={}
    local before=#outputs
    gesture(scenario[1],'press')
    eq(#outputs,before+2); eq(outputs[before+1].binding,scenario[2]); eq(outputs[before+1].command,'DO_PUSH')
    eq(outputs[before+2].command,'DO_CLICK')
    for _,id in ipairs({101,102}) do
        local command=assert(last_member(id),'Actual group must command every member')
        eq(command.command,'RAMP_TO_LEVEL'); eq(command.params.LEVEL,scenario[3])
    end
    advance(800)
end
-- A scheduled On-mode reduction belongs to the target, not the gesture bridge.
group_handlers.UPDATE_BRIGHTNESS_ON_MODE(5001,'UPDATE_BRIGHTNESS_ON_MODE',
    {BRIGHTNESS_PRESET_ID=1,BRIGHTNESS_PRESET_LEVEL=50},{})
set_level(0)
eq(env.ReceivedFromProxy(5001,'SET_BRIGHTNESS_TARGET',{
    LIGHT_BRIGHTNESS_TARGET=100,LIGHT_BRIGHTNESS_TARGET_PRESET_ID=1,RATE=750}),true)
advance(1000)
for _,id in ipairs({101,102}) do
    eq(last_member(id).params.LEVEL,50,'Native app On retains the actual target Nightlight mode')
end
eq(env.ReceivedFromProxy(5001,'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET=35,RATE=0}),true)
advance(1000)
for _,id in ipairs({101,102}) do
    eq(last_member(id).params.LEVEL,35,'An explicit app slider percentage is independent of the On mode')
end
for _,button in ipairs({'top','toggle'}) do
    set_level(0)
    gesture(button,'press')
    advance(1000)
    local levels=0
    for _,command in ipairs(member_commands) do
        if command.command=='RAMP_TO_LEVEL' then
            levels=levels+1
            eq(command.params.LEVEL,50,'A completed tap must retain the target night On level')
        end
    end
    check(levels>=2,'Both real group members receive the night On level')
end
group_handlers.UPDATE_BRIGHTNESS_ON_MODE(5001,'UPDATE_BRIGHTNESS_ON_MODE',
    {BRIGHTNESS_PRESET_ID=1,BRIGHTNESS_PRESET_LEVEL=100},{})
for _,scenario in ipairs({{'top',203,40,100},{'bottom',204,60,0}}) do
    set_level(scenario[3])
    gesture(scenario[1],'hold_start')
    eq(#member_commands,0,'Group applies its own click/hold delay')
    advance(300)
    local ramp=assert(last_member(101))
    eq(ramp.command,'RAMP_TO_LEVEL'); eq(ramp.params.LEVEL,scenario[4]); check(ramp.params.TIME>0)
    local count=#member_commands
    gesture(scenario[1],'hold_repeat')
    eq(#member_commands,count,'Hold repetition cannot restart the group ramp')
    advance(1000)
    gesture(scenario[1],'release')
    eq(outputs[#outputs].binding,scenario[2]); eq(outputs[#outputs].command,'DO_RELEASE')
    for _,id in ipairs({101,102}) do
        local stop=assert(last_member(id))
        eq(stop.command,'RAMP_TO_LEVEL'); eq(stop.params.TIME,0,'Group stops by sending its interpolated current level')
        check(stop.params.LEVEL>math.min(scenario[3],scenario[4]) and stop.params.LEVEL<math.max(scenario[3],scenario[4]),'Release must stop before the endpoint')
    end
    advance(50)
end
set_level(40)
gesture('top','hold_start'); advance(1000)
local before_cleanup=#outputs
latest=copy(latest); latest.attributes.bridge_update_kind='snapshot'
latest.attributes.bridge_sources[1].ready=false
latest.attributes.bridge_sources[1].availability='unavailable'
latest.last_updated='2026-11-15T00:00:30.500Z'
deliver(latest,false)
eq(#outputs,before_cleanup+1,'Source loss must release an existing connected hold')
eq(outputs[#outputs].command,'DO_RELEASE')
local cleanup_stop=assert(last_member(101))
eq(cleanup_stop.params.TIME,0)
check(cleanup_stop.params.LEVEL>40 and cleanup_stop.params.LEVEL<100,'Source loss stops the actual group mid-ramp')
latest=copy(latest)
latest.attributes.bridge_sources[1].ready=true
latest.attributes.bridge_sources[1].availability='available'
latest.last_updated='2026-11-15T00:00:31.000Z'
deliver(latest,false)
local before_outputs,before_members=#outputs,#member_commands
latest=copy(latest); latest.attributes.bridge_update_kind='snapshot'
latest.last_updated='2026-11-15T00:01:00.000Z'
deliver(latest,false)
eq(#outputs,before_outputs,'Metadata refresh never forwards a preserved gesture')
eq(#member_commands,before_members)
check(#group_feedback>0,'Actual group status must cross the return path')
for _,binding in ipairs({203,204,205}) do
    eq(env.ReceivedFromProxy(binding,'MATCH_LED_STATE',{STATE=true}),false)
    eq(env.ReceivedFromProxy(binding,'DO_CLICK',{}),false)
end
eq(#outputs,before_outputs,'Consumer feedback cannot become another button command')
eq(#member_commands,before_members)

-- Detaching a consumer connection clears the tracked logical hold and attempts
-- release. Once Director has removed the wire, it cannot promise physical stop;
-- the detached transport below deliberately does not deliver that cleanup.
set_level(40)
sequence=60
gesture('top','hold_start'); advance(300)
local target=links[203]
links[203]=nil
env.OnBindingChanged(203,'BUTTON_LINK',false)
eq(outputs[#outputs].command,'DO_RELEASE','Detach must attempt logical hold cleanup')
links[203]=target
env.OnBindingChanged(203,'BUTTON_LINK',true)
local before=#outputs
gesture('top','hold_start')
eq(#outputs,before+1,'Rebound controller must not retain the old pressed state')
eq(outputs[#outputs].command,'DO_PUSH')
gesture('top','release')
env.OnDriverDestroyed()
print('actual Dimmer/Light Group links passed: '..assertions..' assertions')
