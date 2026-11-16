-- Pure capability facts for state responses and generic discovery records.
-- No C4 proxy selection, command dispatch, transport, persistence or mutations.
-- Native definitions checked against HA 2026.11.1 components/light/__init__.py:
-- COLOR_MODES_BRIGHTNESS and LightEntityFeature.TRANSITION (32).
local M = { version = 1 }
local TRANSITION = 32
local BRIGHTNESS = { brightness=true, color_temp=true, hs=true, xy=true,
    rgb=true, rgbw=true, rgbww=true, white=true }
local COLOR = { hs=true, xy=true, rgb=true, rgbw=true, rgbww=true }

local function integer(value)
    return type(value)=='number' and value>=0 and value<=4294967295
        and value==math.floor(value)
end
local function text(value, maximum)
    return type(value)=='string' and #value>0 and #value<=(maximum or 128)
        and not value:find('%c')
end
local function object(value)
    if type(value)~='table' or tostring(value)=='JSON array' then return false end
    for key in pairs(value) do if type(key)~='string' then return false end end
    return true
end

-- Helpers intentionally have no switch/light policy and can serve other drivers.
function M.has_feature(mask, flag)
    if not integer(mask) or not integer(flag) or flag==0 then return false end
    local power=flag
    while power>1 and power%2==0 do power=power/2 end
    if power~=1 then return false end
    return mask%(flag*2)>=flag
end

function M.entity_domain(item)
    if not object(item) or not text(item.entity_id,255) then return nil end
    local domain=item.entity_id:match('^([a-z][a-z0-9_]*)%.[a-z0-9_]+$')
    if not domain or (item.domain~=nil and item.domain~=domain) then return nil end
    return domain
end

function M.matches_domain(item, domains)
    local domain=M.entity_domain(item)
    if not domain then return false end
    if type(domains)=='string' then return domain==domains end
    if type(domains)~='table' then return false end
    for _,candidate in ipairs(domains) do if domain==candidate then return true end end
    return false
end

function M.attribute_keys()
    return { 'supported_color_modes', 'supported_features' }
end

local function color_modes(value)
    if value==nil then return false, 'missing' end
    if type(value)~='table' or tostring(value)=='JSON object' or #value==0 or #value>16 then
        return false, 'malformed'
    end
    local count, seen, brightness, color=0, {}, false, false
    for key, mode in pairs(value) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#value
            or type(mode)~='string' or seen[mode]
            or (mode~='onoff' and not BRIGHTNESS[mode]) then return false, 'malformed' end
        count=count+1; seen[mode]=true
        brightness=brightness or BRIGHTNESS[mode]==true
        color=color or COLOR[mode]==true
    end
    if count~=#value or (seen.white and not color) then return false, 'malformed' end
    return brightness, 'valid'
end

local function availability(item)
    if item.state=='unavailable' then return 'unavailable' end
    if item.state=='unknown' then return 'unknown' end
    if item.availability=='unavailable' or item.availability=='unknown' then return item.availability end
    if type(item.state)=='string' and #item.state>0 then return 'available' end
    return 'unknown'
end

-- Backend facts are trusted, validated evidence supplied by a future adapter,
-- not attributes inferred from device names or an installed integration.
-- {
--   provider='deviceside', entity_id='light.office', verified=true,
--   target_supported=true,
--   capabilities={start_raise=true,start_lower=true,stop=true,ramp_to_level=false},
--   led_mapping={verified=true,source='select.office_led',mapping_id='profile:v1'}
-- }
-- DeviceSide installation alone is never evidence of support for a target.
local function verified_backend(facts, entity_id)
    return object(facts) and facts.verified==true and facts.target_supported==true
        and facts.entity_id==entity_id and text(facts.provider)
        and object(facts.capabilities)
end

function M.classify(item, backend)
    local result={version=1,entity_id='',domain='',valid_entity=false,
        supported=false,kind='unsupported',availability='unknown',
        capabilities={on_off=false,toggle=false,set_level=false,ramp_to_level=false,
            hold_dim=false,stop_dim=false,led_colors=false},
        evidence={},metadata={attributes='missing',color_modes='not_applicable',
            supported_features='not_applicable',backend='absent'}}
    local domain=M.entity_domain(item)
    if not domain then return result end
    result.valid_entity=true; result.domain=domain; result.entity_id=item.entity_id
    result.availability=availability(item)
    if domain~='switch' and domain~='input_boolean' and domain~='light' then return result end
    result.supported=true; result.kind='switch'
    local caps=result.capabilities
    caps.on_off=true; caps.toggle=true
    result.evidence.on_off='ha:'..domain
    result.evidence.toggle='ha:'..domain
    local attributes={}
    if item.attributes~=nil then
        if object(item.attributes) then attributes=item.attributes; result.metadata.attributes='valid'
        else result.metadata.attributes='malformed' end
    end
    if domain=='light' then
        local can_dim, status=color_modes(attributes.supported_color_modes)
        result.metadata.color_modes=status
        caps.set_level=can_dim
        if can_dim then
            result.kind='dimmer'; result.evidence.set_level='ha:supported_color_modes'
        end
        local features=attributes.supported_features
        if features==nil then result.metadata.supported_features='missing'
        elseif integer(features) then result.metadata.supported_features='valid'
        else result.metadata.supported_features='malformed' end
        caps.ramp_to_level=can_dim and M.has_feature(features, TRANSITION)
        if caps.ramp_to_level then result.evidence.ramp_to_level='ha:transition' end
    end
    if backend~=nil then
        result.metadata.backend='unverified'
        if verified_backend(backend,item.entity_id) then
            result.metadata.backend='verified'
            local facts=backend.capabilities
            if caps.set_level then
                caps.stop_dim=facts.stop==true
                caps.hold_dim=facts.start_raise==true and facts.start_lower==true and caps.stop_dim
                if facts.ramp_to_level==true then
                    caps.ramp_to_level=true; result.evidence.ramp_to_level='backend:'..backend.provider
                end
                if caps.stop_dim then result.evidence.stop_dim='backend:'..backend.provider end
                if caps.hold_dim then result.evidence.hold_dim='backend:'..backend.provider end
            end
            local led=backend.led_mapping
            if object(led) and led.verified==true and text(led.source,255) and text(led.mapping_id) then
                caps.led_colors=true
                result.evidence.led_colors='mapping:'..led.source..':'..led.mapping_id
            end
        end
    end
    return result
end

return M
