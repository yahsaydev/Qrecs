#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="$ROOT_DIR/Qrecs/Resources/Ambient"
MODE="${1:-fetch}"

usage() {
    echo "usage: $0 [fetch|--verify]" >&2
}

verify_file() {
    local file_path="$1"
    local expected_hash="$2"
    local actual_hash
    actual_hash="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "error: SHA-256 mismatch for $(basename "$file_path")" >&2
        echo "expected: $expected_hash" >&2
        echo "actual:   $actual_hash" >&2
        return 1
    fi
}

NAMES=(fire birds rain waterfall)
URLS=(
    "https://cdn.freesound.org/previews/558/558967_9250976-hq.mp3"
    "https://cdn.freesound.org/previews/723/723913_2008500-hq.mp3"
    "https://cdn.freesound.org/previews/595/595717_2530992-hq.mp3"
    "https://cdn.freesound.org/previews/637/637082_9250976-hq.mp3"
)
HASHES=(
    "62ee6ffe5dbfa1f8a5bd50cd7cb5d28c7953659e1234847fd47bd0e33c4d7889"
    "9aebcb869cf37040c4588fc05d72bed197951aaa1beacb6874b379c69e379dbb"
    "c42458d0383b82d5b03e09650ae3db75368d14f51702acf28c8125a23eadfa73"
    "00ea8141c0c3cfb1b24477a91ba3f949081b8deb7aac9af188645cca3bcfd7b2"
)

case "$MODE" in
    --verify|verify)
        for index in "${!NAMES[@]}"; do
            verify_file "$DESTINATION/${NAMES[$index]}.mp3" "${HASHES[$index]}"
        done
        echo "Verified ${#NAMES[@]} ambient assets."
        exit 0
        ;;
    fetch)
        ;;
    *)
        usage
        exit 2
        ;;
esac

/bin/mkdir -p "$DESTINATION"
STAGING_DIR="$(/usr/bin/mktemp -d "$DESTINATION/.fetch.XXXXXX")"
cleanup() {
    /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

for index in "${!NAMES[@]}"; do
    staged_file="$STAGING_DIR/${NAMES[$index]}.mp3"
    /usr/bin/curl --fail --location --silent --show-error \
        --retry 3 --output "$staged_file" "${URLS[$index]}"
    verify_file "$staged_file" "${HASHES[$index]}"
done

for index in "${!NAMES[@]}"; do
    /bin/chmod 0644 "$STAGING_DIR/${NAMES[$index]}.mp3"
    /bin/mv -f "$STAGING_DIR/${NAMES[$index]}.mp3" "$DESTINATION/${NAMES[$index]}.mp3"
done

echo "Fetched and verified ${#NAMES[@]} ambient assets."
