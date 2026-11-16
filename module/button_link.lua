-- Optional keypad-side output over existing BUTTON_LINK provider bindings.
-- Feed only metadata accepted by the gesture decoder. observe() never replays
-- a snapshot; consume() is called only after a newly accepted live gesture.
-- Native reference: snap-one/drivers-template-code-public, commit 50eee83,
-- c4hooks/c4hook_keypad.lua ClickTimerExpired: a tap is PUSH then CLICK.
-- proxies/light_proxy/light_device_class.lua: RELEASE ends a held ramp.
local M={}
local Output={}; Output.__index=Output
local DEFAULT_BINDINGS={top=200,bottom=201,toggle=202}
local function key(value)
    return type(value)=='string' and #value<=96 and value:match('^[a-z][a-z0-9_]*$')~=nil
end
local function identity(value) return type(value)=='string' and #value>0 and #value<=256 end
local function sequence(a,session)
    local value=a.gesture_sequence
    if a.gesture_session_id==session and type(value)=='number' and value==value and value>=1 and
        value<=9007199254740991 and value%1==0 then return value end
end
local function source_ready(sources,button)
    if type(sources)~='table' or #sources==0 then return false end
    local relevant=false
    for _,source in ipairs(sources) do
        if type(source)~='table' then return false end
        -- Legacy single/unassigned sources apply to every declared button.
        -- With no explicit association, all such sources must be healthy.
        if source.button_id==nil or source.button_id==button then
            relevant=true
            -- Unknown physical availability is normal for a ready event
            -- subscription without a device availability signal.
            if source.ready~=true or (source.availability~='available' and
                source.availability~='unknown') then return false end
        elseif not key(source.button_id) then return false end
    end
    return relevant
end
local function describe(metadata,bindings)
    if type(metadata)~='table' or type(metadata.attributes)~='table' then return nil end
    local a=metadata.attributes
    if not identity(a.bridge_control_id) or not identity(a.bridge_session_id) or
        (a.bridge_update_kind~='snapshot' and a.bridge_update_kind~='gesture') or
        type(a.bridge_buttons)~='table' then return nil end
    local buttons={}
    for _,button in ipairs(a.bridge_buttons) do
        if type(button)~='table' or not key(button.id) or buttons[button.id] or
            type(button.gestures)~='table' then return nil end
        local caps={tap=false,hold=false,release=false,gestures={}}
        for _,gesture in ipairs(button.gestures) do
            if type(gesture)~='table' or not key(gesture.id) or caps.gestures[gesture.id] then return nil end
            caps.gestures[gesture.id]={kind=gesture.kind,press_count=gesture.press_count}
            if gesture.kind=='press' and gesture.press_count==1 then caps.tap=true end
            if gesture.kind=='hold_start' then caps.hold=true end
            if gesture.kind=='release' then caps.release=true end
        end
        -- Starting a logical hold requires a declared way to stop it.
        caps.hold=caps.hold and caps.release
        caps.ready=bindings[button.id]~=nil and source_ready(a.bridge_sources,button.id)
        buttons[button.id]=caps
    end
    return {control=a.bridge_control_id,session=a.bridge_session_id,buttons=buttons}
end

function M.new(options)
    options=options or {}
    assert(type(options.send)=='function','BUTTON_LINK send callback is required')
    local bindings,used={},{}
    for button,binding in pairs(options.bindings or DEFAULT_BINDINGS) do
        assert(key(button) and type(binding)=='number' and binding%1==0 and binding>=1 and binding<=999
            and not used[binding],'Invalid BUTTON_LINK binding map')
        bindings[button],used[binding]=binding,true
    end
    return setmetatable({send=options.send,bindings=bindings,enabled=false,held={},cleanup={},context=nil,last_sequence=0,epoch=0},Output)
end
function Output:_send(button,command)
    local ok,result=pcall(self.send,self.bindings[button],command,{},'COMMAND')
    return ok and result~=false
end
function Output:_release(button)
    if not self.held[button] then return true end
    self.held[button]=nil -- Clear before the boundary, including reentrant calls.
    if self:_send(button,'DO_RELEASE') then self.cleanup[button]=nil; return true end
    self.held[button]=true -- Retain a failed cleanup for the next reset attempt.
    self.cleanup[button]=true
    return false
end
function Output:_clear_holds()
    local ok=true
    -- Fixed ordering keeps cleanup deterministic for the three standard links.
    local buttons={}; for button in pairs(self.held) do buttons[#buttons+1]=button end
    table.sort(buttons)
    if #buttons>0 then self.epoch=self.epoch+1 end
    for _,button in ipairs(buttons) do if not self:_release(button) then ok=false end end
    return ok
end
function Output:reset()
    self.context,self.last_sequence=nil,0
    self.epoch=self.epoch+1
    return self:_clear_holds()
end
function Output:set_enabled(enabled)
    assert(type(enabled)=='boolean','BUTTON_LINK enabled must be boolean')
    self.enabled=enabled
    if not enabled then return self:reset() end
    return true
end
function Output:observe(metadata,delivery)
    if delivery~=nil and delivery~='state' and delivery~='event' then
        self:reset(); return false,'invalid_delivery'
    end
    local next_context=describe(metadata,self.bindings)
    if not next_context then self:reset(); return false,'invalid_metadata' end
    local previous=self.context
    if previous and (previous.control~=next_context.control or previous.session~=next_context.session) then
        if not self:reset() then return false,'cleanup_failed' end
    end
    local a=metadata.attributes
    local incoming=sequence(a,next_context.session)
    -- A refreshed snapshot can reveal a missed release. Likewise, a gap in
    -- live delivery makes an old hold unsafe even if the next event is merely
    -- a repeat. Cleanup is logical C4 state repair, never a physical gesture.
    -- A GET response can contain a cached last occurrence whose attributes
    -- still say "gesture". The caller knows that transport is historical.
    local snapshot=delivery=='state' or a.bridge_update_kind=='snapshot'
    if incoming and incoming>self.last_sequence+(snapshot and 0 or 1) then
        if not self:_clear_holds() then self.context=nil; return false,'cleanup_failed' end
    end
    if snapshot and incoming then self.last_sequence=math.max(self.last_sequence,incoming) end
    -- A source failure or capability removal stops an existing logical hold.
    local cleaned=true
    for button in pairs(self.held) do
        local caps=next_context.buttons[button]
        if self.cleanup[button] or not caps or not caps.ready or not caps.hold then
            self.epoch=self.epoch+1
            if not self:_release(button) then cleaned=false end
        end
    end
    if not cleaned then self.context=nil; return false,'cleanup_failed' end
    self.context=next_context
    return true
end
function Output:pressed(button)
    if not self.enabled or not self.context then return nil end
    local caps=self.context.buttons[button]
    if not caps or not caps.ready or not (caps.tap or caps.hold) then return nil end
    return self.held[button]==true
end
function Output:actions()
    local actions={}
    if not self.enabled or not self.context then return actions end
    local buttons={}
    for button,caps in pairs(self.context.buttons) do
        if caps.ready then buttons[#buttons+1]=button end
    end
    table.sort(buttons,function(a,b) return self.bindings[a]<self.bindings[b] end)
    for _,button in ipairs(buttons) do
        local caps=self.context.buttons[button]
        if caps.tap then actions[#actions+1]={button_id=button,action='click'} end
        -- Composer lists capabilities while authoring a future script. A
        -- release must be selectable before its preceding press has executed.
        if caps.hold then
            actions[#actions+1]={button_id=button,action='press'}
            actions[#actions+1]={button_id=button,action='release'}
        end
    end
    return actions
end
function Output:action(button,kind)
    if not self.enabled then return false,'disabled' end
    local caps=self.context and self.context.buttons[button]
    if not caps or not caps.ready then return false,'unavailable_button' end
    local epoch=self.epoch
    if kind=='press' and caps.hold then
        if self.held[button] then return false,'already_pressed' end
        self.held[button]=true
        if self:_send(button,'DO_PUSH') then
            if self.epoch~=epoch or not self.enabled then return false,'cancelled' end
            return true,'push'
        end
        self:_release(button)
        return false,'send_failed'
    elseif kind=='release' and caps.release then
        if not self.held[button] then return false,'not_pressed' end
        if self:_release(button) then return true,'release' end
        return false,'send_failed'
    elseif kind=='click' and caps.tap then
        -- A source may report a completed click after its original push. Do not
        -- push twice; CLICK is the termination of that logical button action.
        if not self.held[button] then
            self.held[button]=true
            if not self:_send(button,'DO_PUSH') then self:_release(button); return false,'send_failed' end
        end
        if self.epoch~=epoch or not self.enabled then return false,'cancelled' end
        if self:_send(button,'DO_CLICK') then self.held[button]=nil; return true,'click' end
        self:_release(button)
        return false,'send_failed'
    end
    return false,'unmapped_gesture'
end
function Output:consume(metadata)
    local valid,reason=self:observe(metadata)
    if not valid then return false,reason end
    if not self.enabled then return false,'disabled' end
    local a=metadata.attributes
    if a.bridge_update_kind~='gesture' or a.gesture_session_id~=self.context.session then return false,'snapshot_or_history' end
    local incoming=sequence(a,self.context.session)
    if not incoming or incoming<=self.last_sequence then return false,'duplicate_or_invalid_sequence' end
    self.last_sequence=incoming
    local caps=self.context.buttons[a.button_id]
    local declared=caps and caps.gestures[a.gesture_id]
    if not caps or not caps.ready or not declared or declared.kind~=a.event_type or
        declared.press_count~=a.press_count then return false,'unsupported_gesture' end
    local kind=a.event_type=='hold_start' and 'press' or a.event_type=='release' and 'release'
        or a.event_type=='press' and a.press_count==1 and 'click' or nil
    if not kind then return false,'unmapped_gesture' end
    return self:action(a.button_id,kind)
end
return M
