local Choices=require('module.discovery_choices')
local Discovery=require('module.discovery')
local codec=Discovery.new_codec()
local count=0
local function check(value,message) count=count+1; assert(value,message or ('assertion '..count)) end
local function eq(a,b) check(a==b,'expected '..tostring(b)..', got '..tostring(a)) end
local function row(id,name,attributes,availability)
    return {entity_id=id,domain=id:match('^([^%.]+)'),name=name,state='off',availability=availability or 'available',attributes=attributes or {}}
end
local function aggregate(id,load_id,name)
    return row(id,name or 'Internal Gesture Proof',{validated=true,bridge_load=load_id and {entity_id=load_id} or nil})
end
local calls=0
local function validate(row)
    calls=calls+1
    if row.attributes.validated then return {load=row.attributes.bridge_load,source_device_id=row.attributes.bridge_source_device_id} end
end
local physical=row('switch.s2_on_off_switch',"Jeff's Office")
local group=row('light.jeffs_office_light_group',"Jeff's Office Light Group",{entity_id={'light.office_a','light.office_b'}})
local control=aggregate('event.jeffs_office_gesture_proof',physical.entity_id)
local rows={group,physical,control}
local before=codec:encode(rows)
local choices,metadata,aliases=Choices.build(rows,{selected_entity_id=physical.entity_id,operation_mode='Direct',validate_aggregate=validate})
eq(#choices,2); eq(calls,1); eq(codec:encode(rows),before)
eq(choices[1].entity_id,group.entity_id); eq(choices[1].name,"Jeff's Office Light Group (group)")
eq(choices[2].entity_id,control.entity_id); eq(choices[2].name,"Jeff's Office (gestures)")
check(not choices[2].name:find('Proof'))
eq(metadata[control.entity_id].load_id,physical.entity_id); eq(metadata[control.entity_id].gesture_id,control.entity_id)
eq(metadata[control.entity_id].operation_mode,'Gesture Bridge'); check(metadata[control.entity_id].unified)
eq(aliases[physical.entity_id],control.entity_id); eq(metadata[physical.entity_id],metadata[control.entity_id])
-- An alias changes only the visible selection, never the configured Direct ID.
local selected_id,selected_mode=physical.entity_id,'Direct'
local picker=Discovery.build_picker(choices,{selected_entity_id=aliases[selected_id] or selected_id})
eq(picker.label_to_entity[picker.selected_label],control.entity_id)
eq(selected_id,physical.entity_id); eq(selected_mode,'Direct')
-- Unavailable loads still have known identity and consolidate honestly.
local unavailable=row(physical.entity_id,physical.name,{},'unavailable')
choices,metadata,aliases=Choices.build({unavailable,control},{validate_aggregate=validate})
eq(#choices,1); eq(aliases[physical.entity_id],control.entity_id); eq(unavailable.availability,'unavailable')
-- Shared friendly names or group-like names never establish identity.
local similarly_named=row('light.another_target',physical.name)
local named_group=row('light.name_says_group','Definitely A Group')
choices,metadata=Choices.build({physical,similarly_named,named_group},{validate_aggregate=validate})
eq(#choices,3); eq(choices[3].name,'Definitely A Group'); eq(metadata[named_group.entity_id].is_group,false)
-- Two validated controls linked to one load remain explicitly ambiguous.
local second=aggregate('event.another_control',physical.entity_id)
choices,metadata,aliases=Choices.build({control,physical,second},{validate_aggregate=validate})
eq(#choices,3); eq(next(aliases),nil); eq(choices[1].name,"Jeff's Office (gestures 2)")
eq(choices[2].entity_id,physical.entity_id); eq(choices[3].name,"Jeff's Office (gestures 1)")
check(metadata[control.entity_id].ambiguous and metadata[second.entity_id].ambiguous)
eq(metadata[physical.entity_id].operation_mode,'Direct')
local reversed=Choices.build({second,physical,control},{validate_aggregate=validate})
eq(reversed[1].name,choices[3].name); eq(reversed[3].name,choices[1].name)
-- A remote without a linked load stays a gesture entry; normal source events do not.
local remote=aggregate('event.remote',nil,'Patio Remote')
choices,metadata,aliases=Choices.build({row('event.native_action','Source event'),remote,physical},{validate_aggregate=validate})
eq(#choices,2); eq(choices[1].name,'Patio Remote'); eq(metadata[remote.entity_id].operation_mode,'Gestures Only')
eq(metadata[remote.entity_id].load_id,nil); eq(next(aliases),nil)
-- A validated link whose target is absent must not suppress an unrelated load.
local absent=aggregate('event.missing_target','switch.absent','Missing Target Control')
choices,metadata,aliases=Choices.build({absent,physical},{validate_aggregate=validate})
eq(#choices,2); eq(choices[1].name,'Missing Target Control'); eq(next(aliases),nil)
eq(metadata[absent.entity_id].load_id,'switch.absent'); check(not metadata[absent.entity_id].unified)
-- Failure or absence of the real aggregate validator leaves ordinary loads intact.
choices=Choices.build(rows); eq(#choices,2)
choices=Choices.build(rows,{validate_aggregate=function() error('malformed') end}); eq(#choices,2)
choices=Choices.build({physical,control},{validate_aggregate=function() return {load={entity_id='event.bad_target'}} end}); eq(#choices,1)
-- Group labels require actual array evidence, not empty objects or bad members.
for _,members in ipairs({codec:newObject({}),{}, {'not-an-entity'}, {key='light.a'}}) do
    local candidate=row('light.candidate','Candidate',{entity_id=members})
    choices,metadata=Choices.build({candidate}); eq(choices[1].name,'Candidate'); eq(metadata[candidate.entity_id].is_group,false)
end
choices,metadata=Choices.build({row('light.empty_group','Empty Group',{entity_id=codec:newArray({})})})
eq(choices[1].name,'Empty Group (group)'); check(metadata['light.empty_group'].is_group)
-- Duplicate identity records and unrelated domains never produce extra choices.
choices=Choices.build({physical,physical,row('sensor.temp','Temperature'),row('switch.bad','Bad')})
eq(#choices,2)
local mismatch=row('switch.mismatch','Mismatch'); mismatch.domain='light'
choices=Choices.build({mismatch}); eq(#choices,0)
-- HA switch_as_x registry facts prove that a light wrapper and a switch
-- represent the same load. Device, area, object ID and friendly name do not.
local source=row('switch.jeffs_closet','Jeff Closet Physical')
source.registry={platform='zwave_js',device_id='device-a',area_id='primary_bath'}
local wrapper=row('light.jeffs_closet',"Jeff's Closet",{supported_color_modes={'onoff'}})
wrapper.registry={platform='switch_as_x',source_entity_id=source.entity_id,source_inverted=false,
    device_id='device-a',area_id='primary_bath',hidden_by='integration'}
local originals=codec:encode({source,wrapper})
choices,metadata,aliases=Choices.build({source,wrapper})
eq(#choices,1); eq(choices[1].entity_id,wrapper.entity_id); eq(aliases[source.entity_id],wrapper.entity_id)
eq(metadata[source.entity_id].load_id,wrapper.entity_id); eq(metadata[wrapper.entity_id].operation_mode,'Direct')
eq(codec:encode({source,wrapper}),originals)
-- Preserve either already-selected ordinary representation in Direct mode.
for _,selected in ipairs({source.entity_id,wrapper.entity_id}) do
    choices,metadata,aliases=Choices.build({source,wrapper},{selected_entity_id=selected,operation_mode='Direct'})
    eq(#choices,1); eq(choices[1].entity_id,selected); eq(metadata[selected].load_id,selected)
    eq(metadata[selected].operation_mode,'Direct'); eq(aliases[selected],nil)
end
-- The same three representations merge when the bridge links either source.
for _,linked in ipairs({source.entity_id,wrapper.entity_id}) do
    local bridged=aggregate('event.closet_gesture_control',linked)
    choices,metadata,aliases=Choices.build({wrapper,bridged,source},{validate_aggregate=validate})
    eq(#choices,1); eq(choices[1].entity_id,bridged.entity_id); eq(choices[1].name,"Jeff's Closet (gestures)")
    eq(aliases[source.entity_id],bridged.entity_id); eq(aliases[wrapper.entity_id],bridged.entity_id)
    eq(metadata[bridged.entity_id].load_id,linked); eq(metadata[bridged.entity_id].gesture_id,bridged.entity_id)
    eq(#metadata[bridged.entity_id].physical_ids,2)
    local direct_options={selected_entity_id=source.entity_id,operation_mode='Direct',validate_aggregate=validate}
    choices,metadata,aliases=Choices.build({source,wrapper,bridged},direct_options)
    eq(#choices,1); eq(direct_options.selected_entity_id,source.entity_id); eq(direct_options.operation_mode,'Direct')
    eq(choices[1].name,'Jeff Closet Physical (gestures)')
end
-- Source inversion, missing booleans, absent sources and malformed relations
-- are not evidence for equivalence, even with identical names/device IDs.
for _,registry in ipairs({
    {platform='switch_as_x',source_entity_id=source.entity_id,source_inverted=true},
    {platform='switch_as_x',source_entity_id=source.entity_id},
    {platform='switch_as_x',source_entity_id=source.entity_id,source_inverted='false'},
    {platform='switch_as_x',source_entity_id='switch.absent',source_inverted=false},
    {platform='switch_as_x',source_entity_id=wrapper.entity_id,source_inverted=false},
    {platform='template',source_entity_id=source.entity_id,source_inverted=false},
    {platform='switch_as_x',source_entity_id={source.entity_id},source_inverted=false},
    {device_id='device-a',area_id='primary_bath'},
}) do
    local candidate=row(wrapper.entity_id,source.name); candidate.registry=registry
    choices,metadata,aliases=Choices.build({source,candidate})
    eq(#choices,2); eq(next(aliases),nil)
end
-- A claimed reverse wrapper relation forms malformed/cyclic evidence.
local cyclic_source=row(source.entity_id,source.name)
cyclic_source.registry={platform='switch_as_x',source_entity_id=wrapper.entity_id,source_inverted=false}
choices,metadata,aliases=Choices.build({cyclic_source,wrapper}); eq(#choices,2); eq(next(aliases),nil)
-- One member in a group is not an equivalence link to that member.
local single_group=row('light.primary_bath_group','Primary Bath',{entity_id={source.entity_id}})
choices,metadata,aliases=Choices.build({source,wrapper,single_group})
eq(#choices,2); eq(choices[2].entity_id,single_group.entity_id); eq(choices[2].name,'Primary Bath (group)')
eq(aliases[single_group.entity_id],nil)
-- Even contradictory wrapper hints cannot collapse a positively identified group.
single_group.registry={platform='switch_as_x',source_entity_id=source.entity_id,source_inverted=false}
choices=Choices.build({source,single_group}); eq(#choices,2)
-- Multiple aggregate controls remain ambiguous across all equivalent members.
local raw_bridge=aggregate('event.raw_closet_control',source.entity_id)
local wrapper_bridge=aggregate('event.wrapper_closet_control',wrapper.entity_id)
choices,metadata,aliases=Choices.build({source,wrapper,raw_bridge,wrapper_bridge},
    {selected_entity_id=source.entity_id,operation_mode='Direct',validate_aggregate=validate})
eq(#choices,3); eq(choices[1].entity_id,source.entity_id)
eq(aliases[source.entity_id],nil); eq(aliases[wrapper.entity_id],source.entity_id)
check(metadata[raw_bridge.entity_id].ambiguous and metadata[wrapper_bridge.entity_id].ambiguous)
check(not metadata[raw_bridge.entity_id].unified and not metadata[wrapper_bridge.entity_id].unified)
check(choices[2].name~=choices[3].name)
-- Multiple positive wrappers use one deterministic ordinary representative.
local another_wrapper=row('light.another_closet','Another wrapper')
another_wrapper.registry={platform='switch_as_x',source_entity_id=source.entity_id,source_inverted=false}
choices,metadata,aliases=Choices.build({wrapper,source,another_wrapper})
eq(#choices,1); eq(choices[1].entity_id,another_wrapper.entity_id); eq(aliases[wrapper.entity_id],another_wrapper.entity_id)
-- HA's catalog decides preferred representations. C4 validates that its
-- chosen target exists natively, then follows the aliases in every mode.
local source_control=aggregate('event.physical_control',nil,'HA Preferred Paddle')
local preferred={entity_id=source_control.entity_id,aliases={source.entity_id,wrapper.entity_id},
    source_entity_id=wrapper.entity_id,is_group=false}
source_control.catalog_choice=preferred; source.catalog_choice=preferred; wrapper.catalog_choice=preferred
for _,mode in ipairs({'Direct','Gesture Bridge','Gestures Only','C4 Button Controller'}) do
    local opts={selected_entity_id=source.entity_id,operation_mode=mode,validate_aggregate=validate}
    choices,metadata,aliases=Choices.build({source,wrapper,source_control,single_group},opts)
    eq(#choices,2); eq(choices[1].entity_id,source_control.entity_id)
    eq(choices[1].name,'HA Preferred Paddle')
    eq(aliases[source.entity_id],source_control.entity_id); eq(aliases[wrapper.entity_id],source_control.entity_id)
    eq(metadata[source_control.entity_id].source_entity_id,wrapper.entity_id)
    eq(metadata[source_control.entity_id].load_id,nil)
    eq(metadata[source_control.entity_id].operation_mode,'Gestures Only')
    eq(opts.selected_entity_id,source.entity_id)
end
-- Catalog metadata cannot introduce an unavailable native target or override
-- gesture validation. Existing raw choices remain usable on incomplete input.
choices,metadata,aliases=Choices.build({source,wrapper},{validate_aggregate=validate})
eq(#choices,1); eq(choices[1].entity_id,wrapper.entity_id); eq(aliases[source.entity_id],wrapper.entity_id)
source_control.attributes.validated=false
choices,metadata,aliases=Choices.build({source,wrapper,source_control},{validate_aggregate=validate})
eq(#choices,1); eq(metadata[source_control.entity_id],nil)
source_control.attributes.validated=true
-- Removing the optional catalog returns to ordinary native discovery.
source.catalog_choice=nil; wrapper.catalog_choice=nil; source_control.catalog_choice=nil
choices,metadata,aliases=Choices.build({source,wrapper,source_control},{validate_aggregate=validate})
eq(#choices,2); eq(aliases[source.entity_id],wrapper.entity_id)
print('Discovery choices: '..count..' assertions passed')
