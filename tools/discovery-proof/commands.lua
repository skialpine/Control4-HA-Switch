-- Read-only Composer proof for the generic family discovery API.
local Discovery = require("module.discovery")
local Capabilities = require("module.family_capabilities")
local Client, Picker, Timer
local LateInit = false

local function csv(value)
    local result = {}
    for item in tostring(value or ""):gmatch("[^,]+") do
        local trimmed = item:match("^%s*(.-)%s*$")
        if trimmed ~= "" then result[#result + 1] = trimmed end
    end
    if #result > 0 then return result end
end

local function render(rows)
    Picker = Discovery.build_picker(rows or {}, {
        selected_entity_id = Properties["Selected Entity ID"],
    })
    C4:UpdatePropertyList("Entity Selection", Picker.value_list, Picker.selected_label)
    C4:UpdateProperty("Entity Count", tostring(#(rows or {})))
    local summary = "Selected entity is not in the completed discovery list"
    for _, row in ipairs(rows or {}) do
        if row.entity_id == Properties["Selected Entity ID"] then
            local facts = Capabilities.classify(row)
            local names = {}
            for _, action in ipairs({
                {"on_off", "On/Off"}, {"toggle", "Toggle"}, {"set_level", "Set Level"},
                {"ramp_to_level", "Ramp to Level"}, {"hold_dim", "Hold Dimming"},
                {"stop_dim", "Stop Dimming"}, {"led_colors", "LED Colors"},
            }) do
                if facts.capabilities[action[1]] then names[#names + 1] = action[2] end
            end
            summary = facts.kind .. " (" .. facts.availability .. "): " .. table.concat(names, ", ")
            break
        end
    end
    C4:UpdateProperty("Selected Capabilities", summary)
end

local function client()
    if not Client then
        Client = Discovery.new({
            client_id = "discovery-proof-" .. tostring(C4:GetDeviceID()),
            now = os.time,
            timeout = 20,
            send = function(binding, command, params)
                C4:SendToProxy(binding, command, params)
            end,
            on_status = function(reason)
                if LateInit then C4:UpdateProperty("Discovery Status", tostring(reason)) end
            end,
            on_complete = function(rows) if LateInit then render(rows) end end,
        })
    end
    return Client
end

function EC.Refresh_Entities()
    if not LateInit then return end
    return client():refresh({
        domains = csv(Properties["Domains"]),
        attribute_keys = csv(Properties["Attribute Keys"]),
        page_size = 50,
    })
end

function DRV.OnDriverLateInit()
    LateInit = true
    render({})
    client()
    Timer = C4:SetTimer(1000, function() Client:tick() end, true)
    EC.Refresh_Entities()
end

function DRV.OnBindingChanged(binding, class, bound)
    if binding ~= 999 then return end
    client():invalidate()
    if bound then EC.Refresh_Entities() end
end

function DRV.OnDriverDestroyed()
    LateInit = false
    if Timer then Timer:Cancel(); Timer = nil end
    if Client then Client:invalidate() end
end

function OPC.Domains() EC.Refresh_Entities() end
function OPC.Attribute_Keys() EC.Refresh_Entities() end
function OPC.Selected_Entity_ID()
    if LateInit then render(client().choices) end
end

function OPC.Entity_Selection(value)
    if not Picker then return end
    local entity = Picker.label_to_entity[value]
    if type(entity) == "string" and entity ~= "" then
        C4:UpdateProperty("Selected Entity ID", entity)
        Properties["Selected Entity ID"] = entity
        render(client().choices)
    end
end

function RFP.HA_ENTITIES(binding, command, params)
    if binding ~= 999 then return false, "wrong_binding" end
    return client():consume_proxy(command, params)
end
