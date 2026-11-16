-- Load every runtime module from the three built archives, not the source tree.
-- Only Director HTTP/WebSocket boundaries are simulated; no network or load calls.
local coordinator_root,switch_root,dimmer_root,fixture_path=arg[1],arg[2],arg[3],arg[4]
local assertions=0
local function check(value,message) assertions=assertions+1; assert(value,message or ('assertion '..assertions)) end
local function eq(actual,expected,message) check(actual==expected,(message or '')..' expected '..tostring(expected)..', got '..tostring(actual)) end
local function read(path) local file=assert(io.open(path,'r')); local raw=file:read('*a'); file:close(); return raw end
local function execute(path,env)
    local chunk,err
    if setfenv then chunk,err=loadstring(read(path),'@'..path); if chunk then setfenv(chunk,env) end
    else chunk,err=load(read(path),'@'..path,'t',env) end
    assert(chunk,err); return chunk()
end
local function namespace(root)
    local env=setmetatable({},{__index=_G}); env._G=env
    env.table={}; for key,value in pairs(table) do env.table[key]=value end
    env.print=function(...)
        local words={}; for i=1,select('#',...) do words[#words+1]=tostring(select(i,...)) end
        check(not table.concat(words,' '):lower():find('error',1,true),'Driver callback error: '..table.concat(words,' '))
    end
    local cache={}
    env.require=function(name)
        if cache[name]~=nil then return cache[name] end
        if name=='module.websocket' then cache[name]={}; return cache[name] end
        local path=name:gsub('Control4%-HA%-Base%.','Control4-HA-Base/'):gsub('%.','/')..'.lua'
        local value=execute(root..'/'..path,env)
        cache[name]=value==nil and true or value
        return cache[name]
    end
    return env
end
local coordinator=namespace(coordinator_root)
local JSON=coordinator.require('module.json')
local wire=JSON:new({strictTypes=true,null={}})
local fixture=wire:decode(read(fixture_path))
eq(fixture.fixture_version,1); eq(fixture.producer,'ha_gesture_bridge')
local states={}; for _,state in ipairs(fixture.states) do states[state.entity_id]=state end
check(fixture.catalog_rows>50,'Fixture must cross the native page boundary')
local exported=states[fixture.catalog_entity_id].attributes
eq(#exported.catalog_entities,fixture.catalog_rows)
eq(exported.catalog_contract_version,'1.0')
local requests,replies,children,websocket={},{},{},{}
local tick=100000
coordinator.Properties={['Home Assistant URL']='catalog-test.invalid',['Long Lived Access Token']='fake-not-a-token'}
coordinator.JSON=JSON
coordinator.C4={}
function coordinator.C4:GetTime() return tick end
function coordinator.C4:DebugLog() end
function coordinator.C4:ParseXml() return {ChildNodes={}} end
function coordinator.C4:SetTimer() return {Cancel=function() end} end
function coordinator.C4:SendToProxy(binding,command,params)
    eq(binding,1); check(command=='HA_ENTITIES' or command=='RECEIEVE_STATE' or command=='RECEIEVE_EVENT' or command=='HA_CONNECTION_STATUS' or command=='HA_SUBSCRIPTION_STATUS')
    if command=='HA_ENTITIES' then check(#params.JSON<=32768,'Discovery must respect proxy byte limit') end
    replies[#replies+1]={command=command,params=params}
end
function coordinator.C4:url()
    local transfer={}
    function transfer:OnHeaders(callback) self.headers_callback=callback; return self end
    function transfer:OnDone(callback) self.callback=callback; return self end
    function transfer:SetOptions() return self end
    function transfer:Get(url,headers)
        local id=url:match('^http://catalog%-test%.invalid/api/states/(.+)$')
        check(id and states[id],'Only selected primary states may use legacy REST')
        eq(headers.Authorization,'Bearer fake-not-a-token')
        self.callback(self,{{code=200,body=wire:encode(states[id])}},0,''); return self
    end
    function transfer:Post(url,data,headers)
        eq(url,'http://catalog-test.invalid/api/template')
        local variables=wire:decode(data).variables
        local ids,domains={},{}
        for _,id in ipairs(variables.entity_ids or {}) do ids[id]=true end
        for _,domain in ipairs(variables.domains or {}) do domains[domain]=true end
        check(next(ids) or next(domains),'Never request an unfiltered snapshot')
        local projected=wire:newArray()
        for _,state in ipairs(fixture.states) do
            if (not next(ids) or ids[state.entity_id]) and (not next(domains) or domains[state.entity_id:match('^([^%.]+)')]) then
                local modes=state.attributes.supported_color_modes or {}
                local permitted=variables.selector~='switch' or not state.entity_id:match('^light%.') or
                    (#modes==1 and modes[1]=='onoff')
                if permitted then
                    if variables.candidates_only then projected[#projected+1]=state.entity_id
                    else
                        local attributes=wire:newObject({friendly_name=state.attributes.friendly_name})
                        for _,key in ipairs(variables.attribute_keys) do attributes[key]=state.attributes[key] end
                        projected[#projected+1]={entity_id=state.entity_id,state=state.state,attributes=attributes}
                    end
                end
            end
        end
        self.callback(self,{{code=200,body=wire:encode(projected)}},0,''); return self
    end
    return transfer
end
execute(coordinator_root..'/driver.lua',coordinator)
coordinator.Connected=true
coordinator.Socket={Send=function(_,raw)
    local message=wire:decode(raw)
    check(message.type~='call_service','Discovery must never operate loads')
    websocket[#websocket+1]=message
    if message.type=='subscribe_trigger' then
        coordinator.ReceieveMessage(coordinator.Socket,wire:encode({type='result',id=message.id,success=true,result=wire.null}))
    end
end}
local function defaults(path)
    local properties={}
    for block in read(path):gmatch('<property>(.-)</property>') do
        local name=block:match('<name>(.-)</name>')
        if name then properties[name]=block:match('<default>(.-)</default>') or '' end
    end
    return properties
end
local function child(name,root,primary)
    local item={env=namespace(root),lists={},timers={},events=0,primary=primary,name=name}
    local env=item.env
    env.Properties=defaults(root..'/driver.xml')
    env.Properties['Entity ID']=primary; env.Properties['Debug Mode']='Off'
    env.Properties['Discovery Catalog Entity ID']=fixture.catalog_entity_id
    env.Variables={}; env.PersistData={}; env.C4={}
    function env.C4:GetDeviceID() return name=='Switch' and 900 or 901 end
    function env.C4:GetDriverConfigInfo() return name=='Switch' and '107' or '1' end
    function env.C4:GetTime() return tick end
    function env.C4:DebugLog() end
    function env.C4:ParseXml() return {ChildNodes={}} end
    function env.C4:AddVariable() end
    function env.C4:SetVariable() end
    function env.C4:SetPropertyAttribs() end
    function env.C4:AddEvent() return true end
    function env.C4:FireEventByID() item.events=item.events+1 end
    function env.C4:UpdateProperty(key,value) env.Properties[key]=value end
    function env.C4:UpdatePropertyList(key,values,selected) item.lists[key]={values=values,selected=selected} end
    function env.C4:SetTimer(ms,callback)
        local timer={callback=callback}; function timer:Cancel() self.cancelled=true end
        item.timers[#item.timers+1]=timer; return timer
    end
    function env.C4:SendToProxy(binding,command,params)
        if binding~=999 then return end
        check(command=='HA_GET_STATE' or command=='HA_GET_ENTITIES' or command=='HA_RELEASE_ENTITIES' or command=='HA_RELEASE_STATES','Read-only setup sent a command')
        if command=='HA_GET_STATE' then eq(params.entity,env.Properties['Entity ID'],'Catalog must not create a secondary subscription') end
        requests[#requests+1]={consumer=name,command=command,params=params}
        coordinator.ReceivedFromProxy(1,command,params)
    end
    children[#children+1]=item
    local script=read(root..'/driver.xml'):match('<script[^>]+file="([^"]+)"')
    check(script~=nil); execute(root..'/'..script,env)
    env.OnDriverInit(); env.OnDriverLateInit()
    return item
end
local switch=child('Switch',switch_root,fixture.switch_entity_id)
local dimmer=child('Dimmer',dimmer_root,fixture.dimmer_entity_id)
for _,request in ipairs(requests) do eq(request.command,'HA_GET_STATE','Startup reads only selected entities') end
switch.env.ExecuteCommand('RefreshEntities',{})
dimmer.env.ExecuteCommand('RefreshEntities',{})
local pending=1
local catalog_replies=0
local function drain()
    local loops=0
    while pending<=#websocket or #replies>0 do
        loops=loops+1; check(loops<100,'Pagination/replies must terminate')
        while pending<=#websocket do
            local message=websocket[pending]; pending=pending+1
            if message.type=='config/entity_registry/get_entries' then
                check(#message.entity_ids<=50)
                local entries=wire:newObject()
                for _,id in ipairs(message.entity_ids) do
                    check(states[id]~=nil,'Only known candidate metadata can be requested')
                    entries[id]={entity_id=id,id=id,platform='fixture',device_id='fixture',
                        disabled_by=wire.null,entity_category=wire.null}
                end
                coordinator.ReceieveMessage(coordinator.Socket,wire:encode({type='result',id=message.id,success=true,result=entries}))
            else check(message.type=='subscribe_trigger','Discovery cannot request unfiltered states or registry') end
        end
        while #replies>0 do
            local reply=table.remove(replies,1)
            if reply.command=='HA_ENTITIES' then
                local envelope=wire:decode(reply.params.JSON)
                for _,row in ipairs(envelope.entities or {}) do
                    if row.entity_id==fixture.catalog_entity_id then
                        catalog_replies=catalog_replies+1
                        eq(row.attributes.catalog_names_version,1)
                        eq(row.attributes.catalog_names_total,fixture.catalog_rows,'Names count is never truncated')
                        eq(row.attributes.catalog_entities,nil,'Names reads omit the oversized full catalog')
                        local page=row.attributes.catalog_names_page_001
                        if page then
                            eq(tostring(page),'JSON array'); eq(#page,fixture.catalog_rows)
                            for _,item in ipairs(page) do
                                eq(item.attributes,nil,'Names cannot supply capabilities')
                                eq(item.state,nil,'Names cannot supply load state')
                            end
                        end
                    end
                end
            end
            for _,consumer in ipairs(children) do consumer.env.ReceivedFromProxy(999,reply.command,reply.params) end
        end
    end
end
drain()
eq(catalog_replies,4,'Each actual consumer receives a correlated manifest and names page')
local function selected_list(consumer) return consumer.lists['Entity Selection'].values end
for _,consumer in ipairs(children) do
    eq(consumer.env.Properties['Entity ID'],consumer.primary,'Discovery cannot replace selection')
    eq(consumer.events,0,'Catalog snapshots must never become gestures')
    check(selected_list(consumer):find('Fixture Office',1,true),'Catalog area must enrich packaged picker')
    if consumer.name=='Switch' then
        check(selected_list(consumer):find('Catalog Switch 29',1,true),'Final switch entry must survive intact')
        for index=1,30 do
            check(selected_list(consumer):find(string.format('[switch.catalog_switch_%02d]',index),1,true),'Every eligible switch survives')
        end
    else
        for index=1,30 do
            check(selected_list(consumer):find(string.format('[switch.catalog_switch_%02d]',index),1,true),'Dimmer offers every eligible binary switch')
        end
    end
end
check(selected_list(dimmer):find('Catalog Light 29',1,true),'Final dimmer page must survive intact')
for index=1,30 do
    check(selected_list(dimmer):find(string.format('[light.catalog_light_%02d]',index),1,true),'Every eligible light survives pagination')
end
local primary_count=0
for id in pairs(coordinator.EntityTable) do
    check(id==fixture.switch_entity_id or id==fixture.dimmer_entity_id,'Only primaries belong to EntityTable')
    primary_count=primary_count+1
end
eq(primary_count,2)
-- Remove the optional companion while both configured native targets remain.
local without=wire:newArray()
for _,state in ipairs(fixture.states) do
    if state.entity_id~=fixture.catalog_entity_id and not state.attributes.bridge_contract_version then without[#without+1]=state end
end
fixture.states=without
for _,consumer in ipairs(children) do consumer.env.ExecuteCommand('RefreshEntities',{}) end
drain()
for _,consumer in ipairs(children) do
    eq(consumer.env.Properties['Entity ID'],consumer.primary)
    eq(consumer.events,0)
    check(selected_list(consumer):find('['..consumer.primary..']',1,true),'Native choices survive companion removal')
    check(not selected_list(consumer):find('Fixture Office',1,true),'Removed catalog must not leave enrichment')
    consumer.env.OnDriverDestroyed()
end
print('packaged catalog checks passed: '..assertions..' assertions, actual HA export, native pagination, no secondary subscriptions')
