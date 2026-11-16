-- Optional Coordinator subscription acknowledgments. Old coordinators do not
-- send them, so their selected-state API retains its existing behavior.
local M={}
local Subscription={}; Subscription.__index=Subscription
function M.new(consumer_id,codec)
    return setmetatable({consumer_id=tostring(consumer_id),codec=codec},Subscription)
end
function Subscription:request(entity,linked)
    local entities={entity}
    if type(linked)=='string' and linked~='' and linked~=entity then entities[#entities+1]=linked end
    return {entity=entity,consumer_id=self.consumer_id,
        active_entities=self.codec:encode(self.codec:newArray(entities))}
end
function Subscription:release()
    self.status,self.error=nil,nil
    return {consumer_id=self.consumer_id}
end
function Subscription:observe(params,entity)
    if type(params)~='table' or params.ENTITY~=entity then return false end
    local status=params.STATUS
    if status~='pending' and status~='ready' and status~='error' then return false end
    self.status=status
    self.error=type(params.ERROR)=='string' and params.ERROR:gsub('%c',' '):sub(1,160) or nil
    return true
end
function Subscription:ready() return self.status==nil or self.status=='ready' end
function Subscription:message()
    if self.status=='error' then return 'HA event subscription failed: '..(self.error or 'unknown error') end
    if self.status=='pending' then return 'Waiting for HA event subscription acknowledgment' end
end
return M
