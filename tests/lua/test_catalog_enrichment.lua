local Enrichment=require('module.catalog_enrichment')
local Discovery=require('module.discovery')
local codec=Discovery.new_codec()
local assertions=0
local function check(value,message) assertions=assertions+1; assert(value,message or ('assertion '..assertions)) end
local function eq(a,b) check(a==b,'expected '..tostring(b)..', got '..tostring(a)) end
local function copy(value) return codec:decode(codec:encode(value)) end
local sent,statuses,changed,clock={},{},0,100
local enrichment=Enrichment.new({client_id='catalog-test',now=function() return clock end,timeout=5,
    send=function(binding,command,params)
        eq(binding,999)
        if command=='HA_RELEASE_ENTITIES' then return end
        eq(command,'HA_GET_ENTITIES')
        sent[#sent+1]=codec:decode(params.JSON)
    end,
    on_status=function(reason) statuses[#statuses+1]=reason end,
    on_change=function() changed=changed+1 end})
local catalog_id='sensor.ha_gesture_bridge_catalog'
local native={{entity_id='switch.office',domain='switch',name='Native Office',state='off',availability='available',
    attributes=codec:newObject({flag=false})}}
local records=codec:newArray({
    {entity_id='switch.office',domain='switch',friendly_name='Office, East',area_name='First Floor',
        attributes={supported_features=4294967295},state='on'},
    {entity_id='switch.catalog_only',domain='switch',friendly_name='Not natively discovered',area_name=Discovery.null}})
local sensor={entity_id=catalog_id,domain='sensor',name='Catalog',state='2',availability='available',
    attributes={catalog_contract_version='1.0',catalog_names_version=1,catalog_names_revision=string.rep('a',64),catalog_names_total=2,catalog_names_pages=1,catalog_names_page_001=records}}
local function reply(rows,extra,request)
    request=request or sent[#sent]
    local response={version=1,client_id=request.client_id,request_id=request.request_id,
        snapshot_id='catalog-snapshot',total=#rows,complete=true,entities=codec:newArray(rows)}
    for key,value in pairs(extra or {}) do response[key]=value end
    return response
end
local function feed(value)
    return enrichment:consume_proxy('HA_ENTITIES',{JSON=codec:encode(value)})
end
local function deliver_sensor(value)
    feed(reply({value}))
    if enrichment.phase=='page' then feed(reply({value})) end
end

enrichment:refresh(catalog_id)
eq(sent[1].entity_ids[1],catalog_id); eq(#sent[1].entity_ids,1); eq(sent[1].domains,nil)
eq(sent[1].page_size,1); eq(sent[1].attribute_keys[3],'catalog_names_revision')
deliver_sensor(sensor); eq(enrichment.status,'complete')
local enriched=enrichment:merge(native)
eq(#enriched,1); eq(enriched[1].name,'Office, East — First Floor')
eq(enriched[1].state,'off'); eq(enriched[1].attributes,native[1].attributes)
eq(enriched[1].attributes.supported_features,nil); eq(native[1].name,'Native Office')

-- An explicit renamed catalog cancels the previous request and clears old names.
enrichment:refresh(catalog_id); local delayed=reply({sensor})
enrichment:refresh('sensor.renamed_catalog')
eq(enrichment:merge(native)[1].name,'Native Office')
local _,reason=feed(delayed); eq(reason,'stale_response'); eq(enrichment.status,'loading')
local renamed=copy(sensor); renamed.entity_id='sensor.renamed_catalog'
deliver_sensor(renamed); eq(enrichment.status,'complete')
enrichment:invalidate('connection_changed')
eq(enrichment:merge(native)[1].name,'Native Office')
_,reason=feed(reply({renamed})); eq(reason,'stale_response')

-- Every failure falls back atomically; no catalog record can introduce a target.
local invalid={
    {'unsupported_version',function(value) value.attributes.catalog_contract_version='2.0' end},
    {'invalid_catalog',function(value) value.state='1' end},
    {'unavailable',function(value) value.availability='unavailable' end},
    {'invalid_catalog',function(value) value.attributes.catalog_names_page_001=codec:newObject() end},
    {'invalid_catalog',function(value) value.attributes.catalog_names_page_001[2]=copy(value.attributes.catalog_names_page_001[1]) end},
    {'invalid_catalog',function(value) value.attributes.catalog_names_page_001[1].domain='light' end},
    {'invalid_catalog',function(value) value.attributes.catalog_names_page_001[1].friendly_name=false end},
    {'invalid_catalog',function(value) value.attributes.catalog_names_page_001[1].area_name={} end},
}
for _,case in ipairs(invalid) do
    enrichment:refresh(catalog_id)
    local value=copy(sensor); case[2](value)
    deliver_sensor(value); eq(enrichment.status,case[1])
    eq(enrichment:merge(native)[1].name,'Native Office')
end
enrichment:refresh(catalog_id); feed(reply({})); eq(enrichment.status,'absent')
enrichment:refresh(catalog_id)
feed(reply({},{error={code='record_too_large',message='Catalog does not fit a bounded page'}}))
eq(enrichment.status,'error_record_too_large'); eq(enrichment:merge(native)[1].name,'Native Office')
local request_count=#sent; clock=106; enrichment:tick(); eq(#sent,request_count)
enrichment:refresh(catalog_id); clock=112; enrichment:tick(); eq(enrichment.status,'timeout')
eq(enrichment:merge(native)[1].name,'Native Office')
local ok= enrichment:refresh(''); check(ok); eq(enrichment.status,'disabled')
request_count=#sent
ok=enrichment:refresh('switch.not_a_catalog'); eq(ok,false); eq(enrichment.status,'invalid_entity_id')
eq(#sent,request_count); check(changed>0)
-- Names-only pages share a names revision and publish atomically.
local function paged(total,pages)
    return {entity_id=catalog_id,domain='sensor',name='Catalog',state=tostring(total),availability='available',
        attributes={catalog_contract_version='1.0',catalog_names_version=1,catalog_names_revision=string.rep('b',64),
            catalog_names_total=total,catalog_names_pages=pages}}
end
local compact=paged(2,2)
enrichment:refresh(catalog_id)
feed(reply({compact})); eq(enrichment.phase,'page'); eq(enrichment.status,'loading')
check(sent[#sent].attribute_keys[#sent[#sent].attribute_keys]=='catalog_names_page_001')
local first=copy(compact); first.attributes.catalog_names_page_001=codec:newArray({copy(records[1])})
feed(reply({first})); eq(enrichment.phase,'page'); eq(enrichment:merge(native)[1].name,'Native Office')
local second=copy(compact); second.attributes.catalog_names_page_002=codec:newArray({copy(records[2])})
feed(reply({second})); eq(enrichment.status,'complete'); eq(enrichment:merge(native)[1].name,'Office, East — First Floor')
eq(#enrichment:merge(native),1); eq(enrichment:merge(native)[1].state,'off')
for _,change in ipairs({'revision','duplicate','missing','count'}) do
    enrichment:refresh(catalog_id); feed(reply({compact})); feed(reply({first}))
    local changed_page=copy(second)
    if change=='revision' then changed_page.attributes.catalog_names_revision=string.rep('c',64)
    elseif change=='duplicate' then changed_page.attributes.catalog_names_page_002=codec:newArray({copy(records[1])})
    elseif change=='missing' then changed_page.attributes.catalog_names_page_002=nil
    else changed_page.attributes.catalog_names_total=3; changed_page.state='3' end
    feed(reply({changed_page})); check(enrichment.status~='complete')
    eq(enrichment:merge(native)[1].name,'Native Office')
end
enrichment:refresh(catalog_id); feed(reply({paged(0,0)})); eq(enrichment.status,'complete')
local bad=copy(compact); bad.attributes.catalog_names_error='record_too_large'
enrichment:refresh(catalog_id); feed(reply({bad})); eq(enrichment.status,'error_record_too_large')
bad=copy(compact); bad.attributes.catalog_names_version=2
enrichment:refresh(catalog_id); feed(reply({bad})); eq(enrichment.status,'unsupported_names_version')
enrichment:refresh(catalog_id); feed(reply({compact})); clock=118; enrichment:tick(); eq(enrichment.status,'timeout')
-- A connection change delivered synchronously while releasing the completed
-- manifest must not let its old callback start another request or publish names.
local raced,race_request,race_reads=nil,nil,0
raced=Enrichment.new({client_id='catalog-release-race',send=function(_,command,params)
    if command=='HA_RELEASE_ENTITIES' then raced:invalidate('connection_changed')
    else race_reads=race_reads+1; race_request=codec:decode(params.JSON) end
end})
raced:refresh(catalog_id)
raced:consume_proxy('HA_ENTITIES',{JSON=codec:encode(reply({compact},nil,race_request))})
eq(raced.status,'connection_changed'); eq(race_reads,1); eq(next(raced.entries),nil)
-- HA's preferred entry may replace aliases only after all pages pass.
local preferences=copy(sensor)
preferences.attributes.catalog_names_total=2; preferences.state='2'
preferences.attributes.catalog_names_page_001[1].entity_aliases=codec:newArray({'switch.raw_office'})
preferences.attributes.catalog_names_page_001[1].source_entity_id='switch.raw_office'
enrichment:refresh(catalog_id); deliver_sensor(preferences)
eq(enrichment.status,'complete')
local with_alias=enrichment:merge({native[1],{entity_id='switch.raw_office',domain='switch',name='Native Relay',
    state='off',availability='available',attributes=codec:newObject()}})
eq(with_alias[1].catalog_choice.entity_id,'switch.office')
eq(with_alias[2].catalog_choice.entity_id,'switch.office'); eq(with_alias[2].name,'Native Relay')
eq(with_alias[1].catalog_choice.source_entity_id,'switch.raw_office')
for _,bad_aliases in ipairs({codec:newObject(),codec:newArray({'bad'}),codec:newArray({'switch.office'}),
    codec:newArray({'switch.raw_office','switch.raw_office'}),codec:newArray({'switch.catalog_only'})}) do
    local invalid=copy(preferences); invalid.attributes.catalog_names_page_001[1].entity_aliases=bad_aliases
    enrichment:refresh(catalog_id); deliver_sensor(invalid)
    eq(enrichment.status,'invalid_catalog'); eq(enrichment:merge(native)[1].catalog_choice,nil)
end
local invalid=copy(preferences); invalid.attributes.catalog_names_page_001[2].entity_aliases=codec:newArray({'switch.raw_office'})
enrichment:refresh(catalog_id); deliver_sensor(invalid); eq(enrichment.status,'invalid_catalog')
-- There is no legacy full-catalog transfer: an absent/old manifest falls back
-- to native discovery instead of fetching the giant catalog_entities field.
local old=copy(sensor); old.attributes.catalog_names_version=nil
local requests_before=#sent
enrichment:refresh(catalog_id); deliver_sensor(old)
eq(enrichment.status,'unsupported_names_version'); eq(#sent,requests_before+1)
print('Optional catalog enrichment: '..assertions..' assertions passed')
