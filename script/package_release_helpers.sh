#!/usr/bin/env bash

release_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

validate_release_metadata() {
    local app_bundle="$1"
    local expected_version="$2"
    local expected_minimum_macos="$3"
    local actual_version
    local actual_minimum_macos

    actual_version="$(release_plist_value "$app_bundle" CFBundleShortVersionString)" || {
        printf 'error: missing CFBundleShortVersionString in %s\n' "$app_bundle" >&2
        return 1
    }
    actual_minimum_macos="$(release_plist_value "$app_bundle" LSMinimumSystemVersion)" || {
        printf 'error: missing LSMinimumSystemVersion in %s\n' "$app_bundle" >&2
        return 1
    }

    if [ "$actual_version" != "$expected_version" ]; then
        printf 'error: expected version %s, found %s\n' "$expected_version" "$actual_version" >&2
        return 1
    fi
    if [ "$actual_minimum_macos" != "$expected_minimum_macos" ]; then
        printf 'error: expected minimum macOS %s, found %s\n' "$expected_minimum_macos" "$actual_minimum_macos" >&2
        return 1
    fi
}

remove_nonrelease_artifacts() {
    local app_bundle="$1"
    local artifact

    while IFS= read -r artifact; do
        rm -rf "$artifact"
    done < <(find "$app_bundle" \( -name '*.xctest' -o -name '*.xctestplugin' -o -name '*.dSYM' \) -print)
    find "$app_bundle" -type f -name '*.debug.dylib' -delete
}

assert_no_nonrelease_artifacts() {
    local app_bundle="$1"
    local artifact

    artifact="$(find "$app_bundle" \( -name '*.xctest' -o -name '*.xctestplugin' -o -name '*.dSYM' -o -name '*.debug.dylib' \) -print -quit)"
    if [ -n "$artifact" ]; then
        printf 'error: non-release artifact remains: %s\n' "$artifact" >&2
        return 1
    fi
}

extract_entitlements_plist() {
    sed -n '/^<?xml /,$p'
}

release_signed_entitlements() {
    local codesign_output

    codesign_output="$(/usr/bin/codesign -d --entitlements :- "$1" 2>&1)" || return 1
    printf '%s\n' "$codesign_output" | extract_entitlements_plist
}

release_entitlement_is_true() {
    local entitlements="$1"
    local escaped_key_path="$2"
    local value

    value="$(printf '%s\n' "$entitlements" | /usr/bin/plutil -extract "$escaped_key_path" raw -o - - 2>/dev/null)" || return 1
    [ "$value" = "true" ]
}

validate_release_entitlements() {
    local app_bundle="$1"
    local entitlements

    entitlements="$(release_signed_entitlements "$app_bundle")" || return 1
    case "$entitlements" in
        *com.apple.security.get-task-allow*)
            printf 'error: debug get-task-allow entitlement is present\n' >&2
            return 1
            ;;
    esac
    if ! release_entitlement_is_true "$entitlements" 'com\.apple\.security\.app-sandbox'; then
        printf 'error: required app sandbox entitlement is missing or false\n' >&2
        return 1
    fi
    if ! release_entitlement_is_true "$entitlements" 'com\.apple\.security\.network\.client'; then
        printf 'error: required network client entitlement is missing or false\n' >&2
        return 1
    fi
}

release_binary_architectures() {
    /usr/bin/lipo -archs "$1"
}

validate_release_architectures() {
    local binary="$1"
    local expected_architectures="$2"
    local actual_architectures
    local architecture

    actual_architectures="$(release_binary_architectures "$binary")" || return 1
    for architecture in $expected_architectures; do
        case " $actual_architectures " in
            *" $architecture "*) ;;
            *)
                printf 'error: release binary is missing %s (found: %s)\n' "$architecture" "$actual_architectures" >&2
                return 1
                ;;
        esac
    done
}

normalize_release_timestamps() {
    TZ=UTC find "$1" -exec touch -h -t 202601010000 {} +
}

create_release_archive() {
    local app_bundle="$1"
    local archive="$2"

    normalize_release_timestamps "$app_bundle"
    rm -f "$archive"
    TZ=UTC COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$app_bundle" "$archive"
}

write_sha256() {
    local archive="$1"
    local manifest="$2"
    local archive_directory
    local archive_name

    archive_directory="$(cd "$(dirname "$archive")" && pwd)"
    archive_name="$(basename "$archive")"
    (cd "$archive_directory" && shasum -a 256 "$archive_name") > "$manifest"
}
