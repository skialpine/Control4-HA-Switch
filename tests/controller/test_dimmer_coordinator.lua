-- Actual standalone Dimmer + actual Coordinator + original Switch consumer.
-- Only Director HTTP/WebSocket boundaries are stubs. No HA/network access.
local coordinator_root=arg[1] or '../Control4-HA-Coordinator'
local Discovery=require('module.discovery')
local ClientJSON=require('module.json')
local ClientCodec=Discovery.new_codec()
local assertions=0
local function check(value,message) assertions=assertions+1; assert(value,message or ('assertion '..assertions)) end
local function eq(actual,expected,message) check(actual==expected,(message or '')..' expected '..tostring(expected)..', got '..tostring(actual)) end
local function read(path) local f=assert(io.open(path,'r')); local value=f:read('*a'); f:close(); return value end
local function execute(path,env)
    local chunk,err
    if setfenv then chunk,err=loadstring(read(path),'@'..path); if chunk then setfenv(chunk,env) end
    else chunk,err=load(read(path),'@'..path,'t',env) end
    assert(chunk,err); return chunk()
end
local function namespace()
    local env=setmetatable({},{__index=_G}); env._G=env
    env.table={}; for k,v in pairs(table) do env.table[k]=v end
    env.print=function(...)
        local text={}; for i=1,select('#',...) do text[#text+1]=tostring(select(i,...)) end
        check(not table.concat(text,' '):lower():find('error',1,true),'Actual driver reported a callback error: '..table.concat(text,' '))
    end
    return env
end
-- Vendor JSON keeps OBJDEF in its environment. Isolate Coordinator's codec.
local ServerJSON=execute(coordinator_root..'/module/json.lua',namespace())
local Server=assert(loadfile(coordinator_root..'/module/discovery.lua'))()
local Wire=ServerJSON:new({strictTypes=true,null={}})
local function clone(value) return ClientCodec:decode(Wire:encode(value)) end
local function state(id,value,attributes,second)
    return {entity_id=id,state=value,attributes=attributes or Wire:newObject(),
        last_updated=string.format('2026-11-14T20:00:%02d.000Z',second or 0)}
end
local manifest=ClientCodec:decode(read(coordinator_root..'/tests/fixtures/legacy_family/manifest.json'))
local original
for _,entry in ipairs(manifest) do if entry.name=='Switch' then original=entry end end
check(original~=nil,'Pinned original Switch fixture is required')
local legacy_id=original.properties['Entity ID']
local dimmer_id='light.native_dimmer'
local attrs={friendly_name='Native Dimmer',supported_color_modes=Wire:newArray({'brightness'}),supported_features=32,brightness=128}
local states={[legacy_id]=state(legacy_id,'off'),[dimmer_id]=state(dimmer_id,'on',attrs)}
local consumers,websocket,requests,replies,delivered={},{},{},{},{}
local http_requests={}
local deferred_entity,deferred_responses=nil,{}
local coordinator=namespace()
coordinator.Properties={['Home Assistant URL']='ha-controller-test.invalid',['Long Lived Access Token']='test-token-not-real'}
coordinator.JSON=ServerJSON
coordinator.require=function(name)
    if name=='module.websocket' then return {} end
    if name=='module.json' then return ServerJSON end
    if name=='module.discovery' then return Server end
    if name=='module.state_projection' then return assert(loadfile(coordinator_root..'/module/state_projection.lua'))() end
    error('Unexpected Coordinator dependency '..name)
end
coordinator.C4={}
function coordinator.C4:GetTime() return 100000 end
function coordinator.C4:DebugLog() end
function coordinator.C4:FireEvent() end
function coordinator.C4:UpdateProperty(key,value) coordinator.Properties[key]=value end
function coordinator.C4:ParseXml() return {ChildNodes={}} end
function coordinator.C4:SetTimer() return {Cancel=function() end} end
function coordinator.C4:SendToProxy(binding,command,params)
    eq(binding,1,'Coordinator must keep its original HA_DEVICE provider binding')
    check(command=='HA_ENTITIES' or command=='RECEIEVE_STATE' or command=='RECEIEVE_EVENT' or command=='HA_CONNECTION_STATUS' or command=='HA_SUBSCRIPTION_STATUS')
    if command=='HA_ENTITIES' then check(not params.JSON:find('test-token-not-real',1,true)) end
    replies[#replies+1]={command=command,params=params}
end
function coordinator.C4:url()
    local transfer={}
    function transfer:OnHeaders(callback) self.headers_callback=callback; return self end
    function transfer:OnDone(callback) self.callback=callback; return self end
    function transfer:SetOptions() return self end
    function transfer:Get(url,headers)
        local entity=url:match('^http://ha%-controller%-test%.invalid/api/states/(.+)$')
        check(entity and states[entity],'Unexpected HA REST endpoint: '..tostring(url))
        eq(headers.Authorization,'Bearer test-token-not-real')
        local response={code=200,body=Wire:encode(states[entity])}
        if entity==deferred_entity then
            deferred_responses[#deferred_responses+1]=function() self.callback(self,{response},0,'') end
        else self.callback(self,{response},0,'') end
        return self
    end
    function transfer:Post(url,data,headers)
        check(url=='http://ha-controller-test.invalid/api/template','Discovery must use the filtered endpoint')
        local query=Wire:decode(data); check(query.variables.entity_ids or query.variables.domains)
        http_requests[#http_requests+1]=self; return self
    end
    return transfer
end
execute(coordinator_root..'/driver.lua',coordinator)
coordinator.Connected=true
coordinator.Socket={Send=function(_,raw)
    local message=Wire:decode(raw); websocket[#websocket+1]=message
    if message.type=='subscribe_trigger' then
        coordinator.ReceieveMessage(coordinator.Socket,Wire:encode({type='result',id=message.id,success=true,result=Wire.null}))
    end
end}
local function flush()
    local iteration=0
    while #replies>0 do
        iteration=iteration+1; check(iteration<100,'Bounded discovery must terminate')
        local message=table.remove(replies,1)
        delivered[#delivered+1]=message
        for _,child in ipairs(consumers) do child.env.ReceivedFromProxy(999,message.command,clone(message.params)) end
    end
end
local function counts(kind)
    local n=0; for _,message in ipairs(websocket) do if message.type==kind then n=n+1 end end; return n
end
local function last(kind)
    for i=#websocket,1,-1 do if websocket[i].type==kind then return websocket[i] end end
end
local function latest_native(child,command)
    for i=#child.sent,1,-1 do local message=child.sent[i]; if message.binding==5001 and message.command==command then return message end end
end
local function child_environment(name,properties)
    local child={name=name,env=namespace(),sent={},variables={},timers={},lists={}}
    local env=child.env
    env.Properties=properties; env.Variables={}; env.PersistData={}; env.C4={}
    function env.C4:GetDeviceID() return name=='Dimmer' and 800 or 801 end
    function env.C4:GetTime() return 100000 end
    function env.C4:GetDriverConfigInfo() return name=='Dimmer' and '1' or original.version end
    function env.C4:AddVariable(key,value) child.variables[key]=value end
    function env.C4:SetVariable(key,value) child.variables[key]=value end
    function env.C4:UpdateProperty(key,value) env.Properties[key]=value end
    function env.C4:UpdatePropertyList(key,values,selected) child.lists[key]={values=values,selected=selected} end
    function env.C4:DebugLog() end
    function env.C4:SetPropertyAttribs() end
    function env.C4:ParseXml() return {ChildNodes={}} end
    function env.C4:SetTimer(ms,callback)
        local timer={callback=callback}; function timer:Cancel() self.cancelled=true end
        child.timers[#child.timers+1]=timer; return timer
    end
    function env.C4:AddEvent() return true end
    function env.C4:FireEventByID() end
    function env.C4:SendToProxy(binding,command,params,kind)
        child.sent[#child.sent+1]={binding=binding,command=command,params=params or {},kind=kind}
        if binding==999 then
            check(command=='HA_GET_STATE' or command=='HA_CALL_SERVICE' or command=='HA_GET_ENTITIES' or command=='HA_RELEASE_STATES',
                  'Native notifications must not be forwarded as HA requests')
            requests[#requests+1]={consumer=name,command=command,params=clone(params or {})}
            coordinator.ReceivedFromProxy(1,command,clone(params or {}))
        elseif name=='Dimmer' and binding==5001 then
            eq(kind,'NOTIFY','Native proxy notifications use NOTIFY')
            check(not command:match('^HA_'),'HA requests cannot target the native proxy binding')
        end
    end
    consumers[#consumers+1]=child
    return child
end

-- Load the actual original consumer and its exact pinned Base, not a rewrite.
local legacy=child_environment('Original Switch',clone(original.properties))
legacy.env.Properties['Debug Mode']='Off'
legacy.env.require=function(name)
    if name=='module.json' then return ClientJSON end
    if name=='commands' then return execute(coordinator_root..'/tests/fixtures/legacy_family/Switch.lua',legacy.env) end
    if name=='Control4-HA-Base.helpers' then
        return execute(coordinator_root..'/tests/fixtures/legacy_family/base/'..original.base_commit..'/helpers.lua',legacy.env)
    end
    error('Unexpected original Switch dependency '..name)
end
execute(coordinator_root..'/tests/fixtures/legacy_family/base/'..original.base_commit..'/driver.lua',legacy.env)
legacy.env.OnDriverInit(); legacy.env.OnDriverLateInit(); flush()
eq(legacy.env.EntityID,legacy_id); eq(legacy.sent[#legacy.sent].command,'OPENED')
eq(counts('subscribe_trigger'),1)
local dimmer=child_environment('Dimmer',{['Entity ID']=dimmer_id,['Operation Mode']='Control HA Device',
    ['Entity Selection']='Manual Entity ID',['Debug Mode']='Off'})
dimmer.env.require=require
execute('light/driver.lua',dimmer.env)
dimmer.env.OnDriverInit(); eq(#dimmer.sent,0,'Dimmer must have no pre-init side effects')
dimmer.env.OnDriverLateInit(); flush()
eq(counts('subscribe_trigger'),2,'Only each selected primary entity is subscribed')
local level=latest_native(dimmer,'LIGHT_BRIGHTNESS_CHANGED')
check(level~=nil); check(math.abs(level.params.LIGHT_BRIGHTNESS_CURRENT-128*100/255)<0.000001)
eq(latest_native(dimmer,'ONLINE_CHANGED').params.STATE,true)
eq(dimmer.env.Properties['Entity ID'],dimmer_id)
local subscription_snapshot=Wire:encode(coordinator.EntityTable)
local legacy_messages=#legacy.sent

-- Native Dimmer and a second read-only consumer request interleaved, typed
-- discovery. Results are correlated and never become state subscriptions.
eq(#http_requests,0,'Startup needs only the configured entity')
dimmer.env.ExecuteCommand('RefreshEntities',{}) -- Explicit setup action.
local native_request=http_requests[1]; check(native_request~=nil)
local native_query
for _,request in ipairs(requests) do
    if request.consumer=='Dimmer' and request.command=='HA_GET_ENTITIES' then native_query=Wire:decode(request.params.JSON) end
end
check(native_query~=nil)
eq(table.concat(native_query.domains,','),'light,switch,event','Native light selector includes binary HA switches')
coordinator.ReceivedFromProxy(1,'HA_GET_ENTITIES',{JSON=Wire:encode({version=1,client_id='other-reader',request_id='typed',
    domains=Wire:newArray({'light'}),attribute_keys=Wire:newArray({'optional','flag','options','empty_list','empty_object'}),page_size=100})})
local other_request=http_requests[2]; check(other_request~=native_request)
local listing=Wire:newArray({states[legacy_id],states[dimmer_id]})
for i=1,51 do
    listing[#listing+1]=state('light.fixture_'..i,'off',{friendly_name='Light '..i,
        supported_color_modes=Wire:newArray({'brightness'}),supported_features=32,
        optional=Wire.null,flag=false,options=Wire:newArray({'one','two'}),empty_list=Wire:newArray(),empty_object=Wire:newObject()})
end
local function result(request,value)
    request.callback(request,{{code=200,body=Wire:encode(value)}},0,'')
end
result(other_request,listing); flush()
eq(#legacy.sent,legacy_messages,'Original consumer ignores foreign discovery replies')
check(dimmer.lists['Entity Selection'].values=='Manual Entity ID','Foreign list cannot satisfy Dimmer discovery')
local candidates=Wire:newArray()
for _,state in ipairs(listing) do if state.entity_id:match('^light%.') then candidates[#candidates+1]=state.entity_id end end
result(native_request,candidates)
local registry_cursor=1
while registry_cursor<=#websocket do
    local request=websocket[registry_cursor]; registry_cursor=registry_cursor+1
    if request.type=='config/entity_registry/get_entries' then
        check(#request.entity_ids<=50,'Metadata reads are bounded to matching candidates')
        local entries=Wire:newObject()
        for _,id in ipairs(request.entity_ids) do
            check(id:match('^light%.'),'No unrelated registry entry is requested')
            entries[id]={entity_id=id,id=id,platform='fixture',device_id='fixture',
                disabled_by=Wire.null,entity_category=Wire.null}
        end
        coordinator.ReceieveMessage(coordinator.Socket,Wire:encode({type='result',id=request.id,success=true,result=entries}))
    end
end
result(http_requests[3],listing)
flush()
eq(Wire:encode(coordinator.EntityTable),subscription_snapshot,'Discovery must not add subscriptions')
eq(counts('subscribe_trigger'),2)
eq(#legacy.sent,legacy_messages,'Original consumer ignores actual Dimmer discovery')
check(dimmer.lists['Entity Selection'].values:find('['..dimmer_id..']',1,true))
check(dimmer.lists['Entity Selection'].values:find('[light.fixture_51]',1,true),'All pages reach Dimmer')
eq(dimmer.env.Properties['Entity ID'],dimmer_id,'Discovery cannot replace a configured target')
local native_pages,other_pages=0,0
for _,message in ipairs(delivered) do
    if message.command=='HA_ENTITIES' then
        local reply=Wire:decode(message.params.JSON)
        if reply.client_id==native_query.client_id then
            eq(reply.request_id,native_query.request_id); native_pages=native_pages+1
            for _,item in ipairs(reply.entities) do
                if item.domain=='light' then
                    eq(tostring(item.attributes.supported_color_modes),'JSON array'); eq(type(item.attributes.supported_features),'number')
                end
            end
        elseif reply.client_id=='other-reader' then
            other_pages=other_pages+1
            local item=reply.entities[1]
            -- The first native light lacks these fields: absence stays absent.
            for _,candidate in ipairs(reply.entities) do
                if candidate.entity_id=='light.fixture_1' then item=candidate; break end
            end
            eq(item.attributes.optional,Wire.null); eq(item.attributes.flag,false)
            eq(tostring(item.attributes.empty_list),'JSON array'); eq(tostring(item.attributes.empty_object),'JSON object')
            eq(tostring(item.attributes.options),'JSON array')
        end
    end
end
eq(native_pages,2); eq(other_pages,1)

-- A stale/foreign typed reply cannot change an already completed Dimmer list.
local prior_list=dimmer.lists['Entity Selection'].values
coordinator.C4:SendToProxy(1,'HA_ENTITIES',{JSON=Wire:encode({version=1,client_id=native_query.client_id,request_id='retired',
    snapshot_id='retired',entities=Wire:newArray(),total=0,complete=true})}); flush()
eq(dimmer.lists['Entity Selection'].values,prior_list)

-- Actual native commands route through existing HA_CALL_SERVICE unchanged.
local services=counts('call_service')
dimmer.env.ReceivedFromProxy(5001,'SET_BRIGHTNESS_TARGET',{LIGHT_BRIGHTNESS_TARGET='75'})
eq(counts('call_service'),services+1)
local call=last('call_service'); eq(call.domain,'light'); eq(call.service,'turn_on')
eq(call.target.entity_id,dimmer_id); eq(call.service_data.brightness,191)
dimmer.env.ReceivedFromProxy(5001,'RAMP_TO_LEVEL',{LEVEL='50',RATE='1500'})
call=last('call_service'); eq(call.domain,'light'); eq(call.target.entity_id,dimmer_id)
eq(call.service_data.brightness,128); eq(call.service_data.transition,1.5)
local dimmer_notifications=#dimmer.sent
legacy.env.ReceivedFromProxy(1,'CLOSE',{})
call=last('call_service'); eq(call.domain,'switch'); eq(call.service,'turn_on'); eq(call.target.entity_id,legacy_id)
eq(#dimmer.sent,dimmer_notifications,'Legacy commands do not generate Dimmer notifications')
services=counts('call_service')
local legacy_before=#legacy.sent
states[dimmer_id]=state(dimmer_id,'off',attrs,1)
coordinator.ReceieveMessage(coordinator.Socket,Wire:encode({type='event',event={variables={trigger={to_state=states[dimmer_id]}}}})); flush()
eq(latest_native(dimmer,'LIGHT_BRIGHTNESS_CHANGED').params.LIGHT_BRIGHTNESS_CURRENT,0)
eq(#legacy.sent,legacy_before,'Foreign native Dimmer state does not affect original Switch')
eq(counts('call_service'),services,'State/native notifications cannot issue services')
local native_before=#dimmer.sent
states[legacy_id]=state(legacy_id,'on',nil,2)
coordinator.ReceieveMessage(coordinator.Socket,Wire:encode({type='event',event={variables={trigger={to_state=states[legacy_id]}}}})); flush()
eq(legacy.sent[#legacy.sent].command,'CLOSED'); eq(#dimmer.sent,native_before)
eq(counts('call_service'),services); eq(Wire:encode(coordinator.EntityTable),subscription_snapshot)
for _,message in ipairs(websocket) do
    check(message.type=='subscribe_trigger' or message.type=='call_service' or message.type=='config/entity_registry/get_entries','Discovery cannot dump states/registry over WebSocket')
end

-- A real Coordinator WebSocket loss must release a forwarded hold, even
-- though its HA_DEVICE wire remains bound. Original consumers ignore the
-- additive status notifications and retain their existing state/programming.
local fixture=ClientCodec:decode(read('tests/fixtures/gestures/v1.json'))
local function fixture_case(name)
    for _,item in ipairs(fixture.cases) do
        if item.name==name then return Wire:decode(ClientCodec:encode(item.state)) end
    end
    error('Missing fixture '..name)
end
local function physical(sequence,kind)
    local value=fixture_case(kind=='hold_start' and 'hold_start' or 'first_double_press')
    local a=value.attributes
    local stamp=string.format('2026-11-14T20:00:%02d.000Z',sequence+2)
    value.state,value.last_updated=stamp,stamp
    a.gesture_sequence=sequence; a.gesture_event_id=a.bridge_session_id..':'..sequence
    a.gesture_occurred_at=stamp
    if kind=='press' then a.gesture_id='press_1'; a.press_count=1 end
    return value
end
local function event(value)
    coordinator.ReceieveMessage(coordinator.Socket,Wire:encode({type='event',event={data={new_state=value}}}))
    flush()
end
local function output_count(command)
    local n=0
    for _,message in ipairs(dimmer.sent) do
        if message.binding==203 and message.command==command then n=n+1 end
    end
    return n
end
local function state_request_count()
    local n=0
    for _,request in ipairs(requests) do
        if request.consumer=='Dimmer' and request.command=='HA_GET_STATE' then n=n+1 end
    end
    return n
end
states[fixture.entity_id]=fixture_case('initial_snapshot')
local preserved_legacy_messages=#legacy.sent
local preserved_legacy_state=legacy.env.SWITCH_STATE
dimmer.env.Properties['Entity ID']=fixture.entity_id
dimmer.env.Properties['Operation Mode']='Control Connected C4 Light'
dimmer.env.OnPropertyChanged('Operation Mode'); flush()
eq(output_count('DO_PUSH'),0,'Initial aggregate snapshot cannot operate a connected load')
event(fixture_case('hold_start'))
eq(output_count('DO_PUSH'),1); eq(output_count('DO_RELEASE'),0)
local physical_events=0
for _,message in ipairs(dimmer.sent) do
    if message.binding==5001 and message.command=='BUTTON_ACTION' then physical_events=physical_events+1 end
end
coordinator.ConnectionStopped(coordinator.Socket); flush()
eq(coordinator.Connected,false); eq(output_count('DO_RELEASE'),1,'Actual socket loss must stop the held output')
coordinator.ConnectionStopped(coordinator.Socket); flush()
eq(output_count('DO_RELEASE'),1,'Duplicate socket loss cannot release twice')
states[fixture.entity_id]=physical(10,'hold_start')
event(states[fixture.entity_id])
eq(output_count('DO_PUSH'),1,'An offline HA event cannot restart a hold')
eq(output_count('DO_RELEASE'),1)
eq(#legacy.sent,preserved_legacy_messages,'Original Switch ignores additive connection-loss notifications')
eq(legacy.env.SWITCH_STATE,preserved_legacy_state)

-- Delay only the selected REST response so the real auth_ok/status path is
-- tested with a queued live event arriving before its reconnect snapshot.
deferred_entity=fixture.entity_id
local state_requests=state_request_count()
coordinator.ReceieveMessage(coordinator.Socket,Wire:encode({type='auth_ok',ha_version='test'})); flush()
eq(coordinator.Connected,true)
eq(state_request_count(),state_requests+1,'Reconnected consumer requests a fresh primary snapshot')
check(#deferred_responses>0)
eq(#legacy.sent,preserved_legacy_messages+1,'Coordinator also refreshes the original consumer through its unchanged state API')
eq(legacy.sent[#legacy.sent].command,'CLOSED')
local recovered_legacy_messages=#legacy.sent
event(states[fixture.entity_id])
eq(output_count('DO_PUSH'),1,'Queued live history cannot resume dimming before the snapshot')
eq(output_count('DO_RELEASE'),1)
for _,complete in ipairs(deferred_responses) do complete(); flush() end
eq(dimmer.env.Properties['Last Sequence'],'10','REST history establishes the reconnect sequence baseline')
eq(output_count('DO_PUSH'),1,'A historical hold snapshot cannot operate the connected load')
local after_snapshot=0
for _,message in ipairs(dimmer.sent) do
    if message.binding==5001 and message.command=='BUTTON_ACTION' then after_snapshot=after_snapshot+1 end
end
eq(after_snapshot,physical_events,'Loss/status/snapshot cannot fabricate physical programming events')
local fresh=physical(11,'press')
event(fresh)
eq(output_count('DO_PUSH'),2); eq(output_count('DO_CLICK'),1)
event(fresh)
eq(output_count('DO_PUSH'),2); eq(output_count('DO_CLICK'),1,'Recovered occurrence cannot click twice')
local after_fresh=0
for _,message in ipairs(dimmer.sent) do
    if message.binding==5001 and message.command=='BUTTON_ACTION' then after_fresh=after_fresh+1 end
end
eq(after_fresh,physical_events+1,'First fresh occurrence produces exactly one programming event')
eq(#legacy.sent,recovered_legacy_messages,'Original Switch ignores foreign aggregate snapshots and events')
eq(legacy.env.SWITCH_STATE,preserved_legacy_state)
eq(legacy.env.EntityID,legacy_id); check(coordinator.EntityTable[legacy_id]~=nil)
local recovered_services=counts('call_service')
legacy.env.ReceivedFromProxy(1,'OPEN',{})
eq(counts('call_service'),recovered_services+1,'Original Switch commands still route after reconnect')
call=last('call_service')
eq(call.domain,'switch'); eq(call.service,'turn_off'); eq(call.target.entity_id,legacy_id)

-- Model the live report: Coordinator is online but a child missed recovery.
-- The existing provider watchdog must restore it without pressing Connect.
dimmer.env.ReceivedFromProxy(999,'HA_CONNECTION_STATUS',{CONNECTED='false'})
eq(dimmer.env.Properties.Status,'Home Assistant disconnected')
deferred_entity=nil
coordinator.ONE_SECOND=1000
coordinator.CancelTimer=function() end
coordinator.SetTimer=function() end
local snapshots_before=state_request_count()
local pushes_before,clicks_before=output_count('DO_PUSH'),output_count('DO_CLICK')
coordinator.Watchdog(); flush()
eq(state_request_count(),snapshots_before+1,'Watchdog status heals a missed recovery notification')
check(dimmer.env.Properties.Status~='Home Assistant disconnected')
eq(output_count('DO_PUSH'),pushes_before); eq(output_count('DO_CLICK'),clicks_before,'Recovery cannot replay the last press')
snapshots_before=state_request_count()
coordinator.Watchdog(); flush()
eq(state_request_count(),snapshots_before,'Repeated online status does not refetch state')
dimmer.env.OnDriverDestroyed()
if legacy.env.OnDriverDestroyed then legacy.env.OnDriverDestroyed() end
print('Dimmer/Coordinator integration: original Switch + native Dimmer, '..assertions..' assertions passed')
