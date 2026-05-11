#!/usr/bin/env bats
# Smoke tests for sideapt. Network-using tests require apt sources to be reachable.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SIDEAPT="$REPO_ROOT/bin/sideapt"
    export SIDEAPT_ROOT="$(mktemp -d -t sideapt-test-XXXXXX)"
}

teardown() {
    [[ -n "${SIDEAPT_ROOT:-}" && "$SIDEAPT_ROOT" == /tmp/* ]] && rm -rf "$SIDEAPT_ROOT"
}

@test "help is shown for unknown command" {
    run "$SIDEAPT" wat
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command"* ]]
}

@test "help subcommand prints usage" {
    run "$SIDEAPT" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"sideapt"* ]]
    [[ "$output" == *"install"* ]]
}

@test "init creates expected layout" {
    run "$SIDEAPT" init
    [ "$status" -eq 0 ]
    [ -f "$SIDEAPT_ROOT/apt/apt.conf" ]
    [ -d "$SIDEAPT_ROOT/usr" ]
    [ -d "$SIDEAPT_ROOT/db/files" ]
    [ -f "$SIDEAPT_ROOT/db/installed.tsv" ]
    [ -d "$SIDEAPT_ROOT/var/cache/sideapt/archives" ]
}

@test "init writes APT::Sandbox::User for current user" {
    "$SIDEAPT" init
    grep -q "APT::Sandbox::User      \"$(id -un)\"" "$SIDEAPT_ROOT/apt/apt.conf"
}

@test "env emits PATH/LD_LIBRARY_PATH exports" {
    "$SIDEAPT" init
    run "$SIDEAPT" env
    [ "$status" -eq 0 ]
    [[ "$output" == *"export PATH=\"$SIDEAPT_ROOT/usr/bin"* ]]
    [[ "$output" == *"export LD_LIBRARY_PATH=\""* ]]
    [[ "$output" == *"export SIDEAPT_ROOT=\"$SIDEAPT_ROOT\""* ]]
}

@test "eval of env actually sets PATH" {
    "$SIDEAPT" init
    eval "$("$SIDEAPT" env)"
    [[ "$PATH" == "$SIDEAPT_ROOT/usr/bin:$SIDEAPT_ROOT/usr/sbin:"* ]]
    [[ "$SIDEAPT_ROOT" == "$SIDEAPT_ROOT" ]]
}

@test "list says nothing installed on a fresh root" {
    "$SIDEAPT" init
    run "$SIDEAPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"no packages installed"* ]]
}

@test "commands fail before init" {
    run "$SIDEAPT" list
    [ "$status" -ne 0 ]
    [[ "$output" == *"not initialized"* ]]
}

@test "clean is a no-op on empty cache" {
    "$SIDEAPT" init
    run "$SIDEAPT" clean
    [ "$status" -eq 0 ]
}

@test "remove of unknown package is a soft warning" {
    "$SIDEAPT" init
    run "$SIDEAPT" remove definitely-not-installed
    [ "$status" -eq 0 ]
    [[ "$output" == *"not installed"* ]]
}
