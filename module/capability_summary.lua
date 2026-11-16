-- Read-only presentation of current validated facts, shared by both proxies.
local M={}
local ROLES={top='Top',bottom='Bottom',toggle='Toggle'}
local ORDER={top=1,bottom=2,toggle=3}
local function clean(value) return tostring(value or ''):gsub('%s+',' ') end

function M.load(mode,facts,options)
    if mode=='C4 Button Controller' then return 'Connected C4 light controls its own load' end
    if mode=='Gestures Only' then return 'No load control' end
    if not facts or not facts.supported then return 'Waiting for current HA load capabilities' end
    if facts.availability=='unavailable' then return 'HA load unavailable' end
    if facts.availability=='unknown' then return 'HA load state unknown' end
    local caps,names=facts.capabilities or {},{}
    for _,item in ipairs({{'on_off','On/Off'},{'toggle','Toggle'}}) do
        if caps[item[1]] then names[#names+1]=item[2] end
    end
    if not (options and options.switch_only) then
        if caps.set_level then names[#names+1]='Level' end
        if caps.ramp_to_level then names[#names+1]='Timed ramp' end
    end
    return #names>0 and table.concat(names,'; ') or 'No load control exposed'
end

local function taps(counts)
    if #counts==1 and counts[1]==1 then return 'single tap' end
    local ranges,index={},1
    while index<=#counts do
        local first,last=counts[index],counts[index]
        while counts[index+1]==last+1 do index=index+1; last=counts[index] end
        local a,b=string.format('%.0f',first),string.format('%.0f',last)
        ranges[#ranges+1]=first==last and a or a..'–'..b
        index=index+1
    end
    return table.concat(ranges,', ')..' taps'
end
local function profile(button)
    local counts,seen,custom={}, {},{}
    local hold,repeat_hold,release,pushed=false,false,false,false
    for _,gesture in ipairs(button.gestures) do
        if gesture.kind=='press' and not seen[gesture.press_count] then
            seen[gesture.press_count]=true; counts[#counts+1]=gesture.press_count
        elseif gesture.kind=='hold_start' then hold=true
        elseif gesture.kind=='hold_repeat' then repeat_hold=true
        elseif gesture.kind=='release' then release=true
        elseif gesture.kind=='custom' then
            if gesture.id=='button_pushed' and gesture.label=='Button Pushed' then pushed=true
            else custom[#custom+1]=clean(gesture.label) end
        end
    end
    table.sort(counts); table.sort(custom)
    local parts={}
    if #counts>0 then parts[#parts+1]=taps(counts) end
    if pushed then parts[#parts+1]='press' end
    if hold and repeat_hold then parts[#parts+1]='hold/repeat'
    elseif hold then parts[#parts+1]='hold'
    elseif repeat_hold then parts[#parts+1]='hold repeat' end
    if release then parts[#parts+1]='release' end
    if #custom>0 then parts[#parts+1]='custom ('..table.concat(custom,' / ')..')' end
    return table.concat(parts,', ')
end
local function available(button,sources)
    local matched=false
    for _,source in ipairs(sources) do
        if source.button_id==nil or source.button_id==button.id then
            matched=true
            if not source.ready or source.availability=='unavailable' then return false end
        end
    end
    return matched
end
function M.buttons(metadata,mode)
    if mode=='Direct' then return 'Button events need HA Gesture Bridge' end
    local attrs=metadata and metadata.attributes
    if not attrs then return 'Waiting for current button capabilities' end
    local buttons={}
    for _,button in ipairs(attrs.bridge_buttons) do buttons[#buttons+1]=button end
    table.sort(buttons,function(a,b)
        local x,y=ORDER[a.id] or 4,ORDER[b.id] or 4
        return x<y or x==y and a.id<b.id
    end)
    local groups,by_profile={},{}
    for _,button in ipairs(buttons) do
        local text=profile(button)
        if not available(button,attrs.bridge_sources) then text=text..' (unavailable)' end
        local group=by_profile[text]
        if not group then group={names={},text=text}; by_profile[text]=group; groups[#groups+1]=group end
        group.names[#group.names+1]=ROLES[button.id] or clean(button.label)
    end
    local result={}
    for _,group in ipairs(groups) do result[#result+1]=table.concat(group.names,' & ')..': '..group.text end
    return #result>0 and table.concat(result,'; ') or 'Button events not exposed/configured'
end
return M
