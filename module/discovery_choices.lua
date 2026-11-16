-- Pure Switch picker consolidation. Identity comes only from validated links.
local M={}
local LOAD_DOMAINS={switch=true,input_boolean=true,light=true}
local function entity_id(value)
    return type(value)=='string' and value:match('^[a-z][a-z0-9_]*%.[a-z0-9_]+$')~=nil
end
local function copy_row(row)
    local result={}; for key,value in pairs(row) do result[key]=value end; return result
end
local function normal_name(row)
    if type(row.name)=='string' and row.name:match('%S') then return row.name end
    return row.entity_id
end
local function is_group(row)
    local members=type(row.attributes)=='table' and row.attributes.entity_id
    if type(members)~='table' or tostring(members)=='JSON object' then return false end
    local count=0
    for key,value in pairs(members) do
        if type(key)~='number' or key<1 or key~=math.floor(key) or not entity_id(value) then return false end
        count=count+1
    end
    -- A plain empty table is ambiguous; a typed empty JSON array is evidence.
    return count==#members and (count>0 or tostring(members)=='JSON array')
end
local function validation(row,validate)
    if row.domain~='event' or type(validate)~='function' then return nil end
    local ok,metadata=pcall(validate,row)
    if not ok or type(metadata)~='table' then return nil end
    local load=metadata.load
    if load~=nil and (type(load)~='table' or not entity_id(load.entity_id) or
        not LOAD_DOMAINS[load.entity_id:match('^([^%.]+)')]) then return nil end
    return metadata
end

-- Returns picker rows, metadata_by_id, aliases. This function never changes the
-- actual selected Entity ID or Operation Mode. Only an explicit user selection
-- should apply metadata.operation_mode and the chosen row's exact entity_id.
-- validate_aggregate(row) must return {load=validated_load_or_nil} or nil.
local function native_choices(rows,options)
    options=options or {}
    local loads,aggregates,ordered,seen={},{},{},{}
    for _,row in ipairs(rows or {}) do
        if type(row)=='table' and entity_id(row.entity_id) and not seen[row.entity_id] then
            local actual_domain=row.entity_id:match('^([^%.]+)')
            if row.domain==actual_domain then
                seen[row.entity_id]=true; ordered[#ordered+1]=row
                if LOAD_DOMAINS[row.domain] then loads[row.entity_id]=row
                else
                    local metadata=validation(row,options.validate_aggregate)
                    if metadata then aggregates[row.entity_id]=metadata end
                end
            end
        end
    end

    local parents,wrappers={},{}
    for id in pairs(loads) do parents[id]=id end
    local function root(id)
        if parents[id]~=id then parents[id]=root(parents[id]) end
        return parents[id]
    end
    -- Registry enrichment is optional. Only a non-inverted switch_as_x light
    -- with its exact present switch source proves equivalent load identity.
    -- Group membership and coincident names/device IDs never establish this.
    for id,row in pairs(loads) do
        local registry=row.registry
        if row.domain=='light' and not is_group(row) and type(registry)=='table' and
            registry.platform=='switch_as_x' and registry.source_inverted==false and
            entity_id(registry.source_entity_id) then
            local source=loads[registry.source_entity_id]
            local source_registry=source and source.registry
            if source and source.domain=='switch' and not is_group(source) and
                not (type(source_registry)=='table' and source_registry.platform=='switch_as_x') then
                local a,b=root(id),root(source.entity_id)
                if a~=b then if a<b then parents[b]=a else parents[a]=b end end
                wrappers[id]=true
            end
        end
    end
    local components={}
    for id in pairs(loads) do
        local key=root(id)
        components[key]=components[key] or {ids={},key=key}
        local component=components[key]
        component.ids[#component.ids+1]=id
    end
    for _,component in pairs(components) do
        table.sort(component.ids)
        local selected=options.selected_entity_id
        if (options.operation_mode==nil or options.operation_mode=='Direct') and
            loads[selected] and root(selected)==component.key then
            component.preferred=selected
        else
            for _,id in ipairs(component.ids) do if wrappers[id] then component.preferred=id; break end end
            component.preferred=component.preferred or component.ids[1]
        end
    end
    local links,aggregate_keys={},{}
    for id,aggregate in pairs(aggregates) do
        if aggregate.load then
            local load_id=aggregate.load.entity_id
            aggregate_keys[id]=loads[load_id] and root(load_id) or 'missing/'..load_id
        end
        local key=aggregate_keys[id]
        if key then
            links[key]=links[key] or {}; links[key][#links[key]+1]=id
        end
    end
    local ranks={}
    for _,ids in pairs(links) do
        table.sort(ids)
        for index,id in ipairs(ids) do ranks[id]=index end
    end
    local result,metadata_by_id,aliases,emitted={},{},{},{}
    local function publish_aliases(component,choice_id,metadata)
        for _,id in ipairs(component.ids) do
            if id~=choice_id then aliases[id]=choice_id end
            metadata_by_id[id]=metadata
        end
    end
    for _,row in ipairs(ordered) do
        local id=row.entity_id
        local aggregate=aggregates[id]
        if aggregate then
            local load_id=aggregate.load and aggregate.load.entity_id
            local key=aggregate_keys[id]
            local component=key and components[key]
            local load=component and loads[component.preferred]
            local unique=component~=nil and #links[key]==1
            local choice=copy_row(row)
            if load then
                local suffix=is_group(load) and 'group, gestures' or 'gestures'
                if not unique then suffix=suffix..' '..ranks[id] end
                choice.name=normal_name(load)..' ('..suffix..')'
            end
            result[#result+1]=choice
            local metadata={entity_id=id,choice_id=id,load_id=load_id,gesture_id=id,
                source_entity_id=load and load.entity_id or nil,
                operation_mode=load_id and 'Gesture Bridge' or 'Gestures Only',
                unified=unique,is_group=load and is_group(load) or false,
                ambiguous=key~=nil and #links[key]>1 or false,
                equivalent=component~=nil and #component.ids>1 or false,
                physical_ids=component and component.ids or nil}
            metadata_by_id[id]=metadata
            if unique then publish_aliases(component,id,metadata) end
        elseif loads[id] then
            local key=root(id)
            local component=components[key]
            local linked=links[key]
            if not emitted[key] and (not linked or #linked~=1) then
                emitted[key]=true
                local preferred=component.preferred
                local choice=copy_row(loads[preferred])
                local group=is_group(choice)
                if group then choice.name=normal_name(choice)..' (group)' end
                result[#result+1]=choice
                local metadata={entity_id=preferred,choice_id=preferred,load_id=preferred,
                    operation_mode='Direct',unified=false,is_group=group,equivalent=#component.ids>1,
                    ambiguous=linked~=nil and #linked>1 or false,physical_ids=component.ids}
                metadata_by_id[preferred]=metadata
                publish_aliases(component,preferred,metadata)
            end
        end
    end
    return result,metadata_by_id,aliases
end
-- HA decides equivalence when its catalog is present. Accept only preferred
-- entities also seen and validated in native discovery; missing/invalid HA
-- targets leave the ordinary native choices available.
function M.build(rows,options)
    options=options or {}
    local preferred,metadata,aliases={},{},{}
    for _,row in ipairs(rows or {}) do
        local choice=row.catalog_choice
        if type(choice)=='table' and choice.entity_id==row.entity_id and
            entity_id(row.entity_id) and row.domain==row.entity_id:match('^([^%.]+)') then
            local aggregate=validation(row,options.validate_aggregate)
            if LOAD_DOMAINS[row.domain] or aggregate then
                preferred[row.entity_id]=row
                local load_id=aggregate and aggregate.load and aggregate.load.entity_id
                metadata[row.entity_id]={entity_id=row.entity_id,choice_id=row.entity_id,load_id=load_id or (not aggregate and row.entity_id or nil),
                    gesture_id=aggregate and row.entity_id or nil,source_entity_id=choice.source_entity_id,
                    operation_mode=aggregate and (load_id and 'Gesture Bridge' or 'Gestures Only') or 'Direct',
                    is_group=choice.is_group==true,unified=#choice.aliases>0}
            end
        end
    end
    if next(preferred)==nil then return native_choices(rows,options) end
    local result,fallback={},{ }
    for _,row in ipairs(rows or {}) do
        local choice=row.catalog_choice
        local target=type(choice)=='table' and preferred[choice.entity_id]
        if target then
            if row.entity_id==choice.entity_id then result[#result+1]=copy_row(row) end
        else fallback[#fallback+1]=row end
    end
    for id,row in pairs(preferred) do
        for _,alias in ipairs(row.catalog_choice.aliases) do
            aliases[alias]=id; metadata[alias]=metadata[id]
        end
    end
    local ordinary,ordinary_metadata,ordinary_aliases=native_choices(fallback,options)
    for _,row in ipairs(ordinary) do result[#result+1]=row end
    for id,value in pairs(ordinary_metadata) do if not metadata[id] then metadata[id]=value end end
    for id,value in pairs(ordinary_aliases) do if not aliases[id] then aliases[id]=value end end
    return result,metadata,aliases
end
return M
