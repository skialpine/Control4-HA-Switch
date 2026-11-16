> Historical developer reference only. Do not install the proof packages below.
> Current installation uses the production Coordinator 114, Switch 107 and
> fresh-install Dimmer 1, as described in [installation.md](installation.md).
> The user superseded the stock-113/proof prerequisite; live qualification now
> uses those production drivers. Local proof harnesses remain transport tests.

# Generic family discovery proof

This is an isolated read-only Composer test, not the production switch upgrade.
It uses the actual shared discovery client through the pinned base lifecycle.
There is no relay, load command, button simulation, or HA service call. Selecting
an entity changes only the proof's `Selected Entity ID` property. It intentionally
has no primary `Entity ID` property and does not subscribe to selected loads.

The coordinator extension queries HA's native `get_states` over its existing
authenticated WebSocket. No Marketplace integration or HA change is needed.
Only the coordinator handles HA credentials. Its generic API serves all HA
domains and projects the attributes each consumer requests.

## Build and verify

From the switch checkout, with the coordinator sibling checkout present:

```sh
python3 ../Control4-HA-Coordinator/tools/build_driver.py --stock
python3 ../Control4-HA-Coordinator/tools/build_driver.py
.venv/bin/python -m tools.build_transport_proof
.venv/bin/python -m tools.build_discovery_proof
luajit tests/lua/test_discovery.lua
lua tests/lua/test_discovery.lua
luajit tests/controller/test_discovery_proof.lua
lua tests/controller/test_discovery_proof.lua
luajit tests/controller/test_family_discovery.lua
lua tests/controller/test_family_discovery.lua
```

Run the coordinator's independent `tests/test_discovery.lua` from its own root
under both Lua runtimes. Its protocol and family examples are documented in
`../Control4-HA-Coordinator/docs/entity-discovery.md`.

Artifacts:

- `../Control4-HA-Coordinator/dist/stock/HA.Coordinator.c4z`: unmodified upstream
  HEAD, version 113, for the original stock-coordinator gesture proof.
- `../Control4-HA-Coordinator/dist/HA.Coordinator.c4z`: development coordinator
  version 114, with generic discovery. This is not a published upstream release.
- `dist/HA.Gesture.Transport.Proof.c4z`: physical-gesture counters/events.
- `dist/HA.Entity.Discovery.Proof.c4z`: friendly-name selection and discovery
  status without load control.

The two coordinator artifacts have the same basename so version 114 can update
the stock proof coordinator instance. Keep their directories distinct.

## Composer qualification

1. Leave existing production drivers, entity IDs, relay/button links, and the
   Chowmain gateway intact. Add the stock coordinator and isolated gesture proof
   with explicit Device Link binding; configure the coordinator's usual CHV
   connection. Complete [the original gesture proof](transport-proof.md) before
   attributing its results to the updated coordinator.
2. Update that proof coordinator instance to the development version 114 and
   add the entity discovery proof. Bind it to the updated coordinator. Confirm
   the selected coordinator and driver versions rather than relying on autobind.
3. Invoke **Refresh Entities**. The default domains are `switch,input_boolean,light`.
   Verify Jeff's Office switch appears as a friendly name with its exact HA ID.
   Selecting it must update `Selected Entity ID` without switching its load.
   **Selected Capabilities** reports conservative switch/dimmer classification
   from the selected entity's projected metadata. A brightness-capable light can
   show Set Level; Ramp to Level additionally requires HA transition support.
   This property does not implement those load actions in the read-only proof.
4. Change **Domains** to `light`, then `cover`, `climate,select,button`, and an
   additional relevant family domain. An empty Domains value requests all HA
   entities. Verify filtering and complete counts; on/off-only lights and
   unavailable entities must not disappear under a global dimmer-only filter.
5. **Attribute Keys** selects projected state attributes. Inspect projected
   capabilities using the protocol/helper; missing area/registry information is
   not inferred. Duplicate friendly names remain distinguishable by entity ID.
6. Refresh, disconnect/reconnect, unbind/rebind, and test a missing entity.
   Retain the selected ID on errors; old responses must not populate the new
   request. A stock coordinator without discovery support must time out clearly
   without breaking manual configuration or existing state/service traffic.
7. Record actual Director/coordinator versions, entity/page counts, proxy byte
   limits, response timing, selected entity, and legacy driver behavior. Do not
   claim controller or upgrade compatibility solely from the local harnesses.

## Recorded local evidence

The coordinator suite passes 20 tests on LuaJIT and Lua 5.5. Consumer checks cover
correlation, pagination, typed attributes including null/false/empty arrays and
objects, bounds, timeout, recreated clients, and safe picker labels. The proof
lifecycle test exercises base callbacks, selection preservation, and rebinding.

The cross-repository harness loads the actual coordinator and proof entry points
in separate Lua environments, simulates only the Director/WebSocket boundaries,
and delivers 64 entities across 14 HA domains in two pages from one HA read. It
confirms no state subscription or primary entity-table mutation. This is local
integration evidence; actual Composer qualification remains pending.
