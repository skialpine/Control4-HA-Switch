-- Actual production commands.lua through the pinned base's dispatch/lifecycle.
local Discovery=require('module.discovery')
local Codec=Discovery.new_codec()
local file=assert(io.open('tests/fixtures/gestures/v1.json','r'))
local Fixture=Codec:decode(file:read('*a')); file:close()
local assertions=0
local function check(v,m) assertions=assertions+1; assert(v,m or ('assertion '..assertions)) end
local function eq(a,b,m) check(a==b,(m or '')..' expected '..tostring(b)..', got '..tostring(a)) end
local function clone(value) return Codec:decode(Codec:encode(value)) end
local function fresh(id,mode,store)
    local r={sent={},lists={},list_updates=0,events={},fired={},timers={},attributes={},now=100000,late=false}
    Properties={['Entity ID']=id or 'switch.manual',['Operation Mode']=require('module.operation_mode').label(mode or 'Direct'),
        ['Entity Selection']='Manual Entity ID',
        ['Discovery Status']='',['Selected Capabilities']='',['Status']='',
        ['Driver Version']='',['Debug Mode']='Off',['Gesture Count']='0',['Last Gesture']='',['Last Sequence']='0'}
    PersistData=store
    C4={}
    function C4:GetDeviceID() return 42 end
    function C4:GetTime() return r.now end
    function C4:GetDriverConfigInfo() return '107' end
    function C4:AddVariable() end
    function C4:SetVariable(name,value) r[name]=value end
    function C4:UpdateProperty(name,value) Properties[name]=value end
    function C4:SetPropertyAttribs(name,value) r.attributes[name]=value end
    function C4:UpdatePropertyList(name,values,selected)
        check(r.late,'Property list updated before late init')
        if name=='Entity Selection' then r.list_updates=r.list_updates+1 end
        r.lists[name]={values=values,selected=selected}; Properties[name]=selected
    end
    function C4:SendToProxy(binding,command,params,kind) r.sent[#r.sent+1]={binding=binding,command=command,params=params,kind=kind} end
    function C4:SetTimer(ms,callback,repeating)
        local timer={callback=callback}; function timer:Cancel() self.cancelled=true end
        r.timers[#r.timers+1]=timer; return timer
    end
    function C4:AddEvent(id,name,description,order)
        check(r.late,'Event registered before late init')
        r.events[id]={name=name,description=description,order=order}; return true
    end
    function C4:FireEventByID(id)
        r.fired[#r.fired+1]=id
        if r.on_fire then r.on_fire(id) end
    end
    function C4:ParseXml() return {ChildNodes={}} end
    package.loaded.commands=nil
    dofile('Control4-HA-Base/driver.lua')
    OnDriverInit()
    function r:late_init() self.late=true; OnDriverLateInit() end
    function r:property(name,value) Properties[name]=value; OnPropertyChanged(name) end
    function r:services()
        local out={}; for _,entry in ipairs(self.sent) do
            if entry.command=='HA_CALL_SERVICE' then out[#out+1]=Codec:decode(entry.params.JSON) end
        end; return out
    end
    function r:button_outputs()
        local result={}
        for _,entry in ipairs(self.sent) do
            if entry.binding==200 or entry.binding==201 or entry.binding==202 then result[#result+1]=entry end
        end
        return result
    end
    function r:last_service() local list=self:services(); return list[#list] end
    function r:state(value,event)
        local raw=event and Codec:encode({event={data={new_state=value}}}) or Codec:encode(value)
        return ReceivedFromProxy(999,event and 'RECEIEVE_EVENT' or 'RECEIEVE_STATE',event and {data=raw} or {response=raw})
    end
    function r:discovery(rows)
        if not self:discovery_request() then ExecuteCommand('RefreshEntities',{}) end
        local request
        for i=#self.sent,1,-1 do if self.sent[i].command=='HA_GET_ENTITIES' then request=Codec:decode(self.sent[i].params.JSON); break end end
        check(request,'No discovery request')
        ReceivedFromProxy(999,'HA_ENTITIES',{JSON=Codec:encode({version=1,client_id=request.client_id,
            request_id=request.request_id,snapshot_id='snapshot-'..#self.sent,
            entities=Codec:newArray(rows),complete=true,total=#rows})})
    end
    function r:discovery_request()
        for i=#self.sent,1,-1 do if self.sent[i].command=='HA_GET_ENTITIES' then return Codec:decode(self.sent[i].params.JSON) end end
    end
    function r:discovery_error(code)
        local request=self:discovery_request()
        ReceivedFromProxy(999,'HA_ENTITIES',{JSON=Codec:encode({version=1,client_id=request.client_id,
            request_id=request.request_id,error={code=code,message='HA entity discovery is unavailable'},
            entities=Codec:newArray(),complete=true,total=0})})
    end
    function r:discovery_count()
        local count=0; for _,entry in ipairs(self.sent) do if entry.command=='HA_GET_ENTITIES' then count=count+1 end end
        return count
    end
    function r:pick(id)
        local label
        for value in self.lists['Entity Selection'].values:gmatch('[^,]+') do
            if value:find('['..id..']',1,true) then label=value end
        end
        check(label,'Missing picker choice '..id); self:property('Entity Selection',label)
    end
    return r
end
local function state(id,value,second,attributes)
    return {entity_id=id,state=value,last_updated=string.format('2026-11-14T20:00:%02d.000+00:00',second or 0),
        attributes=attributes or Codec:newObject()}
end
local function row(id,name,attrs)
    return {entity_id=id,domain=id:match('^([^.]+)'),name=name or id,state='off',availability='available',attributes=attrs or Codec:newObject()}
end
local function case(name)
    for _,value in ipairs(Fixture.cases) do if value.name==name then return clone(value.state) end end
    error('Missing fixture '..name)
end

-- Baseline manual switch control works even before first metadata or discovery.
local r=fresh()
ExecuteCommand('Turn On',{}); eq(r:last_service().domain,'switch'); eq(r:last_service().target.entity_id,'switch.manual')
r:late_init(); eq(Properties['Operation Mode'],'Control HA Device');
eq(Properties['Entity ID'],'switch.manual')
r:state(state('switch.manual','on',2)); eq(r.sent[#r.sent].command,'CLOSED'); eq(r.sent[#r.sent].binding,1)
ReceivedFromProxy(200,'DO_CLICK',{}); eq(r:last_service().service,'turn_on')
ReceivedFromProxy(201,'DO_CLICK',{}); eq(r:last_service().service,'turn_off')
ReceivedFromProxy(202,'DO_CLICK',{}); eq(r:last_service().service,'turn_on')
ReceivedFromProxy(1,'OPEN',{}); eq(r:last_service().service,'turn_off')
ReceivedFromProxy(1,'CLOSE',{}); eq(r:last_service().service,'turn_on')
ReceivedFromProxy(1,'TOGGLE',{}); eq(r:last_service().service,'turn_off')
local before=#r:services()
ReceivedFromProxy(200,'DO_PUSH',{}); ReceivedFromProxy(200,'DO_RELEASE',{})
ReceivedFromProxy(1,'BUTTON_ACTION',{ACTION='1',BUTTON_ID='0'})
eq(#r:services(),before); eq(#r.fired,0)

-- Old coordinators ignore explicit discovery; timeout never blocks manual baseline.
eq(r:discovery_count(),0,'Startup must not download a device list')
ExecuteCommand('RefreshEntities',{})
r.now=121000; r.timers[1].callback()
check(Properties['Discovery Status']:find('Manual Entity ID',1,true))
ExecuteCommand('Turn On',{}); eq(#r:services(),before+1)
r:property('Entity ID','input_boolean.office')
ExecuteCommand('Turn Off',{}); eq(r:last_service().domain,'input_boolean')
eq(r:last_service().target.entity_id,'input_boolean.office')
r:state(state('input_boolean.office','unavailable',3))
before=#r:services(); ExecuteCommand('Turn On',{}); eq(#r:services(),before)
r:state(state('input_boolean.office','off',4)); ExecuteCommand('Turn On',{}); eq(#r:services(),before+1)

-- Saved/manual light IDs retain on/off, but Switch has no brightness runtime.
local dim={supported_color_modes=Codec:newArray({'brightness'}),supported_features=32}
r:property('Entity ID','light.office'); before=#r:services()
ExecuteCommand('Turn On',{}); eq(#r:services(),before,'Wait for confirmed light state')
r:state(state('light.office','on',5,dim))
for _,name in ipairs({'Set_Level','Ramp_To_Level','Light_Action'}) do eq(EC[name],nil) end
eq(RFP.SET_LEVEL,nil); eq(RFP.RAMP_TO_LEVEL,nil); eq(GCPL.Light_Action,nil)
for _,name in ipairs({'Set Level','Ramp To Level','Light Action'}) do
    ExecuteCommand(name,{Action='On',Level='50',['Rate Millisec']='1000'})
end
ReceivedFromProxy(5001,'SET_LEVEL',{LEVEL='50'})
ReceivedFromProxy(5001,'RAMP_TO_LEVEL',{LEVEL='50',RATE='1000'})
eq(#r:services(),before,'Dimmer commands cannot send services through Switch')
check(not Properties['Selected Capabilities']:find('Level',1,true))
ExecuteCommand('Turn On',{}); eq(r:last_service().domain,'light')
eq(r:last_service().service_data.brightness,nil); eq(r:last_service().service_data.transition,nil)
r:state(state('light.office','off',8),true)
r:state(state('light.office','on',7,dim))
eq(SWITCH_STATE,'open','A delayed reply cannot roll back confirmed state')
r:state(state('light.office','unavailable',9),true); before=#r:services()
ExecuteCommand('Turn On',{}); eq(#r:services(),before)

-- Identity checks prevent old light state authorizing another saved target.
Properties['Entity ID']='light.changed'
r:state(state('light.office','on',10,dim))
ExecuteCommand('Turn On',{}); eq(#r:services(),before)
r:state(state('light.changed','on',11,dim))
ExecuteCommand('Turn On',{}); eq(r:last_service().target.entity_id,'light.changed')
eq(Properties['Entity ID'],'light.changed','Never rewrite a saved ID when moving brightness to Dimmer')

-- Companion-free native discovery offers all compatible loads. Refresh/manual
-- entry never silently change selected ID or mode; duplicate labels are safe.
EC.RefreshEntities()
r:discovery({row('switch.a','Office, East'),row('switch.b','Office, East'),
    row('light.simple','Lamp',{supported_color_modes=Codec:newArray({'onoff'})}),row('sensor.no','No')})
eq(Properties['Entity ID'],'light.changed'); eq(Properties['Operation Mode'],'Control HA Device')
check(r.lists['Entity Selection'].values:find('[switch.a]',1,true))
check(r.lists['Entity Selection'].values:find('[light.simple]',1,true))
check(not r.lists['Entity Selection'].values:find('[sensor.no]',1,true))
r:pick('switch.b'); eq(Properties['Entity ID'],'switch.b'); eq(EntityID,'switch.b'); eq(r.ENTITY_ID,'switch.b')
r:property('Entity Selection','Manual Entity ID'); eq(Properties['Entity ID'],'switch.b')
EC.RefreshEntities(); local stale_request
for i=#r.sent,1,-1 do if r.sent[i].command=='HA_GET_ENTITIES' then stale_request=Codec:decode(r.sent[i].params.JSON); break end end
OnBindingChanged(999,'HA_DEVICE',false)
ReceivedFromProxy(999,'HA_ENTITIES',{JSON=Codec:encode({version=1,client_id=stale_request.client_id,
    request_id=stale_request.request_id,snapshot_id='late',entities=Codec:newArray({row('switch.stale')}),total=1,complete=true})})
check(not r.lists['Entity Selection'].values:find('[switch.stale]',1,true)); eq(Properties['Entity ID'],'switch.b')

-- Projected aggregate metadata configures bridge mode, but cannot authorize a
-- load until an actual validated selected state arrives.
OnBindingChanged(999,'HA_DEVICE',true)
EC.RefreshEntities() -- User explicitly opens/refreshes setup after reconnect.
local initial=case('initial_snapshot'); local aggregate=row(Fixture.entity_id,'Office gestures',initial.attributes)
r:discovery({aggregate})
r:pick(Fixture.entity_id); eq(Properties['Operation Mode'],'Control HA Device with Button Events')
before=#r:services(); ExecuteCommand('Turn On',{}); eq(#r:services(),before)
r:state(initial); eq(#r.fired,0); eq(Properties['Gesture Count'],'0')
ExecuteCommand('Turn On',{}); eq(r:last_service().target.entity_id,'switch.fixture')
eq(r:last_service().domain,'switch')
check(r:last_service().target.entity_id~=Fixture.entity_id)
local double=case('first_double_press')
r:state(double,true); eq(#r.fired,1); eq(Properties['Gesture Count'],'1'); eq(Properties['Last Gesture'],'top/press_2')
eq(Properties['Last Sequence'],'1')
local event_id=r.fired[1]; check(r.events[event_id].name:find('Double Tap',1,true))
r:state(double,true); eq(#r.fired,1); eq(Properties['Gesture Count'],'1')
r:state(double); eq(#r.fired,1); eq(Properties['Gesture Count'],'1')
local older=clone(initial); older.attributes.bridge_load.state='on'
r:state(older); eq(SWITCH_STATE,'open') -- newer gesture's load snapshot wins
-- Contract rejection immediately invalidates command targeting.
local broken=clone(double); broken.last_updated='2026-11-14T20:00:20Z'; broken.attributes.bridge_load.domain='light'
r:state(broken,true); before=#r:services(); ExecuteCommand('Turn On',{}); eq(#r:services(),before)

-- Gestures-only sources need no fake relay load and never send load services.
r:property('Operation Mode','Programming Events Only')
local remote=clone(initial); remote.last_updated='2026-11-14T20:00:21Z'; remote.attributes.bridge_load=Codec.null
r:state(remote); before=#r:services(); ExecuteCommand('Turn On',{}); ExecuteCommand('Toggle',{})
eq(#r:services(),before)
local renamed=clone(double); renamed.last_updated='2026-11-14T20:00:22Z'
renamed.attributes.bridge_buttons[1].label='Office Top'; renamed.attributes.bridge_load=Codec.null
r:state(renamed,true); eq(r.fired[#r.fired],event_id); eq(Properties['Gesture Count'],'2')
eq(r.events[event_id].name,'Office Top Double Tap')
-- Manual mode/ID edits invalidate the old validated bridge target immediately.
Properties['Entity ID']='event.other'; Properties['Operation Mode']='Control HA Device with Button Events'
before=#r:services(); ExecuteCommand('Turn On',{}); eq(#r:services(),before)
r:state(renamed,true); eq(#r:services(),before)

-- Invalid persistence cannot prevent the pre-existing direct switch path.
OnDriverDestroyed(); check(r.timers[1].cancelled)
r=fresh('switch.manual','Direct',{GestureEventIDs='corrupt'})
r:late_init(); ExecuteCommand('Turn On',{}); eq(r:last_service().target.entity_id,'switch.manual')
OnDriverDestroyed()
-- Run all shared/HA-produced publications at the real Switch entry point,
-- including hold distinctions, restored sessions and unrelated controls.
local suite=Fixture
if arg[1] then
    local produced=assert(io.open(arg[1],'r'))
    suite=Codec:decode(produced:read('*a')); produced:close()
end
r=fresh(suite.entity_id,'Gestures Only'); r:late_init()
local expected=0
for _,publication in ipairs(suite.cases) do
    local output_before=#r:button_outputs()
    r:state(publication.state,publication.delivery=='event')
    if publication.expected_event~=nil and publication.expected_event~=Discovery.null then expected=expected+1 end
    eq(#r.fired,expected,publication.name..' fire count')
    eq(tonumber(Properties['Gesture Count']),expected,publication.name..' diagnostic count')
    eq(#r:button_outputs(),output_before,publication.name..' passive Switch must not forward button commands')
end
eq(#r:services(),0,'Passive input must never issue a load command')
local fire_count=#r.fired
ReceivedFromProxy(999,'RECEIEVE_EVENT',{data='{}'})
ReceivedFromProxy(999,'RECEIEVE_STATE',{response='{malformed'})
eq(#r.fired,fire_count,'Malformed input must not fire an event')
ExecuteCommand('Turn On',{}); ExecuteCommand('Set Level',{Level='75'})
eq(#r:services(),0,'Gestures Only blocks commands even with an invalid source')
OnDriverDestroyed()
print('Actual Switch suite: '..#suite.cases..' states, '..expected..' fired gestures')
-- A missing load blocks output, but independent physical gestures still work.
r=fresh(Fixture.entity_id,'Gesture Bridge'); r:late_init()
local unavailable=case('initial_snapshot')
unavailable.attributes.bridge_load.available=false
unavailable.attributes.bridge_load.state='unavailable'
r:state(unavailable)
ExecuteCommand('Turn On',{}); eq(#r:services(),0)
local independent=case('first_double_press')
independent.attributes.bridge_load.available=false
independent.attributes.bridge_load.state='unavailable'
r:state(independent,true)
eq(#r.fired,1,'Load availability must not block a valid physical gesture')
ExecuteCommand('Turn On',{}); eq(#r:services(),0)
local recovered=clone(independent)
recovered.last_updated='2030-01-01T00:00:00Z'
recovered.attributes.bridge_update_kind='snapshot'
recovered.attributes.bridge_load.available=true
recovered.attributes.bridge_load.state='off'
r:state(recovered,true)
eq(#r.fired,1,'Load-only recovery must not replay the preserved gesture')
eq(SWITCH_STATE,'open')
ExecuteCommand('Turn Off',{}); eq(r:last_service().target.entity_id,'switch.fixture')
OnDriverDestroyed()
-- One choice per verified physical switch and a native searchable browser.
r=fresh('switch.closet'); r:late_init()
local callback_items
BrowseHADevices(nil,function(items) callback_items=items end,'Jeff Closet','switch')
check(callback_items==nil,'An uncached browser waits for discovery')
local closet=row('switch.closet','Jeff Closet')
local wrapper=row('light.closet','Jeff Closet',{supported_color_modes=Codec:newArray({'onoff'})})
wrapper.registry={platform='switch_as_x',source_entity_id='switch.closet',source_inverted=false}
local office=row('switch.office','Office')
local office_bridge=row(Fixture.entity_id,'Internal Gesture Proof',clone(initial.attributes))
office_bridge.attributes.bridge_load.entity_id='switch.office'
local group=row('light.office_group','Office Group',{entity_id=Codec:newArray({'switch.office'})})
local dimmer=row('light.desk','Desk',{supported_color_modes=Codec:newArray({'brightness'}),supported_features=32})
r:discovery({closet,wrapper,office,office_bridge,group,dimmer})
eq(#callback_items,1); eq(callback_items[1].value,'switch.closet')
check(not r.lists['Entity Selection'].values:find('[light.closet]',1,true),'Hide a verified equivalent wrapper')
check(not r.lists['Entity Selection'].values:find('[switch.office]',1,true),'Combine physical load with its linked gestures')
check(r.lists['Entity Selection'].values:find('[light.office_group]',1,true),'A group remains a separate target')
eq(Properties['Entity ID'],'switch.closet'); eq(Properties['Operation Mode'],'Control HA Device')
local browsed=BrowseHADevices(nil,nil,'OFFICE','gesture')
eq(#browsed,1); eq(browsed[1].value,Fixture.entity_id)
check(not browsed[1].text:find('Proof',1,true),'Use the physical switch name in the browser')
eq(#BrowseHADevices(nil,nil,'','dimmer'),0,'Dimmable targets belong to the Dimmer driver')
check(not r.lists['Entity Selection'].values:find('[light.desk]',1,true),'Exclude known brightness entities from Switch choices')
eq(#BrowseHADevices(nil,nil,'','group'),1)
eq(Properties['Entity ID'],'switch.closet','Searching does not select a new target')
before=#r:services()
ExecuteCommand('LUA_ACTION',{ACTION='SelectDevice',Device=Fixture.entity_id})
eq(Properties['Entity ID'],Fixture.entity_id); eq(Properties['Operation Mode'],'Control HA Device with Button Events')
eq(#r:services(),before,'Device selection cannot operate a load')
ExecuteCommand('LUA_ACTION',{ACTION='SelectDevice',Device='switch.closet,light.desk'})
eq(Properties['Entity ID'],Fixture.entity_id,'Multiple selections cannot silently choose a target')
OnDriverDestroyed()

-- Filtering brightness affects discovery only, never saved IDs. A known
-- brightness wrapper cannot hide its still-compatible physical switch source.
r=fresh('light.desk'); r:late_init()
r:discovery({dimmer,closet,wrapper})
eq(Properties['Entity ID'],'light.desk'); eq(Properties['Operation Mode'],'Control HA Device')
eq(r.lists['Entity Selection'].selected,'Manual Entity ID')
check(not r.lists['Entity Selection'].values:find('[light.desk]',1,true))
before=#r:services()
ExecuteCommand('LUA_ACTION',{ACTION='SelectDevice',Device='light.desk'})
eq(Properties['Entity ID'],'light.desk'); eq(#r:services(),before)
EC.RefreshEntities()
local brightness_wrapper=clone(wrapper)
brightness_wrapper.attributes.supported_color_modes=Codec:newArray({'brightness'})
r:discovery({closet,brightness_wrapper})
check(r.lists['Entity Selection'].values:find('[switch.closet]',1,true))
check(not r.lists['Entity Selection'].values:find('[light.closet]',1,true))
OnDriverDestroyed()

-- A coordinator starting up retries without manual intervention or load calls.
r=fresh(); r:late_init(); EC.RefreshEntities()
local attempts=r:discovery_count()
r:discovery_error('not_connected')
check(Properties['Discovery Status']:find('not_connected',1,true))
r.now=101999; r.timers[1].callback(); eq(r:discovery_count(),attempts)
r.now=102000; r.timers[1].callback(); eq(r:discovery_count(),attempts+1)
eq(#r:services(),0)
r:discovery({row('switch.ready','Ready')})
eq(Properties['Discovery Status'],'Complete; current Entity ID not listed (preserved)')
attempts=r:discovery_count(); r.now=200000; r.timers[1].callback(); eq(r:discovery_count(),attempts)
eq(Properties['Entity ID'],'switch.manual')
OnDriverDestroyed()

-- Native discovery no longer asks for the entire HA registry. The catalog
-- owns relationships; without it plain switch control remains usable.
r=fresh(); r:late_init(); EC.RefreshEntities(); eq(r:discovery_request().include_registry,nil)
r:discovery({row('switch.manual','Native Switch')})
eq(Properties['Discovery Status'],'Complete')
EC.RefreshEntities(); r:discovery_error('invalid_result')
attempts=r:discovery_count(); r.now=300000; r.timers[1].callback(); eq(r:discovery_count(),attempts)
check(Properties['Discovery Status']:find('invalid_result',1,true))
OnDriverDestroyed()

-- Retry of an explicit browse is bounded even if HA never connects.
r=fresh(); r:late_init(); EC.RefreshEntities()
for i=1,6 do
    r:discovery_error('not_connected')
    r.now=r.now+20000; r.timers[1].callback()
end
attempts=r:discovery_count(); r.now=r.now+20000; r.timers[1].callback()
eq(r:discovery_count(),attempts); eq(attempts,6)
eq(#r:services(),0); eq(Properties['Entity ID'],'switch.manual')
OnDriverDestroyed()

-- Retired beta lighting commands are absent in every mode, while the
-- original Switch load commands remain independently callable.
for _,mode in ipairs({'Direct','Gesture Bridge','Gestures Only','C4 Button Controller'}) do
    r=fresh(mode=='Direct' and 'light.office' or Fixture.entity_id,mode); r:late_init()
    if mode=='Direct' then r:state(state('light.office','on',1,dim)) else r:state(case('initial_snapshot')) end
    before=#r:services()
    eq(#(GetCommandParamList('Light Action','Action') or {}),0)
    for _,name in ipairs({'Set Level','Ramp To Level','Light Action'}) do
        ExecuteCommand(name,{Action='On',Level='50',['Rate Millisec']='1000'})
    end
    eq(#r:services(),before,'Retired lighting commands must not operate a load')
    eq(TestCondition('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE=0}),false)
    OnDriverDestroyed()
end

-- Composer If/While predicates read confirmed selected snapshots, without
-- polling HA, controlling a load or fabricating a physical gesture.
r=fresh('switch.manual'); r:late_init()
local function condition(name,params)
    local sent,fired,id,mode_before=#r.sent,#r.fired,Properties['Entity ID'],Properties['Operation Mode']
    local result=TestCondition(name,params)
    eq(type(result),'boolean'); eq(#r.sent,sent,'Condition/loop tests must not poll or control HA')
    eq(#r.fired,fired); eq(Properties['Entity ID'],id); eq(Properties['Operation Mode'],mode_before)
    return result
end
eq(condition('IS_ON'),false); eq(condition('IS_OFF'),false)
ExecuteCommand('Turn On',{}); eq(condition('IS_ON'),false,'A command is not confirmed feedback')
r:state(state('switch.manual','off',1)); eq(condition('IS_OFF'),true); eq(condition('IS_ON'),false)
ExecuteCommand('Turn On',{}); eq(condition('IS_OFF'),true); eq(condition('IS_ON'),false)
r:state(state('switch.manual','on',2),true); eq(condition('IS_ON'),true); eq(condition('IS_OFF'),false)
ExecuteCommand('Turn Off',{}); eq(condition('IS_ON'),true,'Keep reported On until HA confirms Off')
r:state(state('switch.manual','off',3),true); eq(condition('IS_OFF'),true)
eq(condition('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE='50'}),false,'An on/off switch has no dimmer level')
r:state(state('switch.manual','unavailable',4),true)
eq(condition('IS_ON'),false); eq(condition('IS_OFF'),false)
eq(condition('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE=50}),false)
r:property('Entity ID','input_boolean.office'); eq(condition('IS_OFF'),false)
r:state(state('input_boolean.office','on',5)); eq(condition('IS_ON'),true)
Properties['Entity ID']='light.office'
eq(condition('IS_ON'),false,'A pending property callback cannot leave stale conditions')
local brightness=clone(dim); brightness.brightness=128
r:state(state('light.office','on',6,brightness))
eq(condition('IS_ON'),true); eq(condition('LIGHT_LEVEL',{LOGIC='EQUAL',VALUE='50'}),false)
eq(condition('LIGHT_LEVEL',{LOGIC='LESS_THAN',VALUE='51'}),false)
eq(condition('LIGHT_LEVEL',{LOGIC='GREATER_THAN_OR_EQUAL',VALUE=50}),false)
local max_brightness=clone(brightness); max_brightness.brightness=255
r:state(state('light.office','off',7,max_brightness),true)
eq(condition('IS_OFF'),true); eq(condition('LIGHT_LEVEL',{LOGIC='EQUAL',VALUE='0'}),false)
eq(condition('LIGHT_LEVEL',{LOGIC='GREATER_THAN',VALUE='0'}),false,'Off overrides cached brightness')
r:state(state('light.office','on',6,brightness))
eq(condition('IS_ON'),false,'Old responses cannot change a conditional after newer state')
r:state(state('light.office','unknown',8,brightness),true)
eq(condition('IS_ON'),false); eq(condition('IS_OFF'),false)
eq(condition('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE='0'}),false)
r:state(state('light.office','on',9,dim),true)
eq(condition('IS_ON'),true); eq(condition('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE='0'}),false,'No invented on=100 level')
eq(condition('UNKNOWN'),false)
OnBindingChanged(999,'HA_DEVICE',false)
eq(condition('IS_ON'),false); eq(condition('IS_OFF'),false)
OnDriverDestroyed()
r=fresh(Fixture.entity_id,'Gesture Bridge'); r:late_init()
eq(condition('IS_OFF'),false)
r:state(case('initial_snapshot')); eq(condition('IS_OFF'),true)
ExecuteCommand('Turn On',{}); eq(condition('IS_OFF'),true,'Bridge predicates also await confirmed feedback')
local bridge_on=case('initial_snapshot'); bridge_on.last_updated='2030-01-01T00:00:00Z'
bridge_on.attributes.bridge_load.state='on'
r:state(bridge_on,true); eq(condition('IS_ON'),true)
eq(condition('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE='0'}),false,'Bridge v1 provides on/off loads only')
bridge_on.last_updated='2030-01-01T00:00:01Z'; bridge_on.attributes.bridge_load.available=false
r:state(bridge_on,true); eq(condition('IS_ON'),false); eq(condition('IS_OFF'),false)
Properties['Operation Mode']='Programming Events Only'
eq(condition('IS_ON'),false); eq(condition('IS_OFF'),false)
Properties['Operation Mode']='Control HA Device with Button Events'
eq(condition('IS_ON'),false,'Returning to bridge mode must revalidate state')
Properties['Entity ID']='event.other'
eq(condition('IS_ON'),false); eq(condition('IS_OFF'),false)
OnDriverDestroyed()

-- Retired beta external-light mode is not silently converted into HA load
-- control. Both stored labels and internal identifiers fail closed.
for _,retired in ipairs({'Control Connected C4 Light','C4 Button Controller'}) do
    r=fresh(Fixture.entity_id,retired); r:late_init()
    check(Properties['Status']:find('HA Light',1,true))
    r:state(case('initial_snapshot')); r:state(case('first_double_press'),true)
    eq(#r.fired,0); eq(#r:button_outputs(),0); eq(#r:services(),0)
    for _,cmd in ipairs({'Turn On','Turn Off','Toggle','Button Action'}) do ExecuteCommand(cmd,{Action='Top Single Click'}) end
    for _,message in ipairs({{1,'OPEN'},{1,'CLOSE'},{1,'TOGGLE'},{200,'DO_CLICK'},{201,'DO_CLICK'},{202,'DO_CLICK'},
        {200,'BUTTON_ACTION'}}) do ReceivedFromProxy(message[1],message[2],{ACTION='2',BUTTON_ID='0'}) end
    eq(#r.fired,0); eq(#r:button_outputs(),0); eq(#r:services(),0)
    eq(GetCommandParamList('Button Action','Action'),nil)
    check(Properties['Status']:find('HA Light',1,true))
    eq(Properties['Operation Mode'],'Control Connected C4 Light','Retired mode must remain an explicit user choice to change')
    r:property('Operation Mode','Programming Events Only')
    r:state(case('initial_snapshot')); r:state(case('first_double_press'),true)
    eq(#r.fired,1,'Explicitly choosing a supported mode restores gesture programming')
    eq(#r:button_outputs(),0); eq(#r:services(),0)
    OnDriverDestroyed()
    r=fresh('switch.manual',retired); r:late_init()
    r:state(state('switch.manual','on',1))
    ExecuteCommand('Turn On',{}); ExecuteCommand('Turn Off',{})
    ReceivedFromProxy(200,'DO_CLICK',{})
    eq(#r:services(),0,'Retired mode cannot fall through to direct control even with a valid HA switch')
    check(Properties['Status']:find('HA Light',1,true))
    OnDriverDestroyed()
end

-- Updating/reloading an already configured 107 keeps its source, mode and
-- event IDs. Model saved Composer programs as references to those IDs; a
-- reloaded snapshot must not execute the programs again.
local saved={}
r=fresh(Fixture.entity_id,'Gesture Bridge',saved); r:late_init()
r:state(case('initial_snapshot'))
r:state(case('first_double_press'),true)
eq(#r.fired,1)
local programmed_id=r.fired[1]
local allocations=clone(saved.GestureEventIDs)
OnDriverDestroyed()
saved=clone(saved)
r=fresh(Fixture.entity_id,'Gesture Bridge',saved); r:late_init()
r:state(case('first_double_press'))
eq(Properties['Entity ID'],Fixture.entity_id)
eq(Properties['Operation Mode'],'Control HA Device with Button Events')
eq(#r.fired,0,'Reload must not execute saved gesture programming')
check(r.events[programmed_id]~=nil,'Saved programming still refers to the same registered event')
eq(saved.GestureEventIDs.next_event_id,allocations.next_event_id)
for key,id in pairs(allocations.allocations) do eq(saved.GestureEventIDs.allocations[key],id) end
ExecuteCommand('Turn On',{}); eq(r:last_service().service,'turn_on')
ExecuteCommand('Turn Off',{}); eq(r:last_service().service,'turn_off')
eq(r:last_service().target.entity_id,'switch.fixture')
OnDriverDestroyed()
-- Optional catalog enrichment follows native discovery without becoming a
-- primary subscription, an action source, or a second target authority.
r=fresh('switch.office'); r:late_init()
r:discovery({row('switch.office','Native Office')})
local catalog_request=r:discovery_request()
eq(catalog_request.entity_ids[1],'sensor.ha_gesture_bridge_catalog')
eq(catalog_request.page_size,1)
local catalog_row=row('sensor.ha_gesture_bridge_catalog','Catalog',{
    catalog_contract_version='1.0',catalog_names_version=1,catalog_names_revision=string.rep('a',64),catalog_names_pages=1,catalog_names_total=2,catalog_names_page_001=Codec:newArray({
        {entity_id='switch.office',domain='switch',friendly_name='Office, East',area_name='Upstairs'},
        {entity_id='switch.catalog_only',domain='switch',friendly_name='Not discovered'}})})
catalog_row.state='2'
r:discovery({catalog_row}) -- Names manifest.
r:discovery({catalog_row}) -- Correlated names page.
check(r.lists['Entity Selection'].values:find('Office East — Upstairs [switch.office]',1,true))
check(not r.lists['Entity Selection'].values:find('switch.catalog_only',1,true))
eq(Properties['Entity ID'],'switch.office'); eq(Properties['Operation Mode'],'Control HA Device')
eq(#r.fired,0); eq(#r:services(),0)
for _,message in ipairs(r.sent) do
    if message.command=='HA_GET_STATE' then eq(message.params.entity,'switch.office') end
end
local old_catalog=clone(catalog_request)
r:property('Discovery Catalog Entity ID','sensor.renamed_catalog')
eq(r:discovery_request().entity_ids[1],'sensor.renamed_catalog')
check(not r.lists['Entity Selection'].values:find('Upstairs',1,true))
ReceivedFromProxy(999,'HA_ENTITIES',{JSON=Codec:encode({version=1,client_id=old_catalog.client_id,
    request_id=old_catalog.request_id,snapshot_id='delayed',entities=Codec:newArray({catalog_row}),complete=true,total=1})})
check(not r.lists['Entity Selection'].values:find('Upstairs',1,true))
r:discovery_error('record_too_large')
check(Properties['Discovery Status']:find('optional catalog error_record_too_large',1,true))
eq(Properties['Entity ID'],'switch.office')
local reads=r:discovery_count()
r:property('Discovery Catalog Entity ID','')
eq(r:discovery_count(),reads)
r.now=r.now+30000; r.timers[1].callback(); eq(r:discovery_count(),reads)
r:pick('switch.office'); ExecuteCommand('Turn On',{})
eq(r:last_service().target.entity_id,'switch.office')
OnDriverDestroyed()
-- Friendly labels must still route the released Switch's HA load commands.
r=fresh('switch.manual','Control HA Device'); r:late_init()
eq(Properties['Operation Mode'],'Control HA Device')
ExecuteCommand('Turn On',{}); eq(r:last_service().target.entity_id,'switch.manual')
OnDriverDestroyed()
for _,label in ipairs({'Control HA Device with Button Events','Programming Events Only'}) do
    r=fresh(Fixture.entity_id,label); r:late_init()
    eq(Properties['Operation Mode'],label)
    r:state(case('initial_snapshot')); r:state(case('first_double_press'),true)
    eq(#r.fired,1)
    ExecuteCommand('Turn On',{})
    eq(#r:services(),label=='Control HA Device with Button Events' and 1 or 0)
    OnDriverDestroyed()
end
-- Both entry points use the shared parsed message for routing and validation.
r=fresh(Fixture.entity_id,'Gestures Only'); r:late_init()
local baseline=case('initial_snapshot'); local live=case('first_double_press')
local json_module=getmetatable(require('module.json')); local original_decode=json_module.decode
local decode_calls=0
json_module.decode=function(self,...) decode_calls=decode_calls+1; return original_decode(self,...) end
r:state(baseline); eq(decode_calls,1,'One JSON parse per received snapshot')
decode_calls=0
r:state(live,true); eq(decode_calls,1,'One JSON parse per received live gesture')
json_module.decode=original_decode
OnDriverDestroyed()

-- Owned strict-syntax errors cannot fire programming. Unrelated or wholly
-- undecodable messages cannot fabricate passive Switch output.
r=fresh(Fixture.entity_id,'Gestures Only'); r:late_init()
r:state(case('initial_snapshot')); r:state(case('hold_start'),true)
local function releases()
    local count=0
    for _,sent in ipairs(r.sent) do if sent.binding==200 and sent.command=='DO_RELEASE' then count=count+1 end end
    return count
end
local before_release=releases()
local broken=case('reported_release'); broken.entity_id='event.unrelated'
ReceivedFromProxy(999,'RECEIEVE_EVENT',{data=Codec:encode({event={data={new_state=broken}}})..' trailing'})
eq(releases(),before_release,'Malformed other entity cannot cancel a held output')
ReceivedFromProxy(999,'RECEIEVE_EVENT',{data='{malformed'})
eq(releases(),before_release,'Undecodable messages have no established owner')
broken.entity_id=Fixture.entity_id
local fired_before=#r.fired
ReceivedFromProxy(999,'RECEIEVE_EVENT',{data=Codec:encode({event={data={new_state=broken}}})..' trailing'})
eq(releases(),before_release,'Owned invalid JSON cannot fabricate a Switch button output')
eq(#r.fired,fired_before,'Invalid prefix cannot fire release programming')
OnDriverDestroyed()

-- Reconnection must obtain a current snapshot before queued live events
-- can regain programming authority; Switch never forwards physical holds.
r=fresh(Fixture.entity_id,'Programming Events Only'); r:late_init()
r:state(case('initial_snapshot'))
local picker_updates=r.list_updates
r:state(case('hold_start'),true)
eq(#r:button_outputs(),0); eq(#r.fired,1)
r:state(case('hold_start'),true)
eq(r.list_updates,picker_updates,'Live/duplicate gestures cannot rebuild the entity picker')
eq(#r:button_outputs(),0); eq(#r.fired,1)
local held_messages=#r.sent
for _,invalid in ipairs({{}, {CONNECTED='FALSE'}, {CONNECTED='0'}, {CONNECTED=1}, {CONNECTED={}}, 'garbage', false}) do
    eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',invalid),false)
    eq(#r.sent,held_messages,'Malformed status cannot change held output or issue requests')
end
eq(ReceivedFromProxy(1,'HA_CONNECTION_STATUS',{CONNECTED='false'}),false)
eq(#r.sent,held_messages,'A foreign binding cannot revoke the HA connection')
eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'}),true)
outputs=r:button_outputs(); eq(#outputs,0,'Transport loss cannot fabricate button output')
local down_messages=#r.sent
eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'}),true)
eq(#r.sent,down_messages,'Duplicate loss cannot release twice')
r:state(case('reported_release'),true)
ExecuteCommand('Button Action',{Action='Top Single Click'})
ExecuteCommand('Turn On',{})
eq(#r:button_outputs(),0); eq(#r.fired,1); eq(#r:services(),0)
local state_requests=0
for _,message in ipairs(r.sent) do if message.command=='HA_GET_STATE' then state_requests=state_requests+1 end end
eq(ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'}),true)
local refreshed=0
for _,message in ipairs(r.sent) do if message.command=='HA_GET_STATE' then refreshed=refreshed+1 end end
eq(refreshed,state_requests+1,'Reconnect requests a fresh primary snapshot')
r:state(case('reported_release'),true)
eq(#r.fired,1); eq(#r:button_outputs(),0,'Queued live events cannot pass the reconnect snapshot gate')
r:state(case('snapshot_of_unseen_offline_press'))
eq(Properties['Last Sequence'],'5'); eq(#r.fired,1); eq(#r:button_outputs(),0,'Snapshot establishes history without programming or clicks')
local after_reconnect=case('fresh_press_after_snapshot')
after_reconnect.attributes.gesture_id='press_1'; after_reconnect.attributes.press_count=1
r:state(after_reconnect,true)
eq(#r.fired,2); eq(#r:button_outputs(),0)
r:state(after_reconnect,true)
eq(#r.fired,2); eq(#r:button_outputs(),0,'First recovered live occurrence fires only once')
OnDriverDestroyed()

-- Direct control also loses load authority until its reconnect snapshot.
r=fresh('switch.manual','Control HA Device'); r:late_init()
r:state(state('switch.manual','on',1))
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
before=#r:services(); ExecuteCommand('Turn On',{}); eq(#r:services(),before)
r:state(state('switch.manual','on',2),true); eq(TestCondition('IS_ON',{}),false)
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
ExecuteCommand('Turn On',{}); eq(#r:services(),before)
r:state(state('switch.manual','on',2),true); eq(TestCondition('IS_ON',{}),false)
r:state(state('switch.manual','off',3))
eq(TestCondition('IS_OFF',{}),true)
ExecuteCommand('Turn On',{}); eq(#r:services(),before+1)

-- An HTML response has no established owner. The private codec must neither
-- log its raw contents with debugging Off nor replace confirmed load state.
local saved_print,privacy_logs=print,{}
print=function(...) local values={}; for i=1,select('#',...) do values[#values+1]=tostring(select(i,...)) end; privacy_logs[#privacy_logs+1]=table.concat(values,' ') end
ReceivedFromProxy(999,'RECEIEVE_STATE',{response='<html>PRIVATE_SWITCH_RESPONSE</html>'})
print=saved_print
eq(Properties['Debug Mode'],'Off')
check(not table.concat(privacy_logs,'\n'):find('PRIVATE_SWITCH_RESPONSE',1,true),'HTML response contents must stay private')
eq(TestCondition('IS_OFF',{}),true,'Unknown-owner parse errors cannot clear confirmed authority')
ExecuteCommand('Turn Off',{}); eq(r:last_service().target.entity_id,'switch.manual')
OnDriverDestroyed()

-- Optional LEDs use only the validated selected aggregate. A single physical
-- indicator exposes one Toggle choice, without changing legacy load control.
local function led_state(name)
    local value=case(name or 'initial_snapshot')
    value.attributes.bridge_led_version=1
    value.attributes.bridge_led_command_version=2
    value.attributes.bridge_leds=Codec:newArray({{id='indicator',label='Office Indicator',button_id='toggle',
        available=true,colors=Codec:newArray({'000000','FFFFFF','FF0000','00FF00','0000FF'}),
        brightness_supported=true,color_supported=true,behaviors=Codec:newArray({'follow_load','follow_load_inverted','always_on','always_off'}),color='000000',brightness=50}})
    return value
end
r=fresh(Fixture.entity_id,'Programming Events Only'); r:late_init()
r:state(case('initial_snapshot'))
eq(#GetCommandParamList('Set LED Current Color','Button'),0)
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='FF0000'}),false)
eq(#r:services(),0,'Old companion versions require no LED service')
local indicator=led_state(); indicator.last_updated='2026-11-14T20:00:00.500Z'
r:state(indicator)
local led_choices=GetCommandParamList('Set LED Current Color','Button')
eq(#led_choices,1); eq(led_choices[1],'Toggle'); eq(#r:services(),0)
eq(Properties['LED Status'],'LEDs: toggle (on/off, color, brightness)')
eq(ExecuteCommand('Set LED Current Color',{Button='Top',Color='FFFFFF'}),false)
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='00FF00'}),true)
local led_service=r:last_service()
eq(led_service.domain,'ha_gesture_bridge'); eq(led_service.service,'set_led')
eq(led_service.service_data.entity_id,Fixture.entity_id); eq(led_service.service_data.led_id,'indicator')
eq(led_service.service_data.color,'00FF00')
eq(ExecuteCommand('Set All LED Colors',{Color='FFFFFF'}),true)
eq(ExecuteCommand('Set LED Brightness',{Button='Toggle',Brightness='25'}),true)
eq(r:last_service().service_data.brightness,25)
local led_requests=#r:services()
indicator.last_updated='2026-11-14T20:00:00.750Z'; r:state(indicator)
eq(#r:services(),led_requests); eq(#r.fired,0,'LED metadata snapshots cannot replay programming')
for _,call in ipairs(r:services()) do eq(call.domain,'ha_gesture_bridge'); eq(call.service,'set_led') end
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='FF0000'}),false)
eq(#GetCommandParamList('Set LED Current Color','Button'),0)
ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='FF0000'}),false)
indicator.last_updated='2026-11-14T20:00:01.000Z'; r:state(indicator)
eq(#r:services(),led_requests,'Restoring LED authority cannot write hardware automatically')
OnBindingChanged(999,'HA_DEVICE',false)
eq(ExecuteCommand('Set All LED Colors',{Color='FFFFFF'}),false)
eq(#r:services(),led_requests)
OnBindingChanged(999,'HA_DEVICE',true)
indicator.last_updated='2026-11-14T20:00:02.000Z'; r:state(indicator)
r:property('Entity ID','event.replacement')
eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='FF0000'}),false)
eq(#GetCommandParamList('Set LED Current Color','Button'),0)
eq(#r:services(),led_requests,'Changing source revokes the old indicator')
OnDriverDestroyed()

do
    -- Independent scene-controller LEDs remain individually selectable through
    -- the real driver command surface, without creating native paddle IDs.
    local r=fresh(Fixture.entity_id,'Programming Events Only'); r:late_init()
    local value=led_state()
    value.attributes.bridge_leds=Codec:newArray()
    for index=1,5 do
        value.attributes.bridge_leds[index]={id='scene_'..index,label='Button '..index..' LED',
            button_id='button_'..index,available=true,colors=Codec:newArray({'000000','FF0000','0000FF'}),
            brightness_supported=index~=5,color_supported=true,behaviors=Codec:newArray({'follow_load','follow_load_inverted','always_on','always_off'}),color='000000',brightness=index~=5 and 60 or nil}
    end
    r:state(value)
    local choices=GetCommandParamList('Set LED Current Color','Button')
    eq(#choices,5)
    eq(#GetCommandParamList('Set LED Brightness','Button'),4)
    for index,choice in ipairs(choices) do
        eq(choice,'Button '..index..' LED [scene_'..index..']')
        eq(ExecuteCommand('Set LED Current Color',{Button=choice,Color='FF0000'}),true)
        local calls=r:services()
        eq(calls[#calls].domain,'ha_gesture_bridge'); eq(calls[#calls].service,'set_led')
        eq(calls[#calls].service_data.entity_id,Fixture.entity_id)
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
end

do
    -- More than two physical buttons retain their named programming events.
    local r=fresh(Fixture.entity_id,'Programming Events Only'); r:late_init()
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
    OnDriverDestroyed()
end

do
    -- Capabilities describe confirmed HA loads and actual button declarations
    -- independently. Discovery previews and relay state never imply gestures.
    local r=fresh('switch.manual','Control HA Device'); r:late_init()
    eq(Properties['Button Capabilities'],'Button events need HA Gesture Bridge')
    eq(Properties['LED Status'],'Not exposed/configured')
    r:state(state('switch.manual','on',1,{press_count=5}))
    eq(Properties['Selected Capabilities'],'On/Off; Toggle')
    eq(Properties['Button Capabilities'],'Button events need HA Gesture Bridge')
    r:property('Entity ID','light.office')
    r:state(state('light.office','on',2,{supported_color_modes={'brightness'},supported_features=32,brightness=128}))
    eq(Properties['Selected Capabilities'],'On/Off; Toggle','Switch retains on/off behavior without claiming dimmer controls')
    eq(Properties['Button Capabilities'],'Button events need HA Gesture Bridge')
    r:property('Entity ID',Fixture.entity_id)
    r:property('Operation Mode','Programming Events Only')
    eq(Properties['Selected Capabilities'],'No load control')
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    local profiles=case('initial_snapshot')
    profiles.attributes.bridge_buttons=Codec:newArray()
    profiles.attributes.bridge_sources=Codec:newArray()
    for _,button in ipairs({'top','bottom'}) do
        local gestures=Codec:newArray()
        for count=1,5 do gestures[#gestures+1]={id='press_'..count,kind='press',press_count=count,label=count..' Press'} end
        for _,kind in ipairs({'hold_start','hold_repeat','release'}) do gestures[#gestures+1]={id=kind,kind=kind,label=kind} end
        profiles.attributes.bridge_buttons[#profiles.attributes.bridge_buttons+1]={id=button,label=button,gestures=gestures}
        profiles.attributes.bridge_sources[#profiles.attributes.bridge_sources+1]={id=button,button_id=button,ready=true,availability='unknown'}
    end
    r:state(profiles)
    eq(Properties['Button Capabilities'],'Top & Bottom: 1–5 taps, hold/repeat, release')
    eq(Properties['Selected Capabilities'],'No load control')
    eq(Properties['LED Status'],'Not exposed/configured')
    local picker_updates=r.list_updates
    local changed=clone(profiles); changed.last_updated='2026-11-14T20:00:01Z'
    changed.attributes.bridge_buttons[2].gestures=Codec:newArray({changed.attributes.bridge_buttons[2].gestures[1]})
    changed.attributes.bridge_sources[2].ready=false; changed.attributes.bridge_sources[2].availability='unavailable'
    r:state(changed)
    eq(Properties['Button Capabilities'],'Top: 1–5 taps, hold/repeat, release; Bottom: single tap (unavailable)')
    eq(r.list_updates,picker_updates,'Capability publication cannot rebuild the picker')
    r:property('Operation Mode','Programming Events Only')
    r:state(changed)
    eq(Properties['Selected Capabilities'],'No load control')
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='true'})
    r:state(case('first_double_press'),true)
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities','Queued live data cannot restore stale capability profiles')
    r:state(changed)
    check(Properties['Button Capabilities']:find('Bottom: single tap (unavailable)',1,true))
    r:property('Operation Mode','Control HA Device with Button Events')
    r:state(profiles)
    eq(Properties['Selected Capabilities'],'On/Off; Toggle')
    ExecuteCommand('Turn On',{}); local before=#r:services()
    local invalid=clone(profiles); invalid.last_updated='2026-11-14T20:00:02Z'; invalid.attributes.bridge_buttons=Codec:newArray()
    r:state(invalid)
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    eq(Properties['Selected Capabilities'],'Waiting for current HA load capabilities')
    ExecuteCommand('Turn On',{}); eq(#r:services(),before,'Retired metadata cannot retain load command authority')
    r:property('Entity ID','event.replacement')
    eq(Properties['Button Capabilities'],'Waiting for current button capabilities')
    OnDriverDestroyed()
end

-- A compact setup screen preserves advanced settings and has an explicit,
-- read-only support dump even with Debug Mode Off.
do
    local setup=fresh('switch.manual')
    eq(ExecuteCommand('ShowAdvancedProperties',{}),false); eq(next(setup.attributes),nil,'No property UI APIs before late init')
    setup.attributes['Debug Mode']=1 -- An installed earlier build hid this field.
    setup:late_init()
    eq(Properties['Selected Device'],'switch.manual')
    eq(setup.attributes['Entity ID'],1); eq(setup.attributes['Entity Selection'],1)
    eq(setup.attributes['Debug Mode'],0); eq(setup.attributes['Discovery Status'],1)
    eq(setup.attributes['Selected Device'],nil,'Basic selected name stays visible')
    local before=#setup.sent
    ExecuteCommand('LUA_ACTION',{ACTION='ShowAdvancedProperties'})
    eq(setup.attributes['Entity ID'],0); eq(setup.attributes['Debug Mode'],0)
    eq(Properties['Entity ID'],'switch.manual')
    ExecuteCommand('HideAdvancedProperties',{})
    eq(setup.attributes['Debug Mode'],0,'Logging remains visible in compact mode')
    eq(setup.attributes['Entity ID'],1); eq(#setup.sent,before,'Visibility changes send no commands')
    setup:state(state('switch.manual','on',1,{friendly_name='Manual friendly name',access_token='PRIVATE_DIAGNOSTIC_TOKEN'}))
    eq(Properties['Selected Device'],'Manual friendly name'); eq(Properties['Status'],'On')
    setup:discovery({row('switch.manual','Consolidated Office')})
    eq(Properties['Selected Device'],'Consolidated Office')
    local output,original={},print
    print=function(line) output[#output+1]=tostring(line) end
    local total=#setup.sent
    local ok,result=pcall(ExecuteCommand,'LUA_ACTION',{ACTION='PrintDiagnostics'})
    print=original
    check(ok); eq(result,true); eq(#setup.sent,total,'Diagnostics must not refresh or send load commands')
    local text=table.concat(output,'\n')
    check(text:find('HA Switch | Diagnostics | driver version=107',1,true))
    check(text:find('Entity ID=switch.manual',1,true)); check(text:find('Confirmed entity state=on',1,true))
    check(text:find('Detailed Status=Control HA Device: on',1,true))
    check(text:find('Debug Mode=Off',1,true)); check(not text:find('PRIVATE_DIAGNOSTIC_TOKEN',1,true))
    setup:property('Entity ID','switch.replacement')
    eq(Properties['Selected Device'],'switch.replacement','A new selection cannot inherit the old friendly name')
    ExecuteCommand('ShowAdvancedProperties',{}); OnDriverDestroyed()
    setup=fresh(); setup:late_init(); eq(setup.attributes['Entity ID'],1,'Reload returns to the compact layout')
    OnDriverDestroyed()
    setup=fresh(Fixture.entity_id,'Gestures Only'); setup:late_init()
    setup:state(case('initial_snapshot')); eq(Properties['Status'],'Ready')
    setup:state(case('first_double_press'),true); eq(Properties['Status'],'Ready')
    OnDriverDestroyed()
end

-- LED behavior is an explicit setting; color and preference changes never
-- silently select a hardware mode, including after reload/reconnect.
do
    local setup=fresh(Fixture.entity_id,'Programming Events Only'); setup:late_init()
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

do
    local setup=fresh(Fixture.entity_id,'Programming Events Only')
    setup:property('LED Behavior','Always On') -- A saved property is loaded before late init.
    setup:late_init(); setup:state(led_state())
    eq(Properties['LED Behavior'],'Always On')
    eq(#setup:services(),0,'A saved Always On policy is never written during driver initialization')
    OnDriverDestroyed()
end

-- Programming choices are the union across available channels, while the
-- global property can offer only behavior supported by every indicator.
do
    local setup=fresh(Fixture.entity_id,'Programming Events Only'); setup:late_init()
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

do
    -- Switch has no bound-device LED tracking. Keep unsupported preferences
    -- out of both basic/advanced setup and command lists, including upgrades
    -- with preferences saved by an earlier development package.
    local value=led_state()
    local store={LEDColors={[value.attributes.bridge_control_id]={indicator={ON_COLOR='0000FF',OFF_COLOR='FF0000'}}}}
    local setup=fresh(Fixture.entity_id,'Programming Events Only',store); setup:late_init()
    setup:state(value)
    ExecuteCommand('ShowAdvancedProperties',{}); ExecuteCommand('HideAdvancedProperties',{})
    for _,field in ipairs({'LED Indicator','LED On Color','LED Off Color'}) do
        eq(setup.attributes[field],nil,'Switch cannot address undeclared color-tracking properties')
        eq(Properties[field],nil,'Switch cannot publish unsupported tracking colors')
    end
    eq(GetCommandParamList('Set LED On Color','Button'),nil)
    eq(GetCommandParamList('Set LED Off Color','Button'),nil)
    eq(ExecuteCommand('Set LED On Color',{Button='Toggle',Color='FF0000'}),nil)
    eq(ExecuteCommand('Set LED Off Color',{Button='Toggle',Color='00FF00'}),nil)
    eq(#setup:services(),0,'Retired preferences cannot issue an LED request')
    eq(store.LEDColors[value.attributes.bridge_control_id].indicator.ON_COLOR,'0000FF','Existing saved data is retained')
    eq(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='00FF00'}),true)
    local data=setup:last_service().service_data
    eq(data.color,'00FF00'); eq(data.behavior,nil,'Immediate color still preserves LED behavior')
    OnDriverDestroyed()
end

do
    local setup=fresh('switch.bath','Direct'); setup:late_init()
    local aggregate=case('initial_snapshot')
    aggregate.attributes.bridge_load=nil; aggregate.attributes.bridge_source_device_id='bath-device'
    local relay=row('switch.bath','Primary Bath')
    relay.registry={platform='zwave_js',device_id='bath-device'}
    setup:discovery({relay,row(aggregate.entity_id,'Primary Bath Gestures',aggregate.attributes),
        row('switch.plain','Plain Switch')})
    eq(#BrowseHADevices(nil,nil,'','all'),3,'Native discovery works without a catalog')
    local records=Codec:newArray({
        {entity_id=aggregate.entity_id,domain='event',friendly_name='Primary Bath (gestures)',
            entity_aliases=Codec:newArray({'switch.bath'}),source_entity_id='switch.bath'},
        {entity_id='switch.plain',domain='switch',friendly_name='Plain Switch'},
    })
    local sensor={entity_id='sensor.ha_gesture_bridge_catalog',domain='sensor',name='Catalog',state='2',availability='available',
        attributes={catalog_contract_version='1.0',catalog_names_version=1,catalog_names_revision=string.rep('a',64),
            catalog_names_total=2,catalog_names_pages=1,catalog_names_page_001=records}}
    setup:discovery({sensor}); setup:discovery({sensor})
    local choices=BrowseHADevices(nil,nil,'','switch')
    eq(#choices,2,'Switch picker follows HA preferences but retains a plain switch')
    eq(#BrowseHADevices(nil,nil,'Primary Bath','all'),1)
    eq(Properties['Entity ID'],'switch.bath','Discovery preserves the installed relay target')
    ExecuteCommand('LUA_ACTION',{ACTION='SelectDevice',Device='switch.bath'})
    eq(Properties['Entity ID'],aggregate.entity_id,'Relay aliases select their physical gesture control')
    eq(Properties['Operation Mode'],'Programming Events Only')
    eq(#setup:services(),0,'Physical source identity is not a linked HA load')
    OnDriverDestroyed()
end

-- New coordinators acknowledge event delivery separately from a REST snapshot.
do
    local sub=fresh('switch.subscription','Control HA Device'); sub:late_init()
    local request
    for _,message in ipairs(sub.sent) do if message.command=='HA_GET_STATE' then request=message.params end end
    eq(request.consumer_id,'42'); eq(Codec:decode(request.active_entities)[1],'switch.subscription')
    eq(ReceivedFromProxy(999,'HA_SUBSCRIPTION_STATUS',{ENTITY='switch.other',STATUS='error'}),false)
    ReceivedFromProxy(999,'HA_SUBSCRIPTION_STATUS',{ENTITY='switch.subscription',STATUS='pending'})
    sub:state(state('switch.subscription','on',1))
    eq(TestCondition('IS_ON',{}),false,'Snapshot alone cannot grant delivery readiness')
    local before=#sub:services(); ExecuteCommand('Turn Off',{}); eq(#sub:services(),before)
    check(Properties.Status:find('acknowledgment',1,true))
    ReceivedFromProxy(999,'HA_SUBSCRIPTION_STATUS',{ENTITY='switch.subscription',STATUS='ready'})
    eq(TestCondition('IS_ON',{}),true,'Acknowledgment promotes the stored confirmed snapshot')
    ReceivedFromProxy(999,'HA_SUBSCRIPTION_STATUS',{ENTITY='switch.subscription',STATUS='error',ERROR='unauthorized'})
    eq(TestCondition('IS_ON',{}),false)
    check(Properties.Status:find('unauthorized',1,true))
    sub:property('Entity ID','switch.replacement')
    for _,message in ipairs(sub.sent) do if message.command=='HA_GET_STATE' then request=message.params end end
    local active=Codec:decode(request.active_entities)
    eq(#active,1); eq(active[1],'switch.replacement')
    OnDriverDestroyed()
    eq(sub.sent[#sub.sent].command,'HA_RELEASE_STATES')
end

print('Production Switch actual-base boundary: '..assertions..' assertions passed')
