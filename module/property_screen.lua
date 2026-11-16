-- Shared Composer setup layout and explicit, payload-free support output.
local M={}
local Screen={}; Screen.__index=Screen
local ADVANCED={'Entity Selection','Entity ID','Discovery Catalog Entity ID','Discovery Status',
    'Last Gesture','Gesture Count','Last Sequence','Driver Version'}
local BASIC={'Device Setup','Operation Mode','Mode Description','Selected Device','Status',
    'Selected Capabilities','Button Capabilities','LED Status','LED Behavior','Debug Mode'}
M.LED_BEHAVIOR_LABELS={follow_load='Follow Load',follow_load_inverted='Follow Load (Inverted)',
    always_on='Always On',always_off='Always Off'}
local BEHAVIOR_ORDER={'follow_load','follow_load_inverted','always_on','always_off'}
function M.led_behavior(value)
    for behavior,label in pairs(M.LED_BEHAVIOR_LABELS) do if label==value then return behavior end end
end
function M.led_behavior_options(control,allow_bound)
    local names={'Use Device Setting'}
    if control then
        for _,behavior in ipairs(BEHAVIOR_ORDER) do
            if control:behavior_supported(behavior) then names[#names+1]=M.LED_BEHAVIOR_LABELS[behavior] end
        end
        if allow_bound and control:supports_bound_follow() then names[#names+1]='Follow Bound Device' end
    end
    return names
end
local function display(value)
    local kind=type(value)
    if value==nil then return '(not available)' end
    if kind~='string' and kind~='number' and kind~='boolean' then return '(not available)' end
    return tostring(value):gsub('%c',' '):sub(1,512)
end
local function name(value)
    if type(value)~='string' or not value:find('%S') then return nil end
    return display(value)
end
function M.new(options)
    local fields={}
    for _,field in ipairs(ADVANCED) do fields[#fields+1]=field end
    for _,field in ipairs(options.extra_advanced or {}) do fields[#fields+1]=field end
    return setmetatable({c4=options.c4,properties=options.properties,update=options.update,
        driver=options.driver,version=options.version,advanced=false,fields=fields,values={},
        has_feedback=options.has_led_feedback==true,led_feedback=false},Screen)
end
function Screen:remember(field,value) self.values[field]=value end
local function led_button(choice)
    return ({Top='top',Bottom='bottom',Toggle='toggle'})[choice] or choice
end
local function rgb(hex)
    if type(hex)~='string' or not hex:match('^%x%x%x%x%x%x$') then return nil end
    return string.format('%d,%d,%d',tonumber(hex:sub(1,2),16),tonumber(hex:sub(3,4),16),tonumber(hex:sub(5,6),16))
end
local function hex_rgb(value)
    if type(value)~='string' then return nil end
    local r,g,b=value:match('^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$')
    r,g,b=tonumber(r),tonumber(g),tonumber(b)
    if not r or r>255 or g>255 or b>255 then return nil end
    return string.format('%02X%02X%02X',r,g,b)
end
function Screen:led_color_visibility()
    if type(self.c4.SetPropertyAttribs)~='function' then return end
    self.led_color_attribs=self.led_color_attribs or {}
    local visible=self.led_button~=nil
    local fields={['LED Indicator']=self.led_choices and #self.led_choices>1 and 0 or 1,
        ['LED On Color']=visible and 0 or 1,['LED Off Color']=visible and 0 or 1}
    for field,attribute in pairs(fields) do
        if self.led_color_attribs[field]~=attribute then
            self.c4:SetPropertyAttribs(field,attribute); self.led_color_attribs[field]=attribute
        end
    end
end
-- COLOR_SELECTOR values are decimal RGB triples; the LED contract uses hex.
-- The controller owns saved per-control/per-channel preferences. XML defaults
-- never replace those preferences during startup, source changes or recovery.
function Screen:led_colors(control,ready)
    if self.updating_led_colors then return end
    self.updating_led_colors=true
    local choices=ready and control and control:choices() or {}
    local selected=self.properties['LED Indicator']
    local channel=control and control:channel(led_button(selected))
    local selection
    for _,choice in ipairs(choices) do
        if control:channel(led_button(choice))==channel then selection=choice; break end
    end
    selection=selection or choices[1]
    self.led_button=selection and led_button(selection) or nil
    self.led_choices=choices
    -- Commas delimit Composer property lists; preserve the stable ID suffix.
    local labels={}
    for _,choice in ipairs(choices) do labels[#labels+1]=choice:gsub(',',' ') end
    if selection then selection=selection:gsub(',',' ') end
    local list=table.concat(labels,',')
    if #choices>0 and (list~=self.led_color_list or self.properties['LED Indicator']~=selection) then
        self.c4:UpdatePropertyList('LED Indicator',list,selection)
        self:remember('LED Indicator',selection)
        self.led_color_list=list
    end
    local info=self.led_button and control:get(self.led_button)
    for field,key in pairs({['LED On Color']='ON_COLOR',['LED Off Color']='OFF_COLOR'}) do
        local value=info and rgb(info[key])
        if value and self.properties[field]~=value then self.update(field,value) end
    end
    self:led_color_visibility()
    self.updating_led_colors=false
end
function Screen:change_led_color(field,value,command)
    if self.updating_led_colors or not self.led_button then return false end
    local key=({['LED On Color']='ON_COLOR',['LED Off Color']='OFF_COLOR'})[field]
    local color=hex_rgb(value)
    if not key or not color then return false end
    return command('set_button',self.led_button,{[key]=color})
end
function Screen:status(value)
    self.detailed_status=value
    if value=='Control HA Device: on' then return 'On' end
    if value=='Control HA Device: off' then return 'Off' end
    if value=='Connected C4 light: on' then return 'On' end
    if value=='Connected C4 light: off' then return 'Off' end
    if value:match(': snapshot$') or value:match(': fired$') then return 'Ready' end
    return value
end
function Screen:set_advanced(enabled)
    self.advanced=enabled==true
    if type(self.c4.SetPropertyAttribs)=='function' then
        -- Restore visibility when updating an instance that previously hid it.
        self.c4:SetPropertyAttribs('Debug Mode',0)
        self.c4:SetPropertyAttribs('LED Behavior',0)
        for _,field in ipairs(self.fields) do
            self.c4:SetPropertyAttribs(field,self.advanced and 0 or 1)
        end
        if self.has_feedback then
            self.c4:SetPropertyAttribs('LED Feedback Source',(self.advanced or self.led_feedback) and 0 or 1)
            self:led_color_visibility()
        end
    end
    return true
end
function Screen:set_led_feedback(enabled)
    self.led_feedback=enabled==true
    if self.has_feedback and type(self.c4.SetPropertyAttribs)=='function' then
        self.c4:SetPropertyAttribs('LED Feedback Source',(self.advanced or self.led_feedback) and 0 or 1)
    end
end
function Screen:select(entity_id,rows,aliases,state)
    self.entity_id=entity_id
    self.choice_name=nil
    local target=aliases and aliases[entity_id] or entity_id
    for _,row in ipairs(rows or {}) do
        if row.entity_id==target then self.choice_name=name(row.name); break end
    end
    self.state_name=nil
    self:observe_name(entity_id,state)
end
function Screen:observe_name(entity_id,state)
    if entity_id~=self.entity_id then return end
    if type(state)=='table' and state.entity_id==entity_id and type(state.attributes)=='table' then
        self.state_name=name(state.attributes.friendly_name)
    end
    local label=self.choice_name or self.state_name or name(entity_id) or 'Not selected'
    if self.values['Selected Device']~=label then self.update('Selected Device',label) end
end
function Screen:diagnostics(runtime)
    print(self.driver..' | Diagnostics | driver version='..self.version)
    local function output(field,value) print(self.driver..' | '..field..'='..display(value)) end
    output('Advanced Properties',self.advanced)
    output('Detailed Status',self.detailed_status)
    for _,field in ipairs(BASIC) do
        local value=self.values[field]
        if value==nil then value=self.properties[field] end
        output(field,value)
    end
    if self.has_feedback then
        for _,field in ipairs({'LED Indicator','LED On Color','LED Off Color'}) do
            output(field,self.values[field] or self.properties[field])
        end
    end
    for _,field in ipairs(self.fields) do
        local value=self.values[field]
        if value==nil then value=self.properties[field] end
        output(field,value)
    end
    for _,field in ipairs(runtime or {}) do output(field[1],field[2]) end
    return true
end
return M
