#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FETCH_SCRIPT="$ROOT_DIR/script/fetch_ambient_assets.sh"
EXPECTED_NIGHT_HASH="9600c27a8c4f106530e53a7ca7e5af76b2cc657a366ae324ae79e68df4a7c98d"
FAILURES=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

verification_output="$("$FETCH_SCRIPT" --verify 2>&1)" || fail "ambient asset verification failed"
if [[ "$verification_output" != *"Verified 5 ambient assets."* ]]; then
    fail "ambient verification did not report all five assets"
fi
if ! grep -F -- 'night.wav' "$FETCH_SCRIPT" >/dev/null 2>&1; then
    fail "ambient verification does not require night.wav"
fi
if ! grep -F -- "$EXPECTED_NIGHT_HASH" "$FETCH_SCRIPT" >/dev/null 2>&1; then
    fail "ambient verification does not pin the night asset hash"
fi

if [ "$FAILURES" -ne 0 ]; then
    printf '%s ambient asset regression test(s) failed\n' "$FAILURES" >&2
    exit 1
fi

printf 'All ambient asset regression tests passed\n'
