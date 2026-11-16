-- Translate installer labels to the shared internal behavior identifiers.
local M={}
local definitions={
    {'Direct','Control HA Device','Control the selected HA device; no gesture integration needed.'},
    {'Gesture Bridge','Control HA Device with Button Events','Receive button events and control the HA load linked in HA Gesture Bridge.'},
    {'Gestures Only','Programming Events Only','Use button events in Composer programming without controlling a load.'},
    {'C4 Button Controller','Control Connected C4 Light','Use paddles and app controls to operate the connected C4 light.'},
}
local by_id,by_label={},{}
for _,definition in ipairs(definitions) do
    by_id[definition[1]]=definition
    by_label[definition[2]]=definition
end
function M.identity(value)
    if value==nil or value=='' then return 'Direct' end
    return by_label[value] and by_label[value][1] or value
end
function M.label(value)
    local definition=by_id[value]
    return definition and definition[2] or value
end
function M.description(value,driver)
    if driver=='switch' and M.identity(value)=='C4 Button Controller' then
        return 'Unsupported Switch mode. Use HA Light to control a connected C4 light.'
    end
    local definition=by_id[M.identity(value)]
    return definition and definition[3] or 'Select a supported operation mode.'
end
function M.status(value)
    for _,definition in ipairs(definitions) do
        local prefix=definition[1]..':'
        if value:sub(1,#prefix)==prefix then return definition[2]..value:sub(#prefix) end
    end
    return value
end
function M.update_description(properties,update,driver)
    local value=properties['Operation Mode']
    local description=M.description(value,driver)
    if properties['Mode Description']~=description then
        properties['Mode Description']=description
        update('Mode Description',description)
    end
end
return M
