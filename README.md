# Virbula offline maps

This repository owns the worldwide road-map release automation consumed by
EasyElevation. It extracts 554 bounded PMTiles packs from the official retained
Protomaps planet archive and builds matching Valhalla routing graphs from
immutable Geofabrik/OpenStreetMap extracts. Maps and graphs use coordinated
immutable `maps-*` and `routing-*` releases; the latest catalog joins them into
one logical regional download and identifies the Valhalla engine version needed
to read each graph safely. No Virbula server is required.

The app catalog URL is:

`https://github.com/virbula/offlinemaps/releases/latest/download/catalog.json`

Use [docs/local-processing.md](docs/local-processing.md) for local planning,
building, validation, and explicitly confirmed manual publication. See
[docs/automation.md](docs/automation.md) for scheduled operations and recovery.

A Valhalla graph is routable topology, not a rendered basemap, so PMTiles are
still required. Valhalla software is MIT licensed. Published graph databases
are derived from Geofabrik/OpenStreetMap data and remain subject to the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/),
including © OpenStreetMap contributors attribution and applicable share-alike
obligations for derived databases.
