# Qrecs: Compact Mini-Player and Night Sound

## Goal

Restore the mini-player to a stable, compact single-row presentation and add a fifth independently mixable nature sound, “Night”, featuring crickets.

## Mini-Player Layout

- The complete player surface has a fixed height of 76 points, including the Aurora, glass overlay, controls, and padding.
- The layout remains a single horizontal row at supported window sizes.
- Track and reciter text stays within its existing leading column and truncates instead of increasing the player height.
- A playback error remains visible without changing the player height. It replaces the secondary reciter line while present.
- Existing playback, seek, volume, retry, and Sounds controls remain available.
- The Aurora Canvas is clipped to the same 76-point surface and cannot claim additional vertical space.

## Night Ambient Sound

- Add `AmbientSound.night` as the fifth ambient channel.
- English name: `Night`; Russian name: `Ночь`.
- The recording contains continuous nighttime crickets without speech or music.
- The source must be a compact, decodable MP3 published under CC0. Its author, item URL, download URL, SHA-256, and CC0 URL are recorded alongside the existing effects and in `THIRD_PARTY_NOTICES`.
- The audio file is bundled as `night.mp3` and looped through the existing `AVAudioEngineAmbientBackend` path.
- Night has its own toggle and volume, persists through `AppPreferences`, and mixes with Quran playback and all existing ambient channels.
- Its Aurora accent is a restrained violet/indigo so it remains compatible with Light and Dark appearances.

## Data and UI Flow

`AmbientSound.allCases` remains the source of truth. Adding `.night` automatically feeds default mixer state, persisted preferences, the Sounds popover, Settings attribution, mixer playback, and Aurora accent selection. Explicit metadata switches provide localized names, source attribution, resource identity, and checksum.

The player height is expressed through a small layout contract used by `MiniPlayerView` and tested independently. `PlayerSurface` owns the final height so neither Canvas nor Liquid Glass can expand it.

## Failure Handling

- App startup fails visibly if the bundled Night resource is missing or cannot be decoded, matching existing ambient-resource behavior.
- Night never starts automatically after application launch.
- A disabled Night channel does not affect other playing channels.
- An unavailable source during development prevents the resource from being added; no unverified or incompatible asset is committed.

## Verification

- A failing layout test first proves the player lacks the required compact-height contract.
- Resource tests first require `.night`, localized names, CC0 metadata, exact SHA-256, bundle presence, and successful AVFoundation decoding.
- Mixer and preferences tests verify independent Night enablement, volume persistence, play, pause, and mixing.
- Build-for-testing and the full direct XCTest suite must pass.
- The release bundle must contain `night.mp3`, and packaging tests must reject an archive without it.
- Manual QA covers the 76-point height, narrow-window truncation, Sounds popover, Night volume, simultaneous effects, looping, and Light/Dark Aurora appearance.

## Scope

This change does not alter catalog crawling, Quran playback semantics, cache behavior, release versioning, or publication state.
