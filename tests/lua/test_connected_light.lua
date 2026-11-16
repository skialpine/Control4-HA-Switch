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
function c4:RegisterVariableListener(id,variable)
    watched[id..':'..variable]=true
    target:reset() -- Simulate mode change/destruction during the initial callback.
end
eq(target:refresh(true,'Top').ready,false); eq(next(watched),nil)
print('Connected C4 light adapter: '..assertions..' assertions passed')
