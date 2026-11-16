-- Pure Composer load conditions. Call with the current validated load state and
-- matching Family.classify facts, never an aggregate event or inferred state.
local M={}
local DOMAINS={switch=true,input_boolean=true,light=true}
local LOGIC={
    EQUAL=function(a,b) return a==b end,
    NOT_EQUAL=function(a,b) return a~=b end,
    LESS_THAN=function(a,b) return a<b end,
    LESS_THAN_OR_EQUAL=function(a,b) return a<=b end,
    GREATER_THAN=function(a,b) return a>b end,
    GREATER_THAN_OR_EQUAL=function(a,b) return a>=b end,
}
local function number(value,maximum)
    return type(value)=='number' and value==value and value>=0 and value<=maximum
end
local function target(value)
    -- Composer normally supplies macro values as strings. Accept decimal
    -- numbers only; never coerce arbitrary tables, booleans or non-finite text.
    if type(value)=='string' then
        local trimmed=value:match('^%s*(.-)%s*$')
        if not trimmed:match('^[+-]?%d+%.?%d*$') then return nil end
        value=tonumber(trimmed)
    end
    if number(value,100) and value==math.floor(value) then return value end
end
local function ready(state,facts)
    if type(state)~='table' or type(facts)~='table' or type(state.entity_id)~='string' then return false end
    local domain=state.entity_id:match('^([a-z][a-z0-9_]*)%.[a-z0-9_]+$')
    if not domain or not DOMAINS[domain] or (state.domain~=nil and state.domain~=domain) then return false end
    if facts.entity_id~=state.entity_id or facts.domain~=domain or facts.valid_entity~=true or
        facts.supported~=true or facts.availability~='available' or type(facts.capabilities)~='table' or
        facts.capabilities.on_off~=true then return false end
    if state.availability~=nil and state.availability~='available' then return false end
    return state.state=='on' or state.state=='off'
end

function M.evaluate(name,params,state,facts)
    if name~='IS_ON' and name~='IS_OFF' and name~='LIGHT_LEVEL' then return false end
    -- Validate before every comparison, including NOT_EQUAL. Unknown is neither
    -- Off nor a numeric level and cannot satisfy a negative comparison.
    if not ready(state,facts) then return false end
    if name=='IS_ON' then return state.state=='on' end
    if name=='IS_OFF' then return state.state=='off' end
    if facts.domain~='light' or facts.capabilities.set_level~=true or type(params)~='table' then return false end
    local compare=type(params.LOGIC)=='string' and LOGIC[params.LOGIC]
    local expected=target(params.VALUE)
    if not compare or expected==nil then return false end
    local level=0
    if state.state=='on' then
        local brightness=type(state.attributes)=='table' and state.attributes.brightness
        -- HA brightness is a raw 0..255 byte-scale value, not a percentage:
        -- https://www.home-assistant.io/integrations/light/#default-turn-on-values
        if not number(brightness,255) then return false end
        level=math.floor(brightness*100/255+0.5)
    end
    -- Off is zero regardless of a cached brightness attribute. No on=100 guess.
    return compare(level,expected)
end
return M
