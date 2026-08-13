#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
HELPERS_SCRIPT="$ROOT_DIR/script/build_and_run_helpers.sh"
FAILURES=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        fail "$message (expected '$expected', got '$actual')"
    fi
}

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qrecs-build-script-tests.XXXXXX")"
FAKE_BIN="$TEST_DIR/bin"
SIDE_EFFECTS="$TEST_DIR/side-effects"
mkdir -p "$FAKE_BIN"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

for command_name in pkill xcodebuild; do
    stub="$FAKE_BIN/$command_name"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$QRECS_TEST_SIDE_EFFECTS"\nexit 99\n' "$command_name" > "$stub"
    chmod +x "$stub"
done

assert_rejected_without_side_effects() {
    local description="$1"
    shift
    local status

    : > "$SIDE_EFFECTS"
    PATH="$FAKE_BIN:$PATH" QRECS_TEST_SIDE_EFFECTS="$SIDE_EFFECTS" \
        "$RUN_SCRIPT" "$@" >/dev/null 2>&1
    status=$?

    assert_equal "2" "$status" "$description exits with usage status"
    if [ -s "$SIDE_EFFECTS" ]; then
        fail "$description performed side effects: $(tr '\n' ' ' < "$SIDE_EFFECTS")"
    fi
}

assert_rejected_without_side_effects "invalid mode" --invalid
assert_rejected_without_side_effects "extra argument" run unexpected

if [ ! -f "$HELPERS_SCRIPT" ]; then
    fail "verification helper library is missing"
else
    # shellcheck source=../build_and_run_helpers.sh
    source "$HELPERS_SCRIPT"

    EXPECTED_BINARY="/tmp/Qrecs Test/Qrecs.app/Contents/MacOS/Qrecs"
    find_named_processes() {
        printf '101\n202\n'
    }
    process_command_line() {
        case "$1" in
            101) printf '/Applications/Other/Qrecs\n' ;;
            202) printf '%s --launched-by-launchservices\n' "$EXPECTED_BINARY" ;;
        esac
    }
    sleep_for_verify() {
        fail "verification slept despite finding the matching process"
    }

    matched_pid="$(wait_for_app_process "Qrecs" "$EXPECTED_BINARY" 3 0)"
    assert_equal "202" "$matched_pid" "verification ignores a same-name process with the wrong executable"

    FIND_CALLS="$TEST_DIR/find-calls"
    SLEEP_CALLS="$TEST_DIR/sleep-calls"
    : > "$FIND_CALLS"
    : > "$SLEEP_CALLS"
    find_named_processes() {
        printf 'find\n' >> "$FIND_CALLS"
        printf '101\n'
    }
    process_command_line() {
        printf '/Applications/Other/Qrecs\n'
    }
    sleep_for_verify() {
        printf 'sleep\n' >> "$SLEEP_CALLS"
    }

    if wait_for_app_process "Qrecs" "$EXPECTED_BINARY" 3 0 >/dev/null; then
        fail "verification accepted a same-name process with the wrong executable"
    fi
    assert_equal "3" "$(wc -l < "$FIND_CALLS" | tr -d ' ')" "verification bounds process polling"
    assert_equal "2" "$(wc -l < "$SLEEP_CALLS" | tr -d ' ')" "verification sleeps only between polling attempts"

    app_bundle_identifier() {
        printf 'com.heezya.Qrecs\n'
    }
    if ! app_bundle_matches_identifier "/tmp/Qrecs.app" "com.heezya.Qrecs"; then
        fail "verification rejected the expected bundle identifier"
    fi
    if app_bundle_matches_identifier "/tmp/Qrecs.app" "com.example.Impostor"; then
        fail "verification accepted the wrong bundle identifier"
    fi
fi

if [ "$FAILURES" -ne 0 ]; then
    printf '%s build/run regression test(s) failed\n' "$FAILURES" >&2
    exit 1
fi

printf 'All build/run regression tests passed\n'
