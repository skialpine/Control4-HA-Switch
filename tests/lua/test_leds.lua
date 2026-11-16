local LEDs=require('module.leds')
local Codec=require('module.discovery').new_codec()
local assertions=0
local function check(value,message) assertions=assertions+1; assert(value,message or ('assertion '..assertions)) end
local function eq(actual,expected,message) check(actual==expected,(message or '')..' expected '..tostring(expected)..', got '..tostring(actual)) end
local function copy(value) return Codec:decode(Codec:encode(value)) end
local function channel(id,button,colors)
    local palette=colors or {'000000','FFFFFF','FF0000','00FF00','0000FF'}
    local nonblack=0
    for _,candidate in ipairs(palette) do if candidate~='000000' then nonblack=nonblack+1 end end
    return {id=id or 'indicator',label='Indicator',button_id=button or 'toggle',available=true,
        colors=Codec:newArray(palette),color_supported=nonblack>1,
        behaviors=Codec:newArray({'follow_load','follow_load_inverted','always_on','always_off'}),behavior='always_on',
        brightness_supported=true,color='00FF00',brightness=50}
end
local function metadata(channels)
    return {bridge_control_id='control-one',bridge_session_id='session-one',bridge_led_version=1,
        bridge_led_command_version=2,
        bridge_leds=Codec:newArray(channels or {channel()})}
end
local function runtime(store)
    local r={sent={},notifications={},statuses={},accept=true,store=store or {}}
    r.leds=LEDs.new({store=r.store,
        send=function(data)
            r.sent[#r.sent+1]=copy(data)
            if r.on_send then r.on_send() end
            if r.fail then error('Injected service failure') end
            return r.accept
        end,
        notify=function(button,info)
            r.notifications[#r.notifications+1]={button=button,info=copy(info)}
            if r.on_notify then r.on_notify() end
        end,
        status=function(value) r.statuses[#r.statuses+1]=value end})
    r.leds:set_bound_follow(true) -- Fixture simulates an explicit Follow Bound Device choice.
    return r,r.leds
end

local r,leds=runtime()
eq(leds:observe({}),false); eq(leds:get('toggle'),nil)
eq(leds:set_button('toggle',{CURRENT_COLOR='FF0000'}),false)
eq(leds:match('toggle',true),false); eq(#r.sent,0)
local attrs=metadata()
eq(leds:observe(attrs),true); eq(#r.sent,0); eq(next(r.store),nil,'Snapshot cannot write preferences')
eq(leds:get('top'),nil,'One Zooz indicator is not a separate LED for each paddle')
eq(leds:get(0),nil); eq(leds:get(1),nil)
local info=leds:get(2)
eq(info.ON_COLOR,'FFFFFF'); eq(info.OFF_COLOR,'000000'); eq(info.CURRENT_COLOR,'00FF00')
eq(leds:choices()[1],'Toggle','Existing standard button choices retain their saved values')
info.CURRENT_COLOR='FF0000'; eq(leds:get('toggle').CURRENT_COLOR,'00FF00')
check(leds:summary():find('toggle',1,true))
local renamed=copy(attrs); renamed.bridge_leds[1].label='Renamed Indicator'
eq(leds:observe(renamed),true); eq(#r.sent,0)
eq(#r.notifications,1,'Unchanged LED facts must not add native callbacks to each gesture')
attrs.bridge_leds[1].color='FF0000'
eq(leds:get('toggle').CURRENT_COLOR,'00FF00','Caller metadata cannot mutate confirmed feedback')
attrs=metadata()

local ok,reason=leds:set_button(2,{ON_COLOR='ee0000'})
check(ok); eq(reason,'configured_quantized'); eq(#r.sent,0,'Unknown logical state must not operate hardware')
eq(r.store['control-one'].indicator.ON_COLOR,'FF0000')
eq(leds:get('toggle').CURRENT_COLOR,'00FF00','Preference changes are not confirmed hardware state')
check(r.statuses[#r.statuses]:find('quantized',1,true))
eq(leds:set_button('toggle',{CURRENT_COLOR='ff0000'}),true)
eq(#r.sent,1); eq(r.sent[1].led_id,'indicator'); eq(r.sent[1].color,'FF0000')
eq(r.sent[1].entity_id,nil,'Entry point owns the selected entity binding')
eq(leds:get('toggle').CURRENT_COLOR,'00FF00')
eq(leds:set_button('toggle',{CURRENT_COLOR='FF0000'}),true)
eq(#r.sent,2,'A pending request cannot suppress a retry before confirmation')
attrs.bridge_leds[1].color='FF0000'
eq(leds:observe(attrs),true); eq(#r.sent,2,'Confirmation snapshot does not echo a write')
eq(r.notifications[#r.notifications].info.CURRENT_COLOR,'FF0000')
eq(leds:set_button('toggle',{CURRENT_COLOR='FF0000'}),true); eq(#r.sent,2,'Confirmed hardware state deduplicates')
eq(leds:match('toggle',true),true); eq(#r.sent,2)
eq(leds:match('toggle',false),true); eq(r.sent[3].color,'000000')
eq(leds:match('toggle',false),true); eq(#r.sent,4,'Unconfirmed match requests can retry')
attrs.bridge_leds[1].color='000000'; attrs.bridge_leds[1].behavior='always_off'; leds:observe(attrs)
eq(leds:match('toggle',false),true); eq(#r.sent,4)
eq(leds:set_button('toggle',{ON_COLOR='0000FF'}),true); eq(#r.sent,4,'Changing the future On color preserves confirmed Off')
eq(leds:set_brightness(2,12.5),true); eq(r.sent[5].brightness,12.5); eq(r.sent[5].color,nil)
eq(leds:set_brightness(2,12.5),true); eq(#r.sent,6)
attrs.bridge_leds[1].brightness=12.5; leds:observe(attrs)
eq(leds:set_brightness(2,12.5),true); eq(#r.sent,6)
for _,invalid in ipairs({false,{},'50',-1,101,0/0,math.huge}) do
    eq(leds:set_brightness(2,invalid),false); eq(#r.sent,6)
end
r.accept=false
eq(leds:match('toggle',true),false); eq(leds:get(2).CURRENT_COLOR,'000000')
r.accept=true
eq(leds:match('toggle',true),true); eq(#r.sent,8,'Rejected commands must remain retryable')
r.fail=true; eq(leds:match('toggle',true),false)
r.fail=false; eq(leds:match('toggle',true),true); eq(#r.sent,10,'Thrown service errors must remain retryable')
local persisted=copy(r.store)
leds:reset(); eq(leds:get(2),nil); eq(leds:match(2,true),false); eq(#r.sent,10)
r,leds=runtime(persisted)
leds:observe(metadata()); eq(#r.sent,0); eq(leds:get(2).ON_COLOR,'0000FF','Reload restores preferences, not an output')
leds:match(2,true); local requests=#r.sent
local restarted=metadata(); restarted.bridge_session_id='session-two'
leds:observe(restarted)
leds:set_button(2,{ON_COLOR='FFFFFF'}); eq(#r.sent,requests,'New session clears logical state without replay')
local other=metadata(); other.bridge_control_id='another-control'
leds:observe(other); eq(leds:get(2).ON_COLOR,'FFFFFF','Another control cannot inherit preferences')
other.bridge_leds[1].available=false; other.bridge_leds[1].color=nil
leds:observe(other); eq(leds:get(2),nil); eq(leds:set_brightness(2,25),false); eq(#r.sent,requests)

-- Every malformed catalog revokes authority atomically, without modifying
-- preferences or sending services. No partially valid channel survives.
local invalid={
    function(a) a.bridge_led_version=2 end,
    function(a) a.bridge_led_version='1' end,
    function(a) a.bridge_control_id=false end,
    function(a) a.bridge_session_id=Codec.null end,
    function(a) a.bridge_leds=Codec.null end,
    function(a) a.bridge_leds=Codec:newObject() end,
    function(a) a.bridge_leds[2]=a.bridge_leds[1]; a.bridge_leds[1]=nil end,
    function(a) a.bridge_leds[2]=copy(a.bridge_leds[1]) end,
    function(a) local b=copy(a.bridge_leds[1]); b.id='another'; a.bridge_leds[2]=b end,
    function(a) a.bridge_leds[1].id='bad/id' end,
    function(a) a.bridge_leds[1].button_id=false end,
    function(a) a.bridge_leds[1].label={} end,
    function(a) a.bridge_leds[1].available='true' end,
    function(a) a.bridge_leds[1].brightness_supported=1 end,
    function(a) a.bridge_leds[1].colors=Codec.null end,
    function(a) a.bridge_leds[1].colors=Codec:newObject() end,
    function(a) a.bridge_leds[1].colors={'FFFFFF','FFFFFF'} end,
    function(a) a.bridge_leds[1].colors={'ffffff'} end,
    function(a) a.bridge_leds[1].colors={false} end,
    function(a) a.bridge_leds[1].color='F0F0F0' end,
    function(a) a.bridge_leds[1].color=Codec.null end,
    function(a) a.bridge_leds[1].brightness=false end,
    function(a) a.bridge_leds[1].brightness=0/0 end,
    function(a) a.bridge_leds[1].brightness=101 end,
    function(a) a.bridge_leds[1].brightness_supported=false end,
}
for _,mutate in ipairs(invalid) do
    r,leds=runtime(); leds:observe(metadata())
    local value=metadata(); mutate(value)
    eq(leds:observe(value),false)
    eq(leds:get('toggle'),nil); eq(leds:set_all('FFFFFF'),false)
    eq(#r.sent,0); eq(next(r.store),nil)
end
local many={}
for index=1,16 do many[index]=channel('led_'..index,'button_'..index) end
r,leds=runtime(); eq(leds:observe(metadata(many)),true)
many[17]=channel('led_17','button_17'); eq(leds:observe(metadata(many)),false)
local palette={'000000'}
for index=1,64 do palette[#palette+1]=string.format('%06X',index) end
local bounded=channel('indicator','toggle',palette); bounded.color=nil
eq(leds:observe(metadata({bounded})),true)
bounded.colors[#bounded.colors+1]='FFFFFF'; eq(leds:observe(metadata({bounded})),false)

-- A black request is exact capability matching. Near-black requests choose
-- a nonblack advertised color, never accidentally turning the indicator off.
local no_black=channel('indicator','toggle',{'FF0000','0000FF'}); no_black.color=nil
r,leds=runtime(); leds:observe(metadata({no_black}))
eq(leds:get(2).OFF_COLOR,nil)
eq(leds:set_button(2,{CURRENT_COLOR='000000'}),false); eq(#r.sent,0)
eq(leds:set_button(2,{CURRENT_COLOR='000001'}),true); eq(r.sent[1].color,'0000FF')
local black_only=channel('indicator','toggle',{'000000'}); black_only.color=nil
leds:observe(metadata({black_only}))
eq(leds:match(2,true),false,'Missing On palette must not fall back to the Off preference')
eq(#r.sent,1); eq(leds:match(2,false),true); eq(r.sent[2].color,'000000')

-- set_all validates every available channel before any write or preference
-- change. An unavailable channel cannot prevent supported targets updating.
local top=channel('top_led','top',{'000000','FF0000'}); top.color='000000'
local bottom=channel('bottom_led','bottom',{'0000FF'}); bottom.color='0000FF'
top.color_supported=true; bottom.color_supported=true
r,leds=runtime(); leds:observe(metadata({top,bottom}))
eq(leds:set_all('000000'),false); eq(#r.sent,0); eq(next(r.store),nil)
eq(leds:set_all('00FFFF'),true); eq(#r.sent,1,'Already-confirmed bottom color needs no write')
eq(r.sent[1].led_id,'top_led'); eq(r.sent[1].color,'FF0000')
eq(leds:get('top').ON_COLOR,'FF0000'); eq(leds:get('top').OFF_COLOR,'FF0000')
eq(leds:get('bottom').ON_COLOR,'0000FF'); eq(leds:get('bottom').OFF_COLOR,'0000FF')
eq(leds:get('top').CURRENT_COLOR,'000000')
for _,bad in ipairs({false,{},'', '#FFFFFF','GG0000'}) do
    local before=Codec:encode(r.store)
    eq(leds:set_button('top',{ON_COLOR='FFFFFF',CURRENT_COLOR=bad}),false)
    eq(Codec:encode(r.store),before); eq(#r.sent,1)
end
bottom.available=false; leds:observe(metadata({top,bottom}))
eq(leds:set_all('000000'),false); eq(#r.sent,1,'Black requires explicit Off behavior even if current feedback is black')

-- BUTTON_INFO notification can run Composer programming synchronously. An
-- old command must not save preferences or send against the new source.
r,leds=runtime(); leds:observe(metadata({top,bottom}))
local replacement=metadata(); replacement.bridge_control_id='replacement'
r.on_notify=function() r.on_notify=nil; leds:reset(); leds:observe(replacement) end
local accepted,why=leds:set_button('top',{OFF_COLOR='FF0000',CURRENT_COLOR='FF0000'})
eq(accepted,false); eq(why,'source_changed'); eq(#r.sent,0)
eq(leds:get('toggle').CURRENT_COLOR,'00FF00')
r,leds=runtime(); leds:observe(metadata({top,bottom}))
r.on_notify=function() r.on_notify=nil; leds:reset(); leds:observe(replacement) end
eq(leds:set_all('FF0000'),false); eq(#r.sent,0)
eq(r.store.replacement,nil,'An interrupted plan cannot save old channels under the replacement control')
local unicode=metadata(); unicode.bridge_leds[1].label=string.rep('💡',128)
eq(leds:observe(unicode),true,'LED labels use Unicode character limits')
unicode.bridge_leds[1].label=string.rep('💡',129); eq(leds:observe(unicode),false)
local monochrome=channel('indicator','toggle',{'000000','FFFFFF'}); monochrome.color='000000'
eq(leds:observe(metadata({monochrome})),true)
eq(leds:summary(),'LEDs: toggle (on/off, single color, brightness, always on)','A monochrome indicator must not claim color selection or a physical white LED')
monochrome.brightness_supported=false; monochrome.brightness=nil
leds:observe(metadata({monochrome}))
eq(leds:summary(),'LEDs: toggle (on/off, single color, always on)')
leds:reset(); eq(leds:summary(),'Not exposed/configured','Absent capabilities make no hardware support claim')

-- A scene controller's independent indicators use stable channel identities,
-- including duplicate friendly labels and labels renamed after programming.
local scene_channels={}
for index=1,5 do
    local item=channel('scene_'..index,'button_'..index)
    item.label=index<3 and 'Scene LED' or 'Button '..index..' LED'
    if index==5 then item.brightness_supported=false; item.brightness=nil end
    scene_channels[index]=item
end
r,leds=runtime(); eq(leds:observe(metadata(scene_channels)),true)
local names=leds:choices(); eq(#names,5); eq(#leds:choices(true),4)
local saved='Scene LED [scene_1]'
eq(leds:set_button(saved,{CURRENT_COLOR='FF0000'}),true)
eq(r.sent[1].led_id,'scene_1'); eq(r.sent[1].color,'FF0000')
eq(leds:get(saved).CURRENT_COLOR,'00FF00','Custom channels also wait for confirmed color feedback')
eq(leds:set_button('Scene LED [scene_2]',{ON_COLOR='0000FF'}),true)
eq(r.store['control-one'].scene_2.ON_COLOR,'0000FF')
scene_channels[1].label='Renamed primary LED'
scene_channels[1].color='FF0000'
leds:observe(metadata(scene_channels))
eq(leds:get(saved).CURRENT_COLOR,'FF0000')
eq(leds:set_brightness(saved,25),true,'Stored selector survives a friendly label rename')
eq(r.sent[2].led_id,'scene_1'); eq(r.sent[2].brightness,25)
eq(leds:set_button('Scene LED [missing]',{CURRENT_COLOR='FFFFFF'}),false)
eq(leds:set_button('Scene LED [scene_1] trailing',{CURRENT_COLOR='FFFFFF'}),false)
eq(leds:set_brightness('Button 5 LED [scene_5]',25),false)
eq(#r.sent,2,'Invalid or unsupported choices send no service')
scene_channels[1].available=false; leds:observe(metadata(scene_channels))
eq(leds:get(saved),nil); eq(#leds:choices(),4); eq(#leds:choices(true),3)
eq(leds:set_button(saved,{CURRENT_COLOR='FFFFFF'}),false)
eq(#r.sent,2,'A saved selector cannot bypass current availability')

-- A visible color request must not replace the device's existing LED behavior.
local load_follows=metadata()
load_follows.bridge_leds[1].behavior='follow_load_inverted'
load_follows.bridge_leds[1].color=nil
r,leds=runtime(); leds:observe(load_follows)
check(leds:summary():find('on when local load off',1,true),'Current hardware behavior remains visible under Use Device Setting')
eq(leds.command_version,2); eq(#leds:behavior_choices(),4)
eq(leds:behavior_choices()[1],'follow_load'); eq(leds:behavior_choices()[2],'follow_load_inverted')
check(leds:supports_bound_follow())
eq(leds:set_button('toggle',{CURRENT_COLOR='FF0000'}),true)
eq(r.sent[1].color,'FF0000'); eq(r.sent[1].behavior,nil); eq(r.sent[1].brightness,nil)
eq(leds:get('toggle').CURRENT_COLOR,nil,'Setting a stored color while the LED is off does not invent lit feedback')
eq(leds.channels.toggle.behavior,'follow_load_inverted')
eq(leds:set_button('toggle',{CURRENT_COLOR='000000'}),false)
eq(#r.sent,1,'A black color request cannot silently change the mode parameter')
eq(leds:set_brightness('toggle',30),true)
eq(r.sent[2].brightness,30); eq(r.sent[2].behavior,nil); eq(r.sent[2].color,nil)

-- Choosing an explicit behavior sends a mode request only, and waits for its
-- independent hardware confirmation before deduplicating subsequent requests.
eq(leds:set_behavior('toggle','follow_load'),true)
eq(r.sent[3].behavior,'follow_load'); eq(r.sent[3].color,nil); eq(r.sent[3].brightness,nil)
eq(leds.channels.toggle.behavior,'follow_load_inverted')
eq(leds:set_behavior('toggle','follow_load'),true); eq(#r.sent,4)
load_follows.bridge_leds[1].behavior='follow_load'
leds:observe(load_follows); eq(#r.sent,4,'A behavior confirmation snapshot never writes the device')
eq(leds:set_behavior('toggle','follow_load'),true); eq(#r.sent,4)
eq(leds:set_behavior('toggle','always_off'),true)
eq(r.sent[5].behavior,'always_off'); eq(r.sent[5].color,nil)
for _,bad in ipairs({false,{},'','load','Always On'}) do
    eq(leds:set_behavior('toggle',bad),false); eq(#r.sent,5)
end
eq(leds:set_behavior('missing','always_on'),false)

-- Color preferences are configuration, even when the bound device's current
-- state has already been received. Only a later explicit feedback applies it.
r,leds=runtime(); leds:observe(metadata())
eq(leds:match('toggle',true),true); eq(#r.sent,1)
eq(r.sent[1].behavior,'always_on'); eq(r.sent[1].color,'FFFFFF')
eq(leds:set_button('toggle',{ON_COLOR='FF0000',OFF_COLOR='0000FF'}),true)
eq(#r.sent,1,'Changing On/Off colors must not send either color or mode')
eq(leds:match('toggle',false),true)
eq(r.sent[2].color,'0000FF'); eq(r.sent[2].behavior,'always_on','A lit Off color stays lit under explicit bound tracking')
eq(leds:set_button('toggle',{OFF_COLOR='000000'}),true); eq(#r.sent,2)
eq(leds:match('toggle',false),true)
eq(r.sent[3].color,'000000'); eq(r.sent[3].behavior,'always_off')
eq(leds:set_bound_follow(false),true); eq(next(leds.states),nil)
eq(leds:match('toggle',true),false); eq(#r.sent,3)
eq(leds:set_bound_follow(true),true); eq(#r.sent,3,'Enabling a policy does not itself write a light or an LED')
eq(leds:set_bound_follow('true'),false)

-- On/off-only indicators keep their physical color. Their policy controls are
-- available without exposing misleading color or brightness commands.
local fixed=channel('fixed','toggle',{'000000','FFFFFF'})
fixed.color='000000'; fixed.behavior='always_off'
fixed.behaviors=Codec:newArray({'always_on','always_off'})
fixed.brightness_supported=false; fixed.brightness=nil
r,leds=runtime(); leds:observe(metadata({fixed}))
eq(#leds:choices(false,true),0); eq(#leds:choices(),1); eq(#leds:choices(true),0)
eq(#leds:behavior_choices(),2); eq(leds:behavior_choices()[1],'always_on')
eq(leds:behavior_choices()[2],'always_off'); eq(leds:behavior_supported('follow_load'),false)
check(leds:supports_bound_follow())
eq(leds:set_button('toggle',{CURRENT_COLOR='FFFFFF'}),false)
eq(leds:set_all('FFFFFF'),false); eq(#r.sent,0); eq(next(r.store),nil)
eq(leds:set_button('toggle',{ON_COLOR='FFFFFF',OFF_COLOR='000000'}),true); eq(#r.sent,0)
eq(leds:match('toggle',true),true)
eq(r.sent[1].color,'FFFFFF'); eq(r.sent[1].behavior,'always_on')
eq(leds:set_behavior('toggle','always_on'),true)
eq(r.sent[2].behavior,'always_on'); eq(r.sent[2].color,nil)

-- An all-channel behavior must be valid for every available target before the
-- first parameter write. Unavailable channels do not prevent valid requests.
local color_led=channel('color','top'); local fixed_second=copy(fixed); fixed_second.button_id='bottom'
r,leds=runtime(); leds:observe(metadata({color_led,fixed_second}))
eq(#leds:behavior_choices(),2)
eq(#leds:behavior_choices('top'),4); eq(#leds:behavior_choices('bottom'),2)
eq(leds:set_all_behavior('follow_load'),false); eq(#r.sent,0)
eq(leds:set_all('FF0000'),false); eq(#r.sent,0); eq(next(r.store),nil)
eq(leds:set_all_behavior('always_off'),true); eq(#r.sent,1,'Confirmed off on the fixed indicator needs no duplicate command')
eq(r.sent[1].led_id,'color'); eq(r.sent[1].behavior,'always_off'); eq(r.sent[1].color,nil)
fixed_second.available=false; leds:observe(metadata({color_led,fixed_second}))
eq(#leds:behavior_choices(),4); eq(leds:set_all_behavior('follow_load'),true)
eq(r.sent[2].led_id,'color'); eq(r.sent[2].behavior,'follow_load')

-- Global properties require the intersection; a per-button program action
-- lists the union because Composer does not supply the other selected param.
local color_only=channel('color_only','top')
color_only.behaviors=Codec:newArray({}); color_only.behavior=nil
fixed_second.available=true
r,leds=runtime(); leds:observe(metadata({color_only,fixed_second}))
eq(#leds:behavior_choices(),0,'A color-only channel excludes global behavior changes')
local per_button=leds:behavior_choices_any()
eq(#per_button,2); eq(per_button[1],'always_on'); eq(per_button[2],'always_off')
eq(leds:set_behavior('top','always_on'),false); eq(#r.sent,0)
eq(leds:set_behavior('bottom','always_on'),true)
eq(r.sent[1].led_id,'fixed'); eq(r.sent[1].behavior,'always_on')
fixed_second.available=false; leds:observe(metadata({color_only,fixed_second}))
eq(#leds:behavior_choices_any(),0,'Unavailable targets cannot add action choices')

-- Older companions remain readable. Every hardware-writing path requires the
-- explicit separated-command marker, preventing the old implicit Always On.
for _,command_version in ipairs({false,3}) do
    local old=metadata(); old.bridge_led_command_version=command_version or nil
    if not command_version then
        old.bridge_leds[1].color_supported=nil
        old.bridge_leds[1].behaviors=nil; old.bridge_leds[1].behavior=nil
    end
    r,leds=runtime(); eq(leds:observe(old),true)
    eq(leds:get('toggle').CURRENT_COLOR,'00FF00'); eq(#leds:behavior_choices(),0)
    eq(#leds:behavior_choices_any(),0)
    local accepted,why=leds:set_button('toggle',{CURRENT_COLOR='00FF00'})
    eq(accepted,false); eq(why,'component_upgrade_required','Even an unchanged color must not authorize an older command implementation')
    eq(leds:set_brightness('toggle',50),false)
    eq(leds:set_behavior('toggle','always_on'),false)
    eq(leds:set_all_behavior('always_on'),false)
    eq(leds:set_all('FFFFFF'),false); eq(leds:match('toggle',true),false)
    eq(leds:set_button('toggle',{ON_COLOR='FF0000'}),true)
    eq(#r.sent,0)
end

local invalid_behavior={
    function(a) a.bridge_led_command_version='2' end,
    function(a) a.bridge_led_command_version=0 end,
    function(a) a.bridge_leds[1].behaviors=nil end,
    function(a) a.bridge_leds[1].behaviors=Codec.null end,
    function(a) a.bridge_leds[1].behaviors=Codec:newArray({'always_on','always_on'}) end,
    function(a) a.bridge_leds[1].behaviors=Codec:newArray({'guess_from_label'}) end,
    function(a) a.bridge_leds[1].behaviors=Codec:newArray({'always_off'}) end,
    function(a) a.bridge_leds[1].behavior=false end,
    function(a) a.bridge_leds[1].color_supported=nil end,
    function(a) a.bridge_leds[1].color_supported='true' end,
    function(a) a.bridge_leds[1].color_supported=false end,
}
for _,mutate in ipairs(invalid_behavior) do
    r,leds=runtime(); leds:observe(metadata())
    local invalid=metadata(); mutate(invalid)
    eq(leds:observe(invalid),false); eq(#leds:behavior_choices(),0)
    eq(leds:set_all_behavior('always_on'),false); eq(#r.sent,0)
end

check(not pcall(LEDs.new,{}))
print('LED capability/preferences/output: '..assertions..' assertions passed')
