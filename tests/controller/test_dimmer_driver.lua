-- Real standalone native Dimmer entrypoint with C4 boundaries only stubbed.
local Discovery=require('module.discovery'); local Codec=Discovery.new_codec()
local fixture_file=assert(io.open('tests/fixtures/gestures/v1.json','r'))
local fixtures=Codec:decode(fixture_file:read('*a')); fixture_file:close()
local assertions=0
local function check(value,message) assertions=assertions+1; assert(value,message or ('assertion '..assertions)) end
local function eq(a,b,message) check(a==b,(message or '')..' expected '..tostring(b)..', got '..tostring(a)) end
local function clone(value) return Codec:decode(Codec:encode(value)) end
local function case(name)
    for _,entry in ipairs(fixtures.cases) do if entry.name==name then return clone(entry.state) end end
    error('Missing fixture '..name)
end
local function state(entity,value,second,attributes)
    return {entity_id=entity,state=value,last_updated=string.format('2026-11-14T20:00:%02d.000+00:00',second or 0),attributes=attributes or {}}
end
local function fresh(entity,mode,store,bindings)
    local r={sent={},events={},fired={},timers={},attributes={},late=false,now=100000,bound=bindings or {}}
    Properties={['Entity ID']=entity or 'light.office',['Operation Mode']=require('module.operation_mode').label(mode or 'Direct'),
        ['Entity Selection']='Manual Entity ID',['Status']='',['Discovery Status']=''}
    PersistData=store; C4={}
    function C4:GetDeviceID() return 321 end
    function C4:GetBoundProviderDevice(device,binding)
        eq(device,321); return r.bound[binding] or 0
    end
    function C4:GetTime() return r.now end
    function C4:UpdateProperty(name,value) Properties[name]=value end
    function C4:SetPropertyAttribs(name,value) r.attributes[name]=value end
    function C4:UpdatePropertyList(name,values,selected)
        check(r.late,'No property-list changes before late init')
        if name=='Entity Selection' then r.list={values=values,selected=selected} end
        r.lists=r.lists or {}; r.lists[name]={values=values,selected=selected}; Properties[name]=selected
    end
    function C4:SendToProxy(binding,command,params,kind)
        r.sent[#r.sent+1]={binding=binding,command=command,params=params,kind=kind}
        if r.on_send then r.on_send(binding,command,params,kind) end
    end
    function C4:SetTimer(ms,callback,repeating)
        local timer={callback=callback}; function timer:Cancel() self.cancelled=true end
        r.timers[#r.timers+1]=timer; return timer
    end
    function C4:AddEvent(id,name,description,order)
        check(r.late,'No dynamic events before late init'); r.events[id]={name=name,description=description}; return true
    end
    function C4:FireEventByID(id) r.fired[#r.fired+1]=id; if r.on_fire then r.on_fire(id) end end
    dofile('light/driver.lua'); OnDriverInit(); eq(#r.sent,0)
    function r:start() self.late=true; OnDriverLateInit() end
    function r:property(name,value) Properties[name]=value; OnPropertyChanged(name) end
    function r:state(value,live)
        if live then return ReceivedFromProxy(999,'RECEIEVE_EVENT',{data=Codec:encode({event={data={new_state=value}}})}) end
        return ReceivedFromProxy(999,'RECEIEVE_STATE',{response=Codec:encode(value)})
    end
    function r:messages(command,binding)
        local result={}; for _,message in ipairs(self.sent) do
            if message.command==command and (binding==nil or message.binding==binding) then result[#result+1]=message end
        end; return result
    end
    function r:last(command,binding) local messages=self:messages(command,binding); return messages[#messages] end
    function r:services()
        local result={}; for _,message in ipairs(self:messages('HA_CALL_SERVICE',999)) do result[#result+1]=Codec:decode(message.params.JSON) end
        return result
    end
    function r:discovery(rows)
        if not self:last('HA_GET_ENTITIES',999) then ExecuteCommand('RefreshEntities',{}) end
        local request=Codec:decode(assert(self:last('HA_GET_ENTITIES',999)).params.JSON)
        return ReceivedFromProxy(999,'HA_ENTITIES',{JSON=Codec:encode({version=1,client_id=request.client_id,
            request_id=request.request_id,snapshot_id='test-snapshot',entities=Codec:newArray(rows),complete=true,total=#rows})})
    end
    return r
end
local DIM={supported_color_modes={'brightness'},supported_features=32,brightness=128}
local r=fresh(); r:start()
eq(#r:messages('HA_GET_ENTITIES'),0,'Startup must not download a device list')
eq(Properties['Driver Version'],'1'); eq(r:last('HA_GET_STATE',999).params.entity,'light.office')
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,false)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,false); eq(#r:messages('LIGHT_BRIGHTNESS_CHANGED'),0)
eq(ReceivedFromProxy(5001,'ON',{}),false); eq(#r:services(),0)
eq(r:state(state('light.office','on',1,DIM)),true)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,true)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.ramp_level,true)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.supports_brightness_stop,false)
eq(r:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,128*100/255)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,true)
local cap_count=#r:messages('DYNAMIC_CAPABILITIES_CHANGED',5001)
local level_count=#r:messages('LIGHT_BRIGHTNESS_CHANGED',5001)
eq(r:state(state('light.office','on',2,DIM)),true)
eq(#r:messages('DYNAMIC_CAPABILITIES_CHANGED',5001),cap_count,'Unchanged metadata cannot reset native rate settings')
eq(#r:messages('LIGHT_BRIGHTNESS_CHANGED',5001),level_count,'No duplicate brightness changed event')
local reports=#r:messages('LIGHT_BRIGHTNESS_CHANGED')
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),true)
eq(r:services()[1].domain,'light'); eq(r:services()[1].service,'turn_on')
eq(r:services()[1].service_data.brightness,128)
eq(#r:messages('LIGHT_BRIGHTNESS_CHANGED'),reports,'Requests cannot fabricate confirmed level')
eq(ReceivedFromProxy(5001,'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET=25,RATE=2500}),true)
eq(r:services()[2].service_data.brightness,64); eq(r:services()[2].service_data.transition,2.5)
eq(ReceivedFromProxy(5001,'RAMP_TO_LEVEL',{LEVEL=0,TIME=1000}),true)
eq(r:services()[3].service,'turn_off'); eq(r:services()[3].service_data.transition,1)
eq(ReceivedFromProxy(5001,'OFF',{}),true); eq(ReceivedFromProxy(5001,'TOGGLE',{}),true)
eq(ReceivedFromProxy(5001,'DYNAMIC_ON',{}),true); eq(ReceivedFromProxy(5001,'DYNAMIC_OFF',{}),true)
eq(#r:services(),7)
for _,params in ipairs({{LEVEL=-1},{LEVEL=101},{LEVEL='NaN'},{LEVEL={}}, {LEVEL=20,RATE=-1}}) do
    eq(ReceivedFromProxy(5001,'SET_BRIGHTNESS_TARGET',params),false)
end
eq(#r:services(),7)
eq(ReceivedFromProxy(5001,'SET_BUTTON_COLOR',{COLOR='ff0000'}),false)
check(Properties['LED Status']:find('ready gesture control',1,true)); eq(#r:services(),7)
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=1}),false)
eq(#r:services(),7,'No invented hold/stop implementation')
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=2}),true)
eq(r:services()[8].service,'turn_on')
eq(r:last('BUTTON_ACTION',5001).params.ACTION,2); eq(Properties['Gesture Count'],'0')
eq(ReceivedFromProxy(201,'DO_CLICK',{}),true); eq(r:services()[9].service,'turn_off')
eq(ReceivedFromProxy(202,'DO_CLICK',{}),true); eq(r:services()[10].service,'toggle')
eq(ReceivedFromProxy(123,'ON',{}),false)
local gets=#r:messages('HA_GET_STATE'); eq(ReceivedFromProxy(5001,'SYNCHRONIZE',{}),true)
eq(#r:messages('HA_GET_STATE'),gets+1)
eq(#r:messages('DYNAMIC_CAPABILITIES_CHANGED',5001),cap_count+2,'Explicit synchronization resends native capabilities')
eq(#r:messages('LIGHT_BRIGHTNESS_CHANGED',5001),level_count+1)

-- Confirmed Off overrides cached brightness; older/attribute-less responses
-- cannot restore stale availability or capabilities after newer events.
eq(r:state(state('light.office','off',3,DIM),true),true)
eq(r:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,0)
eq(r:state(state('light.office','on',2,DIM)),false)
eq(r:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,0)
eq(r:state(state('light.office','unavailable',4,DIM),true),true)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,false)
eq(ReceivedFromProxy(5001,'ON',{}),false)
eq(r:state(state('light.office','on',3,DIM)),false)
eq(r:state(state('light.office','on',5,{supported_color_modes={'brightness'},brightness=100})),true)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.ramp_level,false)
eq(ReceivedFromProxy(5001,'RAMP_TO_LEVEL',{LEVEL=50,TIME=1000}),false)
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),true)
eq(r:state(state('light.office','on',6,{supported_color_modes={'brightness'}})),true)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,false,'No on=100 guess for missing dimmer brightness')

-- New selection must revoke the previous light before its property callback.
Properties['Entity ID']='switch.office'
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),false)
eq(r:state(state('light.office','on',7,DIM)),false)
eq(r:state(state('switch.office','off',7)),true)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,false)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.ramp_level,false)
eq(ReceivedFromProxy(5001,'ON',{}),true)
eq(r:services()[#r:services()].domain,'switch')
eq(r:services()[#r:services()].service,'turn_on')
eq(r:services()[#r:services()].target.entity_id,'switch.office')
eq(next(r:services()[#r:services()].service_data),nil,'Binary switches receive no brightness or transition')
eq(ReceivedFromProxy(5001,'OFF',{}),true)
eq(r:services()[#r:services()].service,'turn_off')
eq(ReceivedFromProxy(5001,'TOGGLE',{}),true)
eq(r:services()[#r:services()].service,'toggle')
eq(r:state(state('switch.office','on',8)),true)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,true)
eq(r:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,100)
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),true,'Positive binary target means On')
r:property('Entity ID','light.binary')
eq(r:state(state('light.binary','on',8,{supported_color_modes={'onoff'}})),true)
eq(r:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,100)
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),true)
eq(ReceivedFromProxy(5001,'ON',{}),true)

-- Native discovery works with no Marketplace companion or HA additions.
local selected=Properties['Entity ID']
local rows={
    {entity_id='light.desk',domain='light',name='Office Desk',state='on',availability='available',attributes=DIM},
    {entity_id='switch.desk',domain='switch',name='Desk Switch',state='off',availability='available',attributes=Codec:newObject()},
    {entity_id='event.unrelated',domain='event',name='Unrelated native event',state='unknown',availability='unknown',attributes=Codec:newObject()},
}
eq(r:discovery(rows),true); eq(Properties['Entity ID'],selected,'Refresh never selects a target')
local browser=BrowseHALightDevices(nil,nil,'desk','All Devices'); eq(#browser,2)
check(r.list.values:find('Office Desk [light.desk]',1,true))
eq(ExecuteCommand('SelectDevice',{Device='light.desk'}),true)
eq(Properties['Entity ID'],'light.desk'); eq(Properties['Operation Mode'],'Control HA Device')
eq(ReceivedFromProxy(5001,'ON',{}),false,'Discovery preview cannot authorize service commands')
OnDriverDestroyed(); eq(r.timers[1].cancelled,true)

-- First browsing request waits for native discovery, handles SDK filter names,
-- and completes the original asynchronous callback exactly once.
r=fresh('light.office'); r:start()
local results,completions=nil,0
eq(BrowseHALightDevices(nil,function(found) results=found; completions=completions+1 end,'desk','dimmer'),nil)
eq(completions,0); eq(r:discovery(rows),true); eq(completions,1); eq(#results,1)
eq(results[1].value,'light.desk')
eq(#BrowseHALightDevices(nil,nil,'DESK','DIMMERS'),1)
eq(#BrowseHALightDevices(nil,nil,'desk','all'),2)
-- Unbinding invalidates rows and late replies, with no state/discovery traffic
-- until a new coordinator is actually bound.
local before_gets=#r:messages('HA_GET_STATE'); local before_lists=#r:messages('HA_GET_ENTITIES')
OnBindingChanged(999,'HA_DEVICE',false,1,1)
eq(r.list.values,'Manual Entity ID'); eq(#r:messages('HA_GET_STATE'),before_gets)
eq(#r:messages('HA_GET_ENTITIES'),before_lists)
eq(r:state(state('light.office','on',9,DIM),true),false)
eq(ReceivedFromProxy(5001,'ON',{}),false)
eq(ReceivedFromProxy(5001,'SYNCHRONIZE',{}),false)
r.now=r.now+100000; r.timers[1].callback()
eq(#r:messages('HA_GET_STATE'),before_gets); eq(#r:messages('HA_GET_ENTITIES'),before_lists)
OnBindingChanged(999,'HA_DEVICE',true,2,1)
eq(#r:messages('HA_GET_STATE'),before_gets+1); eq(#r:messages('HA_GET_ENTITIES'),before_lists,'Rebinding must not browse every device')
OnDriverDestroyed()

-- Consolidated picker selects the aggregate's display label for an existing
-- direct load alias without changing the authoritative Entity ID or mode.
r=fresh('switch.fixture'); r:start()
local initial=case('initial_snapshot')
eq(r:discovery({
    {entity_id='switch.fixture',domain='switch',name='Office Paddle',state='off',availability='available',attributes=Codec:newObject()},
    {entity_id=initial.entity_id,domain='event',name='Office Gestures',state='unknown',availability='unknown',attributes=initial.attributes},
}),true)
check(r.list.selected:find('['..initial.entity_id..']',1,true))
eq(Properties['Entity ID'],'switch.fixture'); eq(Properties['Operation Mode'],'Control HA Device')
eq(#BrowseHALightDevices(nil,nil,'switch.fixture','switch'),1)
eq(#BrowseHALightDevices(nil,nil,'switch.fixture','gesture'),1)
eq(#BrowseHALightDevices(nil,nil,'switch.fixture','dimmer'),0)
OnDriverDestroyed()

-- Native discovery avoids whole-registry traffic. Transient coordinator
-- startup failures still retry without changing the selected target.
r=fresh('light.office'); r:start(); ExecuteCommand('RefreshEntities',{})
local function discovery_error(code)
    local request=Codec:decode(r:last('HA_GET_ENTITIES',999).params.JSON)
    return ReceivedFromProxy(999,'HA_ENTITIES',{JSON=Codec:encode({version=1,client_id=request.client_id,
        request_id=request.request_id,entities=Codec:newArray(),complete=true,total=0,error={code=code,message='Retry'}})})
end
eq(discovery_error('invalid_request'),true); r.timers[1].callback()
eq(#r:messages('HA_GET_ENTITIES'),1,'Malformed requests cannot trigger another large fetch')
ExecuteCommand('RefreshEntities',{})
eq(#r:messages('HA_GET_ENTITIES'),2)
eq(Codec:decode(r:last('HA_GET_ENTITIES',999).params.JSON).include_registry,nil)
eq(discovery_error('not_connected'),true); r.now=r.now+3000; r.timers[1].callback()
eq(#r:messages('HA_GET_ENTITIES'),3); eq(Properties['Entity ID'],'light.office')
OnDriverDestroyed()

-- Native LightV2 receives standard button events. Extra/custom gestures use
-- dynamic IDs only, so there is no duplicate standard event in the dropdown.
r=fresh(fixtures.entity_id,'Gesture Bridge'); r:start()
eq(r:state(case('initial_snapshot')),false); eq(#r:messages('BUTTON_ACTION',5001),0)
local native_registered=0
for _,definition in pairs(r.events) do
    if definition.name=='Top Double Tap' or definition.name=='Top Single Tap' or definition.name=='Top Triple Tap' then native_registered=native_registered+1 end
end
eq(native_registered,0)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.dimmer,nil)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,false,'Bridge v1 does not invent brightness')
eq(ReceivedFromProxy(5001,'ON',{}),true); eq(r:services()[1].target.entity_id,'switch.fixture')
eq(r:state(case('first_double_press'),true),true)
eq(r:last('BUTTON_ACTION',5001).params.BUTTON_ID,0); eq(r:last('BUTTON_ACTION',5001).params.ACTION,3)
eq(#r.fired,0); eq(Properties['Gesture Count'],'1')
eq(r:state(case('duplicate_delivery'),true),false); eq(#r:messages('BUTTON_ACTION',5001),1)
eq(r:state(case('second_identical_double_press'),true),true); eq(#r:messages('BUTTON_ACTION',5001),2)
eq(r:state(case('hold_start'),true),true); eq(r:last('BUTTON_ACTION',5001).params.ACTION,1)
eq(r:state(case('hold_repeat'),true),true); eq(#r.fired,1)
eq(r:state(case('reported_release'),true),true); eq(r:last('BUTTON_ACTION',5001).params.ACTION,0)
OnDriverDestroyed()

-- Native notifications may cause a synchronous proxy BUTTON_ACTION echo.
-- Never turn that feedback into extra HA service calls or physical events.
r=fresh(fixtures.entity_id,'Gesture Bridge'); r:start(); r:state(case('initial_snapshot'))
r.on_send=function(binding,command)
    if binding==5001 and command=='BUTTON_ACTION' then
        eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=1}),false)
        eq(ReceivedFromProxy(5001,'DO_CLICK',{}),false)
    end
end
eq(r:state(case('first_double_press'),true),true); eq(#r:services(),0)
eq(#r:messages('BUTTON_ACTION',5001),1)
OnDriverDestroyed()

-- Decoupled mode sends native button-link output to an existing C4 load and
-- blocks every HA load command, including a programmed native click.
r=fresh(fixtures.entity_id,'C4 Button Controller'); r:start(); r:state(case('initial_snapshot'))
eq(r:last('ONLINE_CHANGED',5001).params.STATE,false,'App control requires a readable bound C4 light')
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.hide_proxy_conditionals_loops,true)
for _,command in ipairs({'ON','OFF','TOGGLE','DYNAMIC_ON','DYNAMIC_OFF','SET_LEVEL','SET_BRIGHTNESS_TARGET','RAMP_TO_LEVEL'}) do
    eq(ReceivedFromProxy(5001,command,{LEVEL=50,LIGHT_BRIGHTNESS_TARGET=50,RATE=1000,TIME=1000}),false)
end
eq(#r:services(),0)
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=2}),true)
eq(r:last('DO_PUSH',203).kind,'COMMAND'); eq(r:last('DO_CLICK',203).kind,'COMMAND')
eq(r:last('BUTTON_ACTION',5001).params.ACTION,2); eq(Properties['Gesture Count'],'0')
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=1}),true)
eq(r:last('BUTTON_ACTION',5001).params.ACTION,1); eq(Properties['Gesture Count'],'0')
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=0}),true)
eq(r:last('BUTTON_ACTION',5001).params.ACTION,0); eq(Properties['Gesture Count'],'0')
eq(#r:services(),0)
eq(r:state(case('first_double_press'),true),true)
eq(#r:messages('DO_CLICK',203),1,'Double tap cannot become two load clicks')
eq(r:state(case('hold_start'),true),true); eq(#r:messages('DO_PUSH',203),3)
eq(r:state(case('reported_release'),true),true); eq(#r:messages('DO_RELEASE',203),2)
for _,binding in ipairs({200,201,202}) do
    eq(#r:messages('DO_PUSH',binding),0,'Controller output cannot use legacy provider links')
    eq(#r:messages('DO_CLICK',binding),0)
    eq(#r:messages('DO_RELEASE',binding),0)
end
-- Target status is feedback on a consumer connection, not another physical
-- press or a command to the HA load. Ignore it without echoing or forwarding.
local messages_before=#r.sent
for _,binding in ipairs({203,204,205}) do
    for _,command in ipairs({'MATCH_LED_STATE','BUTTON_COLOR','DO_PUSH','DO_CLICK','DO_RELEASE','ON'}) do
        eq(ReceivedFromProxy(binding,command,{STATE=true,COLOR='FFFFFF'}),false)
    end
end
eq(#r.sent,messages_before,'Consumer feedback cannot create command loops')
eq(#r:services(),0)
-- Rebinding the new consumer link releases a forwarded hold. Touching a
-- legacy provider connection cannot cancel a hold to a separate target.
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=1}),true)
local releases=#r:messages('DO_RELEASE',203)
OnBindingChanged(200,'BUTTON_LINK',true)
eq(#r:messages('DO_RELEASE',203),releases)
OnBindingChanged(203,'BUTTON_LINK',false)
eq(#r:messages('DO_RELEASE',203),releases+1)
local gesture_count=Properties['Gesture Count']
OnBindingChanged(203,'BUTTON_LINK',true)
eq(#r:messages('DO_RELEASE',203),releases+1)
eq(Properties['Gesture Count'],gesture_count,'Binding cleanup is not a physical release')
OnDriverDestroyed(); eq(#r:services(),0)

-- Reentrant source/mode changes from event programming cannot forward to a
-- newly selected bound C4 load using the old physical gesture.
r=fresh(fixtures.entity_id,'C4 Button Controller'); r:start(); r:state(case('initial_snapshot'))
r.on_send=function(binding,command)
    if binding==5001 and command=='BUTTON_ACTION' then r:property('Operation Mode','Control HA Device') end
end
eq(r:state(case('first_double_press'),true),false); eq(#r:messages('DO_PUSH',203),0)
eq(#r:services(),0); OnDriverDestroyed()
r=fresh(fixtures.entity_id,'Gestures Only'); r:start(); r:state(case('initial_snapshot'))
r.on_send=function(binding,command)
    if binding==5001 and command=='BUTTON_ACTION' then Properties['Entity ID']='event.changed_without_callback' end
end
eq(r:state(case('first_double_press'),true),false); eq(#r:services(),0)
OnDriverDestroyed()

-- Contract 1.1 retains a linked HA light's real brightness/transition metadata.
-- A single native Dimmer can therefore expose both its load and paddle events.
local light_snapshot=case('initial_snapshot')
light_snapshot.attributes.bridge_contract_version='1.1'
light_snapshot.attributes.bridge_load={entity_id='light.office',domain='light',state='on',available=true,attributes=clone(DIM)}
r=fresh(fixtures.entity_id,'Gesture Bridge'); r:start()
eq(r:state(light_snapshot),false)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,true)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.ramp_level,true)
eq(r:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,128*100/255)
-- One combined entry remains discoverable as both a dimmer and a gesture
-- control, including searches for the linked load's authoritative Entity ID.
local linked_rows={
    {entity_id='light.office',domain='light',name='Office Dimming Load',state='on',availability='available',attributes=clone(DIM)},
    {entity_id=light_snapshot.entity_id,domain='event',name='Paddle Gestures',state='unknown',availability='unknown',attributes=clone(light_snapshot.attributes)},
}
eq(r:discovery(linked_rows),true)
eq(#BrowseHALightDevices(nil,nil,'','all'),1,'Consolidation cannot duplicate one physical dimmer')
local dimmer_choices=BrowseHALightDevices(nil,nil,'light.office','dimmer')
eq(#dimmer_choices,1); eq(dimmer_choices[1].value,light_snapshot.entity_id)
eq(#BrowseHALightDevices(nil,nil,'light.office','Gestures'),1)
eq(#BrowseHALightDevices(nil,nil,'light.office','Switches'),0)
eq(Properties['Entity ID'],light_snapshot.entity_id); eq(Properties['Operation Mode'],'Control HA Device with Button Events')
eq(#r:services(),0); eq(#r:messages('BUTTON_ACTION',5001),0)
-- Registry/native load rows are optional: validated 1.1 aggregate projection
-- alone still establishes that this combined choice supports dimming.
ExecuteCommand('RefreshEntities',{})
eq(r:discovery({linked_rows[2]}),true)
eq(#BrowseHALightDevices(nil,nil,'light.office','Dimmers'),1)
eq(#BrowseHALightDevices(nil,nil,'light.office','Gestures'),1)
eq(ReceivedFromProxy(5001,'SET_BRIGHTNESS_TARGET',{LEVEL=60,RATE=1500}),true)
eq(r:services()[1].domain,'light'); eq(r:services()[1].service_data.brightness,153)
eq(r:services()[1].service_data.transition,1.5)
local light_press=case('first_double_press')
light_press.attributes.bridge_contract_version='1.1'; light_press.attributes.bridge_load=clone(light_snapshot.attributes.bridge_load)
local reported=#r:messages('LIGHT_BRIGHTNESS_CHANGED',5001)
eq(r:state(light_press,true),true); eq(r:last('BUTTON_ACTION',5001).params.ACTION,3)
eq(#r:messages('LIGHT_BRIGHTNESS_CHANGED',5001),reported,'Gesture alone cannot duplicate a load changed event')
local light_off=clone(light_press); light_off.last_updated='2026-11-14T20:00:30Z'
light_off.attributes.bridge_update_kind='snapshot'; light_off.attributes.bridge_load.state='off'
eq(r:state(light_off),false); eq(r:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,0)
local unavailable=clone(light_off); unavailable.last_updated='2026-11-14T20:00:31Z'
unavailable.attributes.bridge_load.available=false
eq(r:state(unavailable),false); eq(r:last('ONLINE_CHANGED',5001).params.STATE,false)
eq(ReceivedFromProxy(5001,'ON',{}),false); eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),false)
OnDriverDestroyed()

-- Identical event identity/name/order with changed semantics must remap the
-- adapter even though its cosmetic Composer presentation did not change.
local semantic=case('initial_snapshot')
semantic.attributes.bridge_buttons={{id='top',label='Top',gestures={{id='edge',label='Edge',kind='custom'}}}}
r=fresh(fixtures.entity_id,'Gestures Only'); r:start(); r:state(semantic)
local function edge(sequence,kind)
    local value=case('first_double_press'); local a=value.attributes
    value.last_updated=string.format('2026-11-14T20:00:%02dZ',40+sequence)
    a.bridge_buttons=clone(semantic.attributes.bridge_buttons); a.bridge_buttons[1].gestures[1].kind=kind
    a.event_type=kind; a.gesture_id='edge'; a.press_count=nil
    a.gesture_sequence=sequence; a.gesture_event_id=a.bridge_session_id..':'..sequence
    return value
end
eq(r:state(edge(1,'custom'),true),true); eq(#r.fired,1); eq(#r:messages('BUTTON_ACTION',5001),0)
eq(r:state(edge(2,'hold_start'),true),true); eq(#r.fired,1)
eq(r:last('BUTTON_ACTION',5001).params.ACTION,1)
eq(r:state(edge(3,'custom'),true),true); eq(#r.fired,2); eq(#r:messages('BUTTON_ACTION',5001),1)
OnDriverDestroyed()

-- A ready native source need not claim knowledge of physical availability.
r=fresh(fixtures.entity_id,'C4 Button Controller'); r:start()
local unknown_source=case('initial_snapshot'); unknown_source.attributes.bridge_sources[1].availability='unknown'
unknown_source.attributes.bridge_sources[1].ready=true
eq(r:state(unknown_source),false); eq(r:last('ONLINE_CHANGED',5001).params.STATE,false)
OnDriverDestroyed()
-- Catalog names/areas are optional metadata and never brightness authority.
r=fresh('light.office'); r:start()
r:discovery({{entity_id='light.office',domain='light',name='Native Lamp',state='on',availability='available',
    attributes={supported_color_modes=Codec:newArray({'brightness'}),supported_features=32}}})
local request=Codec:decode(r:last('HA_GET_ENTITIES',999).params.JSON)
eq(request.entity_ids[1],'sensor.ha_gesture_bridge_catalog')
local catalog_row={entity_id='sensor.ha_gesture_bridge_catalog',domain='sensor',name='Catalog',state='1',availability='available',
    attributes={catalog_contract_version='1.0',catalog_names_version=1,catalog_names_revision=string.rep('a',64),catalog_names_pages=1,catalog_names_total=1,catalog_names_page_001=Codec:newArray({
        {entity_id='light.office',domain='light',friendly_name='Office Lamp',area_name='Upstairs',
            state='off',attributes={supported_features=0}}})}}
r:discovery({catalog_row}) -- Names manifest.
r:discovery({catalog_row}) -- Correlated names page.
check(r.list.values:find('Office Lamp — Upstairs [light.office]',1,true))
eq(#BrowseHALightDevices(nil,nil,'upstairs','dimmer'),1)
eq(Properties['Entity ID'],'light.office'); eq(Properties['Operation Mode'],'Control HA Device')
eq(#r:services(),0); eq(#r.fired,0)
eq(r:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,false)
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),false)
for _,message in ipairs(r:messages('HA_GET_STATE',999)) do eq(message.params.entity,'light.office') end
local read_count=#r:messages('HA_GET_ENTITIES',999)
r:property('Discovery Catalog Entity ID','')
eq(#r:messages('HA_GET_ENTITIES',999),read_count)
check(not r.list.values:find('Upstairs',1,true))
ReceivedFromProxy(999,'HA_ENTITIES',{JSON=Codec:encode({version=1,client_id=request.client_id,
    request_id=request.request_id,snapshot_id='delayed-catalog',entities=Codec:newArray({catalog_row}),complete=true,total=1})})
check(not r.list.values:find('Upstairs',1,true))
r:state(state('light.office','on',1,DIM))
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),true)
eq(r:services()[1].target.entity_id,'light.office')
OnDriverDestroyed()

-- Opt-in trace exposes the selected input/decision/output path without raw HA
-- JSON, private attributes or unrelated entity traffic. Default Off is quiet.
local normal_print=print
local logs={}
print=function(line) logs[#logs+1]=tostring(line) end
r=fresh(fixtures.entity_id,'C4 Button Controller'); r:start()
r:state(case('initial_snapshot'))
eq(#logs,0,'Absent/default Off debug mode emits no trace')
r:property('Debug Mode','On')
local snapshot=case('initial_snapshot')
snapshot.attributes.access_token='do-not-print-token'
snapshot.attributes.raw_payload='do-not-print-payload'
r:state(snapshot)
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=2,secret='do-not-print-native'}),true)
local unrelated=clone(snapshot); unrelated.entity_id='event.unrelated'; unrelated.state='do-not-print-unrelated'
local before_logs=#logs
eq(r:state(unrelated,true),false); eq(#logs,before_logs,'Unrelated entities do not create trace noise')
eq(r:state(case('first_double_press'),true),true)
local held=case('hold_start')
held.attributes.access_token='do-not-print-token'
held.attributes.raw_payload='do-not-print-payload'
r.on_send=function(_,command) if command=='DO_PUSH' then r.now=r.now+7 end end
eq(r:state(held,true),true)
eq(r:state(held,true),false,'Duplicate trace must retain decoder rejection')
OnBindingChanged(203,'BUTTON_LINK',false)
eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true,secret='do-not-print-feedback'}),false)
local malformed=case('reported_release')
malformed.attributes.gesture_id='line one\n'..string.rep('x',300)..'TAIL_SENTINEL'
eq(r:state(malformed,true),false)
local trace_text=table.concat(logs,'\n')
for _,expected in ipairs({'debug enabled','entity='..fixtures.entity_id,'mode=C4 Button Controller',
    'receive','button=top','kind=hold_start','sequence=7','session=session-a',
    'decision | accepted=true','decision | accepted=false','forward | binding=203 | command=DO_PUSH',
    'local_ms=100000','received_utc=','receive_to_forward_ms=7',
    'forward | binding=203 | command=DO_RELEASE','binding | id=203 | bound=false','feedback ignored',
    'input | binding=5001 | command=BUTTON_ACTION | button=0 | action=2'}) do
    check(trace_text:find(expected,1,true),'Missing diagnostic trace: '..expected)
end
for _,secret in ipairs({'do-not-print-token','do-not-print-payload','do-not-print-unrelated','do-not-print-feedback',
    'do-not-print-native','access_token','raw_payload','TAIL_SENTINEL'}) do
    check(not trace_text:find(secret,1,true),'Raw/private HA data cannot be printed')
end
for _,line in ipairs(logs) do check(not line:find('[\r\n]'),'Trace entries stay on one line') end
r:property('Debug Mode','Off')
local disabled_count=#logs
OnBindingChanged(203,'BUTTON_LINK',true)
OnDriverDestroyed()
eq(#logs,disabled_count,'Turning debug Off silences subsequent cleanup/binding activity')
print=normal_print
-- Arrival timing uses HA/C4 UTC clocks; it cannot change gesture decisions.
logs={}; print=function(line) logs[#logs+1]=tostring(line) end
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start()
r:property('Debug Mode','On'); r:state(case('initial_snapshot'))
local initial_logs=table.concat(logs,'\n')
check(not initial_logs:find('ha_to_driver_ms=',1,true),'Snapshots are not latency samples')
local timed=case('first_double_press')
timed.state='2026-11-15T07:52:52.027+00:00'
timed.attributes.gesture_occurred_at=timed.state
-- 2026-11-15T07:52:52Z = epoch 1794729172 seconds.
r.now=1794729172042
eq(r:state(timed,true),true)
check(table.concat(logs,'\n'):find('ha_to_driver_ms=15',1,true),'Arrival delay is UTC milliseconds, not local time')
local offset=case('second_identical_double_press')
offset.state='2026-11-15T00:52:52.027-07:00'
offset.attributes.gesture_occurred_at=offset.state
r.now=1794729172022
eq(r:state(offset,true),true)
check(table.concat(logs,'\n'):find('ha_to_driver_ms=-5',1,true),'Clock skew remains visible and never rejects a valid gesture')
OnDriverDestroyed(); print=normal_print

-- Explicit latency acknowledgments use the existing coordinator service path,
-- never light services, and do not add traffic for ordinary/debug-only use.
logs={}; print=function(line) logs[#logs+1]=tostring(line) end
local function ack_state(name)
    local value=case(name); value.attributes.bridge_acknowledgment_version=2; return value
end
for _,flags in ipairs({{debug='On',latency='Off'},{debug='Off',latency='On'}}) do
    r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start()
    r:property('Debug Mode',flags.debug); r:property('Latency Diagnostics',flags.latency)
    r:state(ack_state('initial_snapshot')); r:state(ack_state('first_double_press'),true)
    eq(#r:services(),0,'Both diagnostics switches must be enabled before ack traffic')
    OnDriverDestroyed()
end
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start()
r:property('Debug Mode','On'); r:property('Latency Diagnostics','On')
r:state(ack_state('initial_snapshot')); eq(#r:services(),0,'Never acknowledge snapshots')
r.now=1794729172042
r.on_send=function(_,command) if command=='DO_PUSH' or command=='DO_CLICK' then r.now=r.now+3 end end
local single=ack_state('first_double_press'); single.attributes.gesture_id='press_1'; single.attributes.press_count=1
eq(r:state(single,true),true)
local ack=r:services()[1]
eq(ack.domain,'ha_gesture_bridge'); eq(ack.service,'acknowledge')
eq(ack.service_data.entity_id,fixtures.entity_id)
eq(ack.service_data.bridge_session_id,single.attributes.bridge_session_id)
eq(ack.service_data.gesture_sequence,single.attributes.gesture_sequence)
eq(ack.service_data.receiver,'control4:321')
eq(ack.service_data.receiver_received_epoch_ms,1794729172042)
eq(ack.service_data.receiver_processed_epoch_ms,1794729172048)
eq(ack.service_data.receiver_forwarded_epoch_ms,1794729172048)
eq(ack.service_data.receiver_processing_ms,6)
eq(r:state(single,true),false); eq(#r:services(),1,'Duplicates cannot produce a second ack')
eq(r:state(ack_state('second_identical_double_press'),true),true)
eq(#r:services(),2)
eq(r:services()[2].service_data.receiver_forwarded_epoch_ms,nil,'Programming-only double taps cannot claim a forwarded load command')
r:property('Debug Mode','Off'); OnDriverDestroyed()
-- Old companion versions do not advertise the action; no unsupported call.
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start()
r:property('Debug Mode','On'); r:property('Latency Diagnostics','On')
r:state(case('initial_snapshot')); r:state(case('first_double_press'),true)
eq(#r:services(),0)
r:property('Debug Mode','Off'); OnDriverDestroyed()

print=normal_print

-- Each installer label must select its intended behavior.
for _,label in ipairs({'Control HA Device with Button Events','Programming Events Only','Control Connected C4 Light'}) do
    r=fresh(fixtures.entity_id,label); r:start()
    eq(Properties['Operation Mode'],label)
    check(type(Properties['Mode Description'])=='string' and #Properties['Mode Description']>0)
    r:state(case('initial_snapshot'))
    eq(r:state(case('first_double_press'),true),true)
    eq(ReceivedFromProxy(5001,'ON',{}),label=='Control HA Device with Button Events')
    eq(#r:services(),label=='Control HA Device with Button Events' and 1 or 0)
    OnDriverDestroyed()
end
r=fresh('light.office','Control HA Device'); r:start()
r:state(state('light.office','on',1,DIM))
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=25}),true)
eq(r:services()[1].target.entity_id,'light.office')
OnDriverDestroyed()
r=fresh(fixtures.entity_id,'C4 Button Controller'); r:start()
eq(Properties['Operation Mode'],'Control Connected C4 Light','Current controller mode stays selected')
r:state(case('initial_snapshot')); r:state(case('hold_start'),true)
local pushes,releases=#r:messages('DO_PUSH',203),#r:messages('DO_RELEASE',203)
r:property('Operation Mode','Control Connected C4 Light')
eq(Properties['Operation Mode'],'Control Connected C4 Light')
eq(#r:messages('DO_PUSH',203),pushes); eq(#r:messages('DO_RELEASE',203),releases,'Reselecting the same mode must not cancel a held output')
r:state(case('reported_release'),true)
eq(#r:messages('DO_RELEASE',203),releases+1)
OnDriverDestroyed()
-- Both entry points use the shared parsed message for routing and validation.
r=fresh(fixtures.entity_id,'C4 Button Controller'); r:start()
local baseline=case('initial_snapshot'); local live=case('first_double_press')
local json_module=getmetatable(require('module.json')); local original_decode=json_module.decode
local decode_calls=0
json_module.decode=function(self,...) decode_calls=decode_calls+1; return original_decode(self,...) end
r:state(baseline); eq(decode_calls,1,'One JSON parse per received snapshot')
decode_calls=0
r:state(live,true); eq(decode_calls,1,'One JSON parse per received live gesture')
json_module.decode=original_decode
OnDriverDestroyed()

-- Owned strict-syntax errors must still cancel held output. Unrelated or
-- wholly undecodable messages must not change another entity's state.
r=fresh(fixtures.entity_id,'C4 Button Controller'); r:start()
r:state(case('initial_snapshot')); r:state(case('hold_start'),true)
local function releases()
    local count=0
    for _,sent in ipairs(r.sent) do if sent.binding==203 and sent.command=='DO_RELEASE' then count=count+1 end end
    return count
end
local before_release=releases()
local broken=case('reported_release'); broken.entity_id='event.unrelated'
ReceivedFromProxy(999,'RECEIEVE_EVENT',{data=Codec:encode({event={data={new_state=broken}}})..' trailing'})
eq(releases(),before_release,'Malformed other entity cannot cancel a held output')
ReceivedFromProxy(999,'RECEIEVE_EVENT',{data='{malformed'})
eq(releases(),before_release,'Undecodable messages have no established owner')
broken.entity_id=fixtures.entity_id
local fired_before=#r.fired
ReceivedFromProxy(999,'RECEIEVE_EVENT',{data=Codec:encode({event={data={new_state=broken}}})..' trailing'})
eq(releases(),before_release+1,'Owned invalid JSON still cancels unsafe held output')
eq(#r.fired,fired_before,'Invalid prefix cannot fire release programming')
OnDriverDestroyed()

-- HA transport loss stops a forwarded hold once. Reconnection cannot consume
-- queued physical events until the freshly requested snapshot is baselined.
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start()
r:state(case('initial_snapshot')); r:state(case('hold_start'),true)
eq(#r:messages('DO_PUSH',203),1)
local physical_events=#r:messages('BUTTON_ACTION',5001)
local held_messages=#r.sent
for _,invalid in ipairs({{}, {CONNECTED='FALSE'}, {CONNECTED='0'}, {CONNECTED=1}, {CONNECTED={}}, 'garbage', false}) do
    eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',invalid),false)
    eq(#r.sent,held_messages,'Malformed status cannot change held output or issue requests')
end
eq(ReceivedFromProxy(203,'HA_CONNECTION_STATUS',{CONNECTED='false'}),false)
eq(#r.sent,held_messages,'A consumer feedback binding cannot revoke the HA connection')
eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'}),true)
eq(#r:messages('DO_RELEASE',203),1)
local down_messages=#r.sent
eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'}),true)
eq(#r.sent,down_messages,'Duplicate loss cannot release twice')
eq(r:state(case('reported_release'),true),false)
eq(ReceivedFromProxy(5001,'BUTTON_ACTION',{BUTTON_ID=0,ACTION=2}),false)
eq(ReceivedFromProxy(5001,'ON',{}),false)
eq(#r:services(),0); eq(#r:messages('DO_PUSH',203),1)
eq(#r:messages('BUTTON_ACTION',5001),physical_events,'Loss cleanup is not a physical release')
local state_requests=#r:messages('HA_GET_STATE',999)
eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'}),true)
eq(#r:messages('HA_GET_STATE',999),state_requests+1,'Reconnect requests a fresh primary snapshot')
eq(#r:messages('HA_GET_ENTITIES'),0,'Recovery must not rebuild the picker')
eq(r:state(case('reported_release'),true),false)
eq(#r:messages('DO_RELEASE',203),1,'Reconnect cannot repeat loss cleanup')
eq(#r:messages('BUTTON_ACTION',5001),physical_events,'Queued live events cannot pass the reconnect snapshot gate')
eq(r:state(case('snapshot_of_unseen_offline_press')),false)
eq(Properties['Last Sequence'],'5')
eq(#r:messages('BUTTON_ACTION',5001),physical_events,'Snapshot establishes history without programming')
eq(#r:messages('DO_PUSH',203),1)
local after_reconnect=case('fresh_press_after_snapshot')
after_reconnect.attributes.gesture_id='press_1'; after_reconnect.attributes.press_count=1
eq(r:state(after_reconnect,true),true)
eq(#r:messages('BUTTON_ACTION',5001),physical_events+1)
eq(#r:messages('DO_PUSH',203),2); eq(#r:messages('DO_CLICK',203),1)
eq(r:state(after_reconnect,true),false)
eq(#r:messages('BUTTON_ACTION',5001),physical_events+1,'First recovered live occurrence fires only once')
eq(#r:messages('DO_CLICK',203),1)
OnDriverDestroyed()

-- Previously confirmed brightness cannot authorize commands while HA is down
-- or while a reconnect still awaits its primary state response.
r=fresh('light.office','Control HA Device'); r:start()
r:state(state('light.office','on',1,DIM))
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
eq(ReceivedFromProxy(5001,'ON',{}),false)
eq(r:state(state('light.office','on',2,DIM),true),false)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,false)
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=25}),false)
eq(r:state(state('light.office','on',2,DIM),true),false)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,false)
eq(r:state(state('light.office','off',3,DIM)),true)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,true)
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=25}),true)
eq(#r:services(),1)

-- HTML has no established owner; reject it quietly without revoking the
-- valid selected light or fabricating brightness/availability feedback.
local saved_print,privacy_logs=print,{}
local before_feedback=#r:messages('LIGHT_BRIGHTNESS_CHANGED',5001)
r:property('Debug Mode','Off')
print=function(...) local values={}; for i=1,select('#',...) do values[#values+1]=tostring(select(i,...)) end; privacy_logs[#privacy_logs+1]=table.concat(values,' ') end
eq(ReceivedFromProxy(999,'RECEIEVE_STATE',{response='<html>PRIVATE_DIMMER_RESPONSE</html>'}),false)
print=saved_print
eq(Properties['Debug Mode'],'Off')
check(not table.concat(privacy_logs,'\n'):find('PRIVATE_DIMMER_RESPONSE',1,true),'HTML response contents must stay private')
eq(#r:messages('LIGHT_BRIGHTNESS_CHANGED',5001),before_feedback)
eq(r:last('ONLINE_CHANGED',5001).params.STATE,true)
eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=50}),true)
eq(#r:services(),2); eq(r:services()[2].target.entity_id,'light.office')
OnDriverDestroyed()

-- Native and custom LED commands share one optional, validated channel. No
-- palette/feedback is inferred from a light's brightness or its color modes.
local function led_state(name)
    local value=case(name or 'initial_snapshot')
    value.attributes.bridge_led_version=1
    value.attributes.bridge_led_command_version=2
    value.attributes.bridge_leds=Codec:newArray({{id='indicator',label='Office Indicator',button_id='toggle',
        available=true,colors=Codec:newArray({'000000','FFFFFF','FF0000','00FF00','0000FF'}),
        brightness_supported=true,color_supported=true,behaviors=Codec:newArray({'follow_load','follow_load_inverted','always_on','always_off'}),color='000000',brightness=50}})
    return value
end
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start()
r:state(case('initial_snapshot'))
eq(#GetCommandParamList('Set LED Current Color','Button'),0)
eq(ReceivedFromProxy(5001,'SET_BUTTON_COLOR',{Number='2',CURRENT_COLOR='FF0000'}),false)
eq(#r:services(),0,'Old companion versions require no LED service')
local indicator=led_state(); indicator.last_updated='2026-11-14T20:00:00.500Z'
r:state(indicator)
local led_choices=GetCommandParamList('Set LED Current Color','Button')
eq(#led_choices,1); eq(led_choices[1],'Toggle')
eq(Properties['LED Status'],'LEDs: toggle (on/off, color, brightness)')
local led_info=r:last('BUTTON_INFO',5001).params
eq(led_info.BUTTON_ID,2); eq(led_info.ON_COLOR,'FFFFFF'); eq(led_info.OFF_COLOR,'000000')
eq(led_info.CURRENT_COLOR,'000000'); eq(#r:services(),0)
local feedback_count=#r:messages('BUTTON_INFO',5001)
indicator.last_updated='2026-11-14T20:00:00.750Z'; r:state(indicator)
eq(#r:messages('BUTTON_INFO',5001),feedback_count,'Identical LED metadata cannot add native callbacks to each gesture')
eq(ReceivedFromProxy(5001,'SET_BUTTON_COLOR',{Number='2',CURRENT_COLOR='FF0000'}),true)
eq(r:services()[1].service_data.color,'FF0000')
eq(r:last('BUTTON_INFO',5001).params.CURRENT_COLOR,'000000','Queued color is not confirmed hardware feedback')
eq(ReceivedFromProxy(5001,'SET_BUTTON_COLOR',{BUTTON_ID='2',ON_COLOR='0000FF'}),true)
eq(ReceivedFromProxy(5001,'SET_BUTTON_COLOR',{NUMBER=2,OFF_COLOR='00FF00'}),true)
eq(#r:services(),1,'On/Off preferences wait for a known target state')
eq(ReceivedFromProxy(5001,'SET_ALL_LED',{COLOR='0000FF'}),true)
eq(ExecuteCommand('Set LED On Color',{Button='Toggle',Color='FF0000'}),true)
eq(ExecuteCommand('Set LED Off Color',{Button='Toggle',Color='000000'}),true)
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='00FF00'}),true)
eq(ExecuteCommand('Set All LED Colors',{Color='FFFFFF'}),true)
eq(ExecuteCommand('Set LED Brightness',{Button='Toggle',Brightness='25'}),true)
eq(r:services()[#r:services()].service_data.brightness,25)
eq(ExecuteCommand('Set LED Current Color',{Button='Top',Color='FFFFFF'}),false)
local led_requests=#r:services()
eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),false)
eq(#r:services(),led_requests,'Target-follow feedback defaults to Disabled')
r:property('LED Behavior','Follow Bound Device')
eq(Properties['LED Feedback Source'],'Top')
eq(#r:messages('REQUEST_BUTTON_COLORS',203),1)
eq(#r:services(),led_requests,'Enabling feedback requests state, never assumes it')
eq(ReceivedFromProxy(204,'MATCH_LED_STATE',{STATE=true}),false)
eq(#r:services(),led_requests,'Other target bindings cannot drive the selected feedback source')
eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),true)
eq(#r:services(),led_requests+1); eq(r:services()[led_requests+1].service_data.color,'FFFFFF')
eq(ExecuteCommand('Set LED On Color',{Button='Toggle',Color='FF0000'}),true)
eq(#r:services(),led_requests+1,'On color preferences cannot change hardware behavior')
r:property('LED Feedback Source','Disabled')
local disabled_requests=#r:services()
eq(ExecuteCommand('Set LED On Color',{Button='Toggle',Color='00FF00'}),true)
eq(#r:services(),disabled_requests,'Disabling follow clears the old logical state')
eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=false}),false)
eq(#r:services(),disabled_requests)
indicator.last_updated='2026-11-14T20:00:01.000Z'; r:state(indicator)
eq(#r:services(),disabled_requests,'A snapshot cannot apply preferences or echo queued requests')
eq(#r:messages('BUTTON_ACTION',5001),0,'LED metadata is not a physical press')
local offline_indicator=clone(indicator)
offline_indicator.last_updated='2026-11-14T20:00:01.250Z'
offline_indicator.attributes.bridge_leds[1].available=false
offline_indicator.attributes.bridge_leds[1].color=nil
offline_indicator.attributes.bridge_leds[1].brightness=nil
r:state(offline_indicator)
eq(#GetCommandParamList('Set LED Current Color','Button'),0)
eq(r:last('BUTTON_INFO',5001).params.CURRENT_COLOR,nil,'Unavailable LED is unknown, never an invented black')
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='000000'}),false)
indicator.last_updated='2026-11-14T20:00:01.500Z'; r:state(indicator)
eq(#r:services(),disabled_requests,'Availability recovery cannot write the indicator')
for _,call in ipairs(r:services()) do
    eq(call.domain,'ha_gesture_bridge'); eq(call.service,'set_led')
    eq(call.service_data.entity_id,fixtures.entity_id); eq(call.service_data.led_id,'indicator')
end
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
eq(ExecuteCommand('Set All LED Colors',{Color='FFFFFF'}),false)
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='FF0000'}),false)
indicator.last_updated='2026-11-14T20:00:02.000Z'; r:state(indicator)
eq(#r:services(),disabled_requests)
OnBindingChanged(999,'HA_DEVICE',false)
eq(ReceivedFromProxy(5001,'SET_ALL_LED',{COLOR='FFFFFF'}),false)
OnBindingChanged(999,'HA_DEVICE',true)
indicator.last_updated='2026-11-14T20:00:03.000Z'; r:state(indicator)
r:property('Entity ID','event.replacement')
eq(ExecuteCommand('Set LED Brightness',{Button='Toggle',Brightness='25'}),false)
eq(#GetCommandParamList('Set LED Current Color','Button'),0)
eq(#r:services(),disabled_requests,'Unbinding or changing source revokes LED authority')
OnDriverDestroyed()

do
    -- Independent scene-controller LEDs remain individually selectable through
    -- the real driver command surface, without creating native paddle IDs.
    local r=fresh(fixtures.entity_id,'Programming Events Only'); r:start()
    local value=led_state()
    value.attributes.bridge_leds=Codec:newArray()
    for index=1,5 do
        value.attributes.bridge_leds[index]={id='scene_'..index,label='Button '..index..' LED',
            button_id='button_'..index,available=true,colors=Codec:newArray({'000000','FF0000','0000FF'}),
            brightness_supported=index~=5,color_supported=true,behaviors=Codec:newArray({'follow_load','follow_load_inverted','always_on','always_off'}),color='000000',brightness=index~=5 and 60 or nil}
    end
    r:state(value)
    local choices=GetCommandParamList('Set LED Current Color','Button')
    eq(#choices,5); eq(#GetCommandParamList('Set LED On Color','Button'),5)
    eq(#GetCommandParamList('Set LED Off Color','Button'),5)
    eq(#GetCommandParamList('Set LED Brightness','Button'),4)
    eq(#r:messages('BUTTON_INFO',5001),0,'Custom LED channels must not invent native button IDs')
    for index,choice in ipairs(choices) do
        eq(choice,'Button '..index..' LED [scene_'..index..']')
        eq(ExecuteCommand('Set LED Current Color',{Button=choice,Color='FF0000'}),true)
        local calls=r:services()
        eq(calls[#calls].domain,'ha_gesture_bridge'); eq(calls[#calls].service,'set_led')
        eq(calls[#calls].service_data.entity_id,fixtures.entity_id)
        eq(calls[#calls].service_data.led_id,'scene_'..index)
        eq(calls[#calls].service_data.color,'FF0000')
    end
    local saved=choices[1]
    value.last_updated='2026-11-14T20:00:01.000Z'
    value.attributes.bridge_leds[1].label='Renamed first indicator'
    r:state(value)
    eq(#r:services(),5,'A label change cannot emit an LED command')
    eq(ExecuteCommand('Set LED Brightness',{Button=saved,Brightness='30'}),true)
    local last=r:services()[#r:services()]
    eq(last.service_data.led_id,'scene_1'); eq(last.service_data.brightness,30)
    eq(ExecuteCommand('Set LED Current Color',{Button='Button 1 LED [missing]',Color='FF0000'}),false)
    eq(ExecuteCommand('Set LED Brightness',{Button=choices[5],Brightness='30'}),false)
    eq(#r:services(),6,'Rejected selections cannot send a service')
    value.last_updated='2026-11-14T20:00:02.000Z'
    value.attributes.bridge_leds[1].available=false
    value.attributes.bridge_leds[1].color=nil
    value.attributes.bridge_leds[1].brightness=nil
    r:state(value)
    eq(#GetCommandParamList('Set LED Current Color','Button'),4)
    eq(ExecuteCommand('Set LED Current Color',{Button=saved,Color='FF0000'}),false)
    eq(#r:services(),6,'Old choices cannot bypass unavailable channels')
    OnDriverDestroyed()
    local target=fresh(fixtures.entity_id,'Control Connected C4 Light'); target:start()
    for _,channel in ipairs(value.attributes.bridge_leds) do channel.available=true end
    target:state(value)
    target:property('LED Behavior','Follow Bound Device')
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),true)
    eq(#target:services(),5,'Explicit target feedback can drive every independent LED')
    for _,call in ipairs(target:services()) do
        eq(call.domain,'ha_gesture_bridge'); eq(call.service,'set_led')
        check(call.service_data.led_id:match('^scene_[1-5]$'))
    end
    eq(#target:messages('BUTTON_INFO',5001),0,'Custom indicator feedback has no native button ID')
    OnDriverDestroyed()
end

do
    -- More than two physical buttons retain their named programming events.
    local r=fresh(fixtures.entity_id,'Programming Events Only'); r:start()
    local value=case('initial_snapshot')
    value.attributes.bridge_buttons=Codec:newArray()
    value.attributes.bridge_sources=Codec:newArray()
    local buttons={'relay','button_1','button_2','button_3','button_4'}
    for index,button in ipairs(buttons) do
        value.attributes.bridge_buttons[index]={id=button,label='Scene '..index,
            gestures=Codec:newArray({{id='press_2',kind='press',press_count=2,label='Double tap'}})}
        value.attributes.bridge_sources[index]={id='source_'..index,button_id=button,
            ready=true,availability='available'}
    end
    r:state(value)
    eq(#r.fired,0)
    for index,button in ipairs(buttons) do
        local event=clone(value)
        local timestamp=string.format('2026-11-14T20:00:%02d.000Z',index)
        event.state=timestamp; event.last_updated=timestamp
        local attrs=event.attributes
        attrs.bridge_update_kind='gesture'; attrs.event_type='press'
        attrs.button_id=button; attrs.gesture_id='press_2'; attrs.press_count=2
        attrs.gesture_session_id=attrs.bridge_session_id; attrs.gesture_sequence=index
        attrs.gesture_event_id=attrs.bridge_session_id..':'..index; attrs.gesture_occurred_at=timestamp
        r:state(event,true)
        eq(#r.fired,index)
        eq(r.events[r.fired[index]].name,'Scene '..index..' Double Tap')
        r:state(event,true)
        eq(#r.fired,index,'Duplicate occurrences cannot rerun scene-button programming')
    end
    eq(#r:services(),0,'Programming buttons do not operate a load')
    eq(#r:messages('BUTTON_ACTION',5001),0,'Extra buttons do not invent native paddle IDs')
    OnDriverDestroyed()
end

-- BUTTON_INFO can synchronously execute Composer programming that selects a
-- new source. Neither an old gesture nor an old LED plan may affect it.
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start(); r:state(led_state())
r.on_send=function(binding,command)
    if binding==5001 and command=='BUTTON_INFO' then
        r.on_send=nil
        r:property('Entity ID','event.replacement')
        local replacement=led_state(); replacement.entity_id='event.replacement'
        replacement.attributes.bridge_control_id='replacement-control'
        r:state(replacement)
    end
end
local live=led_state('first_double_press')
live.attributes.gesture_id='press_1'; live.attributes.press_count=1
live.attributes.bridge_leds[1].color='FF0000'
eq(r:state(live,true),false)
eq(#r:messages('DO_PUSH',203),0); eq(#r:messages('DO_CLICK',203),0)
eq(#r:services(),0,'LED notification programming cannot forward an old gesture into the replacement source')
OnDriverDestroyed()
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start(); r:state(led_state())
r.on_send=function(binding,command)
    if binding==5001 and command=='BUTTON_INFO' then
        r.on_send=nil
        r:property('Entity ID','event.replacement')
        local replacement=led_state(); replacement.entity_id='event.replacement'
        replacement.attributes.bridge_control_id='replacement-control'
        r:state(replacement)
    end
end
eq(ReceivedFromProxy(5001,'SET_BUTTON_COLOR',{Number='2',ON_COLOR='FF0000',CURRENT_COLOR='FF0000'}),false)
eq(#r:services(),0,'Reentrant notification cannot stamp the new entity onto an old LED write')
eq(r:last('BUTTON_INFO',5001).params.ON_COLOR,'FFFFFF')
eq(r:last('BUTTON_INFO',5001).params.CURRENT_COLOR,'000000')
OnDriverDestroyed()

-- A target can update its indicator while ramping. That metadata snapshot
-- must neither release the physical hold early nor replay its start.
r=fresh(fixtures.entity_id,'Control Connected C4 Light'); r:start(); r:state(led_state())
local held=led_state('hold_start'); eq(r:state(held,true),true)
eq(#r:messages('DO_PUSH',203),1); eq(#r:messages('DO_RELEASE',203),0)
local led_feedback=clone(held)
led_feedback.last_updated='2026-11-14T20:00:09.500Z'
led_feedback.attributes.bridge_update_kind='snapshot'
led_feedback.attributes.bridge_leds[1].color='FF0000'
r:state(led_feedback,true)
eq(#r:messages('DO_PUSH',203),1); eq(#r:messages('DO_RELEASE',203),0)
eq(#r:services(),0,'Indicator feedback cannot echo a service while dimming')
eq(r:state(led_state('reported_release'),true),true)
eq(#r:messages('DO_RELEASE',203),1)
OnDriverDestroyed()

do
    local r=fresh('switch.office','Control HA Device'); r:start()
    eq(Properties['Button Capabilities'],'Button events need HA Gesture Bridge')
    eq(Properties['LED Status'],'Not exposed/configured')
    r:state(state('switch.office','on',1,{press_count=5}))
    eq(Properties['Selected Capabilities'],'On/Off; Toggle')
    eq(Properties['Button Capabilities'],'Button events need HA Gesture Bridge')
    r:property('Entity ID','light.office'); r:state(state('light.office','on',2,DIM))
    eq(Properties['Selected Capabilities'],'On/Off; Toggle; Level; Timed ramp')
    eq(Properties['Button Capabilities'],'Button events need HA Gesture Bridge')
    r:property('Entity ID',fixtures.entity_id)
    r:property('Operation Mode','Control Connected C4 Light')
    eq(Properties['Selected Capabilities'],'No readable C4 light on Top Controller Link')
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    local profiles=case('initial_snapshot')
    profiles.attributes.bridge_buttons=Codec:newArray(); profiles.attributes.bridge_sources=Codec:newArray()
    for _,button in ipairs({'top','bottom'}) do
        local gestures=Codec:newArray()
        for count=1,5 do gestures[#gestures+1]={id='press_'..count,kind='press',press_count=count,label=count..' Press'} end
        for _,kind in ipairs({'hold_start','hold_repeat','release'}) do gestures[#gestures+1]={id=kind,kind=kind,label=kind} end
        profiles.attributes.bridge_buttons[#profiles.attributes.bridge_buttons+1]={id=button,label=button,gestures=gestures}
        profiles.attributes.bridge_sources[#profiles.attributes.bridge_sources+1]={id=button,button_id=button,ready=true,availability='unknown'}
    end
    r:state(profiles)
    eq(Properties['Button Capabilities'],'Top & Bottom: 1–5 taps, hold/repeat, release')
    eq(Properties['Selected Capabilities'],'No readable C4 light on Top Controller Link')
    eq(Properties['LED Status'],'Not exposed/configured')
    local changed=clone(profiles); changed.last_updated='2026-11-14T20:00:01Z'
    changed.attributes.bridge_buttons[2].gestures=Codec:newArray({changed.attributes.bridge_buttons[2].gestures[1]})
    changed.attributes.bridge_sources[2].ready=false; changed.attributes.bridge_sources[2].availability='unavailable'
    r:state(changed)
    eq(Properties['Button Capabilities'],'Top: 1–5 taps, hold/repeat, release; Bottom: single tap (unavailable)')
    r:property('Operation Mode','Programming Events Only'); r:state(changed)
    eq(Properties['Selected Capabilities'],'No load control')
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
    r:state(case('first_double_press'),true)
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    r:state(changed)
    check(Properties['Button Capabilities']:find('Bottom: single tap (unavailable)',1,true))
    r:property('Operation Mode','Control HA Device with Button Events')
    profiles.attributes.bridge_contract_version='1.1'
    profiles.attributes.bridge_load={entity_id='light.office',domain='light',state='on',available=true,attributes=clone(DIM)}
    r:state(profiles)
    eq(Properties['Selected Capabilities'],'On/Off; Toggle; Level; Timed ramp')
    eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=75}),true)
    local before=#r:services()
    local invalid=clone(profiles); invalid.last_updated='2026-11-14T20:00:02Z'; invalid.attributes.bridge_buttons=Codec:newArray()
    r:state(invalid)
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    eq(Properties['Selected Capabilities'],'Waiting for current HA load capabilities')
    eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=75}),false)
    eq(#r:services(),before,'Retired source cannot retain brightness command authority')
    r:property('Entity ID','event.replacement')
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    OnDriverDestroyed()
end

do
    local setup=fresh('light.office')
    eq(ExecuteCommand('ShowAdvancedProperties',{}),false); eq(next(setup.attributes),nil,'No property UI APIs before late init')
    setup.attributes['Debug Mode']=1 -- An installed earlier build hid this field.
    setup:start()
    setup:property('Debug Mode','Off'); setup:property('Latency Diagnostics','Off')
    eq(Properties['Selected Device'],'light.office')
    eq(setup.attributes['Entity ID'],1); eq(setup.attributes['Entity Selection'],1)
    eq(setup.attributes['Debug Mode'],0); eq(setup.attributes['Latency Diagnostics'],1)
    eq(setup.attributes['LED Feedback Source'],1); eq(setup.attributes['Selected Device'],nil)
    local before=#setup.sent
    eq(ExecuteCommand('LUA_ACTION',{ACTION='ShowAdvancedProperties'}),true)
    eq(setup.attributes['Entity ID'],0); eq(setup.attributes['LED Feedback Source'],0)
    eq(Properties['Entity ID'],'light.office')
    eq(ExecuteCommand('HideAdvancedProperties',{}),true)
    eq(setup.attributes['Debug Mode'],0,'Logging remains visible in compact mode')
    eq(setup.attributes['Entity ID'],1); eq(#setup.sent,before,'Visibility changes are presentation only')
    local attrs=clone(DIM); attrs.friendly_name='Office Lamp'; attrs.raw_payload='PRIVATE_DIAGNOSTIC_PAYLOAD'
    setup:state(state('light.office','off',1,attrs))
    eq(Properties['Selected Device'],'Office Lamp'); eq(Properties['Status'],'Off')
    setup:discovery({{entity_id='light.office',domain='light',name='Catalog Office Lamp',state='off',
        availability='available',attributes=DIM}})
    eq(Properties['Selected Device'],'Catalog Office Lamp')
    local output,original={},print
    print=function(line) output[#output+1]=tostring(line) end
    local total=#setup.sent
    local ok,result=pcall(ExecuteCommand,'LUA_ACTION',{ACTION='PrintDiagnostics'})
    print=original
    check(ok); eq(result,true); eq(#setup.sent,total,'Diagnostics must not send native, HA or discovery commands')
    local text=table.concat(output,'\n')
    check(text:find('HA Light | Diagnostics | driver version=1',1,true))
    check(text:find('Entity ID=light.office',1,true)); check(text:find('Confirmed entity state=off',1,true))
    check(text:find('Detailed Status=Control HA Device: off',1,true))
    check(text:find('Debug Mode=Off',1,true)); check(text:find('Latency Diagnostics=Off',1,true))
    check(not text:find('PRIVATE_DIAGNOSTIC_PAYLOAD',1,true))
    setup:property('Entity ID','event.replacement')
    eq(Properties['Selected Device'],'event.replacement')
    ExecuteCommand('ShowAdvancedProperties',{}); OnDriverDestroyed()
    setup=fresh(); setup:start(); eq(setup.attributes['Entity ID'],1,'Reload returns to the compact layout')
    OnDriverDestroyed()
    setup=fresh(fixtures.entity_id,'Gestures Only'); setup:start()
    setup:state(case('initial_snapshot')); eq(Properties['Status'],'Ready')
    setup:state(case('first_double_press'),true); eq(Properties['Status'],'Ready')
    OnDriverDestroyed()
end

-- LED behavior is an explicit setting; color and preference changes never
-- silently select a hardware mode, including after reload/reconnect.
do
    local setup=fresh(fixtures.entity_id,'Programming Events Only'); setup:start()
    eq(Properties['LED Behavior'],'Use Device Setting')
    eq(setup.attributes['LED Behavior'],0,'LED Behavior stays on the main Properties screen')
    local value=led_state(); setup:state(value)
    eq(setup.lists['LED Behavior'].values,'Use Device Setting,Follow Load,Follow Load (Inverted),Always On,Always Off')
    eq(#setup:services(),0,'Rendering available behaviors cannot apply one')
    eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='FF0000'}),true)
    local current=setup:services()[#setup:services()].service_data
    eq(current.color,'FF0000'); eq(current.behavior,nil,'Color-only requests must preserve parameter 2')
    setup:property('LED Behavior','Always On')
    local behavior=setup:services()[#setup:services()].service_data
    eq(behavior.behavior,'always_on'); eq(behavior.color,nil); eq(behavior.brightness,nil)
    local total=#setup:services()
    setup:property('LED Behavior','Use Device Setting')
    eq(#setup:services(),total,'Use Device Setting stops management without restoring/changing hardware')
    eq(ExecuteCommand('Set LED On Color',{Button='Toggle',Color='0000FF'}),true)
    eq(#setup:services(),total,'Color preferences never change the LED mode')
    eq(ExecuteCommand('Set LED Behavior',{Button='Toggle',Behavior='Always Off'}),true)
    behavior=setup:services()[#setup:services()].service_data
    eq(behavior.behavior,'always_off'); eq(behavior.color,nil)
    local options=GetCommandParamList('Set LED Behavior','Behavior')
    eq(#options,4); eq(#GetCommandParamList('Set LED Behavior','Button'),1)
    total=#setup:services()
    value.last_updated='2026-11-14T20:00:01.000Z'
    value.attributes.bridge_leds[1].behavior='follow_load_inverted'
    setup:state(value)
    check(Properties['LED Status']:find('local load off',1,true))
    eq(#setup:services(),total,'Confirmed behavior snapshots cannot reapply a saved policy')
    value.last_updated='2026-11-14T20:00:02.000Z'
    value.attributes.bridge_leds[1].behaviors=Codec:newArray({'always_on','always_off'})
    value.attributes.bridge_leds[1].behavior='always_off'
    value.attributes.bridge_leds[1].color_supported=false
    value.attributes.bridge_leds[1].colors=Codec:newArray({'000000','FFFFFF'})
    setup:state(value)
    eq(setup.lists['LED Behavior'].values,'Use Device Setting,Always On,Always Off')
    eq(#GetCommandParamList('Set LED Current Color','Button'),0,'A fixed-color LED cannot expose a color-only action')
    eq(#GetCommandParamList('Set LED On Color','Button'),1,'Logical on/off colors remain configurable')
    setup:property('LED Behavior','Follow Load')
    eq(#setup:services(),total,'Unsupported local-load tracking cannot write a setting')
    value.last_updated='2026-11-14T20:00:03.000Z'
    value.attributes.bridge_led_command_version=nil
    setup:state(value)
    eq(#GetCommandParamList('Set LED Behavior','Behavior'),0,'Old HA command semantics never grant mode authority')
    eq(ExecuteCommand('Set LED Behavior',{Button='Toggle',Behavior='Always On'}),false)
    eq(#setup:services(),total)
    OnDriverDestroyed()
end

-- Following a bound light is an explicit policy, separate from the LED
-- color. Its source is visible only when needed on the compact screen.
do
    local setup=fresh(fixtures.entity_id,'Control Connected C4 Light'); setup:start()
    setup:state(led_state())
    eq(setup.attributes['LED Feedback Source'],1)
    check(setup.lists['LED Behavior'].values:find('Follow Bound Device',1,true))
    setup:property('LED Behavior','Follow Bound Device')
    eq(Properties['LED Feedback Source'],'Top')
    eq(setup.attributes['LED Feedback Source'],0)
    eq(#setup:messages('REQUEST_BUTTON_COLORS',203),1)
    eq(#setup:services(),0,'Choosing a bound source requests feedback, not an assumed LED state')
    eq(ReceivedFromProxy(204,'MATCH_LED_STATE',{STATE=true}),false)
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),true)
    local data=setup:services()[1].service_data
    eq(data.behavior,'always_on'); eq(data.color,'FFFFFF')
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=false}),true)
    data=setup:services()[2].service_data
    eq(data.behavior,'always_off'); eq(data.color,'000000')
    eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='0000FF'}),true)
    data=setup:services()[3].service_data
    eq(data.color,'0000FF'); eq(data.behavior,nil,'Even while following, an explicit color-only command leaves the mode alone')
    setup:property('LED Behavior','Follow Load')
    data=setup:services()[4].service_data
    eq(data.behavior,'follow_load'); eq(data.color,nil)
    eq(setup.attributes['LED Feedback Source'],1)
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),false)
    eq(#setup:services(),4,'Local-load mode cannot be overwritten by a connected-light message')
    ExecuteCommand('ShowAdvancedProperties',{})
    eq(setup.attributes['LED Feedback Source'],0)
    ExecuteCommand('HideAdvancedProperties',{})
    eq(setup.attributes['LED Feedback Source'],1)
    setup:property('LED Behavior','Follow Bound Device')
    local count=#setup:services()
    local requests=#setup:messages('REQUEST_BUTTON_COLORS',203)
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),false)
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
    local value=led_state(); value.last_updated='2026-11-14T20:00:02.000Z'; setup:state(value)
    eq(#setup:services(),count,'Recovery snapshots cannot apply the saved LED policy')
    eq(#setup:messages('REQUEST_BUTTON_COLORS',203),requests,'Recovery does not request automatic target feedback')
    setup:property('LED Behavior','Use Device Setting')
    eq(setup.attributes['LED Feedback Source'],1)
    eq(#setup:services(),count)
    OnDriverDestroyed()
end

do
    local setup=fresh(fixtures.entity_id,'Programming Events Only')
    setup:property('LED Behavior','Always On') -- A saved property is loaded before late init.
    setup:start(); setup:state(led_state())
    eq(Properties['LED Behavior'],'Always On')
    eq(#setup:services(),0,'A saved Always On policy is never written during driver initialization')
    OnDriverDestroyed()
end

-- Programming choices are the union across available channels, while the
-- global property can offer only behavior supported by every indicator.
do
    local setup=fresh(fixtures.entity_id,'Programming Events Only'); setup:start()
    local value=led_state()
    value.attributes.bridge_leds=Codec:newArray({
        {id='color_only',label='Color indicator',button_id='top',available=true,
            colors=Codec:newArray({'FFFFFF','FF0000'}),brightness_supported=false,
            color_supported=true,behaviors=Codec:newArray()},
        {id='power_only',label='Power indicator',button_id='bottom',available=true,
            colors=Codec:newArray({'000000','FFFFFF'}),brightness_supported=false,
            color_supported=false,behaviors=Codec:newArray({'always_on','always_off'})}})
    setup:state(value)
    eq(setup.lists['LED Behavior'].values,'Use Device Setting')
    local choices=GetCommandParamList('Set LED Behavior','Behavior')
    eq(#choices,2); eq(choices[1],'Always On'); eq(choices[2],'Always Off')
    eq(ExecuteCommand('Set LED Behavior',{Button='Bottom',Behavior='Always On'}),true)
    eq(setup:services()[1].service_data.led_id,'power_only')
    eq(setup:services()[1].service_data.behavior,'always_on')
    eq(ExecuteCommand('Set LED Behavior',{Button='Top',Behavior='Always On'}),false)
    eq(#setup:services(),1,'An offered behavior must still be supported by the selected channel')
    OnDriverDestroyed()
end

-- A retained bound-device policy is inert when the selected metadata cannot
-- support that policy across every indicator. Quiet snapshots never apply it.
do
    local setup=fresh(fixtures.entity_id,'Control Connected C4 Light')
    setup:property('LED Behavior','Follow Bound Device')
    setup:property('LED Feedback Source','Top')
    setup:start()
    local value=led_state()
    value.attributes.bridge_leds=Codec:newArray({
        {id='color_only',label='Color indicator',button_id='top',available=true,
            colors=Codec:newArray({'FFFFFF','FF0000'}),brightness_supported=false,
            color_supported=true,behaviors=Codec:newArray()},
        {id='power_only',label='Power indicator',button_id='bottom',available=true,
            colors=Codec:newArray({'000000','FFFFFF'}),brightness_supported=false,
            color_supported=false,behaviors=Codec:newArray({'always_on','always_off'})}})
    setup:state(value)
    eq(Properties['LED Behavior'],'Follow Bound Device','A saved policy remains visible while unsupported')
    eq(#setup:services(),0)
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),false)
    eq(#setup:services(),0,'A partial policy cannot operate the compatible subset of indicators')
    eq(ExecuteCommand('RefreshLEDFeedback',{}),false)
    eq(#setup:messages('REQUEST_BUTTON_COLORS',203),0,'An unsupported global policy cannot request target feedback')
    local supported=led_state(); supported.last_updated='2026-11-14T20:00:02.000Z'
    setup:state(supported)
    eq(#setup:services(),0,'Restored capabilities do not apply a behavior during snapshot processing')
    eq(#setup:messages('REQUEST_BUTTON_COLORS',203),0)
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=true}),true)
    eq(#setup:services(),1,'Future live feedback can resume the explicitly saved supported policy')
    eq(setup:services()[1].service_data.behavior,'always_on')
    OnDriverDestroyed()
end

do
    -- Property pickers use the same per-channel preferences as programming.
    -- Loading XML defaults, rendering, or editing them never changes hardware.
    local value=led_state()
    local store={LEDColors={[value.attributes.bridge_control_id]={indicator={ON_COLOR='0000FF',OFF_COLOR='FF0000'}}}}
    local setup=fresh(fixtures.entity_id,'Control Connected C4 Light',store)
    setup:property('LED On Color','255,255,255') -- loaded before late init
    setup:start()
    eq(setup.attributes['LED On Color'],1,'Hide pickers until current LED metadata is ready')
    setup:state(value)
    eq(Properties['LED On Color'],'0,0,255','Saved preference survives XML defaults')
    eq(Properties['LED Off Color'],'255,0,0')
    eq(setup.attributes['LED On Color'],0); eq(setup.attributes['LED Off Color'],0)
    eq(setup.attributes['LED Indicator'],1,'A single physical indicator needs no extra selector')
    setup:property('LED On Color',' 3, 250, 2 ')
    eq(Properties['LED On Color'],'0,255,0','Show the actual supported palette color')
    eq(store.LEDColors[value.attributes.bridge_control_id].indicator.ON_COLOR,'00FF00')
    setup:property('LED Off Color','0,0,0')
    eq(store.LEDColors[value.attributes.bridge_control_id].indicator.OFF_COLOR,'000000')
    setup:property('LED On Color','256,0,0')
    eq(Properties['LED On Color'],'0,255,0','Reject invalid RGB and restore the saved color')
    eq(ExecuteCommand('Set LED On Color',{Button='Toggle',Color='FF0000'}),true)
    eq(Properties['LED On Color'],'255,0,0','Programming edits update the property picker too')
    ExecuteCommand('ShowAdvancedProperties',{}); ExecuteCommand('HideAdvancedProperties',{})
    eq(setup.attributes['LED On Color'],0,'Color pickers stay on the main screen')
    eq(#setup:services(),0,'Color preferences never issue a mode, color or relay request')
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
    eq(setup.attributes['LED On Color'],1)
    setup:property('LED On Color','0,0,255')
    eq(store.LEDColors[value.attributes.bridge_control_id].indicator.ON_COLOR,'FF0000','Disconnected edits cannot change preferences')
    OnDriverDestroyed()
end

do
    local setup=fresh(fixtures.entity_id,'Programming Events Only'); setup:start()
    local value=led_state()
    local first=value.attributes.bridge_leds[1]
    first.id='first'; first.button_id='button_1'; first.label='First, indicator'
    local second=clone(first); second.id='second'; second.button_id='button_2'; second.label='Second indicator'
    value.attributes.bridge_leds=Codec:newArray({first,second})
    setup:state(value)
    eq(setup.attributes['LED Indicator'],0)
    setup:property('LED On Color','255,0,0')
    setup:property('LED Indicator','Second indicator [second]')
    eq(Properties['LED On Color'],'255,255,255','Each indicator has independent preferences')
    setup:property('LED Off Color','0,0,255')
    setup:property('LED Indicator','First  indicator [first]')
    eq(Properties['LED On Color'],'255,0,0')
    eq(Properties['LED Off Color'],'0,0,0')
    value.last_updated='2026-11-14T20:00:02.000Z'; first.label='Renamed indicator'
    setup:state(value)
    eq(Properties['LED Indicator'],'Renamed indicator [first]','Selection survives label changes')
    eq(Properties['LED On Color'],'255,0,0')
    setup:property('LED Indicator','Second indicator [second]')
    eq(Properties['LED Off Color'],'0,0,255')
    eq(#setup:services(),0,'Selecting or configuring several indicators cannot write hardware')
    OnDriverDestroyed()
end

do
    -- Exercise Director's wire BOOL forms, not only in-process Lua booleans.
    local setup=fresh(fixtures.entity_id,'Control Connected C4 Light'); setup:start()
    setup:state(led_state())
    setup:property('LED Behavior','Follow Bound Device')
    setup:property('LED On Color','255,0,0')
    setup:property('LED Off Color','0,255,0')
    for _,entry in ipairs({{true,true},{false,false},{1,true},{0,false},
        {'1',true},{'0',false},{'true',true},{'false',false},{'True',true},{'False',false},
        {'TRUE',true},{'FALSE',false},{' 1 ',true},{' 0 ',false}}) do
        local before=#setup:services()
        eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=entry[1]}),true)
        eq(#setup:services(),before+1)
        local data=setup:services()[before+1].service_data
        eq(data.color,entry[2] and 'FF0000' or '00FF00','Both states must use the saved property colors')
        eq(data.behavior,'always_on','Nonblack On and Off colors both keep the indicator lit')
    end
    local before=#setup:services()
    for _,bad in ipairs({'unknown','on','off','',2,-1,0.5,{}}) do
        eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{STATE=bad}),false)
    end
    eq(ReceivedFromProxy(203,'MATCH_LED_STATE',{}),false)
    eq(ReceivedFromProxy(204,'MATCH_LED_STATE',{STATE='1'}),false,'Unselected feedback source is ignored')
    eq(#setup:services(),before,'Invalid or wrong-source feedback must never turn an LED off')
    OnDriverDestroyed()
end

-- Most-capable device selection is independent of mode. A bridge's explicit
-- HA catalog replaces its relay, without claiming the relay load.
do
    local initial=case('initial_snapshot')
    initial.attributes.bridge_load=nil; initial.attributes.bridge_source_device_id='bath-device'
    local toilet=clone(initial); toilet.entity_id='event.toilet_gestures'
    toilet.attributes.bridge_control_id='toilet-control'; toilet.attributes.bridge_source_device_id='toilet-device'
    for _,initial_mode in ipairs({'Direct','Gestures Only','C4 Button Controller'}) do
        local setup=fresh('switch.bath',initial_mode); setup:start()
        setup:discovery({
            {entity_id=initial.entity_id,domain='event',name='Primary Bath Switch Gestures',state='unknown',
                availability='unknown',attributes=initial.attributes},
            {entity_id=toilet.entity_id,domain='event',name='Primary Toilet Switch Gestures',state='unknown',
                availability='unknown',attributes=toilet.attributes},
            {entity_id='switch.bath',domain='switch',name='Primary Bath',state='off',availability='available',
                attributes=Codec:newObject(),registry={platform='zwave_js',device_id='bath-device'}},
            {entity_id='switch.toilet',domain='switch',name='Primary Toilet',state='off',availability='available',
                attributes=Codec:newObject(),registry={platform='zwave_js',device_id='toilet-device'}},
            {entity_id='switch.plain',domain='switch',name='Plain Switch',state='off',
                availability='available',attributes=Codec:newObject()},
        })
        eq(#BrowseHALightDevices(nil,nil,'','all'),5,'Without the optional catalog native choices still work')
        local records=Codec:newArray({
            {entity_id=initial.entity_id,domain='event',friendly_name='Primary Bath (gestures)',
                entity_aliases=Codec:newArray({'switch.bath'}),source_entity_id='switch.bath'},
            {entity_id=toilet.entity_id,domain='event',friendly_name='Primary Toilet (gestures)',
                entity_aliases=Codec:newArray({'switch.toilet'}),source_entity_id='switch.toilet'},
            {entity_id='switch.plain',domain='switch',friendly_name='Plain Switch'},
        })
        local sensor={entity_id='sensor.ha_gesture_bridge_catalog',domain='sensor',name='Catalog',state='3',availability='available',
            attributes={catalog_contract_version='1.0',catalog_names_version=1,catalog_names_revision=string.rep('a',64),
                catalog_names_total=3,catalog_names_pages=1,catalog_names_page_001=records}}
        setup:discovery({sensor}); setup:discovery({sensor})
        eq(#BrowseHALightDevices(nil,nil,'','all'),3)
        eq(#BrowseHALightDevices(nil,nil,'Toilet','all'),1)
        eq(BrowseHALightDevices(nil,nil,'Toilet','all')[1].value,toilet.entity_id)
        eq(#BrowseHALightDevices(nil,nil,'','switch'),3,'Gesture devices remain searchable as their physical switch type')
        check(not setup.list.values:find('[switch.bath]',1,true),'Fallback selector also shows the most capable representation')
        eq(Properties['Entity ID'],'switch.bath','Discovery cannot rewrite an installed target')
        setup.bound[203]=901 -- Selection sees the connection even before a binding callback.
        setup:property('Operation Mode','Control HA Device')
        eq(ExecuteCommand('SelectDevice',{Device='switch.toilet'}),true,'Even a stale relay alias resolves to its gesture control')
        eq(Properties['Entity ID'],toilet.entity_id)
        eq(Properties['Operation Mode'],'Control Connected C4 Light','Choosing a gesture-enabled device sets mode from bindings')
        eq(PersistData.ControllerModeOverride,nil,'A new device selection establishes a new default')
        eq(#setup:services(),0)
        setup:property('Operation Mode','Programming Events Only')
        eq(Properties['Operation Mode'],'Programming Events Only','Manual mode remains available after selecting a device')
        OnDriverDestroyed()
    end
end

-- An external Controller Link establishes the default routing mode. It never
-- guesses a gesture source, replays history, or overrides an installer choice.
do
    for _,binding in ipairs({203,204,205}) do
        local setup=fresh('switch.office','Direct',nil,{[binding]=901})
        setup:start()
        eq(Properties['Operation Mode'],'Control Connected C4 Light','Existing links select controller mode at startup')
        eq(Properties['Entity ID'],'switch.office','Binding cannot guess a physical gesture source')
        eq(ReceivedFromProxy(5001,'ON',{}),false,'Controller setup must not command the HA relay')
        eq(#setup:services(),0); eq(#setup:messages('DO_CLICK'),0)
        local initial=case('initial_snapshot')
        setup:discovery({{entity_id=initial.entity_id,domain='event',name='Office Gestures',state='unknown',
            availability='unknown',attributes=initial.attributes}})
        eq(ExecuteCommand('SelectDevice',{Device=initial.entity_id}),true)
        eq(Properties['Operation Mode'],'Control Connected C4 Light')
        setup:state(initial)
        eq(#setup:messages('DO_CLICK'),0,'Snapshot cannot fire a connected light')
        setup:property('Operation Mode','Programming Events Only')
        eq(PersistData.ControllerModeOverride,true)
        local saved=PersistData
        OnDriverDestroyed()
        setup=fresh(initial.entity_id,'Programming Events Only',saved,{[binding]=901}); setup:start()
        eq(Properties['Operation Mode'],'Programming Events Only','Manual choice survives reload with existing links')
        OnBindingChanged(binding,'BUTTON_LINK',true)
        eq(Properties['Operation Mode'],'Programming Events Only','Binding callback preserves manual override')
        setup:property('Operation Mode','Control Connected C4 Light')
        eq(PersistData.ControllerModeOverride,nil,'Choosing controller mode returns to its automatic default')
        OnDriverDestroyed()
    end
    local setup=fresh('switch.office'); setup:start()
    setup.bound[200]=901; OnBindingChanged(200,'BUTTON_LINK',true)
    eq(Properties['Operation Mode'],'Control HA Device','Legacy provider links do not enable outgoing control')
    setup.bound[205]=321; OnBindingChanged(205,'BUTTON_LINK',true)
    eq(Properties['Operation Mode'],'Control HA Device','Self-connection is not an external light')
    setup.bound[203]=901; OnBindingChanged(203,'BUTTON_LINK',true)
    eq(Properties['Operation Mode'],'Control Connected C4 Light','New external link selects controller mode')
    setup.bound[203]=nil; OnBindingChanged(203,'BUTTON_LINK',false)
    eq(Properties['Operation Mode'],'Control Connected C4 Light','Disconnect cannot silently resume HA load control')
    eq(#setup:services(),0); OnDriverDestroyed()
    setup=fresh('switch.office','Direct',nil,{[205]=321}); setup:start()
    eq(Properties['Operation Mode'],'Control HA Device','Startup also ignores a self-connection')
    OnDriverDestroyed()
end

-- A lost selected snapshot retries just that entity and eventually recovers,
-- without discovery or replaying historical gestures.
for _,setup in ipairs({'startup','rebind','source change'}) do
    local recovery=fresh(fixtures.entity_id,'Programming Events Only'); recovery:start()
    if setup=='rebind' then
        OnBindingChanged(999,'HA_DEVICE',false); OnBindingChanged(999,'HA_DEVICE',true)
    elseif setup=='source change' then
        recovery:property('Entity ID','event.changed')
    end
    local before=#recovery:messages('HA_GET_STATE',999)
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED=true})
    for _=1,10 do recovery.now=recovery.now+5000; recovery.timers[1].callback() end
    eq(#recovery:messages('HA_GET_STATE',999),before+4,setup..' retries are bounded to five total attempts')
    eq(#recovery:messages('HA_GET_ENTITIES',999),0,setup..' never rebuilds discovery')
    check(Properties.Status:find('Unable to load selected entity snapshot',1,true))
    OnDriverDestroyed()
end

-- Subscription acknowledgment and state can arrive in either order. A good
-- snapshot must not make a rejected/missing live subscription look ready.
do
    local recovery=fresh(fixtures.entity_id,'Programming Events Only'); recovery:start()
    local request=recovery:last('HA_GET_STATE',999).params
    eq(request.consumer_id,'321'); eq(Codec:decode(request.active_entities)[1],fixtures.entity_id)
    eq(ReceivedFromProxy(999,'HA_SUBSCRIPTION_STATUS',{ENTITY=fixtures.entity_id,STATUS='pending'}),true)
    recovery:state(case('initial_snapshot'))
    check(Properties.Status:find('subscription acknowledgment',1,true))
    eq(recovery:state(case('first_double_press'),true),false)
    eq(#recovery.fired,0)
    eq(ReceivedFromProxy(999,'HA_SUBSCRIPTION_STATUS',{ENTITY=fixtures.entity_id,STATUS='error',ERROR='denied'}),true)
    recovery:state(case('initial_snapshot'))
    check(Properties.Status:find('subscription failed: denied',1,true))
    for _=1,5 do
        recovery.now=recovery.now+5000; recovery.timers[1].callback()
        check(Properties.Status:find('subscription failed: denied',1,true),'Retries retain the subscription failure explanation')
        recovery:state(case('initial_snapshot'))
    end
    local before=#recovery:messages('HA_GET_STATE',999)
    recovery.now=recovery.now+5000; recovery.timers[1].callback()
    eq(#recovery:messages('HA_GET_STATE',999),before,'Subscription failures keep selected-state retries bounded')
    check(Properties.Status:find('subscription failed: denied',1,true),'Exhaustion cannot misreport a good snapshot as missing')
    eq(ReceivedFromProxy(999,'HA_SUBSCRIPTION_STATUS',{ENTITY=fixtures.entity_id,STATUS='ready'}),true)
    eq(Properties.Status,'Ready'); eq(#recovery.fired,0,'ACK cannot replay a stored gesture')
    eq(recovery:state(case('first_double_press'),true),true); eq(Properties['Gesture Count'],'1')
    OnDriverDestroyed()
    eq(recovery:last('HA_RELEASE_STATES',999).params.consumer_id,'321')
end

do
    local recovery=fresh(fixtures.entity_id,'Control Connected C4 Light'); recovery:start()
    recovery:state(case('initial_snapshot'))
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
    check(Properties.Status:find('Waiting for selected entity snapshot',1,true))
    local before=#recovery:messages('HA_GET_STATE',999)
    local function tick(seconds) recovery.now=recovery.now+seconds*1000; recovery.timers[1].callback() end
    tick(4); eq(#recovery:messages('HA_GET_STATE',999),before)
    tick(1); eq(#recovery:messages('HA_GET_STATE',999),before+1)
    eq(recovery:last('HA_GET_STATE',999).params.entity,fixtures.entity_id)
    eq(#recovery:messages('HA_GET_ENTITIES',999),0,'Recovery never rebuilds a device list')
    eq(recovery:state(case('initial_snapshot')),false)
    tick(10); eq(#recovery:messages('HA_GET_STATE',999),before+1,'A fresh snapshot cancels retries')
    eq(Properties['Gesture Count'],'0')
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
    for _=1,5 do tick(5) end
    check(Properties.Status:find('Unable to load selected entity snapshot',1,true))
    before=#recovery:messages('HA_GET_STATE',999)
    tick(100); eq(#recovery:messages('HA_GET_STATE',999),before,'Failed selected reads have bounded retries')
    OnDriverDestroyed()
end

-- A connected native C4 light (not a group) supplies app control and feedback.
do
    local app=fresh('event.paddle','Control Connected C4 Light',nil,{[203]=900,[204]=902})
    local values={
        [901]={[1000]='1',[1001]='35',[1002]='200',[1003]='300',[1006]='50',
            [6661]='<DynamicCapabilities><dimmer>True</dimmer></DynamicCapabilities>'},
        [902]={[1000]='0',[6661]='<DynamicCapabilities><dimmer>False</dimmer></DynamicCapabilities>'}}
    local listeners,commands={},{ }
    function C4:GetProxyDevices() return 322 end
    function C4:GetProxyDevicesById(provider) if provider==900 then return 901 elseif provider==902 then return 902 end end
    function C4:GetVariable(device,variable) return values[device] and values[device][variable] end
    function C4:GetDeviceDisplayName(device) return device==901 and 'Native Dimmer' or 'Native Switch' end
    function C4:RegisterVariableListener(device,variable)
        listeners[device..':'..variable]=true
        OnWatchedVariableChanged(device,variable,self:GetVariable(device,variable))
    end
    function C4:UnregisterVariableListener(device,variable) listeners[device..':'..variable]=nil end
    function C4:SendToDevice(device,command,params) commands[#commands+1]={device=device,command=command,params=params} end
    app:start()
    eq(Properties['Connected Light'],'Native Dimmer')
    eq(app:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,true)
    eq(app:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.hide_proxy_conditionals_loops,false)
    eq(app:last('ONLINE_CHANGED',5001).params.STATE,true)
    eq(app:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,35)
    eq(app:last('PRESET_LEVEL',5001).params,'50','App On inherits the target preset, including Nightlight')
    for _,entry in ipairs({{'ON',{},'ON'},{'OFF',{},'OFF'},{'TOGGLE',{},'TOGGLE'},
        {'SET_LEVEL',{LEVEL='42'},'SET_LEVEL'},
        {'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET='65'},'SET_LEVEL'},
        {'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET='100',LIGHT_BRIGHTNESS_TARGET_PRESET_ID=1,RATE=750},'ON'},
        {'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET='35',LIGHT_BRIGHTNESS_TARGET_PRESET_ID=10,RATE=750},'ON'},
        {'RAMP_TO_LEVEL',{LEVEL='25',TIME='1200'},'RAMP_TO_LEVEL'}}) do
        eq(ReceivedFromProxy(5001,entry[1],entry[2]),true)
        eq(commands[#commands].device,901); eq(commands[#commands].command,entry[3])
    end
    eq(commands[#commands].params.LEVEL,25); eq(commands[#commands].params.TIME,1200)
    eq(#app:services(),0,'App control of C4 never commands an HA load')
    eq(app:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,35,'Wait for real target state')
    values[901][1001]='42'; OnWatchedVariableChanged(901,1001,'42')
    eq(app:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,42)
    values[901][1006]='30'; OnWatchedVariableChanged(901,1006,'30')
    eq(app:last('PRESET_LEVEL',5001).params,'30','A changed target night preset updates the app')
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED=false})
    eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=20}),true,'Local C4 app control survives HA loss')
    app:property('App Control Link','Bottom')
    eq(Properties['Connected Light'],'Native Switch')
    eq(next(listeners)~=nil,true); eq(listeners['901:1001'],nil,'Old target listener removed')
    eq(OnWatchedVariableChanged(901,1001,'99'),false,'Old feedback cannot change the selected target')
    eq(app:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,false)
    eq(app:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,0)
    eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=100}),true)
    eq(commands[#commands].device,902); eq(commands[#commands].command,'ON')
    eq(next(commands[#commands].params),nil,'Binary C4 target gets no brightness')
    values[902][1000]='1'; OnWatchedVariableChanged(902,1000,'1')
    eq(app:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,100)
    values[902][1001]='60'
    values[902][6661]='<DynamicCapabilities><dimmer>True</dimmer></DynamicCapabilities>'
    OnWatchedVariableChanged(902,6661,values[902][6661])
    eq(listeners['902:1001'],true,'New brightness variable is subscribed after capabilities change')
    eq(app:last('DYNAMIC_CAPABILITIES_CHANGED',5001).params.set_level,true)
    eq(app:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,60)
    local before=#commands
    app.bound[204]=nil; OnBindingChanged(204,'BUTTON_LINK',false)
    eq(ReceivedFromProxy(5001,'ON',{}),false,'Detached target cannot be commanded')
    eq(#commands,before); eq(next(listeners),nil)
    app:property('Operation Mode','Control HA Device')
    eq(app.attributes['App Control Link'],1)
    OnDriverDestroyed(); eq(next(listeners),nil)
end

-- Navigator binary lighting commands arrive as level targets, not only ON/OFF.
for _,entity in ipairs({'switch.front_porch','input_boolean.fixture','light.binary'}) do
    local binary=fresh(entity); binary:start()
    local attrs=entity:match('^light%.') and {supported_color_modes={'onoff'}} or {}
    binary:state(state(entity,'on',1,attrs))
    for _,entry in ipairs({
        {'SET_LEVEL',{LEVEL='0'},'turn_off'},
        {'SET_LEVEL',{LEVEL='100'},'turn_on'},
        {'SET_LEVEL',{LEVEL=35},'turn_on'},
        {'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET='0'},'turn_off'},
        {'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET='100',RATE='0'},'turn_on'},
        {'RAMP_TO_LEVEL',{LEVEL=0,RATE=0},'turn_off'},
    }) do
        local before=#binary:services()
        eq(ReceivedFromProxy(5001,entry[1],entry[2]),true)
        eq(#binary:services(),before+1)
        local request=binary:services()[before+1]
        eq(request.domain,entity:match('^([^%.]+)'))
        eq(request.target.entity_id,entity); eq(request.service,entry[3])
        eq(next(request.service_data),nil,'Binary targets never send brightness/transition')
    end
    eq(binary:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,100,
        'Commands do not fabricate state feedback')
    local before=#binary:services()
    eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=101}),false)
    eq(ReceivedFromProxy(5001,'RAMP_TO_LEVEL',{LEVEL=0,RATE=1000}),false)
    eq(#binary:services(),before,'Unsupported transitions and invalid levels send nothing')
    binary:state(state(entity,'off',2,attrs))
    eq(binary:last('LIGHT_BRIGHTNESS_CHANGED',5001).params.LIGHT_BRIGHTNESS_CURRENT,0)
    binary:state(state(entity,'unavailable',3,attrs))
    eq(ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL=100}),false)
    eq(#binary:services(),before,'Unavailable targets cannot be commanded')
    OnDriverDestroyed()
end

print('Native Dimmer actual entrypoint: '..assertions..' assertions passed')
