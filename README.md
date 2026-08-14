<p align="center">
  <img src="docs/assets/qrecs-icon.png" width="180" alt="Qrecs icon">
</p>

<h1 align="center">Qrecs</h1>

<p align="center">A native Quran recitation library and player for macOS.</p>

<p align="center">
  <a href="README.ru.md">Русский</a> ·
  <a href="docs/releases/v0.1.1.md">v0.1.1 release</a> ·
  <a href="#build-and-test">Build</a> ·
  <a href="LICENSE">License</a>
</p>

Qrecs is built with SwiftUI, AVFoundation, and GRDB for macOS 15 and later.

## Features

- A native library with favorite reciters, search, and sortable surah tables.
- Streaming playback, a queue ordered by surah number, and a global mini-player.
- User-requested offline downloads, explicit offline mode, and per-reciter or global storage cleanup.
- Four independently mixed, gapless-looped ambient sounds: fire, birdsong, rain, and waterfall.
- English and Russian localization, System/Light/Dark appearance controls, and system Liquid Glass where supported.
- A bundled, read-only SQLite catalog. Normal builds, tests, and app launches never crawl catalog sites or fetch catalog metadata.
- Deterministic build-time catalog tooling that can merge an explicitly supplied, audited, confirmed SurahQuran snapshot. Reciters with sparse published selections retain only their available surahs; the app does not invent missing tracks.

## Install v0.1.1

> **Pre-release warning:** `Qrecs-0.1.1-macOS.zip` is ad-hoc signed and not notarized. It is intended for early testing, not general distribution.

Download the ZIP and its `.sha256` file from the [v0.1.1 release](docs/releases/v0.1.1.md), then verify it:

```sh
shasum -a 256 -c Qrecs-0.1.1-macOS.zip.sha256
```

Extract the ZIP and move `Qrecs.app` to Applications. On first launch, macOS may block the unnotarized app. In Finder, right-click (or Control-click) `Qrecs.app`, choose **Open**, then confirm **Open**. Do not disable or bypass Gatekeeper.

## Build and test

Requirements: macOS 15 or later, a compatible Xcode installation, and Xcode command-line tools.

```sh
# Debug build and launch
./script/build_and_run.sh

# Build the app and both test runners
xcodebuild build-for-testing -project Qrecs.xcodeproj -scheme Qrecs \
  -destination 'platform=macOS'

# Run the complete test plan
xcodebuild test -project Qrecs.xcodeproj -scheme Qrecs \
  -destination 'platform=macOS'

# Validate the deterministic catalog builder and snapshot tooling
python3 -m unittest discover -s CatalogTools/Tests -v

# Run release regression checks
bash script/tests/release_branding_tests.sh
bash script/tests/package_release_tests.sh
```

To create the deterministic ad-hoc Release ZIP and SHA-256 manifest in `dist/`:

```sh
./script/package_release.sh
```

The packaging script uses the dependency versions in `Package.resolved`, builds a universal Release app, verifies version and icon metadata, removes debug/test artifacts, signs ad-hoc with the production entitlements, validates the signature, and normalizes archive timestamps.

## Catalog and user data

The checked-in source catalog lives under `CatalogTools/Data/`, and the generated runtime database is `Qrecs/Resources/Catalog/catalog.sqlite`. Catalog size is intentionally not duplicated here; audit the exact bundled database when preparing a release:

```sh
sqlite3 Qrecs/Resources/Catalog/catalog.sqlite \
  'select key, value from catalog_meta where key in ("reciter_count", "surah_count", "track_count") order by key;'
```

Rebuild from checked-in CSV data, optionally merging an audited and confirmed snapshot at build time:

```sh
python3 CatalogTools/build_catalog.py
python3 CatalogTools/build_catalog.py --snapshot /path/to/confirmed-surahquran-snapshot.json
```

Because Qrecs is sandboxed, mutable data is stored under `~/Library/Containers/com.heezya.Qrecs/Data/Library/Application Support/Qrecs/`:

- `UserData/user.sqlite` stores favorites and completed-download metadata.
- `AudioCache/` stores Quran audio explicitly downloaded by the user.

Offline audio is not automatically evicted. Users can remove downloads per reciter or clear all audio storage in Settings.

## Audio notices and legal disclaimer

The bundled ambient recordings are CC0 1.0 assets from Freesound. Authors, source pages, and license details are listed in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). CC0 applies to those ambient files, not to Quran recordings referenced by the catalog.

The [MIT License](LICENSE) covers this repository's code only. It does **not** grant streaming, downloading, redistribution, public-performance, or other rights to Quran recordings hosted by third parties. Hosts, URLs, availability, and terms can change. Users and redistributors are responsible for obtaining any permissions required by their jurisdiction and each source's terms.
