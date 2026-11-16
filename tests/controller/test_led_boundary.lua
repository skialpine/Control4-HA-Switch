-- Actual HA EventEntity metadata -> native Dimmer commands -> HA service wire.
local Discovery=require('module.discovery'); local Codec=Discovery.new_codec()
local function read(path)
    local file=assert(io.open(path,'r')); local value=Codec:decode(file:read('*a')); file:close(); return value
end
local initial=read(assert(arg[1],'Initial HA state path is required'))
local services,feedback,fired={},{},0
local ready=false
Properties={['Entity ID']=initial.entity_id,['Operation Mode']='Programming Events Only',
    ['Entity Selection']='Manual Entity ID'}
PersistData={}; C4={}
function C4:GetDeviceID() return 321 end
function C4:GetTime() return 100000 end
function C4:UpdateProperty(name,value) Properties[name]=value end
function C4:UpdatePropertyList(name,values,selected) Properties[name]=selected end
function C4:SetTimer() return {Cancel=function() end} end
function C4:AddEvent() assert(ready); return true end
function C4:FireEventByID() fired=fired+1 end
function C4:SendToProxy(binding,command,params)
    if binding==999 and command=='HA_CALL_SERVICE' then
        local request=Codec:decode(params.JSON)
        assert(request.domain=='ha_gesture_bridge' and request.service=='set_led')
        assert(request.service_data.entity_id==initial.entity_id)
        assert(request.service_data.led_id=='status')
        services[#services+1]=request
    elseif binding==5001 and command=='BUTTON_INFO' then
        feedback[#feedback+1]=params
    end
end
local function receive(state,event)
    if event then return ReceivedFromProxy(999,'RECEIEVE_EVENT',{data=Codec:encode({event={data={new_state=state}}})}) end
    return ReceivedFromProxy(999,'RECEIEVE_STATE',{response=Codec:encode(state)})
end
dofile('light/driver.lua'); OnDriverInit(); ready=true; OnDriverLateInit()
receive(initial)
assert(#feedback>0 and feedback[#feedback].BUTTON_ID==2)
assert(feedback[#feedback].CURRENT_COLOR=='FFFFFF')
assert(ExecuteCommand('Set LED Current Color',{Button='Toggle',Color='00FF00'}))
assert(ExecuteCommand('Set LED Brightness',{Button='Toggle',Brightness='58'}))
assert(ExecuteCommand('Set LED Behavior',{Button='Toggle',Behavior='Always Off'}))
assert(#services==3)
assert(services[1].service_data.color=='00FF00' and services[1].service_data.brightness==nil)
assert(services[1].service_data.behavior==nil,'A color request changed LED behavior')
assert(services[2].service_data.color==nil and services[2].service_data.brightness==58)
assert(services[2].service_data.behavior==nil,'A brightness request changed LED behavior')
assert(services[3].service_data.behavior=='always_off' and services[3].service_data.color==nil)
assert(feedback[#feedback].CURRENT_COLOR=='FFFFFF','Queued request fabricated hardware confirmation')
assert(fired==0,'LED requests replayed a physical gesture')
local output=assert(io.open(assert(arg[2],'Service output path is required'),'w'))
output:write(Codec:encode(Codec:newArray(services))); output:close()
if arg[3] then
    local confirmed=read(arg[3])
    assert(confirmed.attributes.bridge_leds[1].color=='000000')
    assert(confirmed.attributes.bridge_leds[1].behavior=='always_off')
    assert(confirmed.attributes.bridge_leds[1].brightness==60,'HA nearest brightness mapping was not confirmed')
    receive(confirmed,true)
    assert(feedback[#feedback].CURRENT_COLOR=='000000','Confirmed HA feedback did not reach native proxy')
    assert(#services==3,'Observing confirmed LED state caused another hardware write')
    assert(fired==0,'LED feedback replayed a physical gesture')
end
print('Actual HA/Dimmer LED boundary passed')
