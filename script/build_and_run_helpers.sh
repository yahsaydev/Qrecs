#!/usr/bin/env bash

find_named_processes() {
    pgrep -x "$1" 2>/dev/null || true
}

process_command_line() {
    ps -ww -p "$1" -o command= 2>/dev/null || true
}

sleep_for_verify() {
    sleep "$1"
}

command_line_matches_app_binary() {
    local command_line="$1"
    local expected_binary="$2"

    while [ "${command_line# }" != "$command_line" ]; do
        command_line="${command_line# }"
    done

    case "$command_line" in
        "$expected_binary"|"$expected_binary "*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

wait_for_app_process() {
    local process_name="$1"
    local expected_binary="$2"
    local maximum_attempts="$3"
    local interval="$4"
    local attempt=1
    local pid
    local command_line

    while [ "$attempt" -le "$maximum_attempts" ]; do
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            command_line="$(process_command_line "$pid")"
            if command_line_matches_app_binary "$command_line" "$expected_binary"; then
                printf '%s\n' "$pid"
                return 0
            fi
        done <<EOF
$(find_named_processes "$process_name")
EOF

        if [ "$attempt" -lt "$maximum_attempts" ]; then
            sleep_for_verify "$interval"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

app_bundle_identifier() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

app_bundle_matches_identifier() {
    local app_bundle="$1"
    local expected_identifier="$2"
    local actual_identifier

    actual_identifier="$(app_bundle_identifier "$app_bundle")" || return 1
    [ "$actual_identifier" = "$expected_identifier" ]
}
