-- Real coordinator entry points -> real discovery client -> real base/proof UI.
-- Only Director/WebSocket boundaries are simulated. Run from the switch root.
local root = arg[1] or "../Control4-HA-Coordinator"
local function isolated(path, environment)
    local chunk
    if setfenv then chunk=assert(loadfile(path)); setfenv(chunk,environment)
    else chunk=assert(loadfile(path,"t",environment)) end
    return chunk()
end
-- Each real driver has its own Lua globals; the legacy codec stores OBJDEF there.
local codec_environment=setmetatable({}, {__index=_G})
local ServerJSON=isolated(root.."/module/json.lua",codec_environment)
local Server=assert(loadfile(root.."/module/discovery.lua"))()
local wire=ServerJSON:new({strictTypes=true,null={}})
local ha_requests, responses, proxy_requests = {}, {}, {}
local coordinator=setmetatable({}, {__index=_G})
coordinator.JSON=ServerJSON
coordinator.Properties={['Home Assistant URL']='family-test.invalid:8123',['Long Lived Access Token']='fake-controller-only-token'}
coordinator.require=function(name)
    if name=="module.websocket" then return {} end
    if name=="module.json" then return ServerJSON end
    if name=="module.discovery" then return Server end
    if name=="module.state_projection" then return assert(loadfile(root.."/module/state_projection.lua"))() end
    error("Unexpected coordinator dependency "..name)
end
coordinator.C4={
    GetTime=function() return 100000 end,
    DebugLog=function() end,
    SendToProxy=function(_,binding,command,params)
        assert(binding==1 and command=="HA_ENTITIES")
        assert(not params.JSON:find('fake-controller-only-token',1,true))
        responses[#responses+1]=params
    end,
}
isolated(root.."/driver.lua",coordinator)
coordinator.Connected=true
coordinator.EntityTable={['switch.original']='existing-consumer'}
coordinator.Socket={Send=function() error("Discovery must not make WebSocket requests") end}
function coordinator.C4:url()
    local transfer={}
    function transfer:OnHeaders() return self end
    function transfer:OnDone(fn) self.done=fn; return self end
    function transfer:SetOptions() return self end
    function transfer:Post(url,data)
        local query=wire:decode(data); assert(#query.variables.domains==14)
        ha_requests[#ha_requests+1]=self; return self
    end
    return transfer
end

Properties={Domains="switch,input_boolean,light,cover,climate,select,button,lock,sensor,binary_sensor,fan,alarm_control_panel,media_player,valve",['Attribute Keys']='options,flag,optional,empty_list,empty_object,supported_color_modes',
    ['Entity Selection']='Manual Entity ID',['Selected Entity ID']='switch.manual',
    ['Entity Count']='0',['Driver Version']='',['Debug Mode']='Off'}
local property_list
C4={}
function C4:GetDeviceID() return 52 end
function C4:GetDriverConfigInfo() return "1" end
function C4:AddVariable() end
function C4:SetVariable() end
function C4:UpdateProperty(name,value) Properties[name]=value end
function C4:UpdatePropertyList(name,values,selected)
    property_list=values; Properties[name]=selected
end
function C4:SetTimer()
    return {Cancel=function() end}
end
function C4:SendToProxy(binding,command,params)
    assert(binding==999 and command=="HA_GET_ENTITIES")
    proxy_requests[#proxy_requests+1]=params
    coordinator.ReceivedFromProxy(1,command,params)
end
package.preload.commands=function() return dofile("tools/discovery-proof/commands.lua") end
dofile("Control4-HA-Base/driver.lua")
OnDriverInit(); OnDriverLateInit()
assert(#ha_requests==1 and #responses==0)

local states=wire:newArray()
local domains={'switch','input_boolean','light','cover','climate','select','button','lock','sensor','binary_sensor','fan','alarm_control_panel','media_player','valve'}
for i=1,64 do
    local domain=domains[(i-1)%#domains+1]
    states[#states+1]={entity_id=domain..'.item_'..i,state=i==4 and 'unavailable' or 'on',
        attributes=wire:newObject({friendly_name='Family, '..i,flag=false,optional=wire.null,
            empty_list=wire:newArray(),empty_object=wire:newObject(),
            options=domain=='select' and wire:newArray({'one','two'}) or nil,
            supported_color_modes=domain=='light' and wire:newArray({'onoff'}) or nil,
            private='must-not-project'})}
end
ha_requests[1].done(ha_requests[1],{{code=200,body=wire:encode(states)}},0)
local index=1
while responses[index] do
    local payload=responses[index]
    local decoded=wire:decode(payload.JSON)
    assert(decoded.snapshot_id and decoded.total==64)
    for _,item in ipairs(decoded.entities) do
        assert(item.attributes.private==nil and item.attributes.flag==false)
        assert(item.attributes.optional==wire.null)
        assert(tostring(item.attributes.empty_list)=='JSON array')
        assert(tostring(item.attributes.empty_object)=='JSON object')
    end
    ReceivedFromProxy(999,'HA_ENTITIES',payload)
    index=index+1
    assert(index<10, 'Pagination must terminate')
end
assert(#proxy_requests==2 and #ha_requests==1 and #responses==2)
assert(Properties['Entity Count']=='64' and Properties['Selected Entity ID']=='switch.manual')
assert(property_list:find('[light.item_3]',1,true), 'On/off-only light must remain discoverable')
assert(property_list:find('[select.item_6]',1,true) and property_list:find('[button.item_7]',1,true))
assert(property_list:find('[valve.item_14]',1,true), 'New domains need no coordinator-specific handler')
assert(coordinator.EntityTable['switch.original']=='existing-consumer' and next(coordinator.EntityTable)=='switch.original')
OnDriverDestroyed()
print('Family discovery integration passed: actual driver entry points, 64 entities, 14 domains, 2 pages, one HA read, no subscriptions')
