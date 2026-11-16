-- Exercise the real base lifecycle and the read-only proof's Composer callbacks.
local Codec = require("module.json")
local JSON = Codec:new({strictTypes = true, null = {}})
Properties = {
    Domains = "switch,input_boolean", ["Attribute Keys"] = "device_class,options",
    ["Entity Selection"] = "Manual Entity ID", ["Selected Entity ID"] = "switch.manual",
    ["Discovery Status"] = "Waiting", ["Entity Count"] = "0",
    ["Driver Version"] = "", ["Debug Mode"] = "Off",
}
local requests, lists, timers, writes = {}, {}, {}, {}
C4 = {}
function C4:GetDeviceID() return 42 end
function C4:GetDriverConfigInfo() return "1" end
function C4:AddVariable() end
function C4:SetVariable() end
function C4:UpdateProperty(name, value)
    Properties[name] = value
    writes[#writes+1] = {name, value}
end
function C4:UpdatePropertyList(name, values, selected)
    lists[name] = {values=values,selected=selected}
    Properties[name] = selected
end
function C4:SendToProxy(binding, command, params)
    assert(binding == 999 and command == "HA_GET_ENTITIES", "Proof must send only discovery requests")
    requests[#requests+1] = JSON:decode(params.JSON)
end
function C4:SetTimer(ms, callback, repeating)
    local timer = {callback=callback,cancelled=false}
    function timer:Cancel() self.cancelled=true end
    timers[#timers+1] = timer
    return timer
end
package.preload.commands = function() return dofile("tools/discovery-proof/commands.lua") end
dofile("Control4-HA-Base/driver.lua")
OnDriverInit()
assert(#requests==0, "No discovery before late init")
OnDriverLateInit()
assert(#requests==1)
local first = requests[1]
assert(first.domains[1]=="switch" and first.domains[2]=="input_boolean")

local function row(id, name)
    return {entity_id=id,domain=id:match("^([^.]+)"),name=name,state="on",
        availability="available",attributes=JSON:newObject()}
end
local function respond(request, entries, complete, cursor, total, snapshot)
    local payload = {version=1,client_id=request.client_id,request_id=request.request_id,
        snapshot_id=snapshot or "proof-snapshot",entities=JSON:newArray(entries),
        complete=complete,total=total or #entries,next_cursor=cursor}
    return ReceivedFromProxy(999,"HA_ENTITIES",{JSON=JSON:encode(payload)})
end

-- Other consumers' replies and other bindings cannot change the list.
local before = lists["Entity Selection"].values
respond({client_id="another",request_id=first.request_id}, {row("switch.other","Other")}, true)
assert(lists["Entity Selection"].values==before)
RFP.HA_ENTITIES(1,"HA_ENTITIES",{JSON="{}"})
assert(lists["Entity Selection"].values==before)

respond(first,{row("switch.a","Office, East"),row("switch.b","Office, East")},false,"next",3)
assert(#requests==2 and requests[2].cursor=="next")
assert(requests[2].request_id==first.request_id)
assert(Properties["Entity Count"]=="0", "Partial lists must not replace completed choices")
respond(first,{row("input_boolean.office","Office\nBoolean")},true,nil,3)
assert(Properties["Entity Count"]=="3")
assert(Properties["Selected Entity ID"]=="switch.manual", "Refresh must preserve manual selection")
local choices = lists["Entity Selection"].values
assert(not choices:find("Office, East",1,true) and not choices:find("\n",1,true))
local label
for entry in choices:gmatch("[^,]+") do
    if entry:find("[switch.b]",1,true) then label=entry end
end
assert(label, "Friendly-name choices include exact IDs")
Properties["Entity Selection"] = label
OnPropertyChanged("Entity Selection")
assert(Properties["Selected Entity ID"]=="switch.b")
assert(Properties["Selected Capabilities"]:find("On/Off",1,true))
Properties["Entity Selection"] = "Manual Entity ID"
OnPropertyChanged("Entity Selection")
assert(Properties["Selected Entity ID"]=="switch.b", "Manual choice must not erase target")

EC.Refresh_Entities()
local old = requests[#requests]
OnBindingChanged(999,"HA_DEVICE",false)
respond(old,{row("switch.stale","Stale")},true)
assert(Properties["Entity Count"]=="3", "Rebinding invalidates pending response")
OnBindingChanged(999,"HA_DEVICE",true)
assert(#requests>=4)
Properties.Domains="climate,select,button"
OnPropertyChanged("Domains")
local latest=requests[#requests]
assert(#latest.domains==3 and latest.domains[2]=="select")
assert(Properties["Selected Entity ID"]=="switch.b")
Properties.Domains="light"
OnPropertyChanged("Domains")
local lamp=row("light.office","Office Light")
lamp.attributes=JSON:newObject({supported_color_modes=JSON:newArray({"brightness"}),supported_features=32})
respond(requests[#requests],{lamp},true,nil,1,"light-snapshot")
for entry in lists["Entity Selection"].values:gmatch("[^,]+") do
    if entry:find("[light.office]",1,true) then Properties["Entity Selection"]=entry end
end
OnPropertyChanged("Entity Selection")
assert(Properties["Selected Entity ID"]=="light.office")
assert(Properties["Selected Capabilities"]:find("Set Level",1,true))
assert(Properties["Selected Capabilities"]:find("Ramp to Level",1,true))
assert(not Properties["Selected Capabilities"]:find("LED",1,true))
EC.Refresh_Entities()
lamp.attributes=JSON:newObject({supported_color_modes=JSON:newArray({"onoff"}),supported_features=0})
respond(requests[#requests],{lamp},true,nil,1,"light-snapshot-2")
assert(Properties["Selected Entity ID"]=="light.office")
assert(not Properties["Selected Capabilities"]:find("Set Level",1,true), "Removed capabilities must not stay enabled")
OnDriverDestroyed()
assert(timers[1].cancelled, "Proof must cancel its timer on destroy")
print("Discovery proof lifecycle passed: correlated pages, safe labels, preserved selection, read-only requests")
