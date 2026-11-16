-- Actual HA catalog state -> real bounded Coordinator -> optional enrichment.
local root,path=arg[1],arg[2]
local function isolated(file,env)
    local chunk
    if setfenv then chunk=assert(loadfile(file)); setfenv(chunk,env)
    else chunk=assert(loadfile(file,'t',env)) end
    return chunk()
end
local ServerJSON=isolated(root..'/module/json.lua',setmetatable({}, {__index=_G}))
local Server=assert(loadfile(root..'/module/discovery.lua'))()
local wire=ServerJSON:new({strictTypes=true,null={}})
local file=assert(io.open(path,'r')); local fixture=wire:decode(file:read('*a')); file:close()
local Enrichment=require('module.catalog_enrichment')
local Discovery=require('module.discovery')
local codec=Discovery.new_codec()
local requests,responses,release_count,total_requests={},{},0,0
local projected_bytes=0
local function signature(keys)
    local values={}; for _,key in ipairs(keys) do values[#values+1]=key end
    table.sort(values); return table.concat(values,'\n')
end
local projected={}
for _,entry in ipairs(fixture.projected) do projected[signature(entry.keys)]=entry.states end
local server=Server.new({json=ServerJSON,clock=function() return 100 end,
    fetch=function(done,query)
        if #query.attribute_keys==1 and query.attribute_keys[1]=='catalog_entities' then
            done(fixture.states); return -- Deliberate legacy oversized-record proof.
        end
        local states=assert(projected[signature(query.attribute_keys)],'Missing actual HA projection for names query')
        projected_bytes=projected_bytes+#wire:encode(states)
        done(states)
    end,
    send=function(raw) assert(#raw<=32768,'Proxy packet limit must remain unchanged'); responses[#responses+1]=raw end})
-- Reproduce the original one-record failure through the actual projector.
server:request(codec:encode({version=1,client_id='legacy-test',request_id='full-catalog',page_size=1,
    entity_ids=codec:newArray({fixture.catalog_entity_id}),attribute_keys=codec:newArray({'catalog_entities'})}))
local legacy=wire:decode(table.remove(responses,1))
assert(legacy.error and legacy.error.code=='record_too_large','Fixture must reproduce full catalog failure')
local enrichment=Enrichment.new({client_id='bounded-catalog-test',now=function() return 100 end,
    send=function(binding,command,params)
        assert(binding==999 and (command=='HA_GET_ENTITIES' or command=='HA_RELEASE_ENTITIES'))
        requests[#requests+1]={command=command,raw=params.JSON}
    end})
enrichment:refresh(fixture.catalog_entity_id)
local index=1
while index<=#requests do
    assert(index<140,'Names paging must terminate within its declared bound')
    local request=requests[index]; index=index+1
    if request.command=='HA_RELEASE_ENTITIES' then
        release_count=release_count+1; server:release(request.raw)
    else
        total_requests=total_requests+1
        local query=codec:decode(request.raw)
        for _,key in ipairs(query.attribute_keys) do assert(key~='catalog_entities','New manifest must not request the full catalog') end
        server:request(request.raw)
        while #responses>0 do
            local raw=table.remove(responses,1)
            local response=codec:decode(raw)
            assert(not response.error,'Bounded names transport failed: '..tostring(response.error and response.error.code))
            enrichment:consume_proxy('HA_ENTITIES',{JSON=raw})
        end
    end
end
assert(enrichment.status=='complete','Expected complete enrichment, got '..tostring(enrichment.status))
local count=0; for _ in pairs(enrichment.entries) do count=count+1 end
assert(count==fixture.catalog_rows,'No catalog names may be lost')
assert(release_count==total_requests and next(server.snapshots)==nil,'Completed snapshots must be explicitly released')
local native={{entity_id=fixture.last_entity_id,domain='switch',name='Native name',state='off',availability='available',attributes={}}}
local merged=enrichment:merge(native)
assert(#merged==1 and merged[1].name==fixture.last_name..' — Fixture Transport Area')
assert(merged[1].state=='off' and merged[1].attributes==native[1].attributes,'Catalog cannot grant load authority')
local unprojected_bytes=#wire:encode(fixture.states)*total_requests
assert(projected_bytes<unprojected_bytes/4,'HA projection must avoid repeated full-catalog transfer')
print('Bounded catalog transport passed: '..count..' actual HA rows, '..total_requests..' reads, '..release_count..' releases; '..projected_bytes..' projected HA bytes versus '..unprojected_bytes..' full-state bytes')
