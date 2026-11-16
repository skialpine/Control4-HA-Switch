-- No C4 APIs are required or touched by condition evaluation.
C4=setmetatable({},{__index=function() error('Conditions cannot use C4 APIs') end})
local Conditions=require('module.load_conditions')
local Family=require('module.family_capabilities')
local count=0
local function check(value,message) count=count+1; assert(value,message or ('assertion '..count)) end
local function eq(actual,expected) check(actual==expected,'expected '..tostring(expected)..', got '..tostring(actual)) end
local function state(id,value,attributes)
    return {entity_id=id,state=value,attributes=attributes or {}}
end
local function evaluate(name,params,item,facts)
    return Conditions.evaluate(name,params,item,facts or Family.classify(item))
end
local function compare(item,operator,value,facts)
    return evaluate('LIGHT_LEVEL',{LOGIC=operator,VALUE=value},item,facts)
end
for _,domain in ipairs({'switch','input_boolean','light'}) do
    for _,value in ipairs({'on','off'}) do
        local item=state(domain..'.office',value)
        eq(evaluate('IS_ON',nil,item),value=='on')
        eq(evaluate('IS_OFF',nil,item),value=='off')
        eq(compare(item,'NOT_EQUAL',50),false) -- No brightness capabilities.
    end
end
-- Unknown/unavailable/no state is never Off and never NOT_EQUAL to a number.
for _,value in ipairs({'unknown','unavailable','', 'ON','closed','open','0'}) do
    local item=state('light.office',value,{supported_color_modes={'brightness'},brightness=128})
    eq(evaluate('IS_ON',nil,item),false); eq(evaluate('IS_OFF',nil,item),false)
    eq(compare(item,'NOT_EQUAL',0),false)
end
for _,invalid in ipairs({false,'off',123,{},{entity_id='light.office'},{entity_id='invalid',state='off'},
    {entity_id='event.office',state='off'},{entity_id='sensor.office',state='off'},
    {entity_id='light.office',domain='switch',state='off'}}) do
    eq(evaluate('IS_ON',nil,invalid),false); eq(evaluate('IS_OFF',nil,invalid),false)
    eq(compare(invalid,'NOT_EQUAL',50),false)
end
eq(Conditions.evaluate('IS_OFF',nil,nil,nil),false)
local attributes={supported_color_modes={'brightness'},supported_features=32,brightness=128}
local on=state('light.office','on',attributes)
local facts=Family.classify(on)
local expectations={EQUAL={50,true},NOT_EQUAL={50,false},LESS_THAN={51,true},LESS_THAN_OR_EQUAL={50,true},
    GREATER_THAN={49,true},GREATER_THAN_OR_EQUAL={50,true}}
for operator,pair in pairs(expectations) do eq(compare(on,operator,pair[1]),pair[2]) end
-- Exercise both outcomes for every comparator.
eq(compare(on,'EQUAL',49),false); eq(compare(on,'NOT_EQUAL',49),true)
eq(compare(on,'LESS_THAN',50),false); eq(compare(on,'LESS_THAN_OR_EQUAL',49),false)
eq(compare(on,'GREATER_THAN',50),false); eq(compare(on,'GREATER_THAN_OR_EQUAL',51),false)
for _,value in ipairs({'50',' 50 ','50.0','+50',50}) do eq(compare(on,'EQUAL',value),true) end
for _,value in ipairs({false,{},'','fifty','1e2','0x32','NaN','inf',-1,101,0/0,math.huge,-math.huge,50.5,'50.5'}) do
    eq(compare(on,'NOT_EQUAL',value),false)
end
eq(compare(on,'NOT_EQUAL',nil),false)
for _,operator in ipairs({'unknown','equal','!=','',false,{}}) do eq(compare(on,operator,0),false) end
for _,params in ipairs({false,'50',{}, {LOGIC='EQUAL'},{VALUE=50}}) do eq(evaluate('LIGHT_LEVEL',params,on),false) end
for _,name in ipairs({'UNKNOWN','is_on','',false,{}}) do eq(evaluate(name,nil,on),false) end
-- The same on/off state from another identity or capability snapshot is refused.
for _,bad in ipairs({false,'facts',{},Family.classify(state('light.another','on',attributes)),
    Family.classify(state('switch.office','on')),Family.classify(state('sensor.office','on'))}) do
    eq(Conditions.evaluate('IS_ON',nil,on,bad),false)
    eq(Conditions.evaluate('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE=0},on,bad),false)
end
local function invalid_fact(field,value)
    local model=Family.classify(on); model[field]=value
    eq(Conditions.evaluate('IS_ON',nil,on,model),false)
    eq(Conditions.evaluate('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE=0},on,model),false)
end
invalid_fact('domain','switch'); invalid_fact('valid_entity',false); invalid_fact('supported',false)
invalid_fact('availability','unknown'); invalid_fact('availability','unavailable'); invalid_fact('capabilities',false)
local override=state('light.office','on',attributes); override.availability='unknown'
eq(Conditions.evaluate('IS_ON',nil,override,facts),false)
eq(Conditions.evaluate('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE=0},override,facts),false)
local off=state('light.office','off',{supported_color_modes={'brightness'},brightness=255})
eq(evaluate('IS_OFF',nil,off),true); eq(compare(off,'EQUAL',0),true); eq(compare(off,'NOT_EQUAL',100),true)
-- Off takes precedence even when restored brightness is absent or malformed.
for _,brightness in ipairs({255,'255',false,{},math.huge,0/0,-1}) do
    off.attributes.brightness=brightness; eq(compare(off,'EQUAL',0),true)
end
off.attributes.brightness=nil; eq(compare(off,'EQUAL',0),true)
-- On must have actual finite numeric raw brightness. There is no on=100 guess.
for _,brightness in ipairs({'255',false,{},math.huge,-math.huge,0/0,-1,256}) do
    local item=state('light.office','on',{supported_color_modes={'brightness'},brightness=brightness})
    eq(compare(item,'NOT_EQUAL',0),false)
end
local missing=state('light.office','on',{supported_color_modes={'brightness'}})
eq(compare(missing,'NOT_EQUAL',0),false)
eq(Conditions.evaluate('LIGHT_LEVEL',{LOGIC='NOT_EQUAL',VALUE=0},state('light.office','on',false),facts),false)
-- Percentages use the full HA byte scale and nearest-integer display precision.
for _,case in ipairs({{0,0},{1,0},{2,1},{64,25},{127,50},{128,50},{191,75},{254,100},{255,100},{127.5,50}}) do
    local item=state('light.office','on',{supported_color_modes={'brightness'},brightness=case[1]})
    eq(compare(item,'EQUAL',case[2]),true)
end
-- Evaluation does not mutate state, parameters, or the supplied facts.
local params={LOGIC='EQUAL',VALUE='50'}
eq(Conditions.evaluate('LIGHT_LEVEL',params,on,facts),true)
eq(attributes.brightness,128); eq(params.VALUE,'50'); eq(facts.entity_id,'light.office')
eq(facts.capabilities.set_level,true); eq(on.state,'on')
print('Load conditions: '..count..' assertions passed')
