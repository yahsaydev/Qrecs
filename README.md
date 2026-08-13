# Qrecs

Qrecs is a native SwiftUI app for macOS 15 and later.

Build and launch locally with:

```sh
./script/build_and_run.sh
```

Run the build-and-launch smoke check with `./script/build_and_run.sh --verify`.

## Offline catalog

Qrecs ships a generated SQLite catalog with 172 reciter entries, 114 surahs,
and 19,608 audio tracks. The source CSV and reviewed Russian/English
localization mappings are checked in under `CatalogTools/Data`; normal builds,
tests, and app runtime never fetch catalog data from the network.

Regenerate the bundled database deterministically with:

```sh
python3 CatalogTools/build_catalog.py
```

Run the builder validation and corruption tests with:

```sh
python3 -m unittest discover -s CatalogTools/Tests -v
```
