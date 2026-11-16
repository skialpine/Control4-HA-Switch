-- Generic HA entity discovery transport and Composer picker helpers (Lua 5.1+).
local JSON = require('module.json')
local M = {null={}}
local Client = {}
Client.__index = Client
local MAX_ROWS, MAX_BYTES, MAX_PAGE_BYTES, MAX_PAGES = 10000, 1048576, 32768, 10000
local instance_serial = 0

-- Additive coordinator notification; original coordinators need no change for
-- normal operation. Only an explicit, well-formed status changes authority.
function M.connection_status(params)
    if type(params)~='table' then return nil end
    local value=params.CONNECTED
    if value==true or value=='true' then return true end
    if value==false or value=='false' then return false end
end

function M.new_codec()
    return JSON:new({strictTypes=true, null=M.null,
        onDecodeError=function() error('invalid_json', 0) end,
        onEncodeError=function() error('invalid_json', 0) end})
end
local codec = M.new_codec()
local ARRAY_MT, OBJECT_MT = getmetatable(codec:newArray({})), getmetatable(codec:newObject({}))
local function int(v, lo, hi) return type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi end
local function text(v, limit) return type(v)=='string' and #v>0 and #v<=limit end
local function identifier(v, limit) return text(v,limit) and not v:find('%c') end
local function domain(v) return text(v, 64) and v:match('^[a-z][a-z0-9_]*$')~=nil end
local function entity(v) return text(v, 255) and v:match('^[a-z][a-z0-9_]*%.[a-z0-9_]+$')~=nil end
local function array(v)
    if type(v)~='table' or v==M.null or getmetatable(v)==OBJECT_MT then return false end
    local count=0
    for k in pairs(v) do if not int(k,1,MAX_ROWS) then return false end; count=count+1 end
    return count==#v
end
local function object(v)
    if type(v)~='table' or v==M.null or getmetatable(v)==ARRAY_MT then return false end
    for k in pairs(v) do if type(k)~='string' then return false end end
    return true
end
local function json_value(v, depth, seen)
    if v==M.null then return true end
    local kind=type(v)
    if kind=='string' or kind=='boolean' then return true end
    if kind=='number' then return v==v and v>-math.huge and v<math.huge end
    if kind~='table' or depth>64 or seen[v] then return false end
    if not object(v) and not array(v) then return false end
    seen[v]=true
    for _,child in pairs(v) do if not json_value(child,depth+1,seen) then seen[v]=nil; return false end end
    seen[v]=nil; return true
end
local function copy(v, seen)
    if type(v)~='table' or v==M.null then return v end
    seen=seen or {}; if seen[v] then error('cyclic_value') end; seen[v]=true
    local out=setmetatable({},getmetatable(v))
    for k,x in pairs(v) do out[k]=copy(x,seen) end
    seen[v]=nil; return out
end

-- Validate complete JSON grammar before the older bundled codec decodes it.
local function valid_json(s)
    local i,n=1,#s
    local function ws() while s:sub(i,i):match('[ \r\n\t]') and i<=n do i=i+1 end end
    local function str()
        if s:sub(i,i)~='"' then return false end; i=i+1
        while i<=n do
            local c=s:sub(i,i); i=i+1
            if c=='"' then return true end
            if c=='\\' then
                local e=s:sub(i,i); i=i+1
                if e=='u' then if not s:sub(i,i+3):match('^%x%x%x%x$') then return false end; i=i+4
                elseif e=='' or not e:match('^["\\/bfnrt]$') then return false end
            elseif c:byte()<32 then return false end
        end
        return false
    end
    local value
    value=function(depth)
        if depth>64 then return false end
        ws(); local c=s:sub(i,i)
        if c=='"' then return str() end
        if c=='{' or c=='[' then
            i=i+1; ws(); local close=c=='{' and '}' or ']'
            if s:sub(i,i)==close then i=i+1; return true end
            while true do
                if c=='{' then if not str() then return false end; ws(); if s:sub(i,i)~=':' then return false end; i=i+1 end
                if not value(depth+1) then return false end
                ws(); local sep=s:sub(i,i); i=i+1
                if sep==close then return true end
                if sep~=',' then return false end; ws()
            end
        end
        for _,literal in ipairs({'true','false','null'}) do
            if s:sub(i,i+#literal-1)==literal then i=i+#literal; return true end
        end
        local start=i
        if c=='-' then i=i+1 end
        c=s:sub(i,i)
        if c=='0' then i=i+1
        elseif c:match('[1-9]') and c~='' then repeat i=i+1 until not s:sub(i,i):match('%d')
        else return false end
        if s:sub(i,i)=='.' then i=i+1; if not s:sub(i,i):match('%d') then return false end; repeat i=i+1 until not s:sub(i,i):match('%d') end
        c=s:sub(i,i)
        if c=='e' or c=='E' then
            i=i+1; c=s:sub(i,i); if c=='+' or c=='-' then i=i+1 end
            if not s:sub(i,i):match('%d') then return false end
            repeat i=i+1 until not s:sub(i,i):match('%d')
        end
        return i>start
    end
    ws(); if s:sub(i,i)~='{' or not value(0) then return false end; ws(); return i>n
end

local QUERY_FIELDS={domains=true,entity_ids=true,attribute_keys=true,page_size=true,include_registry=true,selector=true}
local function query_copy(query)
    if query==nil then query={} end
    if not object(query) then return nil,'invalid_query' end
    local out={page_size=query.page_size or 50}
    if query.include_registry~=nil then
        if type(query.include_registry)~='boolean' then return nil,'invalid_include_registry' end
        out.include_registry=query.include_registry
    end
    if query.selector~=nil then
        if query.selector~='switch' and query.selector~='dimmer' then return nil,'invalid_selector' end
        out.selector=query.selector
    end
    if not int(out.page_size,1,100) then return nil,'invalid_page_size' end
    for k in pairs(query) do if not QUERY_FIELDS[k] then return nil,'invalid_query_field' end end
    for _,field in ipairs({'domains','entity_ids','attribute_keys'}) do
        local values=query[field]
        if values~=nil then
            if not array(values) or #values>10000 then return nil,'invalid_'..field end
            local result, seen=JSON:newArray({}),{}
            for _,v in ipairs(values) do
                if (field=='domains' and not domain(v)) or (field=='entity_ids' and not entity(v)) or
                    (field=='attribute_keys' and not text(v,255)) or seen[v] then return nil,'invalid_'..field end
                seen[v]=true; result[#result+1]=v
            end
            out[field]=result
        end
    end
    return out
end
function Client:_status(reason,detail)
    self.status=reason
    if self.on_status then pcall(self.on_status,reason,detail) end
end
function Client:_fail(reason,detail)
    self.pending=nil; self:_status(reason,detail); return true,reason
end
function Client:_send()
    local p=self.pending
    local request=copy(p.query)
    request.version=1; request.client_id=self.client_id; request.request_id=p.request_id
    request.cursor=p.cursor
    local ok,encoded=pcall(self.encode,request)
    if not ok or type(encoded)~='string' then return self:_fail('encode_failed') end
    p.deadline=self.now()+self.timeout
    local sent,result=pcall(self.send,999,'HA_GET_ENTITIES',{JSON=encoded})
    if not sent or result==false then return self:_fail('send_failed') end
    return true,p.request_id
end
function Client:refresh(query)
    self.pending=nil -- A new refresh always invalidates an older in-flight request.
    local normalized,reason=query_copy(query)
    if not normalized then self:_status(reason); return false,reason end
    self.serial=self.serial+1
    local request_id=self.session_id..':'..tostring(self.serial)
    self.pending={request_id=request_id,query=normalized,rows={},seen={},cursors={},bytes=0,pages=0}
    self:_status('loading')
    local ok,id=self:_send()
    if not self.pending then return false,self.status end
    return ok,id
end
function Client:invalidate(reason)
    self.pending=nil; self:_status(reason or 'invalidated'); return true
end
function Client:release(meta)
    meta=meta or self.metadata
    if type(meta)~='table' or not identifier(meta.request_id,96) or not text(meta.snapshot_id,128) then return false end
    local ok,raw=pcall(self.encode,{version=1,client_id=self.client_id,
        request_id=meta.request_id,snapshot_id=meta.snapshot_id})
    if not ok or type(raw)~='string' then return false end
    local sent,result=pcall(self.send,999,'HA_RELEASE_ENTITIES',{JSON=raw})
    return sent and result~=false
end
function Client:tick()
    if self.pending and self.now()>=self.pending.deadline then
        self:_fail('timeout','Coordinator did not answer entity discovery; update or reconnect the coordinator.')
        return true,'timeout'
    end
    return false,self.status
end
Client.expire=Client.tick
local function valid_item(row)
    return object(row) and entity(row.entity_id) and domain(row.domain) and
        row.entity_id:match('^([^%.]+)%.')==row.domain and type(row.name)=='string' and #row.name<=4096 and
        type(row.state)=='string' and #row.state<=4096 and
        (row.availability=='available' or row.availability=='unavailable' or row.availability=='unknown') and
        object(row.attributes) and json_value(row.attributes,0,{})
end
function Client:consume_proxy(command,params)
    if command~='HA_ENTITIES' then return false,'unhandled' end
    if not self.pending then return true,'stale_response' end
    local raw=type(params)=='table' and params.JSON
    if type(raw)~='string' or #raw>MAX_PAGE_BYTES or not valid_json(raw) then return self:_fail('invalid_response') end
    local ok,response=pcall(self.decode,raw)
    if not ok or not object(response) then return self:_fail('invalid_response') end
    if response.client_id~=self.client_id then return true,'other_client' end
    local p=self.pending
    if response.request_id~=p.request_id then return true,'stale_response' end
    if response.version~=1 then return self:_fail('unsupported_version') end
    if response.error~=nil then
        if not object(response.error) or not text(response.error.code,96) or not text(response.error.message,4096) or
            not array(response.entities) or #response.entities~=0 or response.complete~=true or response.total~=0 or
            response.next_cursor~=nil then return self:_fail('invalid_error') end
        return self:_fail('coordinator_error',copy(response.error))
    end
    if not text(response.snapshot_id,128) or not array(response.entities) or not int(response.total,0,MAX_ROWS) or
        type(response.complete)~='boolean' then return self:_fail('invalid_response') end
    if #response.entities>p.query.page_size then return self:_fail('invalid_response') end
    if p.snapshot_id and (p.snapshot_id~=response.snapshot_id or p.total~=response.total) then return self:_fail('snapshot_changed') end
    p.snapshot_id=response.snapshot_id; p.total=response.total
    p.bytes=p.bytes+#raw; p.pages=p.pages+1
    if p.bytes>self.max_bytes or p.pages>self.max_pages then return self:_fail('catalog_limit') end
    local cursor=response.next_cursor
    if response.complete then
        if cursor~=nil then return self:_fail('invalid_pagination') end
    elseif not text(cursor,1024) or p.cursors[cursor] or #response.entities==0 then return self:_fail('invalid_pagination') end
    for _,row in ipairs(response.entities) do
        if not valid_item(row) or p.seen[row.entity_id] then return self:_fail('invalid_entity') end
        p.seen[row.entity_id]=true; p.rows[#p.rows+1]=row
        if #p.rows>self.max_rows or #p.rows>p.total then return self:_fail('catalog_limit') end
    end
    if response.complete then
        if #p.rows~=p.total then return self:_fail('incomplete_catalog') end
        local rows=copy(p.rows)
        local meta={snapshot_id=p.snapshot_id,total=p.total,request_id=p.request_id,pages=p.pages}
        self.pending=nil; self.choices=rows; self.metadata=meta; self:_status('complete')
        if self.on_complete then pcall(self.on_complete,rows,meta) end
        return true,'complete'
    end
    if #p.rows>=p.total then return self:_fail('invalid_pagination') end
    p.cursors[cursor]=true; p.cursor=cursor
    self:_send()
    return true,self.pending and 'page_requested' or self.status
end
function M.new(options)
    options=options or {}
    assert(identifier(options.client_id,96),'client_id must be 1..96 bytes without control characters')
    assert(type(options.send)=='function','send is required')
    local timeout=options.timeout or 10
    assert(type(timeout)=='number' and timeout>0 and timeout<math.huge,'timeout must be positive')
    instance_serial=instance_serial+1
    local session_id=options.session_id or (tostring(os.time())..'-'..tostring(os.clock()):gsub('%.','')..'-'..tostring(instance_serial)..'-'..tostring({}):gsub('[^%w]',''))
    assert(identifier(session_id,64),'session_id must be 1..64 bytes without control characters')
    return setmetatable({client_id=options.client_id,session_id=session_id,send=options.send,
        encode=options.encode or function(v) return codec:encode(v) end,
        decode=options.decode or function(v) return codec:decode(v) end,
        on_complete=options.on_complete,on_status=options.on_status,now=options.now or os.time,timeout=timeout,
        max_rows=math.min(options.max_rows or MAX_ROWS,MAX_ROWS),max_bytes=math.min(options.max_bytes or MAX_BYTES,MAX_BYTES),
        max_pages=math.min(options.max_pages or MAX_PAGES,MAX_PAGES),serial=0,choices={},status='idle'},Client)
end
local function clean(v)
    return tostring(v or ''):gsub('[,\r\n]',' '):gsub('%s+',' '):match('^%s*(.-)%s*$')
end
function M.build_picker(rows,options)
    options=options or {}; local candidates,seen={},{}
    local domains=options.domains
    local allowed
    if domains then
        allowed={}; if type(domains)=='string' then allowed[domains]=true
        else for k,v in pairs(domains) do if type(k)=='number' then allowed[v]=true elseif v then allowed[k]=true end end end
    end
    for _,row in ipairs(rows or {}) do
        if entity(row.entity_id) and not seen[row.entity_id] and (not allowed or allowed[row.domain]) and
            (not options.predicate or options.predicate(row)) then
            seen[row.entity_id]=true
            local name=clean(row.name); if name=='' then name=row.entity_id end
            candidates[#candidates+1]={id=row.entity_id,label=name..' ['..row.entity_id..']'}
        end
    end
    table.sort(candidates,function(a,b) if a.label:lower()==b.label:lower() then return a.id<b.id end; return a.label:lower()<b.label:lower() end)
    local manual=clean(options.manual_label or 'Manual Entity ID'); if manual=='' then manual='Manual Entity ID' end
    -- A custom manual label must not collide with a generated entity label.
    for _,v in ipairs(candidates) do if v.label==manual then manual=manual..' (manual)' end end
    local result={values={manual},manual_label=manual,label_to_entity={[manual]=false},entity_to_label={},
        selected_entity_id=options.selected_entity_id}
    for _,v in ipairs(candidates) do result.values[#result.values+1]=v.label; result.label_to_entity[v.label]=v.id; result.entity_to_label[v.id]=v.label end
    result.selected_label=result.entity_to_label[options.selected_entity_id] or manual
    result.missing_selected=text(options.selected_entity_id,255) and not result.entity_to_label[options.selected_entity_id] or false
    result.value_list=table.concat(result.values,',')
    return result
end
return M
