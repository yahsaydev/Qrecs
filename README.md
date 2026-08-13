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

## User data

Qrecs keeps mutable user data separate from the bundled read-only catalog.
Favorites and completed-download metadata live in
`Application Support/Qrecs/UserData/user.sqlite`; user-requested offline audio
lives in `Application Support/Qrecs/AudioCache`. The app does not place offline
audio in the system Caches directory or evict it automatically.

## Audio playback and ambient sounds

The playback core uses `AVPlayer` for streamed or downloaded Quran tracks and
`AVAudioEngine` for four independently mixable, gapless-looped ambient sounds.
Selecting a track prepares it without autoplay. The player queue follows surah
numbers 1 through 114, while a remote network interruption produces an explicit
retry state and never interrupts an already-downloaded local track.

The bundled Fire, Birdsong, Rain, and Waterfall recordings are CC0 assets from
Freesound. Their authors, item pages, and license are recorded in
`THIRD_PARTY_NOTICES`. Re-fetch all four pinned HQ MP3 files atomically with:

```sh
./script/fetch_ambient_assets.sh
```

Verify the checked-in files without using the network with:

```sh
./script/fetch_ambient_assets.sh --verify
```
