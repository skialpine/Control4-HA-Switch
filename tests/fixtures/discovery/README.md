# HA catalog export, fixture version 1

`ha-catalog-v1.json` is produced by the independent HA Gesture Bridge checkout:

```sh
.venv/bin/python -m tools.generate_catalog_fixtures --output ../Control4-HA-Switch/tests/fixtures/discovery/ha-catalog-v1.json
```

The exporter uses actual Home Assistant entity/area registries, EventEntity
aggregates and the catalog SensorEntity. It creates 66 states and 64 eligible
catalog rows, including switch/light targets, unavailable loads and two
aggregates. Discovery timestamps and producer sessions are fixed for portable
reproducibility; no live installation data or credentials are included.

The companion's `test_catalog_export.py` validates the wire states and checks
this exported artifact when `C4_HA_SWITCH_CHECKOUT` is set. The C4 package test
loads Coordinator, Switch and Dimmer from built archives in both Lua runtimes.
It checks native pagination and the additive names-only catalog manifest/page,
JSON types, complete row counts, explicit snapshot release, metadata-only enrichment,
companion removal, retained selections and absence of secondary subscriptions
or load commands. This is local boundary evidence, not physical qualification.
