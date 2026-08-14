#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/script/package_release.sh"
HELPERS_SCRIPT="$ROOT_DIR/script/package_release_helpers.sh"
FAILURES=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

assert_contains() {
    local file="$1"
    local expected="$2"
    local message="$3"

    if ! grep -F -- "$expected" "$file" >/dev/null 2>&1; then
        fail "$message"
    fi
}

if [ ! -x "$RELEASE_SCRIPT" ]; then
    fail "release packaging script is missing or not executable"
else
    assert_contains "$RELEASE_SCRIPT" '-configuration Release' "release packaging does not select Release configuration"
    assert_contains "$RELEASE_SCRIPT" '-disableAutomaticPackageResolution' "release packaging does not disable automatic package resolution"
    assert_contains "$RELEASE_SCRIPT" '-onlyUsePackageVersionsFromResolvedFile' "release packaging does not enforce Package.resolved"
    assert_contains "$RELEASE_SCRIPT" '-packageCachePath' "release packaging does not keep Swift package caches project-local"
    assert_contains "$RELEASE_SCRIPT" 'CFFIXED_USER_HOME="$BUILD_ROOT/Home" xcodebuild' "release packaging does not isolate Xcode user caches"
    assert_contains "$RELEASE_SCRIPT" 'CODE_SIGN_IDENTITY=-' "release build does not request ad-hoc signing"
    assert_contains "$RELEASE_SCRIPT" 'ARCHS="arm64 x86_64"' "release build does not require a universal binary"
    assert_contains "$RELEASE_SCRIPT" '--entitlements "$ROOT_DIR/Qrecs/Qrecs.entitlements"' "release signing does not use the production entitlements"
    if grep -F -- '--preserve-metadata=' "$RELEASE_SCRIPT" >/dev/null 2>&1; then
        fail "release signing preserves Xcode-injected debug entitlements"
    fi
    assert_contains "$RELEASE_SCRIPT" '/usr/bin/codesign --verify --deep --strict' "release bundle signature is not deeply and strictly verified"
    assert_contains "$RELEASE_SCRIPT" 'validate_release_entitlements "$STAGED_APP"' "release packaging does not validate production entitlements"
    assert_contains "$RELEASE_SCRIPT" 'VERSION="0.1.1"' "release version is not pinned to v0.1.1"
    assert_contains "$RELEASE_SCRIPT" 'Qrecs-0.1.1-macOS.zip' "release archive name is not pinned to v0.1.1"
    assert_contains "$RELEASE_SCRIPT" 'validate_release_icon "$STAGED_APP"' "release packaging does not validate the compiled bundle icon"
fi

if [ ! -f "$HELPERS_SCRIPT" ]; then
    fail "release packaging helper library is missing"
else
    # shellcheck source=../package_release_helpers.sh
    source "$HELPERS_SCRIPT"

    TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qrecs-release-script-tests.XXXXXX")"
    trap 'rm -rf "$TEST_DIR"' EXIT
    APP_BUNDLE="$TEST_DIR/Qrecs.app"
    mkdir -p "$APP_BUNDLE/Contents/PlugIns/QrecsTests.xctest" "$APP_BUNDLE/Contents/MacOS"
    : > "$APP_BUNDLE/Contents/MacOS/Qrecs.debug.dylib"

    cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
EOF

    mkdir -p "$APP_BUNDLE/Contents/Resources"
    printf 'compiled icon fixture\n' > "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

    if ! validate_release_metadata "$APP_BUNDLE" "0.1.1" "15.0" >/dev/null; then
        fail "valid v0.1.1/macOS 15 metadata was rejected"
    fi
    if validate_release_metadata "$APP_BUNDLE" "0.2.0" "15.0" >/dev/null 2>&1; then
        fail "incorrect bundle version was accepted"
    fi
    if validate_release_metadata "$APP_BUNDLE" "0.1.1" "14.0" >/dev/null 2>&1; then
        fail "incorrect deployment target was accepted"
    fi
    if ! validate_release_icon "$APP_BUNDLE" >/dev/null; then
        fail "valid compiled bundle icon was rejected"
    fi
    rm "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    if validate_release_icon "$APP_BUNDLE" >/dev/null 2>&1; then
        fail "missing compiled bundle icon was accepted"
    fi
    printf 'compiled icon fixture\n' > "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

    remove_nonrelease_artifacts "$APP_BUNDLE"
    if find "$APP_BUNDLE" \( -name '*.xctest' -o -name '*.debug.dylib' -o -name '*.dSYM' \) -print -quit | grep . >/dev/null; then
        fail "test or debug artifacts remained in the release app"
    fi
    if ! assert_no_nonrelease_artifacts "$APP_BUNDLE" >/dev/null; then
        fail "clean release app was rejected"
    fi

    entitlement_diagnostics='Executable=/tmp/Qrecs.app/Contents/MacOS/Qrecs
warning: entitlement output follows
<?xml version="1.0"?><plist><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>'
    extracted_entitlements="$(printf '%s\n' "$entitlement_diagnostics" | extract_entitlements_plist)"
    case "$extracted_entitlements" in
        '<?xml version="1.0"?>'*) ;;
        *) fail "codesign diagnostics were not removed from the entitlement plist" ;;
    esac

    release_signed_entitlements() {
        printf '<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n'
    }
    if validate_release_entitlements "$APP_BUNDLE" >/dev/null 2>&1; then
        fail "get-task-allow debug entitlement was accepted"
    fi
    release_signed_entitlements() {
        printf '<plist><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/></dict></plist>\n'
    }
    if ! validate_release_entitlements "$APP_BUNDLE" >/dev/null; then
        fail "production entitlements were rejected"
    fi
    release_signed_entitlements() {
        printf '<plist><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>\n'
    }
    if validate_release_entitlements "$APP_BUNDLE" >/dev/null 2>&1; then
        fail "release entitlements without network client access were accepted"
    fi
    release_signed_entitlements() {
        printf '<plist><dict><key>com.apple.security.network.client</key><true/></dict></plist>\n'
    }
    if validate_release_entitlements "$APP_BUNDLE" >/dev/null 2>&1; then
        fail "release entitlements without the app sandbox were accepted"
    fi

    release_binary_architectures() {
        printf 'arm64 x86_64\n'
    }
    if ! validate_release_architectures "$APP_BUNDLE/Contents/MacOS/Qrecs" "arm64 x86_64" >/dev/null; then
        fail "universal release binary was rejected"
    fi
    release_binary_architectures() {
        printf 'arm64\n'
    }
    if validate_release_architectures "$APP_BUNDLE/Contents/MacOS/Qrecs" "arm64 x86_64" >/dev/null 2>&1; then
        fail "thin release binary was accepted"
    fi

    printf 'qrecs release fixture\n' > "$TEST_DIR/Qrecs-0.1.1-macOS.zip"
    write_sha256 "$TEST_DIR/Qrecs-0.1.1-macOS.zip" "$TEST_DIR/Qrecs-0.1.1-macOS.zip.sha256"
    expected_checksum="$(shasum -a 256 "$TEST_DIR/Qrecs-0.1.1-macOS.zip" | awk '{print $1}')  Qrecs-0.1.1-macOS.zip"
    actual_checksum="$(tr -d '\n' < "$TEST_DIR/Qrecs-0.1.1-macOS.zip.sha256")"
    if [ "$actual_checksum" != "$expected_checksum" ]; then
        fail "SHA-256 manifest is not deterministic or portable"
    fi

    printf 'stable archive contents\n' > "$APP_BUNDLE/Contents/fixture.txt"
    create_release_archive "$APP_BUNDLE" "$TEST_DIR/first.zip"
    touch -t 203012312359 "$APP_BUNDLE/Contents/fixture.txt"
    create_release_archive "$APP_BUNDLE" "$TEST_DIR/second.zip"
    if ! cmp -s "$TEST_DIR/first.zip" "$TEST_DIR/second.zip"; then
        fail "unchanged release bundle did not produce a reproducible ZIP"
    fi
    TZ=UTC create_release_archive "$APP_BUNDLE" "$TEST_DIR/utc.zip"
    TZ=Pacific/Honolulu create_release_archive "$APP_BUNDLE" "$TEST_DIR/honolulu.zip"
    if ! cmp -s "$TEST_DIR/utc.zip" "$TEST_DIR/honolulu.zip"; then
        fail "release ZIP changes with the host time zone"
    fi
fi

if [ "$FAILURES" -ne 0 ]; then
    printf '%s release packaging regression test(s) failed\n' "$FAILURES" >&2
    exit 1
fi

printf 'All release packaging regression tests passed\n'
