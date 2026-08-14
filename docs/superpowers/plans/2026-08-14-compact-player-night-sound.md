# Compact Mini-Player and Night Sound Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the Qrecs mini-player to a fixed 76-point single-row surface and add a fifth independently mixable CC0 Night/crickets sound.

**Architecture:** `MiniPlayerLayout` owns a single tested height constant used by `PlayerSurface`, preventing Canvas or Liquid Glass from expanding the bottom bar. `AmbientSound.allCases` remains the source of truth for the mixer, preferences, popover, Settings attribution, and Aurora; adding `.night` plus its pinned resource metadata automatically integrates the new channel through existing loops.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation/AVAudioEngine, XCTest, Xcode project resources, deterministic shell packaging.

---

## File Map

- Modify `Qrecs/Features/Player/MiniPlayerView.swift`: compact layout contract, fixed player surface height, two-line metadata/error presentation.
- Modify `Qrecs/Models/AmbientSound.swift`: `.night` metadata, violet accent, source and checksum.
- Add `Qrecs/Resources/Ambient/night.mp3`: pinned CC0 Night/crickets preview.
- Modify `Qrecs.xcodeproj/project.pbxproj`: bundle `night.mp3` in the app target.
- Modify `THIRD_PARTY_NOTICES`: Night recording provenance and CC0 notice.
- Modify `QrecsTests/LibraryPresentationTests.swift`: compact height contract.
- Modify `QrecsTests/AmbientResourceTests.swift`: Night metadata, hash, notice, and decode coverage.
- Modify `QrecsTests/AmbientMixerTests.swift`: independent Night playback and volume.
- Modify `QrecsTests/LibraryPresentationTests.swift`: Night preference persistence and Aurora accent coverage.
- Modify `script/tests/package_release_tests.sh`: require `night.mp3` in the release bundle.
- Modify `QrecsUITests/QrecsUITests.swift`: compact player bounds and Night control smoke coverage.

### Task 1: Lock the Mini-Player to the Approved Height

**Files:**
- Modify: `QrecsTests/LibraryPresentationTests.swift`
- Modify: `Qrecs/Features/Player/MiniPlayerView.swift`
- Modify: `QrecsUITests/QrecsUITests.swift`

- [ ] **Step 1: Write the failing layout contract test**

Add to `LibraryPresentationTests`:

```swift
func testMiniPlayerUsesCompactSingleRowHeight() {
    XCTAssertEqual(MiniPlayerLayout.surfaceHeight, 76)
    XCTAssertEqual(MiniPlayerLayout.metadataLineLimit, 2)
}
```

Add a UI assertion after selecting and playing a track:

```swift
let player = app.otherElements["player.surface"]
XCTAssertTrue(player.waitForExistence(timeout: 3))
XCTAssertLessThanOrEqual(player.frame.height, 76.5)
```

- [ ] **Step 2: Run the focused build to verify RED**

Run:

```bash
xcodebuild build-for-testing -project Qrecs.xcodeproj -scheme Qrecs -destination 'platform=macOS' -only-testing:QrecsTests/LibraryPresentationTests
```

Expected: compile failure because `MiniPlayerLayout` does not exist.

- [ ] **Step 3: Add the minimal layout contract and apply it to the surface**

At the top of `MiniPlayerView.swift`, add:

```swift
enum MiniPlayerLayout {
    static let surfaceHeight: CGFloat = 76
    static let metadataLineLimit = 2
}
```

Replace the metadata stack’s unconditional reciter line plus optional third error line with exactly two lines:

```swift
Text(currentSurah?.displayName(language: store.preferences.resolvedLanguage)
    ?? store.preferences.text("Surah"))
    .font(.headline)
    .lineLimit(1)

if let failureMessage = store.playbackFailureMessage {
    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(1)
        .accessibilityIdentifier("player.failure")
} else {
    Text(currentReciter?.displayName(language: store.preferences.resolvedLanguage) ?? "")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
}
```

Apply the contract at the end of `PlayerSurface.body`:

```swift
.frame(height: MiniPlayerLayout.surfaceHeight)
.accessibilityIdentifier("player.surface")
```

Keep the Aurora and glass inside this clipped surface; do not add a height to `Canvas` itself.

- [ ] **Step 4: Verify GREEN**

Run the focused build and direct `LibraryPresentationTests`. Expected: layout contract passes and the UI-test target compiles.

- [ ] **Step 5: Commit the compact player change**

```bash
git add Qrecs/Features/Player/MiniPlayerView.swift QrecsTests/LibraryPresentationTests.swift QrecsUITests/QrecsUITests.swift
git commit -m "fix: restore compact mini player height"
```

### Task 2: Add Night as a Complete Ambient Model Case

**Files:**
- Modify: `QrecsTests/AmbientResourceTests.swift`
- Modify: `Qrecs/Models/AmbientSound.swift`
- Modify: `QrecsTests/LibraryPresentationTests.swift`

- [ ] **Step 1: Write failing Night metadata tests**

Change the expected cases and add explicit assertions:

```swift
XCTAssertEqual(AmbientSound.allCases, [.fire, .birds, .rain, .waterfall, .night])
XCTAssertEqual(AmbientSound.night.nameEN, "Night")
XCTAssertEqual(AmbientSound.night.nameRU, "Ночь")
XCTAssertEqual(AmbientSound.night.accent.hex, 0x5B4AA8)
XCTAssertEqual(
    AmbientSound.night.itemURL.absoluteString,
    "https://freesound.org/people/Solar01/sounds/662882/"
)
XCTAssertEqual(AmbientSound.night.author, "Solar01")
XCTAssertEqual(
    AmbientSound.night.licenseURL.absoluteString,
    "https://creativecommons.org/publicdomain/zero/1.0/"
)
```

In the palette test, assert the Night accent is preserved:

```swift
let colors = AuroraPaletteModel.fieldColors(
    enabledAccents: [AmbientSound.night.accent],
    fieldCount: 6
)
XCTAssertTrue(colors.contains(.ambient(AmbientSound.night.accent)))
```

- [ ] **Step 2: Run RED**

Run the focused Ambient resource and presentation test build. Expected: compile failure because `.night` is missing.

- [ ] **Step 3: Add `.night` and exhaustive metadata**

Add `case night` after `waterfall`. Extend every switch:

```swift
case .night: "Night"
case .night: "Ночь"
case .night: AmbientAccent(hex: 0x5B4AA8)
case .night: "Solar01"
case .night: URL(string: "https://freesound.org/people/Solar01/sounds/662882/")!
```

Set `sourceURL` to the public HTTPS Freesound HQ MP3 preview resolved from the item page, and set `sha256` to the lowercase SHA-256 of the exact downloaded `night.mp3`. Do not accept an original WAV, an authenticated download URL, a non-CC0 substitute, or an unpinned file.

- [ ] **Step 4: Run the focused tests**

Expected: metadata and palette tests pass; the resource test remains RED until Task 3 adds the file.

- [ ] **Step 5: Commit model metadata**

```bash
git add Qrecs/Models/AmbientSound.swift QrecsTests/AmbientResourceTests.swift QrecsTests/LibraryPresentationTests.swift
git commit -m "feat: model night ambient sound"
```

### Task 3: Pin and Bundle the CC0 Night Recording

**Files:**
- Add: `Qrecs/Resources/Ambient/night.mp3`
- Modify: `Qrecs.xcodeproj/project.pbxproj`
- Modify: `THIRD_PARTY_NOTICES`
- Test: `QrecsTests/AmbientResourceTests.swift`

- [ ] **Step 1: Confirm the selected source before downloading**

Verify the Freesound item page states: author `Solar01`, title `Ambience Crickets Night.wav`, duration `14.825` seconds, and `Creative Commons 0`. Resolve its public HQ MP3 preview URL from the page metadata.

- [ ] **Step 2: Download to temporary storage and validate it**

Download the preview to `/tmp/qrecs-night.mp3`, then run:

```bash
file /tmp/qrecs-night.mp3
afinfo /tmp/qrecs-night.mp3
shasum -a 256 /tmp/qrecs-night.mp3
```

Expected: MP3/MPEG audio, positive duration, successful decode, and one stable lowercase hash. Copy the verified file to `Qrecs/Resources/Ambient/night.mp3` and place the exact URL/hash in `AmbientSound.night`.

- [ ] **Step 3: Add the resource to the Xcode project**

Add these deterministic project entries following the existing ambient numbering:

```text
120000000000000000000205 /* night.mp3 in Resources */
220000000000000000000205 /* night.mp3 */
```

Place the file reference in the Ambient group and the build file in the Qrecs Resources phase.

- [ ] **Step 4: Add provenance to notices**

Insert under the ambient recordings list:

```text
* Night, by Solar01
  https://freesound.org/people/Solar01/sounds/662882/
```

Keep the existing CC0 explanation unchanged.

- [ ] **Step 5: Run the resource tests to verify GREEN**

Run `AmbientResourceTests`. Expected: exact source/bundle hashes match, AVFoundation decodes Night, attribution exists, and the host app contains `night.mp3`.

- [ ] **Step 6: Commit the verified resource**

```bash
git add Qrecs/Resources/Ambient/night.mp3 Qrecs.xcodeproj/project.pbxproj Qrecs/Models/AmbientSound.swift THIRD_PARTY_NOTICES QrecsTests/AmbientResourceTests.swift
git commit -m "feat: bundle CC0 night crickets ambience"
```

### Task 4: Verify Night Mixing and Preference Persistence

**Files:**
- Modify: `QrecsTests/AmbientMixerTests.swift`
- Modify: `QrecsTests/LibraryPresentationTests.swift`

- [ ] **Step 1: Write the failing mixer behavior test**

```swift
func testNightPlaysAndPausesIndependently() {
    let backend = RecordingAmbientBackend()
    let mixer = AmbientMixer(backend: backend)

    mixer.setEnabled(true, for: .night)
    mixer.setVolume(0.37, for: .night)
    mixer.play()

    XCTAssertEqual(backend.volumes[.night], 0.37)
    XCTAssertEqual(backend.played, [.night])

    mixer.pause()
    XCTAssertEqual(backend.paused, [.night])
}
```

Add preference persistence:

```swift
preferences.setAmbientEnabled(true, for: .night)
preferences.setAmbientVolume(0.37, for: .night)
let restored = AppPreferences(defaults: defaults)
XCTAssertTrue(restored.ambientEnabled(.night))
XCTAssertEqual(restored.ambientVolume(.night), 0.37, accuracy: 0.0001)
```

- [ ] **Step 2: Run RED before the resource/model implementation is present**

Expected: compile failure for `.night` or assertion failure if a channel is not initialized.

- [ ] **Step 3: Make the minimal integration changes**

No new production mixer branch should be needed. Confirm `AmbientMixState.default`, `AmbientMixer`, `AVAudioEngineAmbientBackend`, `AppPreferences`, `AmbientSoundsView`, Settings attribution, and Aurora all enumerate `AmbientSound.allCases`. Fix only code that incorrectly assumes four cases.

- [ ] **Step 4: Run GREEN**

Run `AmbientMixerTests` and `LibraryPresentationTests`. Expected: Night starts only with the main mix, pauses independently, persists volume/toggle state, and the four previous channels remain unchanged.

- [ ] **Step 5: Commit integration tests and any required fixes**

```bash
git add QrecsTests/AmbientMixerTests.swift QrecsTests/LibraryPresentationTests.swift Qrecs
git commit -m "test: cover night ambience mixing and persistence"
```

### Task 5: Harden Packaging and Perform Full Verification

**Files:**
- Modify: `script/tests/package_release_tests.sh`
- Modify: `QrecsUITests/QrecsUITests.swift`
- Generated, ignored: `dist/Qrecs-0.1.1-macOS.zip`
- Generated, ignored: `dist/Qrecs-0.1.1-macOS.zip.sha256`

- [ ] **Step 1: Write the failing packaging assertion**

Extend the expected ambient resource list from four to five:

```bash
for ambient in fire.mp3 birds.mp3 rain.mp3 waterfall.mp3 night.mp3; do
  require_zip_entry "Qrecs.app/Contents/Resources/${ambient}"
done
```

Expected before bundling: release regression fails because `night.mp3` is absent.

- [ ] **Step 2: Run all local test layers**

```bash
python3 -m unittest discover -s CatalogTools/Tests -v
xcodebuild build-for-testing -project Qrecs.xcodeproj -scheme Qrecs -destination 'platform=macOS'
bash script/tests/build_and_run_tests.sh
bash script/tests/package_release_tests.sh
bash script/tests/release_branding_tests.sh
git diff --check
```

Expected: Python and shell suites pass, Xcode reports `TEST BUILD SUCCEEDED`, and no whitespace errors occur.

- [ ] **Step 3: Run the complete XCTest bundle**

Use the freshly built host app and test bundle with the existing direct-XCTest environment. Expected: all tests pass with zero failures; do not claim UI runtime execution if `testmanagerd` blocks it.

- [ ] **Step 4: Build and inspect the universal test archive**

```bash
./script/package_release.sh
shasum -a 256 -c dist/Qrecs-0.1.1-macOS.zip.sha256
```

Inspect the staged app with `lipo -archs`, `codesign --verify --deep --strict`, `plutil`, and `unzip -l`. Expected: `arm64 x86_64`, version `0.1.1`, build `2`, valid ad-hoc signature, production sandbox/network entitlements, `night.mp3`, and no XCTest/debug artifacts.

- [ ] **Step 5: Manual QA checkpoint**

Verify the player remains 76 points tall in RU/EN and Light/Dark; long titles truncate; playback errors do not grow the surface; Night appears in Sounds and Settings; Night loops without a loud seam; Night mixes with Quran plus every existing ambient effect; pause/resume and Reduce Motion remain correct.

- [ ] **Step 6: Commit final verification changes**

```bash
git add script/tests/package_release_tests.sh QrecsUITests/QrecsUITests.swift
git commit -m "test: verify compact player and night resource release"
```

Do not tag, merge `main`, or publish a GitHub release until the user approves this rebuilt app.
