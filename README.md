# Virbula offline maps

This repository owns the worldwide road-map release automation consumed by
EasyElevation. It extracts 554 bounded PMTiles packs from the official retained
Protomaps planet archive with HTTP range requests and publishes them as an
immutable GitHub Release. No Virbula server and no full planet download are
required.

The app catalog URL is:

`https://github.com/virbula/offlinemaps/releases/latest/download/catalog.json`

See [docs/automation.md](docs/automation.md) for operations and recovery.
