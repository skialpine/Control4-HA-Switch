# Shared Lua entity discovery client

`module/discovery.lua` supplies a generic, dependency-free client for the coordinator's version 1 entity catalog and a pure Composer picker builder. It runs on LuaJIT/Lua 5.1 and Lua 5.5. It does not change production driver XML, send load commands, or install anything on a controller.

```lua
local Discovery = require('module.discovery')
local catalog = Discovery.new({
    client_id = 'switch-driver-123', -- identify this driver instance, 1..96 bytes
    send = function(binding, command, params)
        C4:SendToProxy(binding, command, params, 'COMMAND')
    end,
    on_complete = function(rows, metadata)
        local picker = Discovery.build_picker(rows, {
            domains = {'switch', 'light'},
            selected_entity_id = Properties['Entity ID'],
        })
        -- picker.values: array of display labels; picker.value_list: comma list.
        -- picker.selected_label identifies the current entity or manual entry.
        -- Apply these through the driver's supported Composer property API.
    end,
    on_status = function(reason, detail) end,
})

-- Start after the binding is connected, or from a user-triggered Refresh action.
catalog:refresh({domains={'switch', 'light'}, attribute_keys={'supported_color_modes'}})
-- Forward proxy commands to catalog:consume_proxy(command, tParams).
-- Poll catalog:tick() from a driver's timer to enforce response timeout.
-- On reconnect or binding changes, call catalog:invalidate(), then refresh.
```

`send(binding, command, params)` receives binding `999`, command `HA_GET_ENTITIES`, and `{JSON=encoded_request}`. Returning `false` or throwing signals failure; a nil return is accepted for the Control4 API. Optional `encode(value)` and `decode(string)` injections must preserve JSON arrays, objects, false, and null. `Discovery.new_codec()` returns a suitable private codec; `Discovery.null` is its null sentinel. Defaults use that codec without changing the global JSON instance.

A refresh copies and validates its query, cancels an earlier request, and assigns a new request ID. Request IDs include an instance nonce, so a recreated client with the same `client_id` ignores delayed replies from the previous instance. The optional `session_id` (1..64 bytes) makes that nonce injectable; callers must keep it unique across client lifetimes. Default nonces combine wall time, process clock, an instance counter, and object identity. Client IDs and session IDs cannot contain control characters. `refresh(query)` returns `true, request_id` or `false, reason`.

Query fields are `domains`, `entity_ids`, `attribute_keys`, optional boolean `include_registry`, optional `selector` (`switch` or `dimmer`), and `page_size` (1..100, default 50). At least one of `domains`/`entity_ids` is required by the Coordinator; omit only one to leave that dimension unrestricted; an explicit empty list means no matching entities. Omitted `attribute_keys` requests no projected attributes. A caller cannot inject a cursor, protocol version, or correlation ID. The client keeps the same request ID and copied query across pages and changes only the cursor.

`consume_proxy(command, params)` returns `false, 'unhandled'` for other commands. For `HA_ENTITIES` it returns `true, reason`, including `other_client`, `stale_response`, `page_requested`, or `complete`. Only matching client/request IDs affect an active refresh. Success pages must retain the same snapshot ID and total. Entity IDs must be unique, domains must match their entity IDs, availability must be `available`, `unavailable`, or `unknown`, and each entity must contain an attributes object. An empty attributes object is valid; individual projected fields may be missing or null. Nested JSON arrays and objects retain their shape, including empty containers.

Completion publishes `catalog.choices` and `catalog.metadata` atomically, then calls `on_complete(rows, metadata)`. Metadata includes `snapshot_id`, `request_id`, `total`, and `pages`. A successful empty catalog replaces the previous catalog. Failed, invalidated, or timed-out refreshes retain the last completed choices. Consumers can display `catalog.status` or receive `on_status(reason, detail)`; they should only rebuild choices on completion.

Each reply is limited to 32,768 bytes. A refresh is bounded by 10,000 rows, 1 MiB of response JSON, and 10,000 pages. Repeated cursors, empty incomplete pages, mismatched totals, changed snapshots, duplicates, invalid shapes, and non-finite projected numbers fail the refresh. `max_rows`, `max_bytes`, and `max_pages` may lower these limits. Errors never log raw payloads or credentials. The default 10-second timeout applies to each outstanding page; inject `now()` and `timeout` to change timing. `tick()` (also available as `expire()`) expires a pending page and reports `timeout`, including a diagnostic for coordinators without discovery support. The caller owns the timer. `invalidate(reason)` discards pending work and retains completed choices.

## Picker policy

```lua
local switch_picker = Discovery.build_picker(rows, {
    domains={'switch', 'light'}, selected_entity_id='light.office',
}) -- Includes lights with only on/off support; no brightness requirement.
local shade_picker = Discovery.build_picker(rows, {domains='cover'})
local thermostat_picker = Discovery.build_picker(rows, {domains={'climate'}})
local action_picker = Discovery.build_picker(rows, {domains={'select', 'button'}})
local sensor_picker = Discovery.build_picker(rows, {
    predicate=function(row) return row.domain=='sensor' end,
})
```

Discovery does not decide a driver's capabilities. Consumers filter any HA domain with `domains` (a string, list, or set), an optional `predicate(row)`, or both. Available, unavailable, and unknown rows remain selectable unless the consumer filters them.

`client:release(metadata)` optionally releases a completed snapshot after cursor retries are no longer needed. It sends the additive `HA_RELEASE_ENTITIES` command scoped to the client, request and snapshot IDs, without changing choices or issuing an HA request. The optional paged names catalog uses this after each completed read so large transfers do not exhaust the Coordinator snapshot cache. Older Coordinators ignore the release command; ordinary discovery behavior remains unchanged.

`build_picker` returns `values`, `value_list`, `manual_label`, `selected_label`, `selected_entity_id`, `missing_selected`, `label_to_entity`, and `entity_to_label`. Entity labels use `Friendly name [entity_id]`; commas and line breaks are replaced, duplicate friendly names remain distinct, and options sort by label. Duplicate entity rows are ignored by the pure helper. The first option is `Manual Entity ID` (customizable through `manual_label`). Its explicit label-map value is `false`: selecting it must preserve the driver's editable Entity ID.

```lua
local selected_id = picker.label_to_entity[selected_label]
if selected_id then
    -- Update the Entity ID property with selected_id.
end
```

An entity removed from the catalog or excluded by a filter keeps its `selected_entity_id`, sets `missing_selected=true`, and selects the manual label. This prevents a refresh from silently rebinding the driver. The picker does not parse IDs back out of labels.

## Optional HA companion enrichment in Switch and Light

Both production consumers first complete native discovery and make its choices available. They then use `module/catalog_enrichment.lua` with a separate correlated discovery client to request exactly the sensor named by **Discovery Catalog Entity ID** (default `sensor.ha_gesture_bridge_catalog`). An empty property disables this optional read. Changing that property refetches the new sensor and discards pending replies and metadata for the old one.

The client first requests a small names manifest: `catalog_contract_version`, `catalog_names_version`, `catalog_names_revision`, `catalog_names_total`, `catalog_names_pages` and optional `catalog_names_error`. A version-1 names projection is then fetched one `catalog_names_page_NNN` attribute at a time, together with that manifest. Each ASCII-JSON page is at most 16 KiB; all responses retain the existing 32 KiB proxy limit. Every page must retain the same names revision, row count and page count, with no duplicate or missing IDs. The client publishes names atomically after the final page and never truncates the catalog. Names revisions ignore load state/capability churn, avoiding needless invalidation while lights change.

These reads use `HA_GET_ENTITIES` and page size one, leaving the Coordinator's primary entity table and subscriptions unchanged. Each completed snapshot is explicitly released with `HA_RELEASE_ENTITIES` before the next read so larger catalogs do not exhaust the Coordinator's cache. Older Coordinators ignore this additive command; updated Coordinators support transfers beyond the retained snapshot capacity. If the companion does not advertise the names extension, enrichment is skipped and the native filtered choices remain available. No path uses the legacy `HA_GET_STATE` secondary-subscription mechanism, raises packet limits, or starts an automatic retry loop.

Only a current available sensor with a supported version-1 catalog and valid records supplies enrichment. Friendly name and area are applied only to exact IDs already present in native discovery. Catalog-only rows cannot add a target, and catalog state, capabilities, load links or gesture data cannot authorize commands or fire programming. Native discovery and the selected entity's separately validated live state remain authoritative. Names/areas appear in both the property list and searchable action picker; comma/newline normalization and explicit label-to-ID maps remain in effect.

Opening **Select Device** or explicitly running **Refresh Entities** fetches the filtered native list and optional enrichment. Startup, binding recovery and HA reconnection refresh only the selected entity; they do not rebuild the picker. Disconnect, changed catalog configuration and refresh invalidate pending catalog correlation and remove old enrichment. Missing, unavailable, incompatible, malformed, oversized or timed-out catalogs leave native/manual operation usable. **Discovery Status** identifies catalog errors and a missing current selection while preserving its exact Entity ID, mode and bindings. Companion absence is an ordinary native-only discovery result.

The two-stage read is metadata only. Choosing a displayed device remains an explicit action; neither completing discovery nor receiving a catalog changes the configured target or operation mode. A previously saved Direct switch and a consolidated gesture choice can therefore share a display entry without automatically migrating the saved instance.

## Codec compatibility and verification

`module/json.lua` has two backwards-compatible opt-ins used by private discovery codecs: a configured `null` sentinel survives decode/encode, and `strictTypes=true` preserves explicit empty arrays on encode. Default JSON behavior remains unchanged for existing driver consumers.

Run from the repository root:

```sh
luajit tests/lua/test_discovery.lua
lua tests/lua/test_discovery.lua
luajit tests/lua/test_catalog_enrichment.lua
lua tests/lua/test_catalog_enrichment.lua
luajit tests/lua/test_gestures.lua
lua tests/lua/test_gestures.lua
```

The discovery harness covers the generic switch/light/cover/climate/select/button/sensor family, pagination, correlation, client recreation, stale replies, query copying, explicit empty lists, projection types, invalid shapes, bounds, errors, timeouts, retained choices, and safe picker labels. It exercises injected transport and clock boundaries. Controller transport and Composer UI verification remain separate integration work.


## Preferred HA catalog entries

When available, the optional HA catalog owns device consolidation. Its paged names records may include `entity_aliases`, `source_entity_id` and `is_group`. HA chooses the preferred physical representation and C4 follows those exact aliases after validating the native target. Alias metadata cannot introduce a target absent from native discovery or authorize an HA load command. Without a valid catalog, the client retains ordinary native choices. Switch/Light no longer automatically request the full HA entity registry; the Coordinator no longer fetches the complete state list or registry for any discovery request. Selector profiles first enumerate candidate IDs, read category metadata for those IDs in batches of 50, then read only eligible states. Native metadata also resolves exact on/off wrapper aliases. Switch and Light have different role filters; configuration/diagnostic toggles, hidden/disabled entities, standalone helpers and C4-originated lights/groups are excluded. Physical gesture controls and native HA lighting/groups remain eligible. Filtered HTTP failures are reported rather than broadened into full downloads. The obsolete full-catalog read path was removed.
