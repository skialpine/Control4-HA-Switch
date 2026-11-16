local Family=require('module.family_capabilities')
local Discovery=require('module.discovery')
local codec=Discovery.new_codec()
local count=0
local function check(value,message) count=count+1; assert(value,message or ('assertion '..count)) end
local function eq(actual,expected,message) check(actual==expected,(message or '')..' expected '..tostring(expected)..', got '..tostring(actual)) end
local function state(id,attributes,value)
    return {entity_id=id,attributes=attributes,state=value or 'off'}
end
local function backend(id)
    return {provider='deviceside',entity_id=id,verified=true,target_supported=true,
        capabilities={start_raise=true,start_lower=true,stop=true}}
end
local function dimmer(modes,features)
    return Family.classify(state('light.office',{supported_color_modes=modes,supported_features=features}))
end

-- Domain facts are sufficient for existing manual switch/input_boolean installs.
for _,domain in ipairs({'switch','input_boolean'}) do
    local original=state(domain..'.office',nil)
    local result=Family.classify(original)
    eq(result.version,1); eq(result.domain,domain); eq(result.kind,'switch')
    check(result.valid_entity and result.supported and result.capabilities.on_off and result.capabilities.toggle)
    for _,key in ipairs({'set_level','ramp_to_level','hold_dim','stop_dim','led_colors'}) do eq(result.capabilities[key],false) end
    eq(original.attributes,nil); eq(original.entity_id,domain..'.office')
end

-- Domain-neutral helpers remain usable by future family-specific predicates.
check(Family.matches_domain(state('climate.hall'),{'climate'}))
check(Family.matches_domain(state('cover.garage'),'cover'))
eq(Family.matches_domain(state('sensor.temp'),{'switch','light'}),false)
local unsupported=Family.classify(state('climate.hall'))
check(unsupported.valid_entity and not unsupported.supported)
eq(unsupported.capabilities.on_off,false)
for _,item in ipairs({false,{}, {entity_id='invalid'},{entity_id='switch.office',domain='light'},
    {entity_id='switch.office\n'}, {entity_id='switch.office',domain=codec.null}}) do
    local model=Family.classify(item)
    eq(model.valid_entity,false); eq(model.supported,false); eq(model.capabilities.on_off,false)
end

-- Classify both native state responses and projected discovery items identically.
local attrs={supported_color_modes={'brightness'},supported_features=32}
local live=Family.classify(state('light.office',attrs))
local discovered=Family.classify({entity_id='light.office',domain='light',state='off',
    availability='available',attributes=attrs})
eq(codec:encode(live),codec:encode(discovered))
eq(live.kind,'dimmer'); check(live.capabilities.set_level and live.capabilities.ramp_to_level)
eq(live.capabilities.stop_dim,false); eq(live.capabilities.led_colors,false)

-- On/off-only lights are valid lights. Brightness values alone prove nothing.
for _,attributes in ipairs({{}, {brightness=128}, {supported_color_modes={'onoff'}},
    {supported_color_modes={'unknown'}}, {supported_color_modes={'future_mode'}}}) do
    local model=Family.classify(state('light.simple',attributes))
    check(model.supported and model.capabilities.on_off)
    eq(model.capabilities.set_level,false); eq(model.capabilities.ramp_to_level,false)
end

-- Native modes verified against HA 2026.11.1 COLOR_MODES_BRIGHTNESS.
for _,mode in ipairs({'brightness','color_temp','hs','xy','rgb','rgbw','rgbww'}) do
    local model=dimmer({mode},32)
    check(model.capabilities.set_level and model.capabilities.ramp_to_level)
    eq(model.capabilities.hold_dim,false); eq(model.capabilities.stop_dim,false); eq(model.capabilities.led_colors,false)
end
check(dimmer({'white','rgb'},32).capabilities.set_level)
eq(dimmer({'white'},32).capabilities.set_level,false) -- invalid HA mode combination
check(dimmer({'onoff','brightness'},32).capabilities.set_level) -- HA removes redundant onoff

-- Incomplete or malformed metadata never upgrades behavior from brightness state.
for _,modes in ipairs({false,'brightness',{}, {brightness=true}, {'brightness','brightness'},
    {'brightness',false}, {[2]='brightness'}, codec.null, codec:newObject({})}) do
    local model=dimmer(modes,32)
    eq(model.capabilities.set_level,false); eq(model.capabilities.ramp_to_level,false)
end
for _,attributes in ipairs({'bad',false,codec.null,codec:newArray({})}) do
    local model=Family.classify(state('light.bad',attributes))
    check(model.capabilities.on_off); eq(model.capabilities.set_level,false)
end
eq(dimmer(nil,32).metadata.color_modes,'missing')

-- Feature masks are exact unsigned integers. No coercion or bit library required.
for _,mask in ipairs({0,4,8,12,31}) do eq(dimmer({'brightness'},mask).capabilities.ramp_to_level,false) end
for _,mask in ipairs({32,36,40,44,4294967295}) do check(dimmer({'brightness'},mask).capabilities.ramp_to_level) end
for _,mask in ipairs({false,'32',-1,32.5,math.huge,0/0,4294967296,{},codec.null}) do
    eq(dimmer({'brightness'},mask).capabilities.ramp_to_level,false)
end
eq(Family.has_feature(36,32),true); eq(Family.has_feature(36,4),true)
eq(Family.has_feature(36,8),false); eq(Family.has_feature(36,3),false)
eq(Family.has_feature(36,0),false); eq(Family.has_feature(4294967295,2147483648),true)
eq(dimmer({'onoff'},32).capabilities.ramp_to_level,false)

-- Unavailability is separate from capabilities, avoiding retirement of support
-- during a temporary outage. Consumers decide whether a command is ready.
local offline=Family.classify(state('light.office',attrs,'unavailable'))
eq(offline.availability,'unavailable'); check(offline.capabilities.set_level)
eq(Family.classify(state('light.office',attrs,'unknown')).availability,'unknown')
eq(Family.classify({entity_id='switch.office'}).availability,'unknown')

-- DeviceSide facts require proof for this exact supported target, never merely
-- its name/integration being present. Start without stop cannot enable hold dim.
local facts=backend('light.office')
local enhanced=Family.classify(state('light.office',attrs),facts)
check(enhanced.capabilities.hold_dim and enhanced.capabilities.stop_dim)
eq(enhanced.evidence.hold_dim,'backend:deviceside')
eq(enhanced.capabilities.led_colors,false)
for _,field in ipairs({'verified','target_supported','entity_id','provider'}) do
    local invalid=backend('light.office'); invalid[field]=nil
    local model=Family.classify(state('light.office',attrs),invalid)
    eq(model.capabilities.hold_dim,false); eq(model.capabilities.stop_dim,false)
end
local wrong=backend('light.other')
eq(Family.classify(state('light.office',attrs),wrong).capabilities.hold_dim,false)
local partial=backend('light.office'); partial.capabilities.stop=false
eq(Family.classify(state('light.office',attrs),partial).capabilities.hold_dim,false)
partial=backend('light.office'); partial.capabilities.start_lower=false
eq(Family.classify(state('light.office',attrs),partial).capabilities.hold_dim,false)
eq(Family.classify(state('light.office',{supported_color_modes={'onoff'}}),facts).capabilities.hold_dim,false)
local no_transition=Family.classify(state('light.office',{supported_color_modes={'brightness'}}),facts)
check(no_transition.capabilities.hold_dim and no_transition.capabilities.stop_dim)
eq(no_transition.capabilities.ramp_to_level,false)
facts.capabilities.ramp_to_level=true
check(Family.classify(state('light.office',{supported_color_modes={'brightness'}}),facts).capabilities.ramp_to_level)

-- Load color modes do not prove a switch indicator LED mapping.
facts=backend('switch.office')
facts.led_mapping={verified=true,source='select.office_led_color',mapping_id='profile:v1'}
local led=Family.classify(state('switch.office'),facts)
check(led.capabilities.led_colors); eq(led.capabilities.set_level,false)
for _,key in ipairs({'verified','source','mapping_id'}) do
    local candidate=backend('switch.office')
    candidate.led_mapping={verified=true,source='select.office_led_color',mapping_id='profile:v1'}
    candidate.led_mapping[key]=nil
    eq(Family.classify(state('switch.office'),candidate).capabilities.led_colors,false)
end
eq(dimmer({'rgb'},32).capabilities.led_colors,false)

-- Pure classification neither changes backend facts nor retains mutable inputs.
facts=backend('light.office')
local first=Family.classify(state('light.office',attrs),facts)
facts.capabilities.stop=false; attrs.supported_color_modes[1]='onoff'
check(first.capabilities.hold_dim and first.capabilities.set_level)
local keys=Family.attribute_keys(); keys[1]='changed'
eq(Family.attribute_keys()[1],'supported_color_modes')

print('family_capabilities: '..count..' assertions passed')
