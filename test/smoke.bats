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

# Tests below skip cmd_init's hard apt-get/gpg dependency by faking the
# layout, so they can run on any host (CI, mac, restricted containers).
fake_init() {
    mkdir -p \
        "$SIDEAPT_ROOT/apt/etc/apt/sources.list.d" \
        "$SIDEAPT_ROOT/apt/etc/apt/keyrings" \
        "$SIDEAPT_ROOT/db/files" \
        "$SIDEAPT_ROOT/var/cache/sideapt/archives"
    touch "$SIDEAPT_ROOT/db/installed.tsv" "$SIDEAPT_ROOT/apt/apt.conf"
}

@test "init creates keyrings directory" {
    run "$SIDEAPT" init
    if [ "$status" -ne 0 ]; then skip "init needs apt-get on host"; fi
    [ -d "$SIDEAPT_ROOT/apt/etc/apt/keyrings" ]
}

@test "help lists the new repo subcommands" {
    run "$SIDEAPT" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"add-repo"* ]]
    [[ "$output" == *"add-key"* ]]
    [[ "$output" == *"list-repos"* ]]
    [[ "$output" == *"remove-repo"* ]]
}

@test "add-repo (raw form) writes a .list file" {
    fake_init
    run "$SIDEAPT" add-repo myrepo 'deb http://example.com/ubuntu jammy main'
    [ "$status" -eq 0 ]
    [ -f "$SIDEAPT_ROOT/apt/etc/apt/sources.list.d/myrepo.list" ]
    run cat "$SIDEAPT_ROOT/apt/etc/apt/sources.list.d/myrepo.list"
    [[ "$output" == "deb http://example.com/ubuntu jammy main" ]]
}

@test "add-repo rejects an invalid name" {
    fake_init
    run "$SIDEAPT" add-repo 'bad name' 'deb http://x/ y z'
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid repo name"* ]]
}

@test "add-repo rejects a non-deb line" {
    fake_init
    run "$SIDEAPT" add-repo other 'something else'
    [ "$status" -ne 0 ]
    [[ "$output" == *"deb"* ]]
}

@test "add-repo rejects duplicates" {
    fake_init
    "$SIDEAPT" add-repo myrepo 'deb http://example.com/ubuntu jammy main'
    run "$SIDEAPT" add-repo myrepo 'deb http://example.com/ubuntu jammy main'
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "add-repo rejects a bad ppa spec" {
    fake_init
    run "$SIDEAPT" add-repo 'ppa:onlyuser'
    [ "$status" -ne 0 ]
    [[ "$output" == *"PPA"* ]]
}

@test "add-repo auto-attaches signed-by= when a matching key exists" {
    fake_init
    : > "$SIDEAPT_ROOT/apt/etc/apt/keyrings/withkey.gpg"
    run "$SIDEAPT" add-repo withkey 'deb http://example.com/ubuntu jammy main'
    [ "$status" -eq 0 ]
    run cat "$SIDEAPT_ROOT/apt/etc/apt/sources.list.d/withkey.list"
    [[ "$output" == *"signed-by=$SIDEAPT_ROOT/apt/etc/apt/keyrings/withkey.gpg"* ]]
}

@test "add-repo splices signed-by= into an existing [opts] block" {
    fake_init
    : > "$SIDEAPT_ROOT/apt/etc/apt/keyrings/withopts.gpg"
    run "$SIDEAPT" add-repo withopts 'deb [arch=amd64] http://example.com/ubuntu jammy main'
    [ "$status" -eq 0 ]
    run cat "$SIDEAPT_ROOT/apt/etc/apt/sources.list.d/withopts.list"
    [[ "$output" == *"signed-by=$SIDEAPT_ROOT/apt/etc/apt/keyrings/withopts.gpg"* ]]
    [[ "$output" == *"arch=amd64"* ]]
}

@test "list-repos shows configured entries" {
    fake_init
    "$SIDEAPT" add-repo myrepo 'deb http://example.com/ubuntu jammy main'
    run "$SIDEAPT" list-repos
    [ "$status" -eq 0 ]
    [[ "$output" == *"myrepo.list"* ]]
    [[ "$output" == *"example.com"* ]]
}

@test "list-repos says nothing on a fresh root" {
    fake_init
    run "$SIDEAPT" list-repos
    [ "$status" -eq 0 ]
    [[ "$output" == *"no repositories"* ]]
}

@test "remove-repo deletes the .list and matching key" {
    fake_init
    "$SIDEAPT" add-repo myrepo 'deb http://example.com/ubuntu jammy main'
    : > "$SIDEAPT_ROOT/apt/etc/apt/keyrings/myrepo.gpg"
    run "$SIDEAPT" remove-repo myrepo
    [ "$status" -eq 0 ]
    [ ! -f "$SIDEAPT_ROOT/apt/etc/apt/sources.list.d/myrepo.list" ]
    [ ! -f "$SIDEAPT_ROOT/apt/etc/apt/keyrings/myrepo.gpg" ]
}

@test "remove-repo of unknown name is a soft warning" {
    fake_init
    run "$SIDEAPT" remove-repo nope
    [ "$status" -eq 0 ]
    [[ "$output" == *"no such repo"* ]]
}

# ---- self-update ----

@test "help mentions self-update" {
    run "$SIDEAPT" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"self-update"* ]]
}

@test "self-update fails fast on unreachable URL" {
    command -v curl >/dev/null || command -v wget >/dev/null || skip "needs curl or wget"
    run env SIDEAPT_SELF_UPDATE_URL="http://127.0.0.1:1/nope" \
            SIDEAPT_SELF_UPDATE_TIMEOUT=1 \
            "$SIDEAPT" self-update
    [ "$status" -ne 0 ]
    [[ "$output" == *"download failed"* ]]
}

@test "self-update rejects a payload that doesn't look like sideapt" {
    command -v curl >/dev/null || skip "needs curl (for file:// fetch)"
    local bogus="$SIDEAPT_ROOT/bogus"
    mkdir -p "$SIDEAPT_ROOT"
    printf 'hello world\n' > "$bogus"
    run env SIDEAPT_SELF_UPDATE_URL="file://$bogus" \
            SIDEAPT_SELF_UPDATE_TIMEOUT=2 \
            "$SIDEAPT" self-update
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not look like sideapt"* ]]
}

@test "SIDEAPT_SKIP_UPDATE_CHECK suppresses background update check" {
    fake_init
    # Even with an obviously broken URL, no fetch attempt should happen,
    # and no last-update-check marker should be created.
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 \
            SIDEAPT_SELF_UPDATE_URL="http://127.0.0.1:1/nope" \
            SIDEAPT_SELF_UPDATE_TIMEOUT=1 \
            "$SIDEAPT" list
    [ "$status" -eq 0 ]
    [ ! -f "$SIDEAPT_ROOT/db/last-update-check" ]
}

# ---- info ----

@test "help mentions info and orphans" {
    run "$SIDEAPT" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"info "* ]]
    [[ "$output" == *"orphans"* ]]
}

@test "info on a fake installed package shows fields and files" {
    fake_init
    printf 'jq\t1.6-2\t2026-05-11T00:00:00+00:00\trequested\n' > "$SIDEAPT_ROOT/db/installed.tsv"
    printf 'usr/bin/jq\nusr/share/doc/jq/copyright\n' > "$SIDEAPT_ROOT/db/files/jq.list"
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 "$SIDEAPT" info jq
    [ "$status" -eq 0 ]
    [[ "$output" == *"Package:   jq"* ]]
    [[ "$output" == *"Version:   1.6-2"* ]]
    [[ "$output" == *"Type:      requested"* ]]
    [[ "$output" == *"Files:     2"* ]]
    [[ "$output" == *"/usr/bin/jq"* ]]
}

@test "info on an unknown package fails softly" {
    fake_init
    : > "$SIDEAPT_ROOT/db/installed.tsv"
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 "$SIDEAPT" info nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"not installed in sideapt: nope"* ]]
}

# ---- orphans ----

@test "orphans says nothing on an empty installed.tsv" {
    fake_init
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 "$SIDEAPT" orphans
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing installed"* ]]
}

@test "orphans treats every auto package as orphan when no requested anchors" {
    fake_init
    {
        printf 'libfoo\t1.0\t2026-05-11T00:00:00+00:00\tauto\n'
        printf 'libbar\t2.0\t2026-05-11T00:00:00+00:00\tauto\n'
    } > "$SIDEAPT_ROOT/db/installed.tsv"
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 "$SIDEAPT" orphans
    [ "$status" -eq 0 ]
    [[ "$output" == *"libfoo"* ]]
    [[ "$output" == *"libbar"* ]]
}

@test "orphans says 'no auto-installed' when everything is requested" {
    fake_init
    printf 'jq\t1.6-2\t2026-05-11T00:00:00+00:00\trequested\n' > "$SIDEAPT_ROOT/db/installed.tsv"
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 "$SIDEAPT" orphans
    [ "$status" -eq 0 ]
    [[ "$output" == *"no auto-installed packages"* ]]
}

@test "orphans rejects an unknown flag" {
    fake_init
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 "$SIDEAPT" orphans --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

# ---- lockfile ----

@test "second sideapt blocks while first holds the write lock" {
    command -v flock >/dev/null || skip "flock not available on this host"
    fake_init
    # Hold the lock from a background shell.
    (
        exec 9>"$SIDEAPT_ROOT/db/.lock"
        flock -x 9
        sleep 2
    ) &
    local holder=$!
    sleep 0.2
    SECONDS=0
    run env SIDEAPT_SKIP_UPDATE_CHECK=1 SIDEAPT_LOCK_WAIT=1 "$SIDEAPT" clean
    local elapsed=$SECONDS
    wait "$holder" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"another sideapt instance"* ]]
    # Should have waited ~1s, not 0 and not full 2s.
    [ "$elapsed" -ge 1 ]
}
