local ButtonLink=require('module.button_link')
local count=0
local function check(value,message) count=count+1; assert(value,message or ('assertion '..count)) end
local function eq(a,b,message) check(a==b,message or ('expected '..tostring(b)..', got '..tostring(a))) end
local function copy(value)
    if type(value)~='table' then return value end
    local result={}; for k,v in pairs(value) do result[k]=copy(v) end; return result
end
local function metadata(buttons)
    return {attributes={bridge_control_id='office',bridge_session_id='session1',bridge_update_kind='snapshot',
        bridge_sources={{id='native',ready=true,availability='available'}},bridge_buttons=buttons or {
            {id='top',gestures={{id='press_1',kind='press',press_count=1},
                {id='press_2',kind='press',press_count=2},{id='press_3',kind='press',press_count=3},
                {id='hold',kind='hold_start'},{id='repeat_hold',kind='hold_repeat'},{id='release',kind='release'}}},
            {id='bottom',gestures={{id='press_1',kind='press',press_count=1}}},
            {id='toggle',gestures={{id='press_1',kind='press',press_count=1}}},
        }}}
end
local function event(sequence,button,kind,id,presses,base)
    local result=copy(base or metadata()); local a=result.attributes
    a.bridge_update_kind='gesture'; a.gesture_session_id=a.bridge_session_id
    a.gesture_sequence=sequence; a.gesture_event_id=a.bridge_session_id..':'..sequence
    a.button_id=button; a.event_type=kind; a.gesture_id=id; a.press_count=presses
    return result
end
local function runtime(options)
    local r={sent={},fail=false,hook=nil}
    r.output=ButtonLink.new({bindings=options and options.bindings,send=function(binding,command,params,direction)
        r.sent[#r.sent+1]={binding=binding,command=command,params=params,direction=direction}
        if r.hook then r.hook(binding,command) end
        if r.fail==command then error('injected boundary failure') end
        if r.reject==command then return false end
    end})
    function r:sent_command(index,binding,command)
        local item=self.sent[index]; check(item~=nil); eq(item.binding,binding); eq(item.command,command)
        eq(item.direction,'COMMAND'); eq(type(item.params),'table'); eq(next(item.params),nil)
    end
    return r
end

-- Opt in explicitly. Reading metadata/actions never sends a tap or polls HA.
local r=runtime(); local output=r.output
eq(output:pressed('top'),nil); eq(#output:actions(),0)
eq(output:observe(metadata()),true); eq(#r.sent,0); eq(#output:actions(),0)
eq(output:consume(event(1,'top','press','press_1',1)),false); eq(#r.sent,0)
eq(output:set_enabled(true),true); eq(output:pressed('top'),false)
local available=output:actions(); eq(#available,5)
eq(available[1].button_id,'top'); eq(available[1].action,'click')
eq(available[2].action,'press'); eq(available[3].action,'release')
eq(available[4].button_id,'bottom'); eq(available[5].button_id,'toggle')
available[1].action='mutated'; eq(output:actions()[1].action,'click'); eq(#r.sent,0)

-- Completed taps use exactly one native push/click pair, never a held release.
for index,pair in ipairs({{'top',200},{'bottom',201},{'toggle',202}}) do
    eq(output:consume(event(index,pair[1],'press','press_1',1)),true)
    r:sent_command(index*2-1,pair[2],'DO_PUSH'); r:sent_command(index*2,pair[2],'DO_CLICK')
    eq(output:pressed(pair[1]),false)
end
eq(output:consume(event(3,'toggle','press','press_1',1)),false); eq(#r.sent,6)
for index,presses in ipairs({2,3}) do
    eq(output:consume(event(3+index,'top','press','press_'..presses,presses)),false)
    eq(#r.sent,6)
end
-- Hold starts once, repeats do nothing, and a declared release stops the hold.
eq(output:consume(event(6,'top','hold_start','hold')),true); eq(output:pressed('top'),true)
r:sent_command(7,200,'DO_PUSH')
local actions=output:actions(); eq(actions[2].action,'press'); eq(actions[3].action,'release'); eq(#r.sent,7)
eq(output:consume(event(7,'top','hold_start','hold')),false); eq(#r.sent,7)
eq(output:consume(event(8,'top','hold_repeat','repeat_hold')),false); eq(#r.sent,7)
eq(output:consume(event(9,'top','release','release')),true); eq(output:pressed('top'),false)
r:sent_command(8,200,'DO_RELEASE')
eq(output:consume(event(10,'top','release','release')),false); eq(#r.sent,8)

-- Programmatic actions use declared current capabilities, not HA occurrences.
local sequence=output.last_sequence
eq(output:action('top','press'),true); eq(output:pressed('top'),true)
eq(output:action('top','click'),true); eq(output:pressed('top'),false)
r:sent_command(9,200,'DO_PUSH'); r:sent_command(10,200,'DO_CLICK')
eq(output.last_sequence,sequence); eq(output:action('bottom','press'),false)
eq(output:action('top','release'),false); eq(output:action('top','double'),false)
eq(output:action('missing','click'),false); eq(#r.sent,10)

-- Snapshots may end stale logical state but never start or replay it.
eq(output:action('top','press'),true)
local snapshot=event(10,'top','hold_start','hold'); snapshot.attributes.bridge_update_kind='snapshot'
eq(output:observe(snapshot),true); eq(output:pressed('top'),true); eq(#r.sent,11)
eq(output:consume(snapshot),false); eq(#r.sent,11)
local changed=metadata(); changed.attributes.bridge_session_id='session2'
eq(output:observe(changed),true); r:sent_command(12,200,'DO_RELEASE'); eq(output:pressed('top'),false)
eq(output:action('top','press'),true)
changed.attributes.bridge_control_id='other'; eq(output:observe(changed),true)
r:sent_command(14,200,'DO_RELEASE'); eq(output:pressed('top'),false)
eq(output:action('top','press'),true); eq(output:set_enabled(false),true)
r:sent_command(16,200,'DO_RELEASE'); eq(output:pressed('top'),nil)
eq(output:action('top','click'),false); eq(output:observe(metadata()),true); eq(#r.sent,16)

-- Missing release declaration forbids starting a hold, regardless of label/id.
r=runtime(); output=r.output; output:set_enabled(true)
local missing_release=metadata({{id='top',gestures={{id='hold',kind='hold_start'},
    {id='press_1',kind='press',press_count=1},{id='pushed',kind='custom',label='Button Pushed'}}}})
eq(output:observe(missing_release),true); eq(#output:actions(),1)
eq(output:action('top','press'),false); eq(output:consume(event(1,'top','hold_start','hold',nil,missing_release)),false)
eq(output:consume(event(2,'top','custom','pushed',nil,missing_release)),false); eq(#r.sent,0)
eq(output:action('top','click'),true); eq(#r.sent,2)

-- Invalid metadata/source health/capability loss releases active holds.
for _,mutate in ipairs({
    function(a) a.bridge_sources[1].ready=false end,
    function(a) a.bridge_sources[1].ready=false; a.bridge_sources[1].availability='unknown' end,
    function(a) a.bridge_sources[1].availability='unavailable' end,
    function(a) a.bridge_sources={} end,
    function(a) a.bridge_buttons[1].gestures={} end,
    function(a) table.remove(a.bridge_buttons,1) end,
}) do
    r=runtime(); output=r.output; output:set_enabled(true); output:observe(metadata())
    eq(output:action('top','press'),true)
    local broken=metadata(); mutate(broken.attributes); output:observe(broken)
    r:sent_command(2,200,'DO_RELEASE'); eq(output:pressed('top'),nil)
    eq(output:action('top','press'),false); eq(#r.sent,2)
end
-- A ready subscription may lack physical availability reporting.
r=runtime(); output=r.output; output:set_enabled(true)
local unknown_ready=metadata(); unknown_ready.attributes.bridge_sources[1].availability='unknown'
eq(output:observe(unknown_ready),true); eq(output:action('top','click'),true)
r:sent_command(1,200,'DO_PUSH'); r:sent_command(2,200,'DO_CLICK')
eq(output:action('top','press'),true); eq(output:pressed('top'),true)
unknown_ready.attributes.bridge_sources[1].ready=false; output:observe(unknown_ready)
r:sent_command(4,200,'DO_RELEASE'); eq(output:pressed('top'),nil)
r=runtime(); output=r.output; output:set_enabled(true); output:observe(metadata()); output:action('top','press')
eq(output:observe(false),false); r:sent_command(2,200,'DO_RELEASE'); eq(output:pressed('top'),nil)
eq(output:reset(),true); eq(#r.sent,2)

-- Explicit source-button associations permit independent source availability.
r=runtime(); output=r.output; output:set_enabled(true)
local mapped=metadata(); mapped.attributes.bridge_sources={
    {id='one',button_id='top',ready=true,availability='available'},
    {id='two',button_id='bottom',ready=false,availability='unknown'}}
eq(output:observe(mapped),true); eq(output:action('top','press'),true)
eq(output:pressed('bottom'),nil); eq(output:pressed('toggle'),nil)
mapped.attributes.bridge_sources[1].ready=false; output:observe(mapped)
r:sent_command(2,200,'DO_RELEASE')
-- Without associations an unhealthy source invalidates all buttons safely.
mapped.attributes.bridge_sources[1].button_id=nil; mapped.attributes.bridge_sources[1].ready=true
mapped.attributes.bridge_sources[2].button_id=nil
output:observe(mapped); eq(output:action('top','click'),false)

-- Explicit custom mappings work; unknown button identities are never guessed.
r=runtime({bindings={button_one=200}}); output=r.output; output:set_enabled(true)
local custom=metadata({{id='button_one',gestures={{id='press_1',kind='press',press_count=1}}}})
output:observe(custom); eq(output:action('button_one','click'),true)
r:sent_command(1,200,'DO_PUSH'); r:sent_command(2,200,'DO_CLICK')
eq(output:action('top','click'),false)
check(not pcall(ButtonLink.new,{send=function() end,bindings={top=0}}))
check(not pcall(ButtonLink.new,{send=function() end,bindings={top=200,bottom=200}}))
check(not pcall(ButtonLink.new,{}))

-- Boundary failures attempt release cleanup and cannot authorize new actions
-- until a failed release has been retried successfully.
r=runtime(); output=r.output; output:set_enabled(true); output:observe(metadata())
r.fail='DO_CLICK'; eq(output:action('top','click'),false)
r:sent_command(3,200,'DO_RELEASE'); eq(output:pressed('top'),false)
r.fail=false; output:action('top','press'); r.fail='DO_RELEASE'
eq(output:reset(),false); eq(output:pressed('top'),nil)
eq(output:observe(metadata()),false); eq(output:action('top','click'),false)
r.fail=false; eq(output:observe(metadata()),true); eq(output:pressed('top'),false)
eq(output:action('top','click'),true)
r=runtime(); output=r.output; output:set_enabled(true); output:observe(metadata())
r.reject='DO_PUSH'; eq(output:action('top','click'),false)
r:sent_command(2,200,'DO_RELEASE'); eq(output:pressed('top'),false)

-- Reentrant mode changes during output stop the temporary push and prevent
-- sending a click after the caller has disabled the controller.
r=runtime(); output=r.output; output:set_enabled(true); output:observe(metadata())
r.hook=function(_,command) if command=='DO_PUSH' then output:set_enabled(false) end end
eq(output:action('top','click'),false); eq(#r.sent,2)
r:sent_command(1,200,'DO_PUSH'); r:sent_command(2,200,'DO_RELEASE')
eq(output:pressed('top'),nil)
-- A source becoming unavailable reentrantly also cancels a partially sent tap.
r=runtime(); output=r.output; output:set_enabled(true); output:observe(metadata())
r.hook=function(_,command)
    if command=='DO_PUSH' then
        local unavailable=metadata(); unavailable.attributes.bridge_sources[1].ready=false
        output:observe(unavailable)
    end
end
eq(output:action('top','click'),false); eq(#r.sent,2)
r:sent_command(1,200,'DO_PUSH'); r:sent_command(2,200,'DO_RELEASE')
eq(output:pressed('top'),nil)
-- Historical snapshots establish a baseline and never replay their gesture.
r=runtime(); output=r.output; output:set_enabled(true)
local history=event(40,'top','hold_start','hold'); history.attributes.bridge_update_kind='snapshot'
eq(output:observe(history),true); eq(output.last_sequence,40); eq(#r.sent,0)
eq(output:consume(history),false); eq(output:pressed('top'),false)
eq(output:consume(event(40,'top','hold_start','hold')),false); eq(#r.sent,0)
eq(output:consume(event(41,'top','hold_start','hold')),true); eq(output:pressed('top'),true)
-- A routine snapshot at the current watermark leaves a valid hold intact.
local routine=event(41,'top','hold_start','hold'); routine.attributes.bridge_update_kind='snapshot'
eq(output:observe(routine),true); eq(#r.sent,1); eq(output:pressed('top'),true)
-- A snapshot revealing a missed release ends the logical hold, baselines the
-- observed sequence, and cannot replay a later duplicate live publication.
local advanced=event(42,'top','release','release'); advanced.attributes.bridge_update_kind='snapshot'
eq(output:observe(advanced),true); r:sent_command(2,200,'DO_RELEASE')
eq(output.last_sequence,42); eq(output:pressed('top'),false)
eq(output:consume(event(42,'top','release','release')),false); eq(#r.sent,2)
-- Older snapshots cannot move the baseline backwards or stop a newer hold.
eq(output:consume(event(43,'top','hold_start','hold')),true)
eq(output:observe(routine),true); eq(output.last_sequence,43); eq(output:pressed('top'),true); eq(#r.sent,3)
-- A gap detected by observe before consume repairs holds without swallowing
-- the current event. A repeat after the gap never restarts the ramp.
local repeat_after_gap=event(45,'top','hold_repeat','repeat_hold')
eq(output:observe(repeat_after_gap),true); eq(output.last_sequence,43)
r:sent_command(4,200,'DO_RELEASE'); eq(output:pressed('top'),false)
eq(output:consume(repeat_after_gap),false); eq(output.last_sequence,45); eq(#r.sent,4)
-- A new hold following a gap may start after cleanup, with ordering preserved.
eq(output:consume(event(46,'top','hold_start','hold')),true)
eq(output:consume(event(48,'top','hold_start','hold')),true)
r:sent_command(5,200,'DO_PUSH'); r:sent_command(6,200,'DO_RELEASE'); r:sent_command(7,200,'DO_PUSH')
eq(output:pressed('top'),true)
-- A held cleanup failure blocks a refreshed snapshot until release succeeds.
r.fail='DO_RELEASE'
local missed=event(49,'top','release','release'); missed.attributes.bridge_update_kind='snapshot'
eq(output:observe(missed),false); eq(output:pressed('top'),nil)
r.fail=false; eq(output:observe(missed),true); eq(output.last_sequence,49); eq(output:pressed('top'),false)
-- Old-session historical occurrences do not set a new session's baseline.
local old=event(500,'top','hold_start','hold'); old.attributes.bridge_update_kind='snapshot'
old.attributes.bridge_session_id='session2'
eq(output:observe(old),true); eq(output.last_sequence,0); eq(#r.sent,9)
eq(output:consume(event(1,'top','hold_start','hold',nil,old)),true)
eq(output.last_sequence,1); eq(output:pressed('top'),true)
-- GET-state history often retains bridge_update_kind=gesture. Its transport,
-- not the occurrence attributes, identifies it as a snapshot baseline.
local cached_release=event(2,'top','release','release',nil,old)
eq(output:observe(cached_release,'state'),true); eq(output.last_sequence,2)
eq(output:pressed('top'),false); r:sent_command(11,200,'DO_RELEASE')
eq(output:consume(cached_release),false); eq(#r.sent,11)
local live=event(3,'top','hold_start','hold',nil,old)
eq(output:observe(live,'event'),true); eq(output.last_sequence,2); eq(output:consume(live),true)
eq(output:pressed('top'),true)
print('BUTTON_LINK output: '..count..' assertions passed')
