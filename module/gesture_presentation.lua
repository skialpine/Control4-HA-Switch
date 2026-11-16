-- Presentation only. Call after gesture contract validation; never infers events.
-- Names/order are cosmetic. Event identity remains button_id/gesture_id.
local M = {}
local TAP_NAMES = {[1]='Single Tap',[2]='Double Tap',[3]='Triple Tap'}
local KIND_ORDER = {release=1,press=2,hold_start=3,hold_repeat=4,custom=5}
local function button_order(id) return id=='top' and 1 or id=='bottom' and 2 or 3 end

function M.describe(button,gesture)
    local suffix=gesture.label
    if gesture.kind=='press' then
        suffix=TAP_NAMES[gesture.press_count] or (string.format('%.0f',gesture.press_count)..' Taps')
    elseif gesture.kind=='release' then
        suffix='Button Released'
    end
    local name=button.label..' '..suffix
    return {key=button.id..'/'..gesture.id,button_id=button.id,gesture_id=gesture.id,
        kind=gesture.kind,press_count=gesture.press_count,name=name,description='When NAME '..name,
        -- Only rank an explicitly declared custom action. This cosmetic hint
        -- never creates a Push event or changes the gesture's kind/identity.
        edge_order=gesture.kind=='release' and 2 or
            (gesture.kind=='custom' and gesture.label=='Button Pushed' and 1 or nil)}
end

function M.build(buttons)
    local events={}
    for _,button in ipairs(buttons) do
        for _,gesture in ipairs(button.gestures) do events[#events+1]=M.describe(button,gesture) end
    end
    table.sort(events,function(a,b)
        -- Existing physical-edge actions precede tap options. Push entries
        -- appear only when the source explicitly declares Button Pushed.
        local ak,bk=a.edge_order and 1 or KIND_ORDER[a.kind] or 6,b.edge_order and 1 or KIND_ORDER[b.kind] or 6
        if ak~=bk then return ak<bk end
        local ab,bb=button_order(a.button_id),button_order(b.button_id)
        if ab~=bb then return ab<bb end
        if a.button_id~=b.button_id then return a.button_id<b.button_id end
        if a.edge_order and b.edge_order and a.edge_order~=b.edge_order then return a.edge_order<b.edge_order end
        if a.kind=='press' and a.press_count~=b.press_count then return a.press_count<b.press_count end
        return a.gesture_id<b.gesture_id
    end)
    for index,event in ipairs(events) do event.order=index end
    return events
end
return M
