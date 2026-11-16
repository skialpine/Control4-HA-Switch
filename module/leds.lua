-- Optional indicator LEDs. Only confirmed HA metadata grants authority; an
-- accepted service request never becomes optimistic hardware feedback.
local M={}
local Controller={}; Controller.__index=Controller
local ROLES={[0]='top',[1]='bottom',[2]='toggle'}
local ROLE_NAMES={top='Top',bottom='Bottom',toggle='Toggle'}
local ROLE_ORDER={top=1,bottom=2,toggle=3}
local BEHAVIORS={'follow_load','follow_load_inverted','always_on','always_off'}
local BEHAVIOR_NAMES={follow_load='follows local load',follow_load_inverted='on when local load off',
    always_on='always on',always_off='always off'}

local function key(value)
    return type(value)=='string' and #value>0 and #value<=64 and value:match('^[a-z][a-z0-9_]*$')~=nil
end
local function identity(value)
    return type(value)=='string' and #value>0 and #value<=128 and value:match('^[A-Za-z0-9_-]+$')~=nil
end
local function label(value)
    if type(value)~='string' or not value:match('%S') or value:find('%c') then return false end
    local _,characters=value:gsub('[^\128-\191]','')
    return characters<=128
end
local function color(value,metadata)
    if type(value)~='string' or not value:match('^%x%x%x%x%x%x$') then return nil end
    local normalized=value:upper()
    if metadata and normalized~=value then return nil end
    return normalized
end
local function brightness(value)
    return type(value)=='number' and value==value and value>=0 and value<=100
end
local function array(value)
    if type(value)~='table' or tostring(value)=='JSON object' then return false end
    local n,count=#value,0
    for index in pairs(value) do
        if type(index)~='number' or index%1~=0 or index<1 or index>n then return false end
        count=count+1
    end
    -- A bare empty table may be a JSON null sentinel. Empty wire arrays must
    -- retain the strict codec's array tag to establish their shape.
    return count==n and (n>0 or tostring(value)=='JSON array')
end
local function role(button)
    if type(button)=='number' then return ROLES[button] end
    if key(button) then return button end
end
local function nearest(channel,requested)
    if requested=='000000' then
        if channel.palette[requested] then return requested end
        return nil
    end
    local best,distance
    local r,g,b=tonumber(requested:sub(1,2),16),tonumber(requested:sub(3,4),16),tonumber(requested:sub(5,6),16)
    for _,candidate in ipairs(channel.colors) do
        if candidate~='000000' then
            local dr=r-tonumber(candidate:sub(1,2),16)
            local dg=g-tonumber(candidate:sub(3,4),16)
            local db=b-tonumber(candidate:sub(5,6),16)
            local d=dr*dr+dg*dg+db*db
            if not distance or d<distance then best,distance=candidate,d end
        end
    end
    return best
end
local function validate(attributes)
    if type(attributes)~='table' or attributes.bridge_led_version~=1 or
        not identity(attributes.bridge_control_id) or not identity(attributes.bridge_session_id) or
        not array(attributes.bridge_leds) or #attributes.bridge_leds>16 then return nil end
    local version=attributes.bridge_led_command_version
    if version~=nil and (type(version)~='number' or version%1~=0 or version<1) then return nil end
    local channels,ids={},{}
    for _,item in ipairs(attributes.bridge_leds) do
        if type(item)~='table' or not key(item.id) or not key(item.button_id) or
            not label(item.label) or
            type(item.available)~='boolean' or type(item.brightness_supported)~='boolean' or
            not array(item.colors) or #item.colors>65 or ids[item.id] or channels[item.button_id] then return nil end
        local channel={id=item.id,button_id=item.button_id,label=item.label,available=item.available,
            brightness_supported=item.brightness_supported,colors={},palette={},behaviors={}}
        for _,candidate in ipairs(item.colors) do
            if not color(candidate,true) or channel.palette[candidate] then return nil end
            channel.palette[candidate]=true; channel.colors[#channel.colors+1]=candidate
        end
        if #channel.colors-(channel.palette['000000'] and 1 or 0)>64 then return nil end
        if version==2 and (type(item.color_supported)~='boolean' or not array(item.behaviors)) then return nil end
        if item.color_supported~=nil and type(item.color_supported)~='boolean' then return nil end
        channel.color_supported=item.color_supported==true
        if item.behaviors~=nil then
            if not array(item.behaviors) or #item.behaviors>4 then return nil end
            for _,behavior in ipairs(item.behaviors) do
                if not BEHAVIOR_NAMES[behavior] or channel.behaviors[behavior] then return nil end
                channel.behaviors[behavior]=true
            end
        end
        if item.behavior~=nil then
            if not channel.behaviors[item.behavior] then return nil end
            channel.behavior=item.behavior
        end
        local nonblack=#channel.colors-(channel.palette['000000'] and 1 or 0)
        if version==2 and (channel.color_supported and nonblack==0 or not channel.color_supported and nonblack>1) then return nil end
        table.sort(channel.colors) -- Stable nearest-color ties, independent of metadata order.
        if item.color~=nil then
            if not color(item.color,true) or not channel.palette[item.color] then return nil end
            channel.color=item.color
        end
        if item.brightness~=nil then
            if not item.brightness_supported or not brightness(item.brightness) then return nil end
            channel.brightness=item.brightness
        end
        channels[item.button_id]=channel; ids[item.id]=true
    end
    return channels,version
end

function M.new(options)
    assert(type(options)=='table' and type(options.send)=='function','LED send callback is required')
    assert(options.store==nil or type(options.store)=='table','LED preference store must be a table')
    return setmetatable({send=options.send,notify=options.notify,status=options.status,
        store=options.store or {},channels={},states={},reported={},bound_follow=false},Controller)
end
function Controller:result(ok,reason)
    if self.status then self.status('LEDs: '..reason:gsub('_',' ')) end
    return ok,reason
end
function Controller:reset()
    self.channels,self.states,self.reported={},{},{}
    self.control,self.session,self.command_version=nil,nil,nil
    return true,'reset'
end
function Controller:preferences(channel)
    local control=self.store[self.control]
    local saved=type(control)=='table' and control[channel.id]
    saved=type(saved)=='table' and saved or {}
    local on=color(saved.ON_COLOR) or 'FFFFFF'
    local off=color(saved.OFF_COLOR) or '000000'
    return {ON_COLOR=nearest(channel,on),OFF_COLOR=nearest(channel,off)}
end
function Controller:save(channel,preferences)
    if type(self.store[self.control])~='table' then self.store[self.control]={} end
    self.store[self.control][channel.id]={ON_COLOR=preferences.ON_COLOR,OFF_COLOR=preferences.OFF_COLOR}
end
function Controller:channel(button)
    local channel=self.channels[role(button)]
    if not channel and type(button)=='string' then
        -- Composer saves the displayed choice. Resolve its stable suffix so
        -- changing a friendly label does not invalidate existing programming.
        local channel_id=button:match(' %[(%l[%l%d_]*)%]$')
        if key(channel_id) then
            for _,candidate in pairs(self.channels) do
                if candidate.id==channel_id then channel=candidate; break end
            end
        end
    end
    return channel and channel.available and channel or nil
end
local function available_channels(self,brightness_only,color_only)
    local channels={}
    for _,channel in pairs(self.channels) do
        if channel.available and (not brightness_only or channel.brightness_supported)
            and (not color_only or channel.color_supported) then
            channels[#channels+1]=channel
        end
    end
    table.sort(channels,function(a,b)
        local ar,br=ROLE_ORDER[a.button_id] or 4,ROLE_ORDER[b.button_id] or 4
        if ar~=br then return ar<br end
        if a.label~=b.label then return a.label<b.label end
        return a.id<b.id
    end)
    return channels
end
function Controller:buttons()
    local buttons={}
    for _,channel in ipairs(available_channels(self)) do buttons[#buttons+1]=channel.button_id end
    return buttons
end
function Controller:choices(brightness_only,color_only)
    local names={}
    for _,channel in ipairs(available_channels(self,brightness_only,color_only)) do
        names[#names+1]=ROLE_NAMES[channel.button_id] or (channel.label..' ['..channel.id..']')
    end
    return names
end
function Controller:get(button)
    local channel=self:channel(button)
    if not channel then return nil end
    local info=self:preferences(channel)
    info.CURRENT_COLOR=channel.color
    return info
end
function Controller:feedback(channel)
    if self.channels[channel.button_id]~=channel then return false end
    local info=self:get(channel.button_id) or {}
    local previous=self.reported[channel.button_id]
    if previous and previous.id==channel.id and previous.ON_COLOR==info.ON_COLOR and
        previous.OFF_COLOR==info.OFF_COLOR and previous.CURRENT_COLOR==info.CURRENT_COLOR then return true end
    -- Record the delivered facts before calling Director: a synchronous echo
    -- of this same snapshot must not recursively send BUTTON_INFO again.
    self.reported[channel.button_id]={id=channel.id,ON_COLOR=info.ON_COLOR,
        OFF_COLOR=info.OFF_COLOR,CURRENT_COLOR=info.CURRENT_COLOR}
    if self.notify then self.notify(channel.button_id,info) end
    return self.channels[channel.button_id]==channel
end
function Controller:observe(attributes)
    local channels,version=validate(attributes)
    if not channels then
        self:reset()
        return false,type(attributes)=='table' and attributes.bridge_led_version==nil and 'unsupported' or 'invalid_led_metadata'
    end
    if self.control~=attributes.bridge_control_id or self.session~=attributes.bridge_session_id then
        self.states,self.reported={},{}
    end
    self.control,self.session=attributes.bridge_control_id,attributes.bridge_session_id
    self.command_version=version
    self.channels=channels
    for _,channel in pairs(channels) do
        if not self:feedback(channel) then return false,'source_changed' end
    end
    return true,'observed'
end
function Controller:write(channel,requested_color,requested_brightness,quantized,behavior)
    if self.channels[channel.button_id]~=channel then return self:result(false,'source_changed') end
    if self.command_version~=2 then return self:result(false,'component_upgrade_required') end
    local unchanged=(requested_color==nil or requested_color==channel.color) and
        (requested_brightness==nil or requested_brightness==channel.brightness) and
        (behavior==nil or behavior==channel.behavior)
    if unchanged then return self:result(true,quantized and 'confirmed_quantized' or 'confirmed') end
    local data={led_id=channel.id,color=requested_color,brightness=requested_brightness,behavior=behavior}
    local ok,accepted=pcall(self.send,data)
    if self.channels[channel.button_id]~=channel then return self:result(false,'source_changed') end
    if not ok or accepted~=true then return self:result(false,'send_failed') end
    return self:result(true,quantized and 'queued_quantized' or 'queued')
end
function Controller:set_button(button,params)
    local channel=self:channel(button)
    if not channel then return self:result(false,'unsupported_button') end
    if type(params)~='table' then return self:result(false,'invalid_colors') end
    local preferences=self:preferences(channel)
    local present,quantized,current=false,false,nil
    for _,field in ipairs({'ON_COLOR','OFF_COLOR','CURRENT_COLOR'}) do
        if params[field]~=nil then
            present=true
            local requested=color(params[field])
            if not requested then return self:result(false,'invalid_color') end
            local mapped=nearest(channel,requested)
            if not mapped then return self:result(false,'unsupported_color') end
            quantized=quantized or mapped~=requested
            if field=='CURRENT_COLOR' then current=mapped else preferences[field]=mapped end
        end
    end
    if not present then return self:result(false,'invalid_colors') end
    if current and self.command_version~=2 then return self:result(false,'component_upgrade_required') end
    if current and (not channel.color_supported or current=='000000') then
        return self:result(false,current=='000000' and 'select_always_off_behavior' or 'unsupported_color_control')
    end
    if params.ON_COLOR~=nil or params.OFF_COLOR~=nil then self:save(channel,preferences) end
    if not self:feedback(channel) then return self:result(false,'source_changed') end
    if current then return self:write(channel,current,nil,quantized) end
    return self:result(true,quantized and 'configured_quantized' or 'configured')
end
function Controller:set_all(value)
    local requested=color(value)
    if not requested then return self:result(false,'invalid_color') end
    if self.command_version~=2 then return self:result(false,'component_upgrade_required') end
    if requested=='000000' then return self:result(false,'select_always_off_behavior') end
    local plans,quantized={},false
    for _,channel in pairs(self.channels) do
        if channel.available then
            if not channel.color_supported then return self:result(false,'unsupported_color_control') end
            local mapped=nearest(channel,requested)
            if not mapped then return self:result(false,'unsupported_color') end
            plans[#plans+1]={channel=channel,color=mapped}
            quantized=quantized or mapped~=requested
        end
    end
    if #plans==0 then return self:result(false,'unsupported_button') end
    table.sort(plans,function(a,b) return a.channel.id<b.channel.id end)
    -- Validate every target before changing any preference or issuing a write.
    for _,plan in ipairs(plans) do
        if self.channels[plan.channel.button_id]~=plan.channel then return self:result(false,'source_changed') end
        self:save(plan.channel,{ON_COLOR=plan.color,OFF_COLOR=plan.color})
        if not self:feedback(plan.channel) then return self:result(false,'source_changed') end
    end
    local queued=false
    for _,plan in ipairs(plans) do
        local ok,reason=self:write(plan.channel,plan.color,nil,quantized)
        if not ok then return false,reason end
        queued=queued or reason:match('^queued')~=nil
    end
    return true,queued and (quantized and 'queued_quantized' or 'queued') or (quantized and 'confirmed_quantized' or 'confirmed')
end
function Controller:set_brightness(button,value)
    local channel=self:channel(button)
    if not channel or not channel.brightness_supported then return self:result(false,'unsupported_brightness') end
    if not brightness(value) then return self:result(false,'invalid_brightness') end
    return self:write(channel,nil,value,false)
end
function Controller:match(button,state)
    local channel=self:channel(button)
    if not channel then return self:result(false,'unsupported_button') end
    if type(state)~='boolean' then return self:result(false,'invalid_state') end
    if not self.bound_follow then return self:result(false,'bound_feedback_disabled') end
    if self.command_version~=2 then return self:result(false,'component_upgrade_required') end
    self.states[channel.button_id]=state
    local preferences=self:preferences(channel)
    local requested
    if state then requested=preferences.ON_COLOR else requested=preferences.OFF_COLOR end
    if not requested then return self:result(false,'unsupported_color') end
    local behavior=requested=='000000' and 'always_off' or 'always_on'
    if not channel.behaviors[behavior] then return self:result(false,'unsupported_behavior') end
    if not channel.color_supported and requested~='000000' then requested='FFFFFF' end
    return self:write(channel,requested,nil,false,behavior)
end
function Controller:set_bound_follow(enabled)
    if type(enabled)~='boolean' then return self:result(false,'invalid_state') end
    if self.bound_follow~=enabled then self.states={} end
    self.bound_follow=enabled
    return true,'configured'
end
function Controller:behavior_choices(button)
    if self.command_version~=2 then return {} end
    local channels=button~=nil and {self:channel(button)} or available_channels(self)
    if #channels==0 then return {} end
    local result={}
    for _,behavior in ipairs(BEHAVIORS) do
        local supported=true
        for _,channel in ipairs(channels) do if not channel.behaviors[behavior] then supported=false; break end end
        if supported then result[#result+1]=behavior end
    end
    return result
end
function Controller:behavior_choices_any()
    if self.command_version~=2 then return {} end
    local channels=available_channels(self)
    local result={}
    for _,behavior in ipairs(BEHAVIORS) do
        for _,channel in ipairs(channels) do
            if channel.behaviors[behavior] then result[#result+1]=behavior; break end
        end
    end
    return result
end
function Controller:behavior_supported(behavior,button)
    for _,candidate in ipairs(self:behavior_choices(button)) do if candidate==behavior then return true end end
    return false
end
function Controller:supports_bound_follow()
    return self:behavior_supported('always_on') and self:behavior_supported('always_off')
end
function Controller:set_behavior(button,behavior)
    local channel=self:channel(button)
    if not channel then return self:result(false,'unsupported_button') end
    if self.command_version~=2 then return self:result(false,'component_upgrade_required') end
    if not BEHAVIOR_NAMES[behavior] or not channel.behaviors[behavior] then return self:result(false,'unsupported_behavior') end
    return self:write(channel,nil,nil,false,behavior)
end
function Controller:set_all_behavior(behavior)
    if self.command_version~=2 then return self:result(false,'component_upgrade_required') end
    if not self:behavior_supported(behavior) then return self:result(false,'unsupported_behavior') end
    local channels=available_channels(self)
    table.sort(channels,function(a,b) return a.id<b.id end)
    local queued=false
    for _,channel in ipairs(channels) do
        local ok,reason=self:write(channel,nil,nil,false,behavior)
        if not ok then return false,reason end
        queued=queued or reason=='queued'
    end
    return self:result(true,queued and 'queued' or 'confirmed')
end
function Controller:summary()
    local buttons={}
    for button,channel in pairs(self.channels) do
        if channel.available then
            local features,nonblack={},#channel.colors-(channel.palette['000000'] and 1 or 0)
            if channel.palette['000000'] and nonblack>0 then features[#features+1]='on/off' end
            if nonblack>1 then features[#features+1]='color'
            elseif nonblack==1 then features[#features+1]='single color'
            elseif channel.palette['000000'] then features[#features+1]='off only' end
            if channel.brightness_supported then features[#features+1]='brightness' end
            if channel.behavior then features[#features+1]=BEHAVIOR_NAMES[channel.behavior] end
            buttons[#buttons+1]=button..' ('..table.concat(features,', ')..')'
        end
    end
    table.sort(buttons)
    return #buttons>0 and 'LEDs: '..table.concat(buttons,', ') or next(self.channels) and 'LEDs unavailable' or 'Not exposed/configured'
end
return M
