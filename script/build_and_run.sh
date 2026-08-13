#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Qrecs"
BUNDLE_ID="com.heezya.Qrecs"

usage() {
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

if [ "$#" -gt 1 ]; then
    usage
    exit 2
fi

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        ;;
    *)
        usage
        exit 2
        ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Qrecs.xcodeproj"
DERIVED_DATA="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# shellcheck source=build_and_run_helpers.sh
source "$ROOT_DIR/script/build_and_run_helpers.sh"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    build

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        if ! app_bundle_matches_identifier "$APP_BUNDLE" "$BUNDLE_ID"; then
            echo "error: built app bundle identifier does not match $BUNDLE_ID" >&2
            exit 1
        fi
        open_app
        if ! wait_for_app_process "$APP_NAME" "$APP_BINARY" 20 0.25 >/dev/null; then
            echo "error: $APP_NAME did not launch from $APP_BINARY" >&2
            exit 1
        fi
        ;;
    *)
        usage
        exit 2
        ;;
esac
