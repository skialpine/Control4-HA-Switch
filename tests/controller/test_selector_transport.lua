-- Actual Coordinator consumes candidate/category/state results produced by HA.
local root,path=arg[1],arg[2]
local function execute(file,env)
    local chunk
    if setfenv then chunk=assert(loadfile(file)); setfenv(chunk,env)
    else chunk=assert(loadfile(file,'t',env)) end
    return chunk()
end
local function read(file) local f=assert(io.open(file)); local data=f:read('*a'); f:close(); return data end
local JSON=execute(root..'/module/json.lua',setmetatable({},{__index=_G}))
local codec=JSON:new({strictTypes=true,null={}})
local fixture=codec:decode(read(path))
local function same_ids(a,b)
    local left,right={},{}
    for _,id in ipairs(a) do left[#left+1]=id end
    for _,id in ipairs(b) do right[#right+1]=id end
    table.sort(left); table.sort(right)
    return table.concat(left,'\n')==table.concat(right,'\n')
end
for profile,case in pairs(fixture.selector_cases) do
    local env=setmetatable({},{__index=_G}); env._G=env; env.JSON=JSON
    local replies,http,metadata={},0,0
    env.print=function() end
    env.Properties={['Home Assistant URL']='selector-test.invalid',['Long Lived Access Token']='fake-token'}
    env.require=function(name)
        if name=='module.websocket' then return {} end
        if name=='module.json' then return JSON end
        if name=='module.discovery' or name=='module.state_projection' then
            return assert(loadfile(root..'/'..name:gsub('%.','/')..'.lua'))()
        end
        error('Unexpected dependency '..name)
    end
    env.C4={GetTime=function() return 100000 end,DebugLog=function() end,ParseXml=function() return {ChildNodes={}} end}
    function env.C4:SendToProxy(binding,command,params)
        assert(binding==1 and command=='HA_ENTITIES')
        replies[#replies+1]=codec:decode(params.JSON)
    end
    function env.C4:url()
        local transfer={}
        function transfer:OnHeaders() return self end
        function transfer:OnDone(fn) self.done=fn; return self end
        function transfer:SetOptions() return self end
        function transfer:Cancel() self.canceled=true end
        function transfer:Post(url,data)
            assert(url=='http://selector-test.invalid/api/template')
            local variables=codec:decode(data).variables
            assert(variables.selector==profile)
            http=http+1
            local result
            if variables.candidates_only then result=case.candidates
            else
                assert(same_ids(variables.entity_ids,case.eligible_ids),'Only main eligible controls get a state read')
                result=case.states
            end
            self.done(self,{{code=200,body=codec:encode(result)}},0)
            return self
        end
        return transfer
    end
    execute(root..'/driver.lua',env)
    env.Connected=true; env.EntityTable={['switch.saved']='unchanged'}
    env.Socket={Send=function(_,raw)
        local request=codec:decode(raw)
        assert(request.type=='config/entity_registry/get_entries','No full states/registry request or load command')
        assert(#request.entity_ids<=50)
        metadata=metadata+1
        local result=codec:newObject()
        for _,id in ipairs(request.entity_ids) do
            assert(case.registry[id],'Metadata must be scoped to candidate IDs')
            result[id]=case.registry[id]
        end
        env.ReceieveMessage(env.Socket,codec:encode({type='result',id=request.id,success=true,result=result}))
    end}
    env.ReceivedFromProxy(1,'HA_GET_ENTITIES',{JSON=codec:encode({version=1,client_id=profile,request_id='setup',
        selector=profile,entity_ids=case.scope,domains={'light','switch','event'},attribute_keys=case.keys})})
    assert(#replies==1 and not replies[1].error,codec:encode(replies))
    local ids={}; for _,row in ipairs(replies[1].entities) do ids[#ids+1]=row.entity_id end
    assert(same_ids(ids,case.expected_ids),'Selector must omit settings, helpers, C4 mirrors and duplicate load aliases')
    assert(http==2 and metadata==1,'One ID read, one scoped metadata read, one eligible state read')
    assert(env.EntityTable['switch.saved']=='unchanged' and next(env.EntityTable)=='switch.saved')
end
print('Actual HA selector transport passed: device roles, native JSON types, C4 exclusion and exact aliases')
