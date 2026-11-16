-- Production Switch: legacy relay/button links plus opt-in HA gestures.
local Discovery=require('module.discovery')
local CatalogEnrichment=require('module.catalog_enrichment')
local Family=require('module.family_capabilities')
local Gestures=require('module.gestures')
local DeviceChoices=require('module.discovery_choices')
local LoadConditions=require('module.load_conditions')
local Modes=require('module.operation_mode')
local Time=require('module.rfc3339')
local LEDs=require('module.leds')
local Capabilities=require('module.capability_summary')
local PropertyScreen=require('module.property_screen')
local StateSubscription=require('module.state_subscription')
local Codec=Discovery.new_codec()
local Subscription=StateSubscription.new(C4:GetDeviceID(),Codec)
local LateInit, Timer, Client, Picker, Consumer, ConsumerError=false
local Selected={id=false,mode=false}
local Rows={}
local Choices,ChoiceMetadata,ChoiceAliases={},{},{}
local RetryAt,RetryCount=nil,0
local BrowserPending,DataReady=nil,false
local Catalog
local GestureCount,LastGesture,LastSequence=0,'',0
local TransportReady,AwaitingSnapshot=true,false
local LoadDomains={switch=true,input_boolean=true,light=true}
local synchronize, render, decoder, request_discovery, browse_choices, publish_capabilities
local LedControl
local LedStatus
local Screen
local UpdatingLedBehavior,LedBehaviorList=false,nil

local function now() return C4.GetTime and C4:GetTime()/1000 or os.time() end

local function property(name,value)
    if not LateInit then return end
    if Screen then Screen:remember(name,value) end
    if name=='LED Status' then
        if LedStatus==value then return end
        LedStatus=value
    end
    C4:UpdateProperty(name,tostring(value))
end
Screen=PropertyScreen.new({c4=C4,properties=Properties,update=property,driver='HA Switch',version='107'})
local function status(value)
    value=Subscription:message() or value
    value=Modes.status(value); Selected.status=value
    property('Status',Screen:status(value))
end
local function mode()
    return Modes.identity(Properties['Operation Mode'])
end
local function mode_error(current)
    if current=='C4 Button Controller' then return 'Use HA Light for connected C4 light control' end
    return 'Invalid Operation Mode'
end
local function selected_id()
    return type(Properties['Entity ID'])=='string' and Properties['Entity ID'] or ''
end
local function catalog_id()
    local value=Properties['Discovery Catalog Entity ID']
    return value==nil and 'sensor.ha_gesture_bridge_catalog' or value
end

local function leds()
    if LedControl then return LedControl end
    if PersistData==nil then PersistData={} end
    if type(PersistData)~='table' then return nil end
    if PersistData.LEDColors==nil then PersistData.LEDColors={} end
    if type(PersistData.LEDColors)~='table' then return nil end
    LedControl=LEDs.new({store=PersistData.LEDColors,
        send=function(data)
            synchronize()
            if not LateInit or not TransportReady or not Subscription:ready() or AwaitingSnapshot or not Consumer or not Consumer.ready
                or Selected.mode=='Direct' then return false end
            data.entity_id=Selected.id
            C4:SendToProxy(999,'HA_CALL_SERVICE',{JSON=Codec:encode({domain='ha_gesture_bridge',
                service='set_led',service_data=data})})
            return true
        end,
        status=function(value) property('LED Status',value) end})
    return LedControl
end

local function led_command(method,...)
    synchronize()
    local control=leds()
    if not LateInit or not TransportReady or not Subscription:ready() or AwaitingSnapshot or not Consumer or not Consumer.ready
        or Selected.mode=='Direct' or not control then
        property('LED Status','Select a ready gesture control with configured LEDs'); return false
    end
    local ok,reason=control[method](control,...)
    property('LED Status',reason and ('LEDs: '..reason:gsub('_',' ')) or control:summary())
    return ok
end
local function update_led_behavior_ui()
    if not LateInit then return end
    local control=leds()
    if control then control:set_bound_follow(false) end
    local names=PropertyScreen.led_behavior_options(control,false)
    local selected=Properties['LED Behavior'] or 'Use Device Setting'
    -- A saved policy remains visible while its source is offline. Rendering
    -- never re-applies that policy or queues a device setting change.
    if PropertyScreen.led_behavior(selected) then
        local found=false; for _,name in ipairs(names) do if name==selected then found=true end end
        if not found then names[#names+1]=selected end
    else selected='Use Device Setting' end
    local value=table.concat(names,',')
    if value~=LedBehaviorList or Properties['LED Behavior']~=selected then
        UpdatingLedBehavior=true
        C4:UpdatePropertyList('LED Behavior',value,selected)
        UpdatingLedBehavior=false; LedBehaviorList=value
    end
end
local function led_button(params)
    local value=type(params)=='table' and params.Button
    return ({Top='top',Bottom='bottom',Toggle='toggle'})[value] or value
end
function EC.Set_LED_Current_Color(params) return led_command('set_button',led_button(params),{CURRENT_COLOR=params and params.Color}) end
function EC.Set_All_LED_Colors(params) return led_command('set_all',params and params.Color) end
function EC.Set_LED_Brightness(params)
    local value=params and params.Brightness
    return led_command('set_brightness',led_button(params),(type(value)=='number' or type(value)=='string') and tonumber(value) or nil)
end
function EC.Set_LED_Behavior(params)
    local behavior=PropertyScreen.led_behavior(type(params)=='table' and params.Behavior)
    if not behavior then property('LED Status','LEDs: unsupported behavior'); return false end
    return led_command('set_behavior',led_button(params),behavior)
end
local function led_choices(parameter,brightness_only,color_only)
    if parameter~='Button' then return {} end
    synchronize()
    local control=leds()
    if not LateInit or not TransportReady or not Subscription:ready() or AwaitingSnapshot or not Consumer or not Consumer.ready or not control then return {} end
    return control:choices(brightness_only,color_only)
end
function GCPL.Set_LED_Current_Color(parameter) return led_choices(parameter,false,true) end
function GCPL.Set_LED_Brightness(parameter) return led_choices(parameter,true) end
function GCPL.Set_LED_Behavior(parameter)
    if parameter=='Button' then return led_choices(parameter) end
    if parameter~='Behavior' then return {} end
    synchronize()
    local control=leds(); local names={}
    if not LateInit or not TransportReady or not Subscription:ready() or AwaitingSnapshot or not Consumer or not Consumer.ready or not control then return names end
    for _,behavior in ipairs(control:behavior_choices_any()) do names[#names+1]=PropertyScreen.LED_BEHAVIOR_LABELS[behavior] end
    return names
end

local revision,comparison=Time.parse,Time.compare

local function clear_transient()
    if LedControl then LedControl:reset() end
    property('LED Status',mode()=='Direct' and 'Not exposed/configured' or 'Waiting for current LED capabilities')
    Selected.state,Selected.facts,Selected.revision,Selected.delivery,Selected.load=nil,nil,nil,nil,nil
    SWITCH_STATE=nil; Connected=false
    if Consumer then
        Consumer:set_entity_id('')
        Consumer:set_entity_id(selected_id())
    end
    if publish_capabilities then publish_capabilities() end
end
synchronize=function()
    local id,current=selected_id(),mode()
    if Selected.id~=id or Selected.mode~=current then
        Subscription:release()
        Selected.id,Selected.mode=id,current
        clear_transient()
        EntityID=id -- Protect stock refresh callers before a property callback.
        local supported=current=='Direct' or current=='Gesture Bridge' or current=='Gestures Only'
        status(supported and (current..': waiting for current entity state') or mode_error(current))
        return true
    end
    return false
end

local function refresh_state()
    synchronize()
    if not TransportReady then status('Home Assistant disconnected'); return false end
    if Family.entity_domain({entity_id=Selected.id}) then
        C4:SendToProxy(999,'HA_GET_STATE',Subscription:request(Selected.id))
    else
        C4:SendToProxy(999,'HA_RELEASE_STATES',Subscription:release())
        status('Invalid Entity ID')
    end
end

decoder=function()
    if Consumer then return Consumer end
    if ConsumerError then return nil end
    if PersistData==nil then PersistData={} end
    if type(PersistData)~='table' then ConsumerError='Invalid persisted gesture event IDs'; return nil end
    if PersistData.GestureEventIDs==nil then PersistData.GestureEventIDs={} end
    local ok,result=pcall(Gestures.new,{entity_id=Selected.id,c4=C4,
        event_store=PersistData.GestureEventIDs,
        on_status=function(reason)
            if mode()~='Direct' then status(mode()..': '..tostring(reason)) end
        end})
    if not ok then
        ConsumerError=tostring(result):match('(C4:[%w_]+ API is required)') or 'Gesture decoder initialization failed'
        return nil
    end
    Consumer=result
    if LateInit then Consumer:start() end
    return Consumer
end

local function aggregate_choice(row) return Gestures.preview(row,Discovery.null) end

local function summary()
    if Selected.mode~='Direct' and Selected.mode~='Gesture Bridge' and Selected.mode~='Gestures Only' then
        return mode_error(Selected.mode)
    end
    local facts
    if Selected.mode=='Gesture Bridge' then
        if Consumer and Consumer.ready and Selected.load then facts=Family.classify(Selected.load) end
    else facts=Selected.facts end
    return Capabilities.load(Selected.mode,facts,{switch_only=true})
end
publish_capabilities=function()
    property('Selected Capabilities',summary())
    local metadata=TransportReady and Subscription:ready() and not AwaitingSnapshot and Consumer and Consumer.ready and Consumer.last_metadata or nil
    property('Button Capabilities',Capabilities.buttons(metadata,Selected.mode))
end

render=function()
    if not LateInit then return end
    Modes.update_description(Properties,property,'switch')
    synchronize()
    -- Known dimmable lights belong in HA Light. Preserve all saved/manual
    -- IDs; only filter new discovery choices, leaving on/off wrappers usable.
    local switch_rows={}
    for _,row in ipairs(Catalog and Catalog:merge(Rows) or Rows) do
        if row.domain~='light' or not Family.classify(row).capabilities.set_level then
            switch_rows[#switch_rows+1]=row
        end
    end
    Choices,ChoiceMetadata,ChoiceAliases=DeviceChoices.build(switch_rows,{
        selected_entity_id=Selected.id,operation_mode=Selected.mode,validate_aggregate=aggregate_choice})
    Picker=Discovery.build_picker(Choices,{selected_entity_id=ChoiceAliases[Selected.id] or Selected.id})
    C4:UpdatePropertyList('Entity Selection',Picker.value_list,Picker.selected_label)
    Screen:select(Selected.id,Choices,ChoiceAliases,Selected.state)
    if Client and Client.status=='complete' then
        property('Discovery Status',Catalog and Catalog:describe(false,Picker.missing_selected) or 'Complete')
    end
    publish_capabilities()
    update_led_behavior_ui()
end

local function complete_browser()
    if not BrowserPending then return end
    local pending=BrowserPending; BrowserPending=nil
    pcall(pending.callback,browse_choices(pending.search,pending.filter))
end

local TRANSIENT_ERRORS={not_connected=true,connection_changed=true,busy=true,transport_error=true}
local function discovery_status(reason,detail)
    if reason=='complete' then
        RetryAt,RetryCount=nil,0
        property('Discovery Status','Complete')
        return
    end
    if reason=='coordinator_error' and type(detail)=='table' then
        local code=detail.code
        local message=tostring(detail.message or 'Entity discovery failed'):gsub('[%c]',' '):sub(1,180)
        if TRANSIENT_ERRORS[code] and RetryCount<5 and LateInit then
            RetryCount=RetryCount+1
            RetryAt=now()+math.min(2^RetryCount,10)
            property('Discovery Status',tostring(code)..': '..message..' (retry '..RetryCount..'/5)')
            return
        end
        property('Discovery Status',tostring(code)..': '..message)
    elseif reason=='timeout' then
        property('Discovery Status','Discovery timed out; coordinator 1.1.4+ required. Manual Entity ID remains usable')
    else property('Discovery Status',reason) end
    if reason~='loading' then RetryAt=nil; complete_browser() end
end

local function discovery_client()
    if not Client then
        Client=Discovery.new({client_id='ha-switch-'..tostring(C4:GetDeviceID()),timeout=20,
            now=now,
            send=function(binding,command,params) C4:SendToProxy(binding,command,params) end,
            on_status=discovery_status,
            on_complete=function(rows)
                Rows=rows; DataReady=true; render(); complete_browser()
                Catalog:refresh(catalog_id())
            end})
    end
    return Client
end

local function catalog_client()
    if not Catalog then
        Catalog=CatalogEnrichment.new({client_id='ha-switch-catalog-'..tostring(C4:GetDeviceID()),now=now,
            send=function(binding,command,params) C4:SendToProxy(binding,command,params) end,
            on_change=function() render() end})
    end
    return Catalog
end

request_discovery=function()
    if not TransportReady then return false end
    catalog_client():invalidate('refreshing')
    return discovery_client():refresh({selector='switch',domains={'switch','light','event'},
        attribute_keys={'supported_features','supported_color_modes','bridge_contract_version',
            'bridge_control_id','bridge_buttons','bridge_load','entity_id'},
        page_size=50})
end

function EC.Refresh_Entities()
    synchronize()
    if not LateInit then return end
    RetryAt,RetryCount=nil,0
    refresh_state()
    return request_discovery()
end
EC.RefreshEntities=EC.Refresh_Entities
function EC.ShowAdvancedProperties() if not LateInit then return false end; return Screen:set_advanced(true) end
function EC.HideAdvancedProperties() if not LateInit then return false end; return Screen:set_advanced(false) end
function EC.PrintDiagnostics()
    return Screen:diagnostics({{'Initialized',LateInit},{'HA transport ready',TransportReady},
        {'Waiting for fresh snapshot',AwaitingSnapshot},{'Gesture consumer ready',Subscription:ready() and Consumer and Consumer.ready or false},
        {'Confirmed entity state',Selected.state and Selected.state.state},
        {'Linked HA load',Selected.load and Selected.load.entity_id},
        {'Linked HA load state',Selected.load and Selected.load.state},
        {'Entity discovery',Client and Client.status},{'Discovery request pending',Client and Client.pending~=nil or false},
        {'Optional catalog',Catalog and Catalog.status},{'Discovery retries',RetryCount}})
end

local InstalledCallbacks=false
local function install_callbacks()
    if InstalledCallbacks then return end
    InstalledCallbacks=true
    -- Base definitions exist only after commands.lua returns.
    local base_entity=OPC.Entity_ID
    OPC.Entity_ID=function(value)
        synchronize()
        if base_entity then base_entity(value) else EntityID=value; refresh_state() end
        render()
    end
    EC.REFRESH=refresh_state
end

function DRV.OnDriverInit() install_callbacks(); synchronize() end
function DRV.OnDriverLateInit()
    install_callbacks(); LateInit=true; synchronize(); render()
    Screen:set_advanced(false)
    property('LED Status',Selected.mode=='Direct' and 'Not exposed/configured' or 'Waiting for current LED capabilities')
    property('Gesture Count',GestureCount); property('Last Gesture',LastGesture); property('Last Sequence',LastSequence)
    if Selected.mode=='Gesture Bridge' or Selected.mode=='Gestures Only' then
        local consumer=decoder(); if consumer then consumer:start() end
    elseif Selected.mode~='Direct' then
        status(mode_error(Selected.mode))
    end
    publish_capabilities()
    if Timer then Timer:Cancel() end
    Timer=C4:SetTimer(1000,function()
        if synchronize() then render() end
        if Client then Client:tick() end
        if Catalog then Catalog:tick() end
        if RetryAt and now()>=RetryAt then RetryAt=nil; request_discovery() end
    end,true)
    -- State/capabilities for an existing selection do not need a full picker.
    refresh_state()
    property('Discovery Status','Open Select Device to load the device list')
end
function DRV.OnBindingChanged(binding,class,bound)
    if binding~=999 then return end
    Subscription:release()
    TransportReady=bound==true; AwaitingSnapshot=false
    synchronize(); clear_transient()
    RetryAt,RetryCount=nil,0
    Rows={}; DataReady=false; render()
    if Client then Client:invalidate(bound and 'reconnected' or 'disconnected') end
    if Catalog then Catalog:invalidate('connection_changed') end
    complete_browser()
    if bound then refresh_state() else status('Coordinator disconnected') end
end
function DRV.OnDriverDestroyed()
    C4:SendToProxy(999,'HA_RELEASE_STATES',Subscription:release())
    LateInit=false
    RetryAt=nil
    if BrowserPending then local pending=BrowserPending; BrowserPending=nil; pcall(pending.callback,{}) end
    if Timer then Timer:Cancel(); Timer=nil end
    if Client then Client:invalidate('destroyed') end
    if Catalog then Catalog:invalidate('destroyed') end
    clear_transient()
end
function OPC.Operation_Mode()
    synchronize(); render()
    if LateInit then refresh_state() end
end
function OPC.Discovery_Catalog_Entity_ID()
    if not LateInit then return end
    catalog_client():refresh(catalog_id())
end
function OPC.LED_Behavior(value)
    if not LateInit or UpdatingLedBehavior then return false end
    synchronize()
    local control=leds(); if control then control:set_bound_follow(false) end
    if value=='Use Device Setting' then
        if control then property('LED Status',control:summary()) end
        update_led_behavior_ui(); return true
    end
    local behavior=PropertyScreen.led_behavior(value)
    if not behavior then property('LED Status','LEDs: unsupported behavior'); return false end
    local ok=led_command('set_all_behavior',behavior)
    update_led_behavior_ui(); return ok
end
local function choose_device(id)
    if not LateInit then return end
    if type(id)~='string' then return end
    local metadata=ChoiceMetadata[id]
    if not metadata then status('Selected device is no longer in discovery; refresh and select again'); return false end
    id=metadata.choice_id
    local target_mode=metadata.operation_mode
    C4:UpdateProperty('Operation Mode',Modes.label(target_mode))
    Properties['Operation Mode']=Modes.label(target_mode)
    C4:UpdateProperty('Entity ID',id); Properties['Entity ID']=id
    OPC.Entity_ID(id)
    return true
end
function OPC.Entity_Selection(value)
    if not Picker then return end
    return choose_device(Picker.label_to_entity[value])
end

local function browser_type(row)
    local metadata=ChoiceMetadata[row.entity_id] or {}
    if metadata.is_group then return 'group' end
    local load=row
    for _,candidate in ipairs(Rows) do
        if candidate.entity_id==(metadata.source_entity_id or metadata.load_id) then load=candidate; break end
    end
    local facts=Family.classify(load)
    if facts.supported then return 'switch' end
    return 'gesture'
end
browse_choices=function(search,filter)
    search=tostring(search or ''):lower()
    filter=tostring(filter or 'all'):lower()
    local filters={['all devices']='all',switches='switch',groups='group',
        ['gesture controls']='gesture',gestures='gesture'}
    filter=filters[filter] or filter
    local result,names={},{}
    for _,row in ipairs(Choices) do names[row.name]=(names[row.name] or 0)+1 end
    for _,row in ipairs(Choices) do
        local metadata=ChoiceMetadata[row.entity_id] or {}
        local kind=browser_type(row)
        local matches=filter=='all' or filter=='' or kind==filter or
            (filter=='gesture' and metadata.gesture_id~=nil)
        local searchable=(tostring(row.name)..' '..row.entity_id..' '..tostring(metadata.load_id or '')..' '..tostring(metadata.source_entity_id or '')):lower()
        if matches and (search=='' or searchable:find(search,1,true)) then
            local text=row.name..' — '..({switch='Switch',group='Group',gesture='Gestures'})[kind]
            if names[row.name]>1 then text=text..' ['..row.entity_id..']' end
            result[#result+1]={text=text,value=row.entity_id}
        end
    end
    table.sort(result,function(a,b) return a.text:lower()<b.text:lower() end)
    return result
end

-- Composer's native searchable CUSTOM_SELECT dialog. It is read-only until
-- its Select Device action is confirmed; search/filter never changes a target.
function BrowseHADevices(folder,callback,search,filter)
    if not LateInit then return {} end
    if DataReady then return browse_choices(search,filter) end
    if type(callback)=='function' then BrowserPending={callback=callback,search=search,filter=filter} end
    if not discovery_client().pending then request_discovery() end
    if type(callback)~='function' then return {} end
end
function EC.SelectDevice(params)
    params=params or {}
    local id=params.Device
    if type(id)~='string' or not id:match('^[a-z][a-z0-9_]*%.[a-z0-9_]+$') then
        status('Select exactly one device'); return false
    end
    return choose_device(id)
end
local function load_target()
    synchronize()
    if not Subscription:ready() then return nil,Subscription:message() end
    if not TransportReady or AwaitingSnapshot then return nil,'Home Assistant connection is not ready' end
    if Selected.mode=='Gestures Only' then return nil,'Gestures Only: load commands disabled' end
    if Selected.mode=='Gesture Bridge' then
        local consumer=decoder()
        local load=Selected.load
        if not consumer or not consumer.ready or not load or not load.available
            or (load.state~='on' and load.state~='off') then return nil,'No ready validated bridge load' end
        return load.entity_id,load.domain
    end
    if Selected.mode~='Direct' then return nil,mode_error(Selected.mode) end
    local domain=Family.entity_domain({entity_id=Selected.id})
    if not LoadDomains[domain] then return nil,'Unsupported direct load entity' end
    if Selected.state then
        if Selected.state.state~='on' and Selected.state.state~='off' then return nil,'Selected load is unknown or unavailable' end
    elseif domain=='light' then return nil,'Waiting for selected light state and capabilities' end
    -- Preserve manual switch/input_boolean On/Off before its first refresh.
    return Selected.id,domain
end

local function service(action,data)
    local id,domain=load_target()
    if not id then status(domain); return false end
    C4:SendToProxy(999,'HA_CALL_SERVICE',{JSON=Codec:encode({domain=domain,service=action,
        service_data=Codec:newObject(data or {}),target={entity_id=id}})})
    if action=='turn_on' then SWITCH_STATE='closed' elseif action=='turn_off' then SWITCH_STATE='open' end
    status(Selected.mode..': '..action)
    return true
end
function SwitchControl(action) return service(action) end
function EC.Turn_On() return service('turn_on') end
function EC.Turn_Off() return service('turn_off') end
function EC.Toggle()
    synchronize()
    if SWITCH_STATE=='open' then return service('turn_on') end
    if SWITCH_STATE=='closed' then return service('turn_off') end
    return service('toggle')
end
function RFP.CLOSE() return EC.Turn_On() end
function RFP.OPEN() return EC.Turn_Off() end
function RFP.TOGGLE() return EC.Toggle() end
function RFP.BUTTON_ACTION(binding,command,params)
    synchronize()
    if tostring(params.ACTION)~='2' then return false end
    if tostring(params.BUTTON_ID)=='0' then return EC.Turn_On() end
    if tostring(params.BUTTON_ID)=='1' then return EC.Turn_Off() end
    return EC.Toggle()
end
function RFP.DO_CLICK(binding)
    if binding==200 then return EC.Turn_On() end
    if binding==201 then return EC.Turn_Off() end
    if binding==202 then return EC.Toggle() end
    return false
end
function RFP.DO_PUSH() return false end
function RFP.DO_RELEASE() return false end

-- Composer uses this same callback for If conditionals and While loops.
-- Read only confirmed selected-load snapshots, never optimistic SWITCH_STATE
-- or discovery previews. A conditional evaluation must not poll/control HA.
function TestCondition(name,params)
    if name~='IS_ON' and name~='IS_OFF' then return false end
    synchronize()
    if not Subscription:ready() then return false end
    if Selected.mode=='Direct' then
        return LoadConditions.evaluate(name,params,Selected.state,Selected.facts)
    end
    if Selected.mode=='Gesture Bridge' and Consumer and Consumer.ready and Selected.load
        and Selected.load.available==true then
        local load=Selected.load
        local state={entity_id=load.entity_id,domain=load.domain,state=load.state}
        return LoadConditions.evaluate(name,params,state,Family.classify(state))
    end
    return false
end

local function relay(state)
    if not Subscription:ready() then return end
    if state~='on' and state~='off' then return end
    Connected=true; SWITCH_STATE=state=='on' and 'closed' or 'open'
    C4:SendToProxy(1,state=='on' and 'CLOSED' or 'OPENED',{},'NOTIFY')
end
local function receive(command,params)
    synchronize()
    if not TransportReady then return false,'disconnected' end
    if not Subscription:ready() and command=='RECEIEVE_EVENT' then return false,'subscription_not_ready' end
    if AwaitingSnapshot and command=='RECEIEVE_EVENT' then return false,'waiting_for_snapshot' end
    local parsed=Gestures.parse_proxy(command,params,Selected.mode~='Direct')
    local state=parsed.state
    if type(state)~='table' or state.entity_id~=Selected.id then return false end
    if Selected.mode=='Direct' then
        local incoming=revision(state.last_updated)
        if Selected.revision then
            if not incoming then return false,'missing_revision' end
            local compared=comparison(incoming,Selected.revision)
            if compared<0 or (compared==0 and command=='RECEIEVE_STATE' and Selected.delivery=='RECEIEVE_EVENT') then
                return false,'stale_state'
            end
        end
        Selected.state=state; Selected.facts=Family.classify(state)
        Screen:observe_name(Selected.id,state)
        Selected.revision=incoming; Selected.delivery=command
        AwaitingSnapshot=false
        relay(state.state)
        status('Direct: '..tostring(state.state)); publish_capabilities()
        return true
    end
    if Selected.mode~='Gesture Bridge' and Selected.mode~='Gestures Only' then
        status(mode_error(Selected.mode)); return false
    end
    local consumer=decoder()
    if not consumer then Selected.load=nil; status(ConsumerError or 'Gesture support unavailable'); return false end
    local previous=consumer.last_state
    local source_id,source_mode=Selected.id,Selected.mode
    local fired,reason,key=consumer:consume_parsed(parsed)
    if command=='RECEIEVE_STATE' and consumer.ready then AwaitingSnapshot=false end
    -- Composer event programming may change selection synchronously while an
    -- event fires. Such an event cannot then operate a new source's binding.
    if synchronize() or Selected.id~=source_id or Selected.mode~=source_mode then
        render(); return fired,reason,key
    end
    if not consumer.ready or not consumer.last_metadata then Selected.load=nil
    elseif consumer.last_state~=previous then
        Screen:observe_name(Selected.id,state)
        Selected.load=consumer.last_metadata.attributes.bridge_load
        LastSequence=consumer.last_metadata.attributes.gesture_sequence or 0
        property('Last Sequence',LastSequence)
        if Selected.mode=='Gesture Bridge' and Selected.load then relay(Selected.load.state) end
    end
    local control=leds()
    if control then
        if consumer.ready and consumer.last_metadata then control:observe(consumer.last_metadata.attributes)
        else control:reset() end
        property('LED Status',control:summary())
    end
    update_led_behavior_ui()
    if not LateInit or Consumer~=consumer or Selected.id~=source_id or Selected.mode~=source_mode or
        Selected.id~=selected_id() or Selected.mode~=mode() then synchronize(); return false end
    if fired then
        GestureCount=GestureCount+1; LastGesture=key
        property('Gesture Count',GestureCount); property('Last Gesture',LastGesture)
    end
    publish_capabilities()
    return fired,reason,key
end
function RFP.RECEIEVE_STATE(binding,command,params)
    if binding~=999 then return false end
    return receive('RECEIEVE_STATE',params)
end
function RFP.RECEIEVE_EVENT(binding,command,params)
    if binding~=999 then return false end
    return receive('RECEIEVE_EVENT',params)
end
function RFP.HA_CONNECTION_STATUS(binding,command,params)
    if binding~=999 then return false end
    local ready=Discovery.connection_status(params)
    if ready==nil then return false end
    if TransportReady==ready then return true end
    Subscription:release()
    TransportReady,AwaitingSnapshot=ready,ready
    clear_transient()
    RetryAt,RetryCount=nil,0
    Rows={}; DataReady=false
    if Client then Client:invalidate('connection_changed') end
    if Catalog then Catalog:invalidate('connection_changed') end
    complete_browser(); render()
    if ready then refresh_state() else status('Home Assistant disconnected') end
    return true
end
function RFP.HA_SUBSCRIPTION_STATUS(binding,command,params)
    if binding~=999 or not TransportReady then return false end
    synchronize()
    if not Subscription:observe(params,Selected.id) then return false end
    if not Subscription:ready() then
        if params.STATUS=='error' then clear_transient() end
        status(Subscription:message()); publish_capabilities()
        return true
    end
    if Selected.mode=='Direct' and Selected.state then
        relay(Selected.state.state); status('Direct: '..tostring(Selected.state.state))
    elseif Consumer and Consumer.ready and Consumer.last_metadata then
        if Selected.mode=='Gesture Bridge' and Selected.load then relay(Selected.load.state) end
        status(Selected.mode..': snapshot')
    else status('Waiting for selected entity snapshot') end
    publish_capabilities()
    return true
end
function RFP.HA_ENTITIES(binding,command,params)
    if not TransportReady then return true,'disconnected' end
    if binding~=999 then return false end
    synchronize()
    local handled,reason=discovery_client():consume_proxy(command,params)
    if Catalog then
        local catalog_handled,catalog_reason=Catalog:consume_proxy(command,params)
        if catalog_handled and catalog_reason~='other_client' and catalog_reason~='stale_response' then
            return catalog_handled,catalog_reason
        end
    end
    return handled,reason
end
