-- Optional preferred-device catalog from HA. Native states still own targets.
local Discovery=require('module.discovery')
local codec=Discovery.new_codec()
local M={}
local Client={}; Client.__index=Client
local DOMAINS={switch=true,input_boolean=true,light=true,event=true}
local MANIFEST={'catalog_contract_version','catalog_names_version','catalog_names_revision',
    'catalog_names_total','catalog_names_pages','catalog_names_error'}
local function text(value) return type(value)=='string' and #value>0 and #value<=4096 end
local function integer(value,maximum)
    return type(value)=='number' and value>=0 and value<=maximum and value==math.floor(value)
end
local function entity(value)
    return type(value)=='string' and #value<=255 and value:match('^[a-z][a-z0-9_]*%.[a-z0-9_]+$')~=nil
end
local function sensor(rows,expected)
    if #rows==0 then return nil,'absent' end
    if #rows~=1 or rows[1].entity_id~=expected then return nil,'invalid_catalog' end
    local row=rows[1]
    if row.availability~='available' then return nil,'unavailable' end
    local attrs=row.attributes
    if type(attrs.catalog_contract_version)~='string' or not attrs.catalog_contract_version:match('^1%.%d+$') then
        return nil,'unsupported_version'
    end
    return row
end
local function add_records(values,mapped)
    if type(values)~='table' or tostring(values)~='JSON array' or #values>10000 then return nil,'invalid_catalog' end
    for _,value in ipairs(values) do
        if type(value)~='table' or not entity(value.entity_id) or
            value.domain~=value.entity_id:match('^([^%.]+)') or not DOMAINS[value.domain] or
            mapped[value.entity_id] or not text(value.friendly_name) or
            (value.area_name~=nil and value.area_name~=Discovery.null and not text(value.area_name)) then
            return nil,'invalid_catalog'
        end
        local aliases=value.entity_aliases
        if aliases~=nil and (type(aliases)~='table' or tostring(aliases)~='JSON array' or #aliases>10000) then
            return nil,'invalid_catalog'
        end
        local source=value.source_entity_id
        if source~=nil and not entity(source) then return nil,'invalid_catalog' end
        if value.is_group~=nil and type(value.is_group)~='boolean' then return nil,'invalid_catalog' end
        local seen={}
        for _,alias in ipairs(aliases or {}) do
            if not entity(alias) or alias==value.entity_id or seen[alias] then return nil,'invalid_catalog' end
            seen[alias]=true
        end
        mapped[value.entity_id]={entity_id=value.entity_id,name=value.friendly_name,
            area=value.area_name~=Discovery.null and value.area_name or nil,
            aliases=aliases or {},source_entity_id=source,is_group=value.is_group==true}
    end
    return #values
end
local function manifest(row)
    local attrs=row.attributes
    if attrs.catalog_names_version~=1 then return nil,'unsupported_names_version' end
    if attrs.catalog_names_error~=nil then
        if attrs.catalog_names_error=='record_too_large' or attrs.catalog_names_error=='catalog_limit' then
            return nil,'error_'..attrs.catalog_names_error
        end
        return nil,'invalid_catalog'
    end
    local revision,total,pages=attrs.catalog_names_revision,attrs.catalog_names_total,attrs.catalog_names_pages
    if type(revision)~='string' or #revision~=64 or not revision:match('^%x+$') or
        not integer(total,10000) or tonumber(row.state)~=total or not integer(pages,64) or
        (total==0 and pages~=0) or (total>0 and (pages==0 or pages>total)) then return nil,'invalid_catalog' end
    return {revision=revision,total=total,pages=pages,index=1,mapped={},count=0,bytes=0}
end
function Client:_status(reason,detail)
    self.status=reason
    if self.on_status then self.on_status(reason,detail) end
end
function Client:_clear(reason)
    self.entries={}; self.transfer=nil; self.phase=nil
    self:_status(reason)
    if self.on_change then self.on_change() end
end
function Client:_request(phase,page)
    self.phase=phase
    local attrs={}
    for _,key in ipairs(MANIFEST) do attrs[#attrs+1]=key end
    if page then attrs[#attrs+1]=string.format('catalog_names_page_%03d',page) end
    return self.discovery:refresh({entity_ids={self.expected},attribute_keys=attrs,page_size=1})
end
function Client:_complete(rows)
    local row,reason=sensor(rows,self.expected)
    if not row then self:_clear(reason); return end
    local current,invalid=manifest(row)
    if not current then self:_clear(invalid); return end
    if self.phase=='manifest' then
        self.transfer=current
    else
        local pending=self.transfer
        if not pending or current.revision~=pending.revision or current.total~=pending.total or current.pages~=pending.pages then
            self:_clear('snapshot_changed'); return
        end
        local values=row.attributes[string.format('catalog_names_page_%03d',pending.index)]
        local count,error_code=add_records(values,pending.mapped)
        if not count or count==0 then self:_clear(error_code or 'invalid_catalog'); return end
        pending.count=pending.count+count
        pending.bytes=pending.bytes+#codec:encode(values)
        if pending.count>pending.total or pending.bytes>1048576 then self:_clear('catalog_limit'); return end
        pending.index=pending.index+1
    end
    local pending=self.transfer
    if pending.index<=pending.pages then self:_request('page',pending.index); return end
    if pending.count~=pending.total then self:_clear('invalid_catalog'); return end
    local entries={}
    for id,entry in pairs(pending.mapped) do entries[id]=entry end
    local count=pending.count
    for _,entry in pairs(pending.mapped) do
        for _,alias in ipairs(entry.aliases) do
            if entries[alias] then self:_clear('invalid_catalog'); return end
            count=count+1
            if count>10000 then self:_clear('catalog_limit'); return end
            entries[alias]=entry
        end
    end
    self.entries=entries
    self.phase=nil; self.transfer=nil
    self:_status('complete')
    if self.on_change then self.on_change() end
end
function Client:refresh(entity_id)
    self.expected=entity_id
    self.discovery:invalidate('refreshing')
    self:_clear(entity_id=='' and 'disabled' or 'loading')
    if entity_id=='' then return true,'disabled' end
    if not entity(entity_id) or entity_id:match('^([^%.]+)')~='sensor' then
        self:_status('invalid_entity_id'); return false,'invalid_entity_id'
    end
    return self:_request('manifest')
end
function Client:invalidate(reason)
    self.expected=nil
    self.discovery:invalidate('refreshing')
    self:_clear(reason or 'invalidated')
end
function Client:tick() return self.discovery:tick() end
function Client:consume_proxy(command,params) return self.discovery:consume_proxy(command,params) end
function Client:merge(rows)
    local result={}
    for _,row in ipairs(rows) do
        local entry=self.entries[row.entity_id]
        if entry then
            local enriched={}; for key,value in pairs(row) do enriched[key]=value end
            if entry.entity_id==row.entity_id then
                enriched.name=entry.name..(entry.area and ' — '..entry.area or '')
            end
            enriched.catalog_choice=entry
            result[#result+1]=enriched
        else result[#result+1]=row end
    end
    return result
end
function Client:describe(basic_metadata,missing_selected)
    local message=basic_metadata and 'Complete; basic metadata' or 'Complete'
    if missing_selected then message=message..'; current Entity ID not listed (preserved)' end
    if self.status=='complete' then return message..'; HA device catalog' end
    if self.status~='idle' and self.status~='loading' and self.status~='refreshing'
        and self.status~='disabled' and self.status~='absent' then
        return message..'; optional catalog '..self.status
    end
    return message
end
function M.new(options)
    local self=setmetatable({entries={},status='idle',on_change=options.on_change,on_status=options.on_status},Client)
    self.discovery=Discovery.new({client_id=options.client_id,send=options.send,now=options.now,timeout=options.timeout or 20,
        on_status=function(reason,detail)
            if reason=='complete' or reason=='loading' or reason=='refreshing' then return end
            self.transfer=nil; self.phase=nil; self.entries={}
            self:_status(reason=='coordinator_error' and ('error_'..tostring(detail.code)) or reason,detail)
            if self.on_change then self.on_change() end
        end,
        on_complete=function(rows,metadata)
            local serial=self.discovery.serial
            self.discovery:release(metadata)
            -- A transport callback may invalidate or refresh during release.
            if self.discovery.serial~=serial or not self.phase then return end
            self:_complete(rows)
        end})
    return self
end
return M
