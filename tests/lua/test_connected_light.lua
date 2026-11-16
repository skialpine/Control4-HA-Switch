local Target=require('module.connected_light')
local assertions=0
local function eq(a,b) assertions=assertions+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local c4,values,providers,proxies,watched={},{},{[203]=20},{[20]={21}},{}
local changes,sends=0,0
function c4:GetDeviceID() return 10 end
function c4:GetProxyDevices() return 11 end
function c4:GetProxyDevicesById(id)
    if unpack then return unpack(proxies[id] or {}) end
    return table.unpack(proxies[id] or {})
end
function c4:GetBoundProviderDevice(_,binding) return providers[binding] end
function c4:GetVariable(id,variable) return values[id] and values[id][variable] end
function c4:RegisterVariableListener(id,variable) watched[id..':'..variable]=true end
function c4:UnregisterVariableListener(id,variable) watched[id..':'..variable]=nil end
function c4:SendToDevice() sends=sends+1 end
local target=Target.new(c4,function() changes=changes+1 end)
eq(target:refresh(false,'Top').ready,false); eq(next(watched),nil)
eq(target:refresh(true,'Top').ready,false) -- The target may initialize later.
values[21]={[1000]='1',[1001]='27',[6661]='<DynamicCapabilities><dimmer>True</dimmer></DynamicCapabilities>'}
eq(target:refresh(true,'Top').ready,true); eq(target:state().level,27)
eq(target:state().dimmer,true); eq(watched['21:1001'],true)
eq(target:observe(21,1001,'42'),true); eq(changes,1); eq(target:state().level,42)
eq(target:observe(22,1001,'99'),false); eq(target:state().level,42)
eq(target:observe(21,1001,'NaN'),true); eq(target:state().ready,false)
eq(target:send('ON'),false); eq(sends,0)
target:observe(21,1000,'0')
eq(target:state().level,0); eq(target:state().ready,true)
eq(target:send('ON'),true); eq(sends,1); eq(target:state().level,0)
values[22]={[1000]='0',[1001]='50',[6661]='<DynamicCapabilities><dimmer>False</dimmer></DynamicCapabilities>'}
proxies[20]={21,22}
eq(target:refresh(true,'Top').ready,false); eq(next(watched),nil) -- Never guess among multiple proxies.
proxies[20]={22}
eq(target:refresh(true,'Top').dimmer,false)
target:observe(22,1000,'1'); eq(target:state().level,100) -- Explicit binary capability wins.
target:observe(22,1000,'unknown'); eq(target:state().ready,false)
providers[203]=10; eq(target:refresh(true,'Top').ready,false); eq(next(watched),nil)
providers[203]=11; values[11]={[1000]='1',[1001]='88'}
eq(target:refresh(true,'Top').ready,false) -- Own proxy is also excluded.
providers[203]=22; proxies[22]={22}
eq(target:refresh(true,'Top').id,22) -- A bound provider can already be a proxy.
function c4:SendToDevice() return false end
local ok,reason=target:send('ON'); eq(ok,false); eq(reason,'C4 target command failed')
target:reset(); eq(next(watched),nil)
eq(target:refresh(true,'Invalid link').ready,false)

-- Native color capabilities need actual feedback; writes never invent it.
function c4:SendToDevice(id,command,params)
    sends=sends+1; c4.last={id=id,command=command,params=params}
end
local color_caps='<DynamicCapabilities><dimmer>True</dimmer><supports_color>True</supports_color>'
    ..'<supports_color_correlated_temperature>True</supports_color_correlated_temperature>'
    ..'<color_correlated_temperature_min>2700</color_correlated_temperature_min>'
    ..'<color_correlated_temperature_max>6500</color_correlated_temperature_max>'
    ..'<color_rate_behavior>2</color_rate_behavior><color_rate_min>0</color_rate_min>'
    ..'<color_rate_max>60000</color_rate_max><supports_color_stop>True</supports_color_stop></DynamicCapabilities>'
values[22]={[1000]='1',[1001]='50',[6661]=color_caps}
local function feedback(variable,value) values[22][variable]=value; target:observe(22,variable,value) end
eq(target:refresh(true,'Top').full_color,false)
eq(watched['22:1200'],true) -- Late color can arrive without another capability change.
feedback(1200,'0.2,0.3,0')
eq(target:state().full_color,true); eq(target:state().cct,true)
eq(target:state().cct_min,2700); eq(target:state().cct_max,6500)
eq(target:send('SET_COLOR_TARGET',{LIGHT_COLOR_TARGET_X='0.4',LIGHT_COLOR_TARGET_Y='0.3',
    LIGHT_COLOR_TARGET_MODE=0,LIGHT_COLOR_TARGET_COLOR_RATE=1250,
    LIGHT_COLOR_TARGET_PRESET_ID=1,LIGHT_COLOR_TARGET_PRESET_ORIGIN=1}),true)
eq(c4.last.command,'SET_COLOR_TARGET'); eq(c4.last.params.LIGHT_COLOR_TARGET_RATE,1250)
eq(c4.last.params.LIGHT_COLOR_TARGET_PRESET_ID,nil) -- This proxy's local IDs are not the target's.
eq(target:state().color.x,0.2)
eq(target:send('SET_COLOR_TARGET',{LIGHT_COLOR_TARGET_X=0.4,LIGHT_COLOR_TARGET_Y=0.3,
    LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE=-1,
    LIGHT_COLOR_TARGET_PRESET_ID=0,LIGHT_COLOR_TARGET_PRESET_ORIGIN=0}),true)
eq(c4.last.params.LIGHT_COLOR_TARGET_PRESET_ID,nil)
eq(target:send('SET_COLOR_TARGET',{LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE=3000,
    LIGHT_COLOR_TARGET_RATE=500,LIGHT_COLOR_TARGET_PRESET_ID=3,LIGHT_COLOR_TARGET_PRESET_ORIGIN=2}),true)
eq(c4.last.params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE,3000)
eq(c4.last.params.LIGHT_COLOR_TARGET_PRESET_ID,3); eq(c4.last.params.LIGHT_COLOR_TARGET_PRESET_ORIGIN,2)
eq(target:send('SET_COLOR_STOP',{}),true); eq(c4.last.command,'SET_COLOR_STOP')
local before=sends
for _,params in ipairs({{},
    {LIGHT_COLOR_TARGET_X='NaN',LIGHT_COLOR_TARGET_Y=0.3},
    {LIGHT_COLOR_TARGET_X=0.8,LIGHT_COLOR_TARGET_Y=0.8},
    {LIGHT_COLOR_TARGET_X=0.2,LIGHT_COLOR_TARGET_Y=0.3,LIGHT_COLOR_TARGET_MODE=2},
    {LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE=2600},
    {LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE=6600},
    {LIGHT_COLOR_TARGET_X=0.2,LIGHT_COLOR_TARGET_Y=0.3,RATE=60001},
    {LIGHT_COLOR_TARGET_X=0.2,LIGHT_COLOR_TARGET_Y=0.3,RATE=-1},
    {LIGHT_COLOR_TARGET_X=0.2,LIGHT_COLOR_TARGET_Y=0.3,LIGHT_COLOR_TARGET_COLOR_RATE=false},
    {LIGHT_COLOR_TARGET_X=0.2,LIGHT_COLOR_TARGET_Y=0.3,LIGHT_COLOR_TARGET_PRESET_ID=0,LIGHT_COLOR_TARGET_PRESET_ORIGIN=2}}) do
    eq(target:send('SET_COLOR_TARGET',params),false)
end
eq(sends,before)
feedback(1200,'0.4,0.4,1')
eq(target:state().color.mode,1)
feedback(6661,color_caps:gsub('<supports_color>True','<supports_color>False'))
eq(target:state().full_color,false); eq(target:state().cct,true)
eq(target:send('SET_COLOR_TARGET',{LIGHT_COLOR_TARGET_X=0.2,LIGHT_COLOR_TARGET_Y=0.3}),false)
eq(target:send('SET_COLOR_TARGET',{LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE=4000}),true)
feedback(1200,'NaN,0.4,1')
eq(target:state().color,nil); eq(target:state().cct,false)
feedback(1200,'0.4,0.4,1')
eq(target:state().cct,true)
feedback(6661,color_caps:gsub('<color_correlated_temperature_max>6500','<color_correlated_temperature_max>2000'))
eq(target:state().cct,false)
eq(target:send('SET_COLOR_STOP'),false)
target:reset(); eq(watched['22:1200'],nil)

function c4:RegisterVariableListener(id,variable)
    watched[id..':'..variable]=true
    target:reset() -- Simulate mode change/destruction during the initial callback.
end
eq(target:refresh(true,'Top').ready,false); eq(next(watched),nil)
print('Connected C4 light adapter: '..assertions..' assertions passed')
