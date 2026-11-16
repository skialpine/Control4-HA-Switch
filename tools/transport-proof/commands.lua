-- Isolated transport proof: count gestures; never send a load command.
local Gestures = require("module.gestures")
local Consumer
local LateInit = false
local GestureCount = 0
local SnapshotCount = 0

local function decoder()
    if not Consumer then
        Consumer = Gestures.new({
            entity_id = Properties["Entity ID"],
            c4 = C4,
            on_status = function(reason)
                if LateInit then C4:UpdateProperty("Status", tostring(reason)) end
            end,
        })
        if LateInit then Consumer:start() end
    elseif Consumer.entity_id ~= Properties["Entity ID"] then
        Consumer:set_entity_id(Properties["Entity ID"])
    end
    return Consumer
end

local function receive(command, params)
    local consumer = decoder()
    local previous = consumer.last_state
    local fired, reason, key = consumer:consume_proxy(command, params)
    if LateInit and consumer.last_state and consumer.last_state ~= previous then
        local attrs = consumer.last_state.attributes
        C4:UpdateProperty("Last Update Kind", tostring(attrs.bridge_update_kind))
        C4:UpdateProperty("Last Sequence", tostring(attrs.gesture_sequence or 0))
        if command == "RECEIEVE_STATE" or attrs.bridge_update_kind == "snapshot" then
            SnapshotCount = SnapshotCount + 1
            C4:SetVariable("SNAPSHOT_COUNT", tostring(SnapshotCount))
            C4:UpdateProperty("Snapshot Count", tostring(SnapshotCount))
        end
    end
    if fired then
        GestureCount = GestureCount + 1
        C4:SetVariable("GESTURE_COUNT", tostring(GestureCount))
        C4:SetVariable("LAST_GESTURE", key)
        C4:UpdateProperty("Gesture Count", tostring(GestureCount))
        C4:UpdateProperty("Last Gesture", key)
    end
    return fired, reason, key
end

function DRV.OnDriverInit()
    C4:AddVariable("GESTURE_COUNT", "0", "NUMBER")
    C4:AddVariable("SNAPSHOT_COUNT", "0", "NUMBER")
    C4:AddVariable("LAST_GESTURE", "", "STRING")
end

function DRV.OnDriverLateInit()
    LateInit = true
    decoder():start()
    EC.REFRESH()
end

function DRV.OnBindingChanged(idBinding, strClass, bIsBound)
    if idBinding == 999 and bIsBound then EC.REFRESH() end
end

function RFP.RECEIEVE_STATE(idBinding, strCommand, params)
    return receive("RECEIEVE_STATE", params)
end

function RFP.RECEIEVE_EVENT(idBinding, strCommand, params)
    return receive("RECEIEVE_EVENT", params)
end

function EC.Refresh()
    decoder()
    EC.REFRESH()
end

function EC.Reset_Count()
    GestureCount = 0
    SnapshotCount = 0
    C4:SetVariable("GESTURE_COUNT", "0")
    C4:SetVariable("SNAPSHOT_COUNT", "0")
    C4:SetVariable("LAST_GESTURE", "")
    C4:UpdateProperty("Gesture Count", "0")
    C4:UpdateProperty("Snapshot Count", "0")
    C4:UpdateProperty("Last Gesture", "")
end
