local D=require('module.discovery')
local JSON=require('module.json')
local codec=D.new_codec()
local count=0
local function check(v,m) count=count+1; assert(v,m or ('assertion '..count)) end
local function eq(a,b,m) check(a==b,(m or '')..' expected '..tostring(b)..', got '..tostring(a)) end
local function row(id,name,availability,attrs)
    return {entity_id=id,domain=id:match('^([^%.]+)'),name=name or id,state='off',availability=availability or 'available',attributes=attrs or codec:newObject({})}
end
local sent,completed,statuses,clock={}, {}, {}, 100
local client=D.new{client_id='test-family',session_id='session',now=function() return clock end,timeout=5,
    send=function(binding,command,params) sent[#sent+1]={binding=binding,command=command,raw=params.JSON,request=codec:decode(params.JSON)} end,
    on_complete=function(rows,meta) completed[#completed+1]={rows=rows,meta=meta} end,
    on_status=function(status,detail) statuses[#statuses+1]={status,detail} end}
local function reply(rows,extra)
    local req=sent[#sent].request
    local v={version=1,client_id=req.client_id,request_id=req.request_id,snapshot_id='snapshot-a',
        entities=codec:newArray(rows or {}),complete=true,total=#(rows or {})}
    for k,x in pairs(extra or {}) do v[k]=x end
    return v
end
local function feed(v,c) return (c or client):consume_proxy('HA_ENTITIES',{JSON=codec:encode(v)}) end
local function reason(v,expected,c) local handled,r=feed(v,c); check(handled); eq(r,expected) end
local families={row('switch.office','Office'),row('light.simple','Simple'),row('light.dimmer','Dimmer','available',codec:newObject({brightness=128})),
    row('cover.shade','Shade','unavailable'),row('climate.hall','Hall'),row('select.mode','Mode'),row('button.door','Door'),row('sensor.temp','Temperature','unknown')}
local ok,id=client:refresh({domains=codec:newArray({}),attribute_keys=codec:newArray({}),page_size=3})
check(ok); eq(id,'session:1'); eq(sent[1].binding,999); eq(sent[1].command,'HA_GET_ENTITIES')
check(sent[1].raw:find('"domains":%[%]')); check(sent[1].raw:find('"attribute_keys":%[%]'))
local first=reply({families[1],families[2],families[3]},{total=8,complete=false,next_cursor='cursor-1'})
reason(first,'page_requested'); eq(#completed,0); eq(#client.choices,0)
local request=sent[#sent].request
eq(request.request_id,id); eq(request.cursor,'cursor-1'); eq(request.page_size,3); eq(#request.domains,0)
reason(reply({families[4],families[5],families[6]},{total=8,complete=false,next_cursor='cursor-2'}),'page_requested')
reason(reply({families[7],families[8]},{total=8}),'complete'); eq(#client.choices,8); eq(#completed,1); eq(client.metadata.pages,3)
local previous=client.choices
-- Preserve nested JSON shapes, false, null and array positions without changing legacy codec behavior.
local nested=codec:decode('{"n":null,"f":false,"a":[null,false,{},[],{"n":null}],"o":{}}')
eq(nested.n,D.null); eq(nested.f,false); eq(#nested.a,5); eq(nested.a[1],D.null)
local encoded=codec:encode(nested)
check(encoded:find('"n":null')); check(encoded:find('"o":{}')); check(encoded:find('%[null,false,{},%[%],{"n":null}%]'))
eq(JSON:decode('{"n":null}').n,nil); eq(JSON:encode(JSON:newObject({n=D.null})), '{"n":{}}')
client:refresh(); reason(reply({row('sensor.nulls','Nulls','available',nested)}),'complete')
eq(client.choices[1].attributes.a[1],D.null); eq(client.choices[1].attributes.f,false)
previous=client.choices
-- Correlation and refresh invalidation.
local _,old_id=client:refresh(); local old=reply({})
local _,new_id=client:refresh(); check(old_id~=new_id)
reason(old,'stale_response'); check(client.pending)
reason(reply({},{client_id='different'}),'other_client'); check(client.pending)
eq(client:consume_proxy('RECEIEVE_STATE',{}),false)
reason(reply({}),'complete'); eq(#client.choices,0)
client:refresh(); clock=105; local expired,why=client:tick(); check(expired); eq(why,'timeout'); eq(client.choices[1],nil)
reason(reply({}),'stale_response')
client:refresh(); client:invalidate('reconnected'); eq(client.status,'reconnected'); reason(reply({}),'stale_response')
-- Seed choices before checking transactional failures.
client:refresh(); reason(reply(families),'complete'); previous=client.choices
local mutable={domains={'switch'},attribute_keys={'brightness'},page_size=1}
client:refresh(mutable); mutable.domains[1]='sensor'; mutable.attribute_keys[1]='changed'; mutable.page_size=100
reason(reply({row('switch.first')},{total=2,complete=false,next_cursor='copy-test'}),'page_requested')
eq(sent[#sent].request.domains[1],'switch'); eq(sent[#sent].request.attribute_keys[1],'brightness'); eq(sent[#sent].request.page_size,1)
clock=110; check(client:tick()); eq(client.choices,previous)
client:refresh(); client:invalidate(); eq(client.choices,previous)
local invalid={
    {'unsupported_version',{version=2}}, {'invalid_response',{entities=codec:newObject({})}},
    {'invalid_response',{total=-1}}, {'invalid_response',{snapshot_id=D.null}},
    {'invalid_response',{complete='true'}}, {'invalid_pagination',{complete=false}},
    {'invalid_pagination',{next_cursor='unneeded'}}, {'incomplete_catalog',{total=2}},
    {'catalog_limit',{total=0}}, {'invalid_entity',{entities=codec:newArray({row('switch.x'),row('switch.x')}),total=2}},
    {'invalid_entity',{entities=codec:newArray({{entity_id='switch.x',domain='light',name='x',state='on',availability='available',attributes=codec:newObject({})}})}},
    {'invalid_entity',{entities=codec:newArray({row('switch.x',nil,'bad')})}},
    {'invalid_entity',{entities=codec:newArray({row('switch.x',nil,nil,codec:newArray({}))})}},
    {'invalid_error',{error=codec:newObject({code='no_message'})}},
    {'coordinator_error',{entities=codec:newArray({}),total=0,error=codec:newObject({code='not_supported',message='Update coordinator'})}},
}
for _,case in ipairs(invalid) do
    client:refresh(); reason(reply({row('switch.x')},case[2]),case[1]); eq(client.choices,previous); eq(client.pending,nil)
end
client:refresh(); reason(reply({row('switch.x')},{total=2,complete=false,next_cursor='c'}),'page_requested')
reason(reply({row('switch.y')},{snapshot_id='other',total=2}),'snapshot_changed'); eq(client.choices,previous)
client:refresh(); reason(reply({row('switch.x')},{total=3,complete=false,next_cursor='c'}),'page_requested')
reason(reply({row('switch.y')},{total=3,complete=false,next_cursor='c'}),'invalid_pagination')
client:refresh(); reason(reply({row('switch.x')},{total=2,complete=false,next_cursor='c'}),'page_requested')
reason(reply({row('switch.x')},{total=2}),'invalid_entity')
for _,raw in ipairs({'{} {}','{"x":01}','{"x":1.}','{"x":"\\q"}','{"x":true,}','{"x":[1,]}','{"x":"a\nb"}',string.rep(' ',32769)}) do
    client:refresh(); local handled,r=client:consume_proxy('HA_ENTITIES',{JSON=raw}); check(handled); eq(r,'invalid_response'); eq(client.choices,previous)
end
for _,query in ipairs({{page_size=0},{page_size=101},{domains={'Switch'}},{domains={'switch','switch'}},{entity_ids={'bad'}},{attribute_keys={false}},{cursor='bad'}}) do
    local valid=client:refresh(query); eq(valid,false); eq(client.pending,nil); eq(client.choices,previous)
end
local limited=D.new{client_id='limited',max_rows=1,max_bytes=1000,max_pages=1,send=function(_,_,params) sent[#sent+1]={request=codec:decode(params.JSON)} end}
limited:refresh(); reason(reply({row('switch.a'),row('switch.b')}),'catalog_limit',limited)
limited:refresh(); reason(reply({row('switch.a')},{total=2,complete=false,next_cursor='c'}),'page_requested',limited)
reason(reply({row('switch.b')},{total=2}),'catalog_limit',limited)
local byte_limited=D.new{client_id='byte-limit',max_bytes=1,send=function(_,_,params) sent[#sent+1]={request=codec:decode(params.JSON)} end}
byte_limited:refresh(); reason(reply({}),'catalog_limit',byte_limited)
local broken=D.new{client_id='broken',send=function() return false end}; local works,r=broken:refresh(); eq(works,false); eq(r,'send_failed')
local old_client=D.new{client_id='same-client',send=function(_,_,params) sent[#sent+1]={request=codec:decode(params.JSON)} end}
old_client:refresh(); local delayed=reply({})
local new_client=D.new{client_id='same-client',send=function(_,_,params) sent[#sent+1]={request=codec:decode(params.JSON)} end}
new_client:refresh(); check(delayed.request_id~=sent[#sent].request.request_id); reason(delayed,'stale_response',new_client)
reason(reply({}),'complete',new_client)
check(not pcall(D.new,{client_id='bad\nclient',send=function() end}))
client:refresh(); local finite=reply({row('sensor.number',nil,nil,codec:newObject({number=123}))})
local nonfinite=codec:encode(finite):gsub('"number":123','"number":1e9999')
local handled,nonfinite_reason=client:consume_proxy('HA_ENTITIES',{JSON=nonfinite}); check(handled); eq(nonfinite_reason,'invalid_entity')
-- Picker filtering is each consumer's policy: on/off lights need no brightness capability.
local picker=D.build_picker(families,{domains={'switch','light'},selected_entity_id='light.simple'})
eq(#picker.values,4); eq(picker.label_to_entity[picker.selected_label],'light.simple'); eq(picker.label_to_entity[picker.manual_label],false)
local sensors=D.build_picker(families,{domains='sensor',selected_entity_id='sensor.temp'}); eq(#sensors.values,2)
local controls=D.build_picker(families,{predicate=function(v) return v.domain=='cover' or v.domain=='climate' or v.domain=='button' or v.domain=='select' end})
eq(#controls.values,5)
local missing=D.build_picker(families,{domains={'switch'},selected_entity_id='light.simple'})
eq(missing.selected_entity_id,'light.simple'); eq(missing.selected_label,missing.manual_label); check(missing.missing_selected)
local safe=D.build_picker({row('switch.a','Same, name\nnext'),row('switch.b','Same, name\nnext'),row('switch.a','duplicate')},{manual_label='Manual,\nEntry'})
eq(#safe.values,3); check(not safe.values[2]:find('[,\r\n]')); check(safe.values[2]~=safe.values[3]); eq(safe.label_to_entity[safe.values[2]],'switch.a')
eq(select(2,safe.value_list:gsub(',','')),2)
local empty=D.build_picker({}, {selected_entity_id='switch.unavailable'}); eq(#empty.values,1); eq(empty.selected_entity_id,'switch.unavailable')
local unavailable=D.build_picker(families,{domains='cover'}); eq(#unavailable.values,2)
-- Release is explicit and does not mutate current choices or flow state.
local release_client=D.new{client_id='release-owner',session_id='release-session',send=function(binding,command,params)
    sent[#sent+1]={binding=binding,command=command,request=codec:decode(params.JSON)}
end}
eq(release_client:release(),false)
release_client:refresh(); reason(reply({row('switch.release')}),'complete',release_client)
local choices=release_client.choices
check(release_client:release(release_client.metadata))
local released=sent[#sent]
eq(released.binding,999); eq(released.command,'HA_RELEASE_ENTITIES')
eq(released.request.version,1); eq(released.request.client_id,'release-owner')
eq(released.request.request_id,release_client.metadata.request_id)
eq(released.request.snapshot_id,release_client.metadata.snapshot_id)
eq(release_client.choices,choices); eq(release_client.status,'complete')
eq(release_client:release({request_id='bad\n',snapshot_id='snapshot'}),false)
local release_failure=D.new{client_id='release-failure',send=function() return false end}
eq(release_failure:release({request_id='finished',snapshot_id='snapshot'}),false)
print('Discovery: '..count..' assertions passed')
