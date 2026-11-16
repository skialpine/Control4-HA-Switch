-- A bound Light V2 target, using only its proxy variables and native commands.
-- No HA lookup, project-wide discovery, inferred brightness or optimistic state.
local M={}
local Target={}; Target.__index=Target
local VARIABLES={1000,1001,1002,1003,1006,1200,6661}
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
local function field(xml,key)
    if type(xml)~='string' or #xml>65536 then return nil end
    return xml:match('<'..key..'>(.-)</'..key..'>')
end
local function flag(xml,key) return bool(field(xml,key)) end
local function integer(value,max)
    value=number(value,max)
    if value and value==math.floor(value) then return value end
end
local function coordinates(x,y,mode)
    x,y,mode=number(x,1),number(y,1),integer(mode,1)
    if x and y and mode and x+y>0 and x+y<=1 then return {x=x,y=y,mode=mode} end
end
local function color(value)
    if type(value)~='string' or #value>128 then return nil end
    return coordinates(value:match('^%s*([^,]+),([^,]+),([^,]+)%s*$'))
end
local function color_params(state,params)
    if type(params)~='table' then return nil,'Invalid color target' end
    local data={}
    local kelvin=params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE
    -- Full-color proxy payloads can carry an unset CCT alongside valid xy.
    if kelvin==0 or kelvin=='0' or kelvin==-1 or kelvin=='-1' then kelvin=nil end
    if kelvin~=nil then
        kelvin=number(kelvin,4294967295)
        if not kelvin or not state.cct or kelvin<state.cct_min or kelvin>state.cct_max then
            return nil,'Connected C4 light does not support this color temperature'
        end
        data.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE=kelvin
        data.LIGHT_COLOR_TARGET_MODE=1
    else
        local requested=coordinates(params.LIGHT_COLOR_TARGET_X,params.LIGHT_COLOR_TARGET_Y,
            params.LIGHT_COLOR_TARGET_MODE==nil and 0 or params.LIGHT_COLOR_TARGET_MODE)
        if not requested then return nil,'Invalid color coordinates or mode' end
        if not (requested.mode==0 and state.full_color or requested.mode==1 and state.cct) then
            return nil,'Connected C4 light does not support this color mode'
        end
        data.LIGHT_COLOR_TARGET_X,data.LIGHT_COLOR_TARGET_Y,data.LIGHT_COLOR_TARGET_MODE=requested.x,requested.y,requested.mode
    end
    local rate=params.LIGHT_COLOR_TARGET_COLOR_RATE
    if rate==nil then rate=params.LIGHT_COLOR_TARGET_RATE end
    if rate==nil then rate=params.RATE end
    if rate~=nil then
        rate=integer(rate,4294967295)
        if not rate or rate<state.color_rate_min or rate>state.color_rate_max then
            return nil,'Connected C4 light does not support this color transition'
        end
        -- Preserve the rate across current and older Light V2 field names.
        data.LIGHT_COLOR_TARGET_COLOR_RATE,data.LIGHT_COLOR_TARGET_RATE,data.RATE=rate,rate,rate
    end
    local preset,origin=params.LIGHT_COLOR_TARGET_PRESET_ID,params.LIGHT_COLOR_TARGET_PRESET_ORIGIN
    if integer(origin,2)==2 then
        preset,origin=integer(preset,2147483647),integer(origin,2)
        if not preset or preset<1 then return nil,'Invalid Color Agent preset identity' end
        -- Device presets belong to this proxy, so forward their explicit color
        -- only. Color Agent identities are shared across the C4 project.
        data.LIGHT_COLOR_TARGET_PRESET_ID,data.LIGHT_COLOR_TARGET_PRESET_ORIGIN=preset,origin
    end
    return data
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
            local color_input=variable==1200 and (flag(self.values[6661],'supports_color') or flag(self.values[6661],'supports_color_correlated_temperature'))
            if (self.values[variable]~=nil or color_input) and not self.watched[variable] and type(self.c4.RegisterVariableListener)=='function' then
                self.watched[variable]=true -- Registration can call back synchronously.
                local ok,result=pcall(self.c4.RegisterVariableListener,self.c4,device,variable)
                if retired() then return self:state() end
                if not ok or result==false then self.watched[variable]=nil end
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
    local xml=self.values[6661]
    local current=color(self.values[1200])
    local full_color=flag(xml,'supports_color')==true
    local cct_min=integer(field(xml,'color_correlated_temperature_min'),4294967295)
    local cct_max=integer(field(xml,'color_correlated_temperature_max'),4294967295)
    local cct=flag(xml,'supports_color_correlated_temperature')==true and cct_min~=nil and cct_min>0 and cct_max~=nil and cct_max>=cct_min
    if current and not (current.mode==0 and full_color or current.mode==1 and cct) then current=nil end
    -- Enabling color requires an immediate confirmed color notification. Keep
    -- listening if the target's capabilities arrive before its first color.
    full_color,cct=ready and current~=nil and full_color,ready and current~=nil and cct
    local rate_min=integer(field(xml,'color_rate_min'),4294967295) or 0
    local rate_max=integer(field(xml,'color_rate_max'),4294967295) or 0
    local rate_behavior=integer(field(xml,'color_rate_behavior'),2) or 0
    if rate_max<rate_min then rate_min,rate_max,rate_behavior=0,0,0 end
    return {id=self.device,name=self.name or (self.device and 'C4 light '..self.device or self.reason),
        ready=ready,level=ready and level or nil,dimmer=dim==true,
        ramp=dim==true and flag(self.values[6661],'ramp_level')~=false,
        preset=number(self.values[1006],100),up=number(self.values[1002],86400000),
        down=number(self.values[1003],86400000),reason=self.reason,
        color=ready and current or nil,full_color=full_color,cct=cct,
        cct_min=cct and cct_min or nil,cct_max=cct and cct_max or nil,
        color_stop=(full_color or cct) and flag(xml,'supports_color_stop')==true,
        color_rate_behavior=rate_behavior,color_rate_min=rate_min,color_rate_max=rate_max}
end
function Target:send(command,params)
    local state=self:state()
    if not state.ready then return false,state.reason end
    if command=='SET_COLOR_TARGET' then
        local reason
        params,reason=color_params(state,params)
        if not params then return false,reason end
    elseif command=='SET_COLOR_STOP' then
        if not state.color_stop then return false,'Connected C4 light does not support color stop' end
        params={}
    end
    if self.sending or type(self.c4.SendToDevice)~='function' then return false,'C4 target command unavailable' end
    self.sending=true
    local ok,result=pcall(self.c4.SendToDevice,self.c4,state.id,command,params or {})
    self.sending=false
    local sent=ok and result~=false
    return sent,sent and 'Awaiting connected C4 light feedback' or 'C4 target command failed'
end
return M
