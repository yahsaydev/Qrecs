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

FILES=(fire.mp3 birds.mp3 rain.mp3 waterfall.mp3 night.wav)
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
    "9600c27a8c4f106530e53a7ca7e5af76b2cc657a366ae324ae79e68df4a7c98d"
)

case "$MODE" in
    --verify|verify)
        for index in "${!FILES[@]}"; do
            verify_file "$DESTINATION/${FILES[$index]}" "${HASHES[$index]}"
        done
        echo "Verified ${#FILES[@]} ambient assets."
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
if [[ ! -f "$DESTINATION/night.wav" ]]; then
    echo "error: night.wav is manually sourced from Freesound item 662882 and must already exist" >&2
    exit 1
fi
verify_file "$DESTINATION/night.wav" "${HASHES[4]}"

STAGING_DIR="$(/usr/bin/mktemp -d "$DESTINATION/.fetch.XXXXXX")"
cleanup() {
    /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

for index in "${!URLS[@]}"; do
    staged_file="$STAGING_DIR/${FILES[$index]}"
    /usr/bin/curl --fail --location --silent --show-error \
        --retry 3 --output "$staged_file" "${URLS[$index]}"
    verify_file "$staged_file" "${HASHES[$index]}"
done

for index in "${!URLS[@]}"; do
    /bin/chmod 0644 "$STAGING_DIR/${FILES[$index]}"
    /bin/mv -f "$STAGING_DIR/${FILES[$index]}" "$DESTINATION/${FILES[$index]}"
done

echo "Fetched 4 remote assets and verified ${#FILES[@]} ambient assets; night.wav is manually sourced."
