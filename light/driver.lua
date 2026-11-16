-- Fresh-install native LightV2 driver. No dependency on the legacy Switch Base.
local Discovery=require('module.discovery')
local CatalogEnrichment=require('module.catalog_enrichment')
local Choices=require('module.discovery_choices')
local Family=require('module.family_capabilities')
local Gestures=require('module.gestures')
local ButtonLink=require('module.button_link')
local Modes=require('module.operation_mode')
local Time=require('module.rfc3339')
local LEDs=require('module.leds')
local Capabilities=require('module.capability_summary')
local PropertyScreen=require('module.property_screen')
local ConnectedLight=require('module.connected_light')
local StateSubscription=require('module.state_subscription')
local Codec=Discovery.new_codec()
local subscription=StateSubscription.new(C4:GetDeviceID(),Codec)
local function log_value(value)
    local kind=type(value)
    if kind~='string' and kind~='number' and kind~='boolean' and value~=nil then return '<non-scalar>' end
    return tostring(value):gsub('%c',' '):sub(1,160)
end
local function trace(event,fields)
    if Properties['Debug Mode']~='On' then return end
    local parts={'HA Light',event}
    for _,field in ipairs(fields or {}) do parts[#parts+1]=field[1]..'='..log_value(field[2]) end
    if C4.GetTime then parts[#parts+1]='local_ms='..log_value(C4:GetTime()) end
    print(table.concat(parts,' | '))
end
local late,timer,client,consumer,consumer_error=false,nil,nil,nil,nil
local selected={}; local rows,picker,choice_rows,choice_meta={},{},{},{}
local native_events,registered_custom={},{}
-- Keypad-side consumers command the target light's provider connections.
-- Preserve 200-202 for existing keypad -> HA load control; these new links
-- carry HA paddle -> existing C4 light commands without reversing old roles.
local CONTROLLER_BINDINGS={top=203,bottom=204,toggle=205}
local forwarded_at
local output=ButtonLink.new({bindings=CONTROLLER_BINDINGS,
    send=function(binding,command,params,kind)
        trace('forward',{{'binding',binding},{'command',command}})
        C4:SendToProxy(binding,command,params,kind)
        if Properties['Debug Mode']=='On' and Properties['Latency Diagnostics']=='On' and C4.GetTime then
            forwarded_at=C4:GetTime()
        end
    end})
local BUTTONS={top=0,bottom=1,toggle=2}; local BUTTON_IDS={[0]='top',[1]='bottom',[2]='toggle'}
local CONTROLLER='C4 Button Controller'
local count,last_sequence=0,0
local button_notification_depth=0
local pending_browser,data_ready,retry_at,retry_count=nil,false,nil,0
local coordinator_bound=true
local transport_ready,awaiting_snapshot=true,true
local snapshot_retry_at,snapshot_attempts=nil,0
local catalog
local published={}
local source_generation=0
local sync,refresh,render,publish,discover
local sync_target
local target_retry_at=0
local led_control
local led_status
local screen
local updating_led_behavior,led_behavior_list=false,nil

local function prop(name,value)
    if not late then return end
    if screen then screen:remember(name,value) end
    if name=='LED Status' then
        if led_status==value then return end
        led_status=value
    end
    C4:UpdateProperty(name,tostring(value))
end
screen=PropertyScreen.new({c4=C4,properties=Properties,update=prop,driver='HA Light',version='1',
    extra_advanced={'Latency Diagnostics','LED Feedback Source'},has_led_feedback=true})
local function status(value)
    value=Modes.status(value); prop('Status',screen:status(value)); trace('status',{{'value',value}})
end
local function notify(command,params)
    if not late then return end
    if command=='BUTTON_ACTION' then button_notification_depth=button_notification_depth+1 end
    local ok,failure=pcall(C4.SendToProxy,C4,5001,command,params or {},'NOTIFY')
    if command=='BUTTON_ACTION' then button_notification_depth=button_notification_depth-1 end
    if not ok then error(failure) end
end
local function now() return C4.GetTime and C4:GetTime()/1000 or os.time() end
local function mode() return Modes.identity(Properties['Operation Mode']) end
local function id() return Properties['Entity ID'] or '' end
local connected
connected=ConnectedLight.new(C4,function()
    if late and selected.mode==CONTROLLER then
        publish()
        local state=connected and connected:state()
        if state and state.ready then status('Connected C4 light: '..(state.level>0 and 'on' or 'off')) end
    end
end)
sync_target=function()
    local state=connected:refresh(late and selected.mode==CONTROLLER,Properties['App Control Link'] or 'Top')
    prop('Connected Light',state.name)
    return state
end
local function catalog_id()
    local value=Properties['Discovery Catalog Entity ID']
    return value==nil and 'sensor.ha_gesture_bridge_catalog' or value
end
local function leds()
    if led_control then return led_control end
    if PersistData==nil then PersistData={} end
    if type(PersistData)~='table' then return nil end
    if PersistData.LEDColors==nil then PersistData.LEDColors={} end
    if type(PersistData.LEDColors)~='table' then return nil end
    led_control=LEDs.new({store=PersistData.LEDColors,
        send=function(data)
            sync()
            if not late or not coordinator_bound or not transport_ready or awaiting_snapshot or not consumer
                or not consumer.ready or selected.mode=='Direct' then return false end
            data.entity_id=selected.id
            C4:SendToProxy(999,'HA_CALL_SERVICE',{JSON=Codec:encode({domain='ha_gesture_bridge',
                service='set_led',service_data=data})},'COMMAND')
            trace('led requested',{{'led',data.led_id},{'color',data.color},{'brightness',data.brightness},{'behavior',data.behavior}})
            return true
        end,
        notify=function(button,info)
            local button_id=BUTTONS[button]
            if button_id==nil then return end
            local data={BUTTON_ID=button_id,ON_COLOR=info.ON_COLOR,OFF_COLOR=info.OFF_COLOR,
                CURRENT_COLOR=info.CURRENT_COLOR}
            notify('BUTTON_INFO',data)
        end,
        status=function(value) prop('LED Status',value) end})
    return led_control
end
local function led_command(method,...)
    sync()
    local control=leds()
    if not late or not coordinator_bound or not transport_ready or awaiting_snapshot or not consumer
        or not consumer.ready or selected.mode=='Direct' or not control then
        prop('LED Status','Select a ready gesture control with configured LEDs'); return false
    end
    local ok,reason=control[method](control,...)
    prop('LED Status',reason and ('LEDs: '..reason:gsub('_',' ')) or control:summary())
    screen:led_colors(control,coordinator_bound and transport_ready and not awaiting_snapshot and consumer and consumer.ready and selected.mode~='Direct')
    return ok
end
local function update_led_colors()
    if not late then return end
    screen:led_colors(leds(),coordinator_bound and transport_ready and not awaiting_snapshot and consumer and consumer.ready and selected.mode~='Direct')
end
local function led_button(params)
    local value=type(params)=='table' and (params.Button or params.BUTTON_ID or params.NUMBER or params.Number)
    if type(value)=='string' and value:match('^[012]$') then return tonumber(value) end
    return ({Top='top',Bottom='bottom',Toggle='toggle'})[value] or value
end
local function feedback_state(value)
    -- Director BOOL parameters can arrive as booleans or serialized 0/1.
    -- Keep unknown values distinct from Off; Lua considers both 0 and '0' true.
    if type(value)=='string' then value=value:match('^%s*(.-)%s*$'):lower() end
    if value==true or value==1 or value=='1' or value=='true' then return true end
    if value==false or value==0 or value=='0' or value=='false' then return false end
end
local function request_led_feedback()
    local binding=({Top=203,Bottom=204,Toggle=205})[Properties['LED Feedback Source']]
    if Properties['LED Behavior']~='Follow Bound Device' or not binding or not late or selected.mode~=CONTROLLER
        or not transport_ready or awaiting_snapshot then return false end
    local control=leds()
    if not consumer or not consumer.ready or not control or not control:supports_bound_follow() then return false end
    C4:SendToProxy(binding,'REQUEST_BUTTON_COLORS',{},'COMMAND')
    return true
end
local function update_led_behavior_ui()
    if not late then return end
    update_led_colors()
    local control=leds()
    local policy=Properties['LED Behavior'] or 'Use Device Setting'
    local ready=coordinator_bound and transport_ready and not awaiting_snapshot and consumer and consumer.ready
    if control then
        control:set_bound_follow(ready==true and selected.mode==CONTROLLER and policy=='Follow Bound Device'
            and control:supports_bound_follow())
    end
    screen:set_led_feedback(policy=='Follow Bound Device')
    local names=PropertyScreen.led_behavior_options(control,selected.mode==CONTROLLER)
    if PropertyScreen.led_behavior(policy) or policy=='Follow Bound Device' then
        local found=false; for _,name in ipairs(names) do if name==policy then found=true end end
        if not found then names[#names+1]=policy end
    else policy='Use Device Setting' end
    local value=table.concat(names,',')
    if value~=led_behavior_list or Properties['LED Behavior']~=policy then
        updating_led_behavior=true
        C4:UpdatePropertyList('LED Behavior',value,policy)
        updating_led_behavior=false; led_behavior_list=value
    end
end
local function apply_led_behavior()
    if not late or updating_led_behavior then return false end
    sync()
    local policy=Properties['LED Behavior'] or 'Use Device Setting'
    local control=leds()
    if control then control:set_bound_follow(false) end
    if policy=='Use Device Setting' then
        if control then prop('LED Status',control:summary()) end
        update_led_behavior_ui(); return true
    end
    if policy=='Follow Bound Device' then
        if not control or not control:supports_bound_follow() or selected.mode~=CONTROLLER or not consumer
            or not consumer.ready or not coordinator_bound or not transport_ready or awaiting_snapshot then
            prop('LED Status','Select a ready gesture control in Control Connected C4 Light mode'); return false
        end
        if Properties['LED Feedback Source']==nil or Properties['LED Feedback Source']=='Disabled' then
            updating_led_behavior=true
            Properties['LED Feedback Source']='Top'; prop('LED Feedback Source','Top')
            updating_led_behavior=false
        end
        control:set_bound_follow(true)
        update_led_behavior_ui()
        return request_led_feedback()
    end
    local behavior=PropertyScreen.led_behavior(policy)
    if not behavior then prop('LED Status','LEDs: unsupported behavior'); return false end
    local ok=led_command('set_all_behavior',behavior)
    update_led_behavior_ui(); return ok
end
local function finite(value,maximum)
    return type(value)=='number' and value==value and value>=0 and value<=maximum
end
local function number(value,maximum)
    if type(value)~='number' and type(value)~='string' then return nil end
    local n=tonumber(value); if finite(n,maximum) then return n end
end
local revision,compare=Time.parse,Time.compare

local function native_definition(definition)
    if not definition or BUTTONS[definition.button_id]==nil then return nil end
    local action
    if definition.kind=='press' and definition.press_count>=1 and definition.press_count<=3 then action=definition.press_count+1
    elseif definition.kind=='hold_start' then action=1
    elseif definition.kind=='release' then action=0 end
    if action~=nil then return {BUTTON_ID=BUTTONS[definition.button_id],ACTION=action} end
end
local function allocation_definition(event_id)
    local metadata=consumer and consumer.last_metadata
    if not metadata or type(PersistData)~='table' then return nil end
    local store=PersistData.DimmerGestureEventIDs
    if type(store)~='table' or type(store.allocations)~='table' then return nil end
    local control=metadata.attributes.bridge_control_id
    for key,allocated in pairs(store.allocations) do
        if allocated==event_id and key:sub(1,#control+1)==control..'/' then
            local relative=key:sub(#control+2)
            return metadata.capabilities.lookup[relative]
        end
    end
end
local function decoder()
    if consumer then return consumer end
    if consumer_error then return nil end
    if PersistData==nil then PersistData={} end
    if type(PersistData)~='table' then consumer_error='Invalid persisted gesture IDs'; return nil end
    if PersistData.DimmerGestureEventIDs==nil then PersistData.DimmerGestureEventIDs={} end
    local adapter={}
    function adapter:AddEvent(event_id,name,description,order)
        local native=native_definition(allocation_definition(event_id))
        if native then native_events[event_id]=native; return true end
        native_events[event_id]=nil
        local ok,added=pcall(C4.AddEvent,C4,event_id,name,description,order)
        if ok and added==true then registered_custom[event_id]=true; return true end
        return false
    end
    function adapter:FireEventByID(event_id)
        -- Registration maps by control/button/gesture identity, never labels.
        local native=native_events[event_id]
        if native then notify('BUTTON_ACTION',{BUTTON_ID=native.BUTTON_ID,ACTION=native.ACTION})
        elseif registered_custom[event_id] then C4:FireEventByID(event_id)
        else error('Unregistered gesture') end
    end
    local ok,result=pcall(Gestures.new,{entity_id=selected.id or id(),c4=adapter,event_store=PersistData.DimmerGestureEventIDs})
    if not ok then consumer_error='Gesture initialization failed'; return nil end
    consumer=result
    if late then consumer:start() end
    return consumer
end
local function current_load()
    if not coordinator_bound or not transport_ready or awaiting_snapshot or not subscription:ready() then return nil end
    if selected.mode=='Direct' then
        local state,facts=selected.state,selected.facts
        if state and facts and facts.supported and facts.availability=='available' and
            (state.state=='on' or state.state=='off') then return state,facts end
    elseif selected.mode=='Gesture Bridge' and consumer and consumer.ready then
        local load=selected.load
        if load and load.available and (load.state=='on' or load.state=='off') then
            return load,Family.classify(load)
        end
    end
end
local function clear()
    trace('clear',{{'entity',selected.id},{'mode',selected.mode}})
    source_generation=source_generation+1
    output:reset()
    if led_control then led_control:reset() end
    prop('LED Status',mode()=='Direct' and 'Not exposed/configured' or 'Waiting for current LED capabilities')
    selected.state,selected.facts,selected.load,selected.revision,selected.delivery=nil,nil,nil,nil,nil
    if consumer then consumer:set_entity_id('') end
    consumer,consumer_error=nil,nil
    native_events={}
    snapshot_retry_at,snapshot_attempts=nil,0
    subscription:release()
end
sync=function()
    if selected.id~=id() or selected.mode~=mode() then
        clear(); selected.id,selected.mode=id(),mode(); awaiting_snapshot=true
        trace('selected',{{'entity',selected.id},{'mode',selected.mode}})
        output:set_enabled(late and selected.mode==CONTROLLER)
        sync_target()
        if publish then publish() end
        status(selected.mode..': waiting for selected entity')
        return true
    end
    return false
end
publish=function(force)
    if not late then return end
    local state,facts=current_load(); local caps=facts and facts.capabilities or {}
    local dim=caps.set_level==true
    local level
    if state then
        if state.state=='off' then level=0
        elseif not dim then level=100
        elseif type(state.attributes)=='table' and finite(state.attributes.brightness,255) then level=state.attributes.brightness*100/255 end
    end
    local gesture_ready=false
    if (selected.mode==CONTROLLER or selected.mode=='Gestures Only') and not awaiting_snapshot and subscription:ready()
        and consumer and consumer.ready and consumer.last_metadata then
        local sources=consumer.last_metadata.attributes.bridge_sources
        gesture_ready=type(sources)=='table' and #sources>0
        for _,source in ipairs(sources or {}) do
            if not source.ready or source.availability=='unavailable' then gesture_ready=false end
        end
    end
    local online=(state~=nil and level~=nil) or gesture_ready
    local hide_conditions=state==nil or level==nil
    local target=selected.mode==CONTROLLER and connected:state() or nil
    if target then
        dim=target.dimmer; level=target.level; online=target.ready
        hide_conditions=not target.ready
        caps={ramp_to_level=target.ramp}
    end
    local signature=tostring(dim)..'/'..tostring(caps.ramp_to_level==true)..'/'..tostring(hide_conditions)
    local capabilities_changed=published.capabilities~=signature
    if force or capabilities_changed then
        -- Repeating dimmer notifications resets the proxy's native rates.
        notify('DYNAMIC_CAPABILITIES_CHANGED',{dimmer=dim})
        notify('DYNAMIC_CAPABILITIES_CHANGED',{set_level=dim,ramp_level=caps.ramp_to_level==true,
            supports_target=false,supports_brightness_stop=false,supports_color=false,
            supports_color_correlated_temperature=false,hide_proxy_conditionals_loops=hide_conditions})
        published.capabilities=signature
    end
    if target then
        -- Capability changes can reset native presets/rates. Seed them after
        -- capabilities, including when the new target has identical settings.
        for field,command in pairs({preset='PRESET_LEVEL',up='CLICK_RATE_UP',down='CLICK_RATE_DOWN'}) do
            if target[field]~=nil and (force or capabilities_changed or published[field]~=target[field]) then
                notify(command,tostring(target[field])); published[field]=target[field]
            end
        end
    end
    if force or published.online~=online then notify('ONLINE_CHANGED',{STATE=online}); published.online=online end
    if level~=nil and (force or published.level~=level) then notify('LIGHT_BRIGHTNESS_CHANGED',{LIGHT_BRIGHTNESS_CURRENT=level}) end
    published.level=level
    prop('Selected Capabilities',target and (target.ready and
        ('Connected C4 light: On/Off; Toggle'..(dim and '; Level' or '')..(target.ramp and '; Timed ramp' or ''))
        or target.reason) or Capabilities.load(selected.mode,facts))
    local metadata=coordinator_bound and transport_ready and not awaiting_snapshot and consumer and consumer.ready and consumer.last_metadata or nil
    prop('Button Capabilities',Capabilities.buttons(metadata,selected.mode))
end
local function connected_command(command,params)
    sync_target()
    if not late or selected.mode~=CONTROLLER or mode()~=CONTROLLER then return false end
    local ok,reason=connected:send(command,params)
    trace('app forward',{{'target',connected.device},{'command',command},{'sent',ok}})
    status(reason)
    return ok
end
refresh=function()
    sync()
    if late and selected.mode==CONTROLLER then sync_target(); publish() end
    if not late or not coordinator_bound or not transport_ready then return false end
    if Family.entity_domain({entity_id=selected.id}) then
        if awaiting_snapshot then
            snapshot_attempts=snapshot_attempts+1
            snapshot_retry_at=now()+5
            status(subscription:message() or ('Waiting for selected entity snapshot (attempt '..snapshot_attempts..' of 5)'))
        end
        C4:SendToProxy(999,'HA_GET_STATE',subscription:request(selected.id),'COMMAND'); return true
    end
    C4:SendToProxy(999,'HA_RELEASE_STATES',subscription:release(),'COMMAND')
    status('Invalid Entity ID'); return false
end
local function service(action,data)
    sync()
    if selected.mode==CONTROLLER then
        return connected_command(({turn_on='ON',turn_off='OFF',toggle='TOGGLE'})[action])
    end
    local state,facts=current_load()
    if not state then status(selected.mode..': no ready HA load; command blocked'); return false end
    C4:SendToProxy(999,'HA_CALL_SERVICE',{JSON=Codec:encode({domain=facts.domain,service=action,
        service_data=Codec:newObject(data or {}),target={entity_id=state.entity_id}})},'COMMAND')
    status(selected.mode..': '..action..' requested; awaiting HA feedback')
    return true
end
local function level(params,ramp,native_target)
    sync(); params=params or {}
    local value=number(params.LIGHT_BRIGHTNESS_TARGET or params.LEVEL or params.Level,100)
    local rate=number(params.RATE or params.TIME or params.RateMillisec or params['Rate Millisec'],4294967295)
    if not value or (ramp and rate==nil) then status('Invalid level or ramp time'); return false end
    if selected.mode==CONTROLLER then
        local target=sync_target()
        if not target.ready then status(target.reason); return false end
        -- Native Navigator On names its brightness preset; a slider percentage
        -- does not. Let the target apply its active On mode (e.g. Nightlight),
        -- rather than turning that logical On into our default preset level.
        local preset=number(params.LIGHT_BRIGHTNESS_TARGET_PRESET_ID,2147483647)
        if native_target and value>0 and (preset==1 or preset==10) then return connected_command('ON') end
        if not target.dimmer then
            if ramp and rate>0 then status('Connected C4 light does not support timed transition'); return false end
            return connected_command(value==0 and 'OFF' or 'ON')
        end
        if ramp and rate>0 and not target.ramp then status('Connected C4 light does not support timed transition'); return false end
        return connected_command(ramp and 'RAMP_TO_LEVEL' or 'SET_LEVEL',
            ramp and {LEVEL=value,TIME=rate} or {LEVEL=value})
    end
    local state,facts=current_load()
    if not state then status('No ready HA load; command blocked'); return false end
    if not facts.capabilities.set_level then
        -- Light V2 uses level targets for binary On/Off too. Never send HA
        -- brightness/transition data to a switch or an on/off-only light.
        if facts.domain=='light' and facts.metadata.color_modes~='valid' then
            status('Waiting for valid HA light capabilities'); return false
        end
        if ramp and rate>0 then status('Selected load does not support timed transition'); return false end
        return service(value==0 and 'turn_off' or 'turn_on')
    end
    if ramp and rate>0 and not facts.capabilities.ramp_to_level then status('Selected light does not support timed transition'); return false end
    local data={}
    if value>0 then data.brightness=math.floor(value*255/100+0.5) end
    if ramp and rate>0 then data.transition=rate/1000 end
    return service(value==0 and 'turn_off' or 'turn_on',data)
end
local function aggregate(row) return Gestures.preview(row,Discovery.null) end

render=function()
    if not late then return end
    Modes.update_description(Properties,prop)
    if type(C4.SetPropertyAttribs)=='function' then
        local hidden=selected.mode==CONTROLLER and 0 or 1
        C4:SetPropertyAttribs('App Control Link',hidden); C4:SetPropertyAttribs('Connected Light',hidden)
    end
    local aliases
    choice_rows,choice_meta,aliases=Choices.build(catalog and catalog:merge(rows) or rows,
        {selected_entity_id=selected.id,operation_mode=selected.mode,validate_aggregate=aggregate})
    picker=Discovery.build_picker(choice_rows,{selected_entity_id=aliases[selected.id] or selected.id})
    C4:UpdatePropertyList('Entity Selection',picker.value_list,picker.selected_label)
    screen:select(selected.id,choice_rows,aliases,selected.state)
    if client and client.status=='complete' then
        prop('Discovery Status',catalog and catalog:describe(false,picker.missing_selected) or 'Complete')
    end
    update_led_behavior_ui()
end
local function complete_browser()
    if pending_browser then
        local pending=pending_browser; pending_browser=nil
        pcall(pending.callback,data_ready and BrowseHALightDevices(nil,nil,pending.search,pending.filter) or {})
    end
end
local function catalog_client()
    if not catalog then
        catalog=CatalogEnrichment.new({client_id='ha-light-catalog-'..tostring(C4:GetDeviceID()),now=now,
            send=function(binding,command,params) C4:SendToProxy(binding,command,params,'COMMAND') end,
            on_change=function() render() end})
    end
    return catalog
end
discover=function()
    if not late or not coordinator_bound or not transport_ready then return false end
    catalog_client():invalidate('refreshing')
    if not client then
        client=Discovery.new({client_id='ha-light-'..tostring(C4:GetDeviceID()),now=now,timeout=20,
            send=function(binding,command,params) C4:SendToProxy(binding,command,params,'COMMAND') end,
            on_status=function(reason,detail)
                local message=reason
                if reason=='timeout' then message='Discovery timed out; update/reconnect Coordinator. Manual Entity ID is available.'
                elseif reason=='coordinator_error' and type(detail)=='table' then
                    local code=detail.code
                    if (code=='not_connected' or code=='connection_changed' or code=='busy' or
                        code=='transport_error') and retry_count<5 then
                        retry_count=retry_count+1; retry_at=now()+math.min(2^retry_count,10)
                        message=tostring(code)..'; retrying entity discovery'
                    else message=tostring(code)..': '..tostring(detail.message):gsub('%c',' '):sub(1,160) end
                elseif reason=='complete' then retry_at=nil; retry_count=0 end
                prop('Discovery Status',message)
                if reason~='loading' and reason~='complete' and not retry_at then complete_browser() end
            end,
            on_complete=function(found)
                rows=found; data_ready=true; render(); complete_browser()
                catalog:refresh(catalog_id())
            end})
    end
    return client:refresh({selector='dimmer',domains={'light','switch','event'},
        attribute_keys={'supported_features','supported_color_modes','entity_id','bridge_contract_version','bridge_control_id','bridge_buttons','bridge_load'},page_size=50})
end
local function controller_link_bound()
    if type(C4.GetBoundProviderDevice)~='function' then return false end
    local own=C4:GetDeviceID()
    for _,binding in pairs(CONTROLLER_BINDINGS) do
        local provider=tonumber(C4:GetBoundProviderDevice(own,binding))
        if provider and provider>0 and provider~=own then return true end
    end
    return false
end
local function manual_controller_mode()
    return type(PersistData)=='table' and PersistData.ControllerModeOverride==true
end
local function select_controller_mode()
    if mode()==CONTROLLER or manual_controller_mode() then return false end
    Properties['Operation Mode']=Modes.label(CONTROLLER)
    prop('Operation Mode',Properties['Operation Mode'])
    trace('mode selected from Controller Link')
    return true
end
local function choose(entity)
    local meta=choice_meta[entity]
    if not meta then status('Selection is no longer in discovery; refresh'); return false end
    -- Selecting a device is a new setup decision. Pick its best supported
    -- mode; a later manual mode edit is retained until another selection.
    local connected=controller_link_bound()
    local next_mode=meta.gesture_id and (connected or selected.mode==CONTROLLER)
        and CONTROLLER or meta.operation_mode
    if type(PersistData)=='table' then PersistData.ControllerModeOverride=connected and next_mode~=CONTROLLER or nil end
    C4:UpdateProperty('Operation Mode',Modes.label(next_mode)); Properties['Operation Mode']=Modes.label(next_mode)
    C4:UpdateProperty('Entity ID',meta.choice_id); Properties['Entity ID']=meta.choice_id
    sync(); render(); refresh(); return true
end
function BrowseHALightDevices(folder,callback,search,filter)
    if not late then return {} end
    if not data_ready then
        if type(callback)=='function' then pending_browser={callback=callback,search=search,filter=filter} end
        if not client or not client.pending then discover() end
        if type(callback)~='function' then return {} end
        return
    end
    local result={}; search=tostring(search or ''):lower(); filter=tostring(filter or 'All Devices')
    filter=({all='All Devices',['all devices']='All Devices',switch='Switches',switches='Switches',
        dimmer='Dimmers',dimmers='Dimmers',gesture='Gestures',gestures='Gestures',['gesture controls']='Gestures'})[filter:lower()] or filter
    for _,row in ipairs(choice_rows) do
        local meta=choice_meta[row.entity_id] or {}
        local load=row
        local load_id=meta.source_entity_id or meta.load_id
        if load_id then
            -- A consolidated gesture row is also a load choice. Prefer current
            -- native discovery metadata; a validated aggregate carries the
            -- linked light's projected capability facts even without that row.
            local native
            for _,candidate in ipairs(rows) do if candidate.entity_id==load_id then native=candidate; break end end
            local validated=not native and aggregate(row)
            load=native or (validated and validated.load) or row
        end
        local facts=Family.classify(load)
        local matches=filter=='All Devices' or (filter=='Gestures' and meta.gesture_id~=nil) or
            (filter=='Dimmers' and facts.kind=='dimmer') or
            (filter=='Switches' and facts.supported and facts.kind=='switch')
        local searchable=row.name..' '..row.entity_id..' '..tostring(meta.load_id or '')..' '..tostring(meta.source_entity_id or '')
        if matches and (search=='' or searchable:lower():find(search,1,true)) then
            result[#result+1]={text=row.name..' ['..row.entity_id..']',value=row.entity_id}
        end
    end
    return result
end
local function receive(command,params)
    if not transport_ready then return false,'disconnected' end
    if (awaiting_snapshot or not subscription:ready()) and command=='RECEIEVE_EVENT' then return false,'waiting_for_snapshot' end
    local started=Properties['Debug Mode']=='On' and C4.GetTime and C4:GetTime() or nil
    local started_tick=started and C4.GetTickCount and C4:GetTickCount() or nil
    sync()
    local parsed=Gestures.parse_proxy(command,params,selected.mode~='Direct')
    local state=parsed.state
    if type(state)~='table' then
        if parsed.error then trace('reject',{{'command',command},{'reason',parsed.error}}) end
        return false
    end
    if state.entity_id~=selected.id then return false end
    local attributes=type(state.attributes)=='table' and state.attributes or {}
    trace('receive',{{'command',command},{'entity',state.entity_id},{'state',state.state},
        {'update',attributes.bridge_update_kind},{'button',attributes.button_id},
        {'kind',attributes.event_type},{'gesture',attributes.gesture_id},
        {'sequence',attributes.gesture_sequence},{'session',attributes.gesture_session_id or attributes.bridge_session_id},
        {'received_utc',Properties['Debug Mode']=='On' and os.date('!%Y-%m-%dT%H:%M:%SZ') or nil}})
    -- GetTime is UTC epoch milliseconds (DriverWorks OS 3.2.3+). This
    -- cross-host estimate includes clock offset; never use it to accept,
    -- reject or schedule gestures. Snapshots/restored history aren't samples.
    if started and command=='RECEIEVE_EVENT' and attributes.bridge_update_kind=='gesture' then
        local occurred=revision(attributes.gesture_occurred_at)
        if occurred then
            local age=started-(occurred.seconds*1000+tonumber(occurred.fraction)/1000000)
            trace('arrival',{{'sequence',attributes.gesture_sequence},{'ha_to_driver_ms',math.floor(age+0.5)}})
        end
    end
    if selected.mode=='Direct' then
        local incoming=revision(state.last_updated)
        if not incoming then trace('decision',{{'accepted',false},{'reason','missing_revision'}}); return false end
        if selected.revision then
            local order=compare(incoming,selected.revision)
            if order<0 or (order==0 and selected.delivery=='RECEIEVE_EVENT' and command=='RECEIEVE_STATE') then
                trace('decision',{{'accepted',false},{'reason','stale_state'}}); return false
            end
        end
        selected.state,selected.facts,selected.revision,selected.delivery=state,Family.classify(state),incoming,command
        screen:observe_name(selected.id,state)
        awaiting_snapshot=not subscription:ready()
        if not awaiting_snapshot then snapshot_retry_at,snapshot_attempts=nil,0 end
        publish(); status(subscription:message() or ('Direct: '..tostring(state.state))); return true
    end
    if selected.mode~='Gesture Bridge' and selected.mode~='Gestures Only' and selected.mode~=CONTROLLER then return false end
    local c=decoder()
    if not c then status(consumer_error); return false end
    local previous=c.last_state
    local original_id,original_mode=selected.id,selected.mode
    local fired,reason,key=c:consume_parsed(parsed)
    if command=='RECEIEVE_STATE' and c.ready then awaiting_snapshot=not subscription:ready() end
    if not awaiting_snapshot then snapshot_retry_at,snapshot_attempts=nil,0 end
    trace('decision',{{'accepted',fired},{'reason',reason},{'gesture',key}})
    -- Event programming can reentrantly change source/mode or destroy driver.
    if not late or consumer~=c or selected.id~=original_id or selected.mode~=original_mode or
        selected.id~=id() or selected.mode~=mode() then sync(); return false end
    if c.ready and c.last_metadata then
        screen:observe_name(selected.id,c.last_state)
        selected.load=c.last_metadata.attributes.bridge_load
        last_sequence=c.last_metadata.attributes.gesture_sequence or 0
        prop('Last Sequence',last_sequence)
    else selected.load=nil end
    local control=leds()
    if control then
        if c.ready and c.last_metadata then control:observe(c.last_metadata.attributes)
        else control:reset() end
        prop('LED Status',control:summary())
    end
    update_led_behavior_ui()
    -- Native LED feedback can synchronously run Composer programming too.
    if not late or consumer~=c or selected.id~=original_id or selected.mode~=original_mode or
        selected.id~=id() or selected.mode~=mode() then sync(); return false end
    if fired then
        forwarded_at=nil
        count=count+1
        prop('Gesture Count',count); prop('Last Gesture',key)
    end
    if selected.mode==CONTROLLER then
        if c.ready and c.last_metadata then
            output:observe(c.last_metadata,(command=='RECEIEVE_STATE' or reason=='snapshot') and 'state' or 'event')
            if fired then
                local sent,output_reason=output:consume(c.last_metadata)
                if output_reason=='unmapped_gesture' then output_reason='programming_event_only' end
                trace('controller',{{'sent',sent},{'reason',output_reason}})
                if started then trace('timing',{{'sequence',last_sequence},{'receive_to_forward_ms',C4:GetTime()-started}}) end
            end
        else output:reset() end
    else output:set_enabled(false) end
    if c.last_state~=previous then publish() end
    status(subscription:message() or (selected.mode..': '..tostring(reason)))
    if fired and started and Properties['Latency Diagnostics']=='On' and late and consumer==c and
        selected.id==original_id and selected.mode==original_mode and selected.id==id() and selected.mode==mode() then
        local a=c.last_metadata and c.last_metadata.attributes
        if a and a.bridge_acknowledgment_version==2 and C4.GetDeviceID then
            local completed=C4:GetTime()
            local elapsed=started_tick and C4:GetTickCount()-started_tick or completed-started
            if elapsed>=0 and elapsed<=60000 then
                local data={entity_id=selected.id,bridge_session_id=a.bridge_session_id,
                    gesture_sequence=a.gesture_sequence,receiver='control4:'..tostring(C4:GetDeviceID()),
                    receiver_received_epoch_ms=started,receiver_processed_epoch_ms=completed,
                    receiver_forwarded_epoch_ms=forwarded_at,receiver_processing_ms=elapsed}
                local sent,result=pcall(C4.SendToProxy,C4,999,'HA_CALL_SERVICE',{
                    JSON=Codec:encode({domain='ha_gesture_bridge',service='acknowledge',service_data=data})})
                trace('acknowledgment',{{'queued',sent and result~=false},{'sequence',a.gesture_sequence},
                    {'received_epoch_ms',started},{'processed_epoch_ms',completed},
                    {'forwarded_epoch_ms',forwarded_at},{'processing_ms',elapsed}})
            else trace('acknowledgment',{{'queued',false},{'reason','invalid_local_duration'}}) end
        else trace('acknowledgment',{{'queued',false},{'reason','bridge_update_required'}}) end
    end
    return fired,reason
end
function OnWatchedVariableChanged(device,variable,value)
    if late and selected.mode==CONTROLLER then return connected:observe(device,variable,value) end
    return false
end
function ReceivedFromProxy(binding,command,params)
    params=params or {}; sync()
    if binding==999 then
        if not coordinator_bound then return false,'coordinator_unbound' end
        if command=='HA_CONNECTION_STATUS' then
            local ready=Discovery.connection_status(params)
            if ready==nil then return false end
            if transport_ready==ready then return true end
            transport_ready,awaiting_snapshot=ready,ready
            clear(); output:set_enabled(ready and late and selected.mode==CONTROLLER)
            retry_at=nil; retry_count=0; rows={}; data_ready=false
            if client then client:invalidate('connection_changed') end
            if catalog then catalog:invalidate('connection_changed') end
            complete_browser(); publish(); render()
            if ready then refresh() else status('Home Assistant disconnected') end
            return true
        end
        if not transport_ready then return false,'disconnected' end
        if command=='HA_SUBSCRIPTION_STATUS' then
            if not subscription:observe(params,selected.id) then return false end
            if subscription:ready() then
                local ready=selected.mode=='Direct' and selected.state~=nil or consumer and consumer.ready
                if ready then
                    awaiting_snapshot=false; snapshot_retry_at,snapshot_attempts=nil,0
                    publish(); render(); status(selected.mode..': '..(selected.mode=='Direct' and selected.state.state or 'snapshot'))
                end
            else
                awaiting_snapshot=true; output:reset(); publish(); render(); status(subscription:message())
            end
            return true
        end
        if command=='HA_ENTITIES' then
            local handled,reason=false,'unhandled'
            if client then handled,reason=client:consume_proxy(command,params) end
            if catalog then
                local catalog_handled,catalog_reason=catalog:consume_proxy(command,params)
                if catalog_handled and catalog_reason~='other_client' and catalog_reason~='stale_response' then
                    return catalog_handled,catalog_reason
                end
            end
            return handled,reason
        end
        if command=='RECEIEVE_STATE' or command=='RECEIEVE_EVENT' then return receive(command,params) end
        return false
    end
    if binding==203 or binding==204 or binding==205 then
        if command=='MATCH_LED_STATE' then
            trace('led feedback',{{'binding',binding},{'state',params.STATE},{'state_type',type(params.STATE)},
                {'source',Properties['LED Feedback Source']},{'behavior',Properties['LED Behavior']}})
        end
        if command=='MATCH_LED_STATE' and selected.mode==CONTROLLER and Properties['LED Behavior']=='Follow Bound Device' then
            local source=Properties['LED Feedback Source'] or 'Disabled'
            local role=({[203]='Top',[204]='Bottom',[205]='Toggle'})[binding]
            local value=feedback_state(params.STATE)
            if role==source and value~=nil then
                local control=leds()
                if not control or not consumer or not consumer.ready or not transport_ready or awaiting_snapshot then return false end
                local matched=false
                for _,button in ipairs(control:buttons()) do
                    if control:get(button) then
                        local ok=led_command('match',button,value)
                        matched=ok or matched
                    end
                end
                trace('led feedback applied',{{'binding',binding},{'state',value},{'sent',matched}})
                return matched
            end
        end
        trace('feedback ignored',{{'binding',binding},{'command',command}})
        return false
    end
    if binding~=5001 and binding~=200 and binding~=201 and binding~=202 then return false end
    trace('input',{{'binding',binding},{'command',command},{'button',params.BUTTON_ID},
        {'action',params.ACTION},{'level',params.LIGHT_BRIGHTNESS_TARGET or params.LEVEL},
        {'rate',params.RATE or params.TIME}})
    if button_notification_depth>0 and (command=='BUTTON_ACTION' or command=='DO_PUSH' or
        command=='DO_CLICK' or command=='DO_RELEASE') then return false,'proxy_button_echo' end
    if command=='SET_BUTTON_COLOR' then return led_command('set_button',led_button(params),params) end
    if command=='SET_ALL_LED' then return led_command('set_all',params.COLOR) end
    if command=='SYNCHRONIZE' or command=='GET_CONNECTED_STATE' then publish(true); return refresh() end
    if command=='GET_LIGHT_LEVEL' then publish(true); return true end
    if command=='CLEAR_ALL_SCENES' then return true end -- This proxy advertises no scene storage.
    if command=='ON' or command=='DYNAMIC_ON' then return service('turn_on') end
    if command=='OFF' or command=='DYNAMIC_OFF' then return service('turn_off') end
    if command=='TOGGLE' then return service('toggle') end
    if command=='SET_LEVEL' then return level(params,false) end
    if command=='RAMP_TO_LEVEL' then return level(params,true) end
    if command=='SET_BRIGHTNESS_TARGET' then return level(params,params.RATE~=nil and tonumber(params.RATE)~=0,true) end
    if command=='BUTTON_ACTION' or command=='DO_PUSH' or command=='DO_CLICK' or command=='DO_RELEASE' then
        local generation=source_generation
        local button=BUTTON_IDS[tonumber(params.BUTTON_ID)] or (binding>=200 and binding<=202 and BUTTON_IDS[binding-200])
        local action=command=='BUTTON_ACTION' and tonumber(params.ACTION) or command=='DO_PUSH' and 1 or command=='DO_CLICK' and 2 or 0
        if not button or (action~=0 and action~=1 and action~=2) then status('Invalid button action'); return false end
        if selected.mode==CONTROLLER then
            local ok,reason=output:action(button,action==1 and 'press' or action==2 and 'click' or 'release')
            if ok then
                if not late or generation~=source_generation or selected.id~=id() or selected.mode~=mode() then sync(); return false,'source_changed' end
                notify('BUTTON_ACTION',{BUTTON_ID=BUTTONS[button],ACTION=action})
            end
            status('C4 Button Controller: '..tostring(reason)); return ok
        end
        if action==2 then
            local ok=service(button=='top' and 'turn_on' or button=='bottom' and 'turn_off' or 'toggle')
            if ok then
                if not late or generation~=source_generation or selected.id~=id() or selected.mode~=mode() then sync(); return false,'source_changed' end
                notify('BUTTON_ACTION',{BUTTON_ID=BUTTONS[button],ACTION=action})
            end
            return ok
        end
        status('Continuous dimming/stop requires a verified backend'); return false
    end
    status('Unsupported native command: '..tostring(command)); return false
end
function OnDriverInit() end
function OnDriverLateInit()
    if late then return end
    late=true
    if controller_link_bound() then select_controller_mode() end
    sync(); prop('Driver Version','1'); prop('Gesture Count',count)
    screen:set_advanced(false)
    if mode()~='Direct' then local c=decoder(); if c then c:start() end end
    -- The selected entity's state carries its capabilities. Rebuilding the
    -- complete picker is setup work, requested only when browsing/refreshing.
    publish(); render(); refresh()
    prop('Discovery Status','Open Select Device to load the device list')
    timer=C4:SetTimer(1000,function()
        if client then client:tick() end
        if catalog then catalog:tick() end
        if retry_at and now()>=retry_at then retry_at=nil; discover() end
        if awaiting_snapshot and transport_ready and snapshot_retry_at and now()>=snapshot_retry_at then
            snapshot_retry_at=nil
            if snapshot_attempts<5 then refresh()
            else status(subscription:message() or 'Unable to load selected entity snapshot; see Coordinator Print Diagnostics') end
        end
        -- Only retry a target that was not yet readable during startup.
        if selected.mode==CONTROLLER and not connected.device and now()>=target_retry_at then
            target_retry_at=now()+5; sync_target(); publish()
        end
    end,true)
end
function OnDriverDestroyed()
    trace('destroyed')
    if late and coordinator_bound and selected.id then C4:SendToProxy(999,'HA_RELEASE_STATES',subscription:release(),'COMMAND') end
    output:set_enabled(false); late=false
    connected:reset()
    retry_at=nil
    if pending_browser then local pending=pending_browser; pending_browser=nil; pcall(pending.callback,{}) end
    if timer then timer:Cancel(); timer=nil end
    if client then client:invalidate('destroyed') end
    if catalog then catalog:invalidate('destroyed') end
    clear()
end
function OnBindingChanged(binding,class,bound)
    trace('binding',{{'id',binding},{'bound',bound}})
    if binding==999 then
        coordinator_bound=bound==true
        transport_ready,awaiting_snapshot=coordinator_bound,coordinator_bound
        clear(); retry_at=nil; retry_count=0
        rows={}; data_ready=false
        if client then client:invalidate('connection_changed') end
        if catalog then catalog:invalidate('connection_changed') end
        complete_browser(); publish(); render()
        if coordinator_bound then refresh() else status('Coordinator disconnected') end
    elseif binding==203 or binding==204 or binding==205 then
        output:reset()
        if late and bound==true and controller_link_bound() and select_controller_mode() then sync(); render(); refresh() end
        if selected.mode==CONTROLLER and consumer and consumer.ready then output:observe(consumer.last_metadata,'state') end
        sync_target(); publish(); render()
    end
end
function OnPropertyChanged(name)
    if name=='Debug Mode' then trace('debug enabled',{{'entity',id()},{'mode',mode()}})
    elseif name=='Entity ID' or name=='Operation Mode' then
        if name=='Operation Mode' then
            if PersistData==nil then PersistData={} end
            if type(PersistData)=='table' then
                PersistData.ControllerModeOverride=mode()~=CONTROLLER and controller_link_bound() or nil
            end
        end
        sync(); render(); refresh()
    elseif name=='App Control Link' then sync_target(); publish(true); render()
    elseif name=='Discovery Catalog Entity ID' then if late then catalog_client():refresh(catalog_id()) end
    elseif name=='LED Behavior' then return apply_led_behavior()
    elseif name=='LED Indicator' then return update_led_colors()
    elseif name=='LED On Color' or name=='LED Off Color' then
        if not late then return false end
        local ok=screen:change_led_color(name,Properties[name],led_command)
        update_led_colors(); return ok
    elseif name=='LED Feedback Source' then
        if updating_led_behavior then return false end
        -- Retire the previous link's match state even when following is disabled.
        local control=leds()
        if control then
            control:reset()
            if consumer and consumer.ready and consumer.last_metadata then control:observe(consumer.last_metadata.attributes) end
            prop('LED Status',control:summary())
        end
        update_led_behavior_ui()
        return request_led_feedback()
    elseif name=='Entity Selection' then local entity=picker.label_to_entity and picker.label_to_entity[Properties[name]]; if entity then return choose(entity) end end
end
function ExecuteCommand(command,params)
    params=params or {}
    if command=='LUA_ACTION' then command=params.ACTION end
    if command=='ShowAdvancedProperties' then if not late then return false end; return screen:set_advanced(true) end
    if command=='HideAdvancedProperties' then if not late then return false end; return screen:set_advanced(false) end
    if command=='PrintDiagnostics' then
        return screen:diagnostics({{'Initialized',late},{'Coordinator bound',coordinator_bound},
            {'App Control Link',Properties['App Control Link'] or 'Top'},{'Connected C4 proxy',connected.device},
            {'Connected C4 light',connected:state().name},
            {'HA transport ready',transport_ready},{'Waiting for fresh snapshot',awaiting_snapshot},
            {'HA event subscription',subscription.status or 'legacy/unknown'},
            {'Snapshot attempts',snapshot_attempts},{'Snapshot retry pending',snapshot_retry_at~=nil},
            {'Gesture consumer ready',not awaiting_snapshot and subscription:ready() and consumer and consumer.ready or false},
            {'Confirmed entity state',selected.state and selected.state.state},
            {'Linked HA load',selected.load and selected.load.entity_id},
            {'Linked HA load state',selected.load and selected.load.state},
            {'Entity discovery',client and client.status},{'Discovery request pending',client and client.pending~=nil or false},
            {'Optional catalog',catalog and catalog.status},{'Discovery retries',retry_count}})
    end
    if command=='RefreshEntities' or command=='Refresh Entities' then refresh(); return discover() end
    if command=='SelectDevice' then return choose(params.Device) end
    if command=='Turn On' then return service('turn_on') end
    if command=='Turn Off' then return service('turn_off') end
    if command=='Toggle' then return service('toggle') end
    if command=='RefreshLEDFeedback' then return request_led_feedback() end
    if command=='Set LED On Color' then return led_command('set_button',led_button(params),{ON_COLOR=params.Color}) end
    if command=='Set LED Off Color' then return led_command('set_button',led_button(params),{OFF_COLOR=params.Color}) end
    if command=='Set LED Current Color' then return led_command('set_button',led_button(params),{CURRENT_COLOR=params.Color}) end
    if command=='Set All LED Colors' then return led_command('set_all',params.Color) end
    if command=='Set LED Brightness' then
        local value=params.Brightness
        return led_command('set_brightness',led_button(params),(type(value)=='number' or type(value)=='string') and tonumber(value) or nil)
    end
    if command=='Set LED Behavior' then
        local behavior=PropertyScreen.led_behavior(params.Behavior)
        if not behavior then prop('LED Status','LEDs: unsupported behavior'); return false end
        return led_command('set_behavior',led_button(params),behavior)
    end
    if command=='Set Level' then return level(params,false) end
    if command=='Ramp To Level' then return level(params,true) end
    status('Unsupported command: '..tostring(command)); return false
end
function GetCommandParamList(command,parameter)
    if command~='Set LED On Color' and command~='Set LED Off Color' and command~='Set LED Current Color'
        and command~='Set LED Brightness' and command~='Set LED Behavior' then return {} end
    if parameter~='Button' and not (command=='Set LED Behavior' and parameter=='Behavior') then return {} end
    sync()
    local control=leds()
    if not late or not transport_ready or awaiting_snapshot or not consumer or not consumer.ready or not control then return {} end
    if parameter=='Behavior' then
        local names={}
        for _,behavior in ipairs(control:behavior_choices_any()) do names[#names+1]=PropertyScreen.LED_BEHAVIOR_LABELS[behavior] end
        return names
    end
    return control:choices(command=='Set LED Brightness',command=='Set LED Current Color')
end
