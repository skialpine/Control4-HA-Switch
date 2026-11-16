-- A bound Light V2 target, using only its proxy variables and native commands.
-- No HA lookup, project-wide discovery, inferred brightness or optimistic state.
local M={}
local Target={}; Target.__index=Target
local VARIABLES={1000,1001,1002,1003,1006,6661}
local BINDINGS={Top=203,Bottom=204,Toggle=205}
local function bool(value)
    if type(value)=='string' then value=value:match('^%s*(.-)%s*$'):lower() end
    if value==true or value==1 or value=='1' or value=='true' then return true end
    if value==false or value==0 or value=='0' or value=='false' then return false end
end
local function number(value,max)
    if type(value)~='string' and type(value)~='number' then return nil end
    value=tonumber(value)
    if value and value==value and value>=0 and value<=max then return value end
end
local function flag(xml,key)
    if type(xml)~='string' or #xml>65536 then return nil end
    return bool(xml:match('<'..key..'>(.-)</'..key..'>'))
end
function M.new(c4,changed)
    return setmetatable({c4=c4,changed=changed,values={},watched={},reason='No connected C4 light'},Target)
end
function Target:read(device,variable)
    local fn=self.c4.GetDeviceVariable or self.c4.GetVariable
    if type(fn)~='function' then return nil end
    local ok,value=pcall(fn,self.c4,device,variable)
    if ok then return value end
end
function Target:reset()
    local device=self.device
    self.generation=(self.generation or 0)+1
    self.device=nil; self.name=nil; self.values={}
    for variable in pairs(self.watched) do
        if type(self.c4.UnregisterVariableListener)=='function' then
            pcall(self.c4.UnregisterVariableListener,self.c4,device,variable)
        end
    end
    self.watched={}
end
function Target:refresh(enabled,link)
    if not enabled then self:reset(); self.reason='No connected C4 light'; return self:state() end
    self.link=link or 'Top'
    local provider
    local own=self.c4:GetDeviceID()
    if enabled and BINDINGS[link or 'Top'] and type(self.c4.GetBoundProviderDevice)=='function' then
        local ok,id=pcall(self.c4.GetBoundProviderDevice,self.c4,own,BINDINGS[link or 'Top'])
        if ok then provider=number(id,2147483647) end
    end
    local candidates,seen={},{}
    local function add(id)
        id=number(id,2147483647)
        if id and id>0 and id~=own and not seen[id] then
            seen[id]=true
            -- Light State (1000) distinguishes a usable light proxy from
            -- its protocol device. A binary light need not have level 1001.
            if bool(self:read(id,1000))~=nil then candidates[#candidates+1]=id end
        end
    end
    if provider and provider>0 and provider~=own then
        if type(self.c4.GetProxyDevicesById)=='function' then
            local ids={pcall(self.c4.GetProxyDevicesById,self.c4,provider)}
            if ids[1] then for index=2,#ids do add(ids[index]) end end
        end
        -- Some providers are already proxy IDs.
        if #candidates==0 then add(provider) end
    end
    if type(self.c4.GetProxyDevices)=='function' then
        local own_ids={pcall(self.c4.GetProxyDevices,self.c4)}
        for index=2,#own_ids do
            local id=own_ids[index]
            for index=#candidates,1,-1 do if tonumber(id)==candidates[index] then table.remove(candidates,index) end end
        end
    end
    local device=#candidates==1 and candidates[1] or nil
    self.reason=#candidates>1 and 'Connected driver has multiple lights; choose a single light target'
        or 'No readable C4 light on '..(link or 'Top')..' Controller Link'
    if device~=self.device then self:reset(); self.device=device end
    if device then
        local generation=self.generation
        local function retired() return self.device~=device or self.generation~=generation end
        if type(self.c4.GetDeviceDisplayName)=='function' then
            local ok,value=pcall(self.c4.GetDeviceDisplayName,self.c4,device)
            if retired() then return self:state() end
            if ok and type(value)=='string' then self.name=value:gsub('%c',' ') end
        end
        for _,variable in ipairs(VARIABLES) do
            local value=self:read(device,variable)
            if retired() then return self:state() end
            self.values[variable]=value
        end
        for _,variable in ipairs(VARIABLES) do
            if self.values[variable]~=nil and not self.watched[variable] and type(self.c4.RegisterVariableListener)=='function' then
                self.watched[variable]=true -- Registration can call back synchronously.
                local ok=pcall(self.c4.RegisterVariableListener,self.c4,device,variable)
                if retired() then return self:state() end
                if not ok then self.watched[variable]=nil end
            end
        end
    end
    return self:state()
end
function Target:observe(device,variable,value)
    device,variable=tonumber(device),tonumber(variable)
    if device~=self.device or not self.watched[variable] then return false end
    self.values[variable]=value
    -- A binary target can become dimmable after initialization; discover and
    -- subscribe to its newly added brightness variable on that notification.
    if variable==6661 then self:refresh(true,self.link) end
    self.changed()
    return true
end
function Target:state()
    local on=bool(self.values[1000])
    local level=number(self.values[1001],100)
    local dim=flag(self.values[6661],'dimmer')
    if dim==nil then dim=level~=nil end -- Variable 1001 is dimmer-only.
    if on==false then level=0 elseif not dim and on==true then level=100 end
    local ready=self.device~=nil and on~=nil and level~=nil
    return {id=self.device,name=self.name or (self.device and 'C4 light '..self.device or self.reason),
        ready=ready,level=ready and level or nil,dimmer=dim==true,
        ramp=dim==true and flag(self.values[6661],'ramp_level')~=false,
        preset=number(self.values[1006],100),up=number(self.values[1002],86400000),
        down=number(self.values[1003],86400000),reason=self.reason}
end
function Target:send(command,params)
    local state=self:state()
    if not state.ready then return false,state.reason end
    if self.sending or type(self.c4.SendToDevice)~='function' then return false,'C4 target command unavailable' end
    self.sending=true
    local ok,result=pcall(self.c4.SendToDevice,self.c4,state.id,command,params or {})
    self.sending=false
    local sent=ok and result~=false
    return sent,sent and 'Awaiting connected C4 light feedback' or 'C4 target command failed'
end
return M
