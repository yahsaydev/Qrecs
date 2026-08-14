#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Qrecs"
VERSION="0.1.1"
MINIMUM_MACOS="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Qrecs.xcodeproj"
BUILD_ROOT="$ROOT_DIR/.release-build"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
STAGING_DIR="$BUILD_ROOT/staging"
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
OUTPUT_DIR="${QRECS_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
ARCHIVE="$OUTPUT_DIR/Qrecs-0.1.1-macOS.zip"
CHECKSUM="$ARCHIVE.sha256"
PACKAGE_SUPPORT_CACHE="$BUILD_ROOT/PackageCache"

# shellcheck source=package_release_helpers.sh
source "$ROOT_DIR/script/package_release_helpers.sh"

if [ -d "$ROOT_DIR/DerivedData/SourcePackages/checkouts" ]; then
    PACKAGE_CACHE="$ROOT_DIR/DerivedData/SourcePackages"
else
    PACKAGE_CACHE="$BUILD_ROOT/SourcePackages"
fi

if [ ! -d "$PACKAGE_CACHE/checkouts" ]; then
    CFFIXED_USER_HOME="$BUILD_ROOT/Home" xcodebuild \
        -resolvePackageDependencies \
        -project "$PROJECT_PATH" \
        -scheme "$APP_NAME" \
        -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
        -packageCachePath "$PACKAGE_SUPPORT_CACHE" \
        -onlyUsePackageVersionsFromResolvedFile
fi

CFFIXED_USER_HOME="$BUILD_ROOT/Home" xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
    -packageCachePath "$PACKAGE_SUPPORT_CACHE" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    DEVELOPMENT_TEAM= \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
    printf 'error: Release app was not produced at %s\n' "$BUILT_APP" >&2
    exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$OUTPUT_DIR"
/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"

remove_nonrelease_artifacts "$STAGED_APP"
assert_no_nonrelease_artifacts "$STAGED_APP"
validate_release_metadata "$STAGED_APP" "$VERSION" "$MINIMUM_MACOS"
validate_release_icon "$STAGED_APP"
validate_release_architectures "$STAGED_APP/Contents/MacOS/$APP_NAME" "arm64 x86_64"

/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --deep --sign - --options runtime --entitlements "$ROOT_DIR/Qrecs/Qrecs.entitlements" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
validate_release_entitlements "$STAGED_APP"

rm -f "$ARCHIVE" "$CHECKSUM"
create_release_archive "$STAGED_APP" "$ARCHIVE"
write_sha256 "$ARCHIVE" "$CHECKSUM"

printf 'Created %s\n' "$ARCHIVE"
printf 'Created %s\n' "$CHECKSUM"
