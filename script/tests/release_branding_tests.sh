#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Qrecs.xcodeproj/project.pbxproj"
ASSET_DIR="$ROOT_DIR/Qrecs/Resources/Assets.xcassets/AppIcon.appiconset"
DOC_ICON="$ROOT_DIR/docs/assets/qrecs-icon.png"
FAILURES=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

assert_project_setting_count() {
    local setting="$1"
    local expected_count="$2"
    local actual_count

    actual_count="$(grep -F -c -- "$setting" "$PROJECT_FILE" || true)"
    if [ "$actual_count" != "$expected_count" ]; then
        fail "expected $expected_count occurrences of '$setting', found $actual_count"
    fi
}

assert_png() {
    local path="$1"
    local expected_size="$2"
    local width
    local height
    local alpha

    if [ ! -f "$path" ]; then
        fail "missing PNG: ${path#"$ROOT_DIR/"}"
        return
    fi
    width="$(/usr/bin/sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
    height="$(/usr/bin/sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
    alpha="$(/usr/bin/sips -g hasAlpha "$path" 2>/dev/null | awk '/hasAlpha:/ { print $2 }')"
    if [ "$width" != "$expected_size" ] || [ "$height" != "$expected_size" ]; then
        fail "${path#"$ROOT_DIR/"} is ${width}x${height}, expected ${expected_size}x${expected_size}"
    fi
    if [ "$alpha" != "no" ]; then
        fail "${path#"$ROOT_DIR/"} must preserve an opaque background"
    fi
}

assert_project_setting_count 'MARKETING_VERSION = 0.1.1;' 2
assert_project_setting_count 'CURRENT_PROJECT_VERSION = 2;' 2
assert_project_setting_count 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' 2

if ! grep -F -- '?? "0.1.1"' "$ROOT_DIR/Qrecs/Features/Settings/SettingsView.swift" >/dev/null 2>&1; then
    fail "Settings version fallback is not 0.1.1"
fi

assert_png "$DOC_ICON" 2048

if [ ! -f "$ASSET_DIR/Contents.json" ]; then
    fail "missing AppIcon Contents.json"
else
    while IFS='|' read -r logical_size scale filename physical_size; do
        if ! /usr/bin/plutil -convert json -o - "$ASSET_DIR/Contents.json" 2>/dev/null | \
            /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)
size,scale,filename=sys.argv[1:]
assert any(i.get("idiom")=="mac" and i.get("size")==size and i.get("scale")==scale and i.get("filename")==filename for i in d["images"])' \
            "$logical_size" "$scale" "$filename"; then
            fail "Contents.json missing mac $logical_size $scale entry for $filename"
        fi
        assert_png "$ASSET_DIR/$filename" "$physical_size"
    done <<'EOF'
16x16|1x|appicon_16x16.png|16
16x16|2x|appicon_16x16@2x.png|32
32x32|1x|appicon_32x32.png|32
32x32|2x|appicon_32x32@2x.png|64
128x128|1x|appicon_128x128.png|128
128x128|2x|appicon_128x128@2x.png|256
256x256|1x|appicon_256x256.png|256
256x256|2x|appicon_256x256@2x.png|512
512x512|1x|appicon_512x512.png|512
512x512|2x|appicon_512x512@2x.png|1024
EOF
fi

if [ "$FAILURES" -ne 0 ]; then
    printf '%s release branding regression test(s) failed\n' "$FAILURES" >&2
    exit 1
fi

printf 'All release branding regression tests passed\n'
