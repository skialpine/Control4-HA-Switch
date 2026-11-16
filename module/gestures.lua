-- Version 1 HA Gesture Bridge consumer. Lua 5.1/5.5, no radio-specific parsing.
-- Pass event_store from PersistData to retain programming IDs across reloads.
local JSON = require("module.json")
local Presentation = require("module.gesture_presentation")
local Time = require("module.rfc3339")
local NULL = {}
local function invalid_json() error("invalid_json", 0) end
local Decoder = JSON:new({strictTypes=true, null=NULL, onDecodeError=invalid_json,
    onDecodeOfHTMLError=invalid_json, onDecodeOfNilError=invalid_json})
local M = {}
local Consumer = {}
Consumer.__index = Consumer

local MAX_INTEGER = 9007199254740991
local FIRST_EVENT_ID, LAST_EVENT_ID = 1000, 65535
local KINDS = { press=true, hold_start=true, hold_repeat=true, release=true, custom=true }

local function integer(value)
    return type(value) == "number" and value >= 1 and value <= MAX_INTEGER and value == math.floor(value)
end

local function key(value)
    return type(value) == "string" and #value <= 64 and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function identity(value)
    return type(value) == "string" and #value >= 1 and #value <= 128 and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function label(value)
    if type(value) ~= "string" or not value:match("%S") then return false end
    -- The contract's label limit counts Unicode characters, not UTF-8 bytes.
    local _, characters = value:gsub("[^\128-\191]", "")
    return characters <= 128
end

local function array(value)
    if type(value) ~= "table" then return false end
    local count, maximum = 0, 0
    for index in pairs(value) do
        if not integer(index) then return false end
        count, maximum = count + 1, math.max(maximum, index)
    end
    return count >= 1 and count == maximum
end

local function only_fields(value, fields)
    for field in pairs(value) do
        if not fields[field] then return false end
    end
    return true
end

local function number_text(number)
    return string.format("%.0f", number)
end

local timestamp=Time.parse
local function older(a,b) return b~=nil and Time.compare(a,b)<0 end

-- The bundled decoder otherwise accepts trailing JSON and tolerates bad string
-- escapes. Check one complete object and string syntax before consuming it.
local function complete_json_object(text)
    local stack, in_string, i, started = {}, false, 1, false
    while i <= #text do
        local c = text:sub(i, i)
        if in_string then
            if c == '"' then in_string = false
            elseif c == "\\" then
                local escape = text:sub(i + 1, i + 1)
                if escape == "u" then
                    if not text:sub(i + 2, i + 5):match("^%x%x%x%x$") then return false end
                    i = i + 5
                elseif escape ~= "" and escape:match('^["\\/bfnrt]$') then i = i + 1
                else return false end
            elseif c:byte() < 32 then return false end
        elseif c == '"' then
            if #stack == 0 then return false end
            in_string = true
        elseif c == "{" or c == "[" then
            if #stack == 0 then
                if started or c ~= "{" then return false end
                started = true
            end
            stack[#stack + 1] = c
        elseif c == "}" or c == "]" then
            local opener = stack[#stack]
            if (c == "}" and opener ~= "{") or (c == "]" and opener ~= "[") then return false end
            stack[#stack] = nil
        elseif #stack == 0 and not c:match("^[ \n\r\t]$") then return false end
        i = i + 1
    end
    return started and #stack == 0 and not in_string
end

local function capabilities(attrs)
    if not array(attrs.bridge_buttons) then return nil, "invalid_buttons" end
    local definitions, lookup, buttons = {}, {}, {}
    for _, button in ipairs(attrs.bridge_buttons) do
        if type(button) ~= "table" or not key(button.id) or not label(button.label) or
            buttons[button.id] or not array(button.gestures) or
            not only_fields(button, {id=true, label=true, gestures=true}) then
            return nil, "invalid_button"
        end
        buttons[button.id] = true
        for _, gesture in ipairs(button.gestures) do
            if type(gesture) ~= "table" or not key(gesture.id) or not KINDS[gesture.kind] or
                not label(gesture.label) or not only_fields(gesture, {id=true, kind=true, label=true, press_count=true}) then
                return nil, "invalid_capability"
            end
            if gesture.kind == "press" then
                if not integer(gesture.press_count) or gesture.id ~= "press_" .. number_text(gesture.press_count) then
                    return nil, "invalid_press_capability"
                end
            elseif gesture.press_count ~= nil or gesture.id:match("^press_") then
                return nil, "invalid_nonpress_capability"
            end
            local event_key = button.id .. "/" .. gesture.id
            if lookup[event_key] then return nil, "duplicate_capability" end
            local definition = Presentation.describe(button, gesture)
            lookup[event_key] = definition
            definitions[#definitions + 1] = definition
        end
    end
    for _, presented in ipairs(Presentation.build(attrs.bridge_buttons)) do
        lookup[presented.key].display_order = presented.order
    end
    return {definitions=definitions, lookup=lookup}
end

local function validate(state)
    if type(state) ~= "table" or type(state.state) ~= "string" or type(state.attributes) ~= "table" then
        return nil, "invalid_state"
    end
    local revision = timestamp(state.last_updated)
    if not revision then return nil, "invalid_revision" end
    local a = state.attributes
    if type(a.bridge_contract_version) ~= "string" or not a.bridge_contract_version:match("^1%.%d+$") then
        return nil, "unsupported_contract"
    end
    if not identity(a.bridge_control_id) or not identity(a.bridge_session_id) or
        (a.bridge_update_kind ~= "snapshot" and a.bridge_update_kind ~= "gesture") then
        return nil, "invalid_metadata"
    end
    local caps, error = capabilities(a)
    if not caps then return nil, error end
    if not array(a.bridge_sources) then return nil, "invalid_sources" end
    local sources = {}
    for _, source in ipairs(a.bridge_sources) do
        if type(source) ~= "table" or not identity(source.id) or sources[source.id] or
            type(source.ready) ~= "boolean" or
            (source.availability ~= "available" and source.availability ~= "unavailable" and source.availability ~= "unknown") then
            return nil, "invalid_source"
        end
        sources[source.id] = true
    end
    -- The existing JSON parser represents a JSON null load as Lua nil.
    if a.bridge_load ~= nil then
        local load = a.bridge_load
        if type(load) ~= "table" or type(load.entity_id) ~= "string" or
            (load.domain ~= "switch" and load.domain ~= "input_boolean" and load.domain ~= "light") or
            not load.entity_id:match("^" .. load.domain .. "%.[a-z0-9_]+$") or
            type(load.available) ~= "boolean" or
            (load.state ~= "on" and load.state ~= "off" and load.state ~= "unknown" and load.state ~= "unavailable") or
            (load.available and load.state ~= "on" and load.state ~= "off") then
            return nil, "invalid_load"
        end
        if load.domain == "light" then
            local minor = tonumber(a.bridge_contract_version:match("^1%.(%d+)$"))
            local attrs = load.attributes
            if not minor or minor < 1 or type(attrs) ~= "table" or attrs == NULL or
                tostring(attrs) == "JSON array" or not only_fields(attrs,
                    {supported_color_modes=true, supported_features=true, brightness=true}) then
                return nil, "invalid_light_attributes"
            end
            local modes = attrs.supported_color_modes
            if modes ~= nil then
                if type(modes) ~= "table" or modes == NULL or tostring(modes) == "JSON object" then
                    return nil, "invalid_light_modes"
                end
                local count, maximum, seen = 0, 0, {}
                local known = {onoff=true, brightness=true, color_temp=true, hs=true, xy=true,
                    rgb=true, rgbw=true, rgbww=true, white=true}
                for index, value in pairs(modes) do
                    if not integer(index) or index > 16 or type(value) ~= "string" or
                        not known[value] or seen[value] then return nil, "invalid_light_modes" end
                    count, maximum, seen[value] = count + 1, math.max(maximum, index), true
                end
                if count ~= maximum then return nil, "invalid_light_modes" end
            end
            local features, brightness = attrs.supported_features, attrs.brightness
            if features ~= nil and (type(features) ~= "number" or features < 0 or features > 4294967295 or
                features ~= math.floor(features)) then return nil, "invalid_light_features" end
            if brightness ~= nil and (type(brightness) ~= "number" or brightness ~= brightness or
                brightness < 0 or brightness > 255) then return nil, "invalid_light_brightness" end
        end
    end
    if a.gesture_event_id == nil then
        for _, field in ipairs({"event_type", "button_id", "gesture_id", "press_count", "gesture_session_id", "gesture_sequence", "gesture_occurred_at"}) do
            if a[field] ~= nil then return nil, "incomplete_gesture" end
        end
        if a.bridge_update_kind ~= "snapshot" or (state.state ~= "unknown" and state.state ~= "unavailable") then
            return nil, "missing_gesture"
        end
    else
        if not KINDS[a.event_type] or not key(a.button_id) or not key(a.gesture_id) or
            not identity(a.gesture_session_id) or not integer(a.gesture_sequence) or
            type(a.gesture_event_id) ~= "string" or
            a.gesture_event_id ~= a.gesture_session_id .. ":" .. number_text(a.gesture_sequence) or
            not timestamp(a.gesture_occurred_at) then return nil, "invalid_gesture" end
        if a.event_type == "press" then
            if not integer(a.press_count) or a.gesture_id ~= "press_" .. number_text(a.press_count) then
                return nil, "invalid_press"
            end
        elseif a.press_count ~= nil then return nil, "invalid_nonpress" end
        if state.state == "unknown" or state.state == "unavailable" then
            if a.bridge_update_kind == "gesture" then return nil, "unavailable_gesture" end
        elseif not timestamp(state.state) then return nil, "invalid_event_timestamp" end
        if a.bridge_update_kind == "gesture" then
            if a.gesture_session_id ~= a.bridge_session_id then return nil, "restored_gesture" end
            local definition = caps.lookup[a.button_id .. "/" .. a.gesture_id]
            if not definition or definition.kind ~= a.event_type or definition.press_count ~= a.press_count then
                return nil, "undeclared_gesture"
            end
        end
    end
    return {attributes=a, capabilities=caps, revision=revision}
end

local function allocation_store(store)
    if store == nil then return {}, FIRST_EVENT_ID end
    if type(store) ~= "table" then return nil end
    if next(store) == nil then
        store.version, store.allocations, store.next_event_id = 1, {}, FIRST_EVENT_ID
    end
    if store.version ~= 1 or type(store.allocations) ~= "table" or
        not integer(store.next_event_id) or store.next_event_id < FIRST_EVENT_ID or
        store.next_event_id > LAST_EVENT_ID + 1 then return nil end
    local seen = {}
    for name, event_id in pairs(store.allocations) do
        if type(name) ~= "string" then return nil end
        local control, button, gesture = name:match("^([^/]+)/([^/]+)/([^/]+)$")
        if not identity(control) or not key(button) or not key(gesture) or
            not integer(event_id) or event_id < FIRST_EVENT_ID or event_id > LAST_EVENT_ID or
            event_id >= store.next_event_id or seen[event_id] then return nil end
        seen[event_id] = true
    end
    return store.allocations, store.next_event_id
end

local function require_event_method(c4, name)
    -- Director exposes C4 as a native userdata on some runtimes. Validate its
    -- documented methods, not its Lua representation; never replace the API.
    local ok, method = pcall(function() return c4[name] end)
    if not ok or type(method) ~= "function" then
        error("C4:" .. name .. " API is required", 0)
    end
end

function M.new(options)
    assert(type(options) == "table" and type(options.entity_id) == "string", "entity_id is required")
    local c4 = options.c4 or _G.C4
    require_event_method(c4, "AddEvent")
    require_event_method(c4, "FireEventByID")
    local allocations, next_id = allocation_store(options.event_store)
    return setmetatable({entity_id=options.entity_id, c4=c4, on_status=options.on_status,
        event_store=options.event_store, invalid_store=allocations == nil,
        started=false, ready=false, allocations=allocations or {}, registered={}, next_event_id=next_id or FIRST_EVENT_ID,
        last_sequence=0, retired_sessions={}}, Consumer)
end

function Consumer:_status(reason)
    self.status = reason
    if self.on_status then self.on_status(reason) end
end

function Consumer:_reject(reason)
    self.ready = false
    self.last_state = nil
    self.last_metadata = nil
    self:_status(reason)
    return false, reason
end

function Consumer:set_entity_id(entity_id)
    assert(type(entity_id) == "string", "entity_id must be a string")
    if entity_id == self.entity_id then return end
    self.entity_id, self.ready, self.last_state, self.last_metadata = entity_id, false, nil, nil
    self.last_revision, self.current_session, self.current_control = nil, nil, nil
    self.last_sequence, self.retired_sessions = 0, {}
    self:_status("entity_changed")
end

function Consumer:_register(metadata)
    if not self.started then return false, "not_started" end
    if self.invalid_store then return false, "invalid_event_store" end
    local control = metadata.attributes.bridge_control_id
    -- Allocate in contract declaration order, independently of cosmetic order.
    for _, definition in ipairs(metadata.capabilities.definitions) do
        local order = definition.display_order
        local allocation_key = control .. "/" .. definition.key
        local event_id = self.allocations[allocation_key]
        if not event_id then
            if self.event_store then self.next_event_id = self.event_store.next_event_id end
            if self.next_event_id > LAST_EVENT_ID then return false, "event_id_exhausted" end
            event_id, self.next_event_id = self.next_event_id, self.next_event_id + 1
            self.allocations[allocation_key] = event_id
            if self.event_store then self.event_store.next_event_id = self.next_event_id end
        end
        local signature = definition.name .. "\n" .. definition.description .. "\n" .. order
            .. "\n" .. definition.kind .. "\n" .. tostring(definition.press_count)
        if self.registered[event_id] ~= signature then
            local ok, added = pcall(self.c4.AddEvent, self.c4, event_id, definition.name, definition.description, order)
            if not ok or added ~= true then return false, "registration_failed" end
            self.registered[event_id] = signature
        end
    end
    return true
end

function Consumer:start()
    self.started = true
    if self.last_metadata then
        local ok, reason = self:_register(self.last_metadata)
        self.ready = ok
        if not ok then self:_status(reason) end
        return ok, reason
    end
    self:_status("waiting_for_state")
    return true
end

function Consumer:consume(state, delivery)
    if delivery ~= "state" and delivery ~= "event" then return self:_reject("invalid_delivery") end
    if type(state) ~= "table" then return self:_reject("invalid_state") end
    if state.entity_id ~= self.entity_id then return false, "other_entity" end
    if not self.entity_id:match("^event%.[a-z0-9_]+$") then return self:_reject("invalid_entity") end
    local incoming_revision = timestamp(state.last_updated)
    if incoming_revision and older(incoming_revision, self.last_revision) then return false, "stale_state" end
    if state.state == "unavailable" and (type(state.attributes) ~= "table" or state.attributes.bridge_contract_version == nil) then
        -- This authoritative availability revision must also suppress older
        -- in-flight live updates, even though it carries no bridge metadata.
        if incoming_revision then self.last_revision = incoming_revision end
        return self:_reject("source_unavailable")
    end
    local metadata, error = validate(state)
    if not metadata then return self:_reject(error) end
    if older(metadata.revision, self.last_revision) then return false, "stale_state" end
    local a = metadata.attributes
    local session_key = a.bridge_control_id .. "/" .. a.bridge_session_id
    if self.retired_sessions[session_key] then return false, "retired_session" end
    if self.current_session ~= a.bridge_session_id or self.current_control ~= a.bridge_control_id then
        if self.current_session then
            self.retired_sessions[self.current_control .. "/" .. self.current_session] = true
        end
        self.current_session, self.current_control, self.last_sequence = a.bridge_session_id, a.bridge_control_id, 0
    end
    self.last_state, self.last_metadata, self.last_revision = state, metadata, metadata.revision
    local registered, reason = self:_register(metadata)
    self.ready = registered
    if not registered then
        -- State received before late init is history when the consumer starts.
        if a.gesture_session_id == self.current_session then self.last_sequence = math.max(self.last_sequence, a.gesture_sequence) end
        self:_status(reason)
        return false, reason
    end
    if delivery == "state" or a.bridge_update_kind == "snapshot" then
        if a.gesture_session_id == self.current_session then self.last_sequence = math.max(self.last_sequence, a.gesture_sequence) end
        self:_status("snapshot")
        return false, "snapshot"
    end
    if a.gesture_sequence <= self.last_sequence then return false, "duplicate_or_older" end
    local gap = a.gesture_sequence > self.last_sequence + 1
    self.last_sequence = a.gesture_sequence -- Set before the side effect to prevent reentrant replay.
    local event_key = a.button_id .. "/" .. a.gesture_id
    local event_id = self.allocations[a.bridge_control_id .. "/" .. event_key]
    local fired = pcall(self.c4.FireEventByID, self.c4, event_id)
    if not fired then return self:_reject("fire_failed") end
    self:_status(gap and "fired_with_sequence_gap" or "fired")
    return true, self.status, event_key
end

-- Parse once for both routing and consumption. Retain a decodable prefix on
-- strict syntax failure only so callers can identify its owner: malformed
-- messages for another entity must not cancel this entity's held output.
-- Direct load control opts out of the gesture syntax guard to retain its
-- existing wire behavior; no decoded gesture bypasses consume_parsed below.
function M.parse_proxy(command, params, strict)
    if type(params) ~= "table" then return {error="invalid_proxy_params"} end
    local payload, delivery
    if command == "RECEIEVE_STATE" then payload, delivery = params.response, "state"
    elseif command == "RECEIEVE_EVENT" then payload, delivery = params.data, "event"
    else return {error="other_command"} end
    local parsed={delivery=delivery}
    if type(payload) ~= "string" then parsed.error="invalid_json"; return parsed end
    if strict ~= false and not complete_json_object(payload) then parsed.error="invalid_json" end
    local ok, decoded = pcall(Decoder.decode, Decoder, payload)
    if not ok or type(decoded) ~= "table" then parsed.error="invalid_json"; return parsed end
    if delivery == "event" then
        if type(decoded.event) ~= "table" or type(decoded.event.data) ~= "table" then
            parsed.error=parsed.error or "invalid_event_wrapper"; return parsed
        end
        decoded = decoded.event.data.new_state
    end
    parsed.state=decoded
    return parsed
end

function Consumer:consume_parsed(parsed)
    if type(parsed) ~= "table" then return self:_reject("invalid_proxy_params") end
    if parsed.error == "other_command" then return false, parsed.error end
    if parsed.error then return self:_reject(parsed.error) end
    local decoded=parsed.state
    if type(decoded) == "table" and type(decoded.attributes) == "table" then
        if decoded.attributes.bridge_load == NULL then decoded.attributes.bridge_load = nil end
        if decoded.attributes.event_type == NULL then decoded.attributes.event_type = nil end
    end
    return self:consume(decoded, parsed.delivery)
end

function Consumer:consume_proxy(command, params)
    return self:consume_parsed(M.parse_proxy(command, params))
end

-- Eligibility preview shares the actual contract validator without allocating
-- events or authorizing commands. Catalogs use their own JSON null sentinel.
function M.preview(row,null)
    if type(row)~='table' or row.domain~='event' or type(row.attributes)~='table' then return nil end
    local a=row.attributes
    local load=a.bridge_load~=null and a.bridge_load or nil
    if null and type(load)=='table' and (load.attributes==null or
        type(load.attributes)=='table' and load.attributes.supported_color_modes==null) then return nil end
    local attrs={bridge_contract_version=a.bridge_contract_version,bridge_control_id=a.bridge_control_id,
        bridge_session_id='discovery-preview',bridge_update_kind='snapshot',bridge_buttons=a.bridge_buttons,
        bridge_sources={{id='preview',ready=false,availability='unknown'}},bridge_load=load}
    local metadata=validate({entity_id=row.entity_id,state='unknown',last_updated='2000-01-01T00:00:00Z',attributes=attrs})
    if metadata then return {load=metadata.attributes.bridge_load} end
end

return M
