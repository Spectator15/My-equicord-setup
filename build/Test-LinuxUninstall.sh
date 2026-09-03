#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Disposable fixtures only. Mock boundaries never patch or close a real Discord.
# SC2034: fixture globals are consumed by the separately sourced release.
# shellcheck disable=SC2317,SC2329,SC2034
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
release="$repo_root/Equicord-Linux.sh"

fixture() {
    local format=${1:-native}
    export HOME="$case_root/home données with spaces"
    export XDG_DATA_HOME="$HOME/data" XDG_STATE_HOME="$HOME/state" XDG_CONFIG_HOME="$HOME/config" XDG_CACHE_HOME="$HOME/cache"
    export MES_TEST_MODE=1 MES_NONINTERACTIVE=1 MES_ASSUME_YES=1 MES_SKIP_PROCESS_MANAGEMENT=1
    init_paths
    make_manager_directories
    mkdir -p "$WORKSPACE/src/userplugins" "$WORKSPACE/dist/desktop"
    git init -q "$WORKSPACE"
    git -C "$WORKSPACE" config user.name Test
    git -C "$WORKSPACE" config user.email test@example.invalid
    git -C "$WORKSPACE" remote add origin "$EQUICORD_REMOTE"
    printf '{"packageManager":"pnpm@11.22.0"}\n' > "$WORKSPACE/package.json"
    printf 'lockfileVersion: 9\n' > "$WORKSPACE/pnpm-lock.yaml"
    printf 'src/userplugins/\nnode_modules/\ndist/\n' > "$WORKSPACE/.gitignore"
    printf '// fixture\n' > "$WORKSPACE/src/tracked.ts"
    git -C "$WORKSPACE" add .
    git -C "$WORKSPACE" commit -qm fixture
    write_owner_marker
    extract_embedded_plugins "$WORKSPACE/src/userplugins"
    local target="$HOME/clients/Discord" resources app=''
    if [[ $format == flatpak ]]; then
        app=com.discordapp.Discord
        target="$HOME/.var/app/$app/config/discord"
        resources="$target/app-1.2.3/resources"
    elif [[ $format == system-electron ]]; then resources=$target
    else resources="$target/resources"
    fi
    mkdir -p "$resources"
    # These arrays are consumed by the sourced release functions.
    # shellcheck disable=SC2034
    DISCORD_PATHS=("$target"); DISCORD_RESOURCE_DIRS=("$resources"); DISCORD_BRANCHES=(stable)
    # shellcheck disable=SC2034
    DISCORD_FORMATS=("$format"); DISCORD_APP_IDS=("$app"); DISCORD_STATUSES=(injected); SELECTED_TARGET_INDEX=0
    export MES_DISCORD_SEARCH_ROOTS="$HOME/clients"
    node - "$resources" "$WORKSPACE/dist/desktop" <<'JS'
const fs = require("node:fs");
const [root, expected] = process.argv.slice(2);
function archive(files, contents, minimum) {
    const json = Buffer.from(JSON.stringify({files}));
    const aligned = (json.length + 3) & ~3;
    const out = Buffer.alloc(Math.max(minimum, aligned + 16 + Buffer.byteLength(contents)));
    [4, aligned + 8, aligned + 4, json.length].forEach((n, i) => out.writeUInt32LE(n, i * 4));
    json.copy(out, 16); Buffer.from(contents).copy(out, aligned + 16);
    return out;
}
const original = archive({"package.json": {size: 0, offset: "0"}, app_bootstrap: {files: {}}, common: {files: {}}}, "", 8192);
fs.writeFileSync(root + "/_app.asar", original);
const code = `require(${JSON.stringify(expected)})`;
const packageJson = '{\n\t"name": "discord",\n\t"main": "index.js"\n}';
const loader = archive({"index.js": {size: Buffer.byteLength(code), offset: "0"}, "package.json": {size: packageJson.length, offset: String(Buffer.byteLength(code))}}, code + packageJson, 0);
fs.writeFileSync(root + "/app.asar", loader);
JS
    [[ $format != system-electron ]] || mkdir -p "$resources/_app.asar.unpacked"
    write_state_manifest success ''
    # Default removal mock uses the same filesystem contract as official Equilotl.
    execute_selected_injector() {
        [[ $1 == uninstall ]]
        printf '%s\n' "$1" > "$case_root/injector-action"
        restore_fixture_discord
    }
}

restore_fixture_discord() {
    local resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]}
    mv -f -- "$resources/_app.asar" "$resources/app.asar"
    if [[ -d $resources/_app.asar.unpacked ]]; then mv -- "$resources/_app.asar.unpacked" "$resources/app.asar.unpacked"; fi
}

must_fail() {
    if "$@"; then printf 'Expected failure: %s\n' "$*" >&2; return 1; fi
}

assert_removed() {
    [[ ! -e $DATA_ROOT && ! -e $STATE_ROOT && ! -e $CONFIG_ROOT && ! -e $CACHE_ROOT ]]
    [[ -f $HOME/clients/Discord/resources/app.asar || -f $HOME/.var/app/com.discordapp.Discord/config/discord/app-1.2.3/resources/app.asar ]]
}

test_menu_help() {
    fixture
    print_menu | grep -Fq '4. Fully remove my Equicord setup'
    if print_menu | grep -Fq 'Remove only'; then return 1; fi
    "$release" --help | grep -Fq -- '--remove --confirm-remove'
    must_fail "$release" --confirm-remove
}
test_confirmation() {
    fixture
    must_fail perform_remove
    [[ ! -e $UNINSTALL_STATE && -e $OWNER_MARKER ]]
    MES_NONINTERACTIVE=0
    perform_remove <<< 'yes'
    [[ ! -e $UNINSTALL_STATE && -e $OWNER_MARKER ]]
    perform_remove <<< 'REMOVE'
    assert_removed
}
test_full_remove() { fixture; perform_remove --confirm-remove; assert_removed; grep -Fxq uninstall "$case_root/injector-action"; }
test_already_clean() { fixture; restore_fixture_discord; execute_selected_injector() { return 99; }; perform_remove --confirm-remove; assert_removed; }
test_failed_uninjection() { fixture; execute_selected_injector() { return 42; }; must_fail perform_remove --confirm-remove; [[ -d $WORKSPACE && -f $OWNER_MARKER && $(tsv_value "$UNINSTALL_STATE" stage) == uninjection-started ]]; }
test_unverified_restoration() { fixture; execute_selected_injector() { :; }; must_fail perform_remove --confirm-remove; [[ -f $OWNER_MARKER && -f $STATE_FILE ]]; }
test_corrupt_backup() { fixture; printf 'bad' > "${DISCORD_RESOURCE_DIRS[0]}/_app.asar"; must_fail perform_remove --confirm-remove; [[ ! -f $UNINSTALL_STATE ]]; }
test_missing_backup() { fixture; rm -- "${DISCORD_RESOURCE_DIRS[0]}/_app.asar"; must_fail perform_remove --confirm-remove; [[ -f $OWNER_MARKER ]]; }
test_hash_mismatch() {
    fixture
    execute_selected_injector() { restore_fixture_discord; printf x >> "${DISCORD_RESOURCE_DIRS[0]}/app.asar"; }
    must_fail perform_remove --confirm-remove
    [[ -d $WORKSPACE && -f $STATE_FILE ]]
}
test_dirty_workspace() { fixture; printf 'edit' >> "$WORKSPACE/package.json"; must_fail perform_remove --confirm-remove; [[ -d $WORKSPACE && -f $STATE_FILE && ! -e ${DISCORD_RESOURCE_DIRS[0]}/_app.asar ]]; }
test_untracked_workspace() { fixture; printf 'personal' > "$WORKSPACE/personal.txt"; must_fail perform_remove --confirm-remove; [[ -f $WORKSPACE/personal.txt ]]; }
test_ignored_plugin_edit() { fixture; printf '// personal' >> "$WORKSPACE/src/userplugins/fakeDM/index.tsx"; must_fail perform_remove --confirm-remove; [[ -d $WORKSPACE ]]; }
test_unknown_plugin() { fixture; mkdir "$WORKSPACE/src/userplugins/unknown"; printf 'keep' > "$WORKSPACE/src/userplugins/unknown/index.ts"; must_fail perform_remove --confirm-remove; [[ -f $WORKSPACE/src/userplugins/unknown/index.ts ]]; }
test_wrong_remote() { fixture; git -C "$WORKSPACE" remote set-url origin https://github.com/example/other; must_fail perform_remove --confirm-remove; [[ ! -f $UNINSTALL_STATE ]]; }
test_missing_owner() { fixture; rm -- "$OWNER_MARKER"; must_fail perform_remove --confirm-remove; [[ -d $WORKSPACE ]]; }
test_invalid_manifest() { fixture; printf 'upstream_remote\thttps://example.invalid\n' >> "$STATE_FILE"; must_fail perform_remove --confirm-remove; [[ ! -e $UNINSTALL_STATE ]]; }
test_root_refusal() { fixture; id() { printf '0\n'; }; must_fail perform_remove --confirm-remove; [[ ! -f $UNINSTALL_STATE ]]; }
test_symlink_root() {
    fixture
    mv -- "$DATA_ROOT" "$case_root/retained-data"
    ln -s "$case_root/retained-data" "$DATA_ROOT"
    must_fail perform_remove --confirm-remove
    [[ -d $case_root/retained-data/Equicord ]]
}
test_symlink_ancestor() {
    fixture
    mv -- "$DATA_HOME" "$case_root/retained-base"
    ln -s "$case_root/retained-base" "$DATA_HOME"
    must_fail perform_remove --confirm-remove
    [[ -d $case_root/retained-base/my-equicord-setup/Equicord ]]
}
test_containment() {
    fixture
    for path in / "$HOME" "$DATA_HOME" ''; do
        DATA_ROOT=$path
        must_fail validate_removal_roots
    done
}
test_recorded_target() {
    fixture
    mkdir -p "$HOME/clients/DiscordCanary/resources"
    cp -- "${DISCORD_RESOURCE_DIRS[0]}/app.asar" "$HOME/clients/DiscordCanary/resources/app.asar"
    local hash
    hash=$(sha256_file "$HOME/clients/DiscordCanary/resources/app.asar")
    perform_remove --confirm-remove
    [[ $(sha256_file "$HOME/clients/DiscordCanary/resources/app.asar") == "$hash" ]]
}
test_missing_target() { fixture; mv -- "$HOME/clients/Discord" "$HOME/clients/Unavailable"; must_fail perform_remove --confirm-remove; [[ -f $OWNER_MARKER ]]; }
test_flatpak_legacy() { fixture flatpak; perform_remove --confirm-remove 2> "$case_root/warnings"; assert_removed; grep -Fq 'no ownership snapshot' "$case_root/warnings"; }
test_flatpak_owned() {
    fixture flatpak
    local path
    path=$(flatpak_override_location)
    mkdir -p "$(dirname "$path")"
    printf '[Context]\nfilesystems=/unrelated;\n' > "$path"
    cp "$path" "$case_root/before"
    record_flatpak_override_before
    printf '[Context]\nfilesystems=/unrelated;%s;\n' "$WORKSPACE/dist/desktop" > "$path"
    record_flatpak_override_after
    perform_remove --confirm-remove
    cmp "$path" "$case_root/before"
}
test_flatpak_new_override() {
    fixture flatpak
    local path
    path=$(flatpak_override_location)
    record_flatpak_override_before
    mkdir -p "$(dirname "$path")"
    printf '[Context]\nfilesystems=%s;\n' "$WORKSPACE/dist/desktop" > "$path"
    record_flatpak_override_after
    perform_remove --confirm-remove
    [[ ! -f $path ]]
}
test_flatpak_changed_override() {
    fixture flatpak
    local path
    path=$(flatpak_override_location)
    record_flatpak_override_before
    mkdir -p "$(dirname "$path")"
    printf '[Context]\nfilesystems=%s;\n' "$WORKSPACE/dist/desktop" > "$path"
    record_flatpak_override_after
    printf 'unrelated-change=true\n' >> "$path"
    local hash
    hash=$(sha256_file "$path")
    perform_remove --confirm-remove
    [[ $(sha256_file "$path") == "$hash" ]]
}
test_flatpak_reinjection_does_not_claim_changes() {
    fixture flatpak
    local path
    path=$(flatpak_override_location)
    record_flatpak_override_before
    mkdir -p "$(dirname "$path")"
    printf 'grant' > "$path"
    record_flatpak_override_after
    printf 'unrelated' >> "$path"
    record_flatpak_override_before
    record_flatpak_override_after
    restore_owned_flatpak_override
    grep -Fq unrelated "$path"
}
test_partial_cleanup_retry() {
    fixture
    # Fail after the data root has already been removed. Recovery no longer has Git.
    remove_validated_manager_root() {
        if [[ $1 == "$CACHE_ROOT" && ! -f $case_root/retry ]]; then return 1; fi
        rm -rf -- "$1"
    }
    must_fail perform_remove --confirm-remove
    [[ ! -e $WORKSPACE && -e $UNINSTALL_INVENTORY/owner.tsv ]]
    touch "$case_root/retry"
    perform_remove --confirm-remove
    assert_removed
}
test_partial_cleanup_new_file() {
    fixture
    remove_validated_manager_root() { [[ $1 != "$DATA_ROOT" ]] || return 1; }
    must_fail perform_remove --confirm-remove
    printf keep > "$WORKSPACE/new-file"
    must_fail perform_remove --confirm-remove
    [[ -f $WORKSPACE/new-file ]]
}
test_repeated_and_fresh() { fixture; perform_remove --confirm-remove; perform_remove --confirm-remove; make_manager_directories; [[ -d $DATA_ROOT && -d $STATE_ROOT ]]; }
test_no_launcher_or_dependency_removal() {
    fixture
    mkdir -p "$HOME/Downloads" "$HOME/shared-tools"
    printf launcher > "$HOME/Downloads/Equicord-Linux.sh"
    printf tool > "$HOME/shared-tools/node"
    perform_remove --confirm-remove
    [[ -f $HOME/Downloads/Equicord-Linux.sh && -f $HOME/shared-tools/node ]]
}
test_dependency_symlinks_do_not_escape() {
    fixture
    mkdir -p "$WORKSPACE/node_modules" "$HOME/external"
    printf keep > "$HOME/external/file"
    ln -s "$HOME/external" "$WORKSPACE/node_modules/link"
    perform_remove --confirm-remove
    [[ -f $HOME/external/file ]]
}
test_official_command() {
    fixture
    # Restore only the real shared invocation function, retaining fixture setup.
    local definition
    definition=$(sed -n '/^execute_selected_injector() {$/,/^}$/p' "$release")
    # Source fixed repository code, never untrusted manifest or user input.
    # shellcheck source=/dev/null
    source /dev/stdin <<< "$definition"
    download_verified_injector() { :; }
    env() { printf '%s\n' "$@" > "$case_root/arguments"; }
    execute_selected_injector uninstall
    grep -Fxq -- '--uninstall' "$case_root/arguments"
    grep -Fxq -- '--location' "$case_root/arguments"
    grep -Fxq "${DISCORD_PATHS[0]}" "$case_root/arguments"
}
test_narrow_elevation() {
    fixture
    local definition
    definition=$(sed -n '/^execute_selected_injector() {$/,/^}$/p' "$release")
    # shellcheck source=/dev/null
    source /dev/stdin <<< "$definition"
    download_verified_injector() { :; }
    chmod 0555 "${DISCORD_RESOURCE_DIRS[0]}"
    stat() { if [[ $1 == -c && $2 == %u ]]; then printf '0\n'; else command stat "$@"; fi; }
    sudo() { printf '%s\n' "$@" > "$case_root/sudo-arguments"; }
    execute_selected_injector uninstall
    grep -Fxq -- '--uninstall' "$case_root/sudo-arguments"
    grep -Fxq "$INJECTOR_CACHE" "$case_root/sudo-arguments"
    if grep -Eq '^(node|pnpm|git|npm)$' "$case_root/sudo-arguments"; then return 1; fi
    chmod 0755 "${DISCORD_RESOURCE_DIRS[0]}"
}
test_default_xdg() {
    fixture
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
    init_paths
    validate_removal_roots
    [[ $WORKSPACE == "$HOME/.local/share/my-equicord-setup/Equicord" ]]
}
test_exact_processes() {
    fixture
    MES_SKIP_PROCESS_MANAGEMENT=0
    cp /usr/bin/python3 "${DISCORD_PATHS[0]}/Discord"
    mkdir -p "$HOME/other"
    cp /usr/bin/python3 "$HOME/other/Discord"
    "${DISCORD_PATHS[0]}/Discord" -c 'import time; time.sleep(30)' & local selected=$!
    "$HOME/other/Discord" -c 'import time; time.sleep(30)' & local other=$!
    # The two disposable processes are the only processes this test can signal.
    trap 'kill "$selected" "$other" 2>/dev/null || true' RETURN
    local deadline=$((SECONDS+5)) found=''
    while ((SECONDS<deadline)); do found=$(selected_removal_pids); [[ $found == "$selected" ]] && break; done
    [[ $found == "$selected" ]]
    capture_removal_processes
    close_removal_processes
    wait "$selected" 2>/dev/null || true
    kill -0 "$other"
    local restart_path=''
    nohup() { printf '%s\n' "$1" > "$case_root/restarted"; }
    restart_removal_client
    wait "$!"
    restart_path=$(cat "$case_root/restarted")
    [[ $restart_path == "${DISCORD_PATHS[0]}/Discord" ]]
    kill "$other" 2>/dev/null || true
    wait "$other" 2>/dev/null || true
    trap - RETURN
}

test_unknown_config_preserved() { fixture; printf keep > "$CONFIG_ROOT/personal.txt"; must_fail perform_remove --confirm-remove; [[ -f $CONFIG_ROOT/personal.txt && -d $WORKSPACE ]]; }
test_wrong_file_owner() {
    fixture
    stat() { if [[ $1 == -c && $2 == %u && ${4:-} == "$DATA_ROOT" ]]; then printf '0\n'; else command stat "$@"; fi; }
    must_fail perform_remove --confirm-remove
    [[ ! -e $UNINSTALL_STATE ]]
}
test_system_electron() {
    fixture system-electron
    perform_remove --confirm-remove
    [[ ! -e $DATA_ROOT && -d $HOME/clients/Discord/app.asar.unpacked && ! -e $HOME/clients/Discord/_app.asar.unpacked ]]
}
test_direct_release() {
    fixture
    restore_fixture_discord
    (cd / && "$release" --remove --confirm-remove)
    assert_removed
}
test_download_failure_cannot_execute_cache() {
    fixture
    local definition
    definition=$(sed -n '/^execute_selected_injector() {$/,/^}$/p' "$release")
    # shellcheck source=/dev/null
    source /dev/stdin <<< "$definition"
    download_verified_injector() { return 1; }
    env() { touch "$case_root/unsafe-execution"; }
    must_fail execute_selected_injector uninstall
    [[ ! -e $case_root/unsafe-execution ]]
}
test_real_equilotl_fixture() {
    fixture
    [[ -f ${MES_VERIFIED_TEST_INJECTOR:-} && $(sha256_file "$MES_VERIFIED_TEST_INJECTOR") == "$EQUILOTL_LINUX_SHA256" ]]
    cp -- "$MES_VERIFIED_TEST_INJECTOR" "$INJECTOR_CACHE"
    chmod 0755 "$INJECTOR_CACHE"
    local definition
    definition=$(sed -n '/^execute_selected_injector() {$/,/^}$/p' "$release")
    # shellcheck source=/dev/null
    source /dev/stdin <<< "$definition"
    perform_remove --confirm-remove
    assert_removed
}

signal_fixture() {
    local phase=$1
    fixture
    if [[ $phase == before ]]; then
        execute_selected_injector() {
            printf '%s\n' "$BASHPID" > "$case_root/ready"
            while true; do sleep 0.1; done
        }
    else
        remove_validated_manager_root() {
            printf '%s\n' "$BASHPID" > "$case_root/ready"
            while true; do sleep 0.1; done
        }
    fi
    perform_remove --confirm-remove
}

if [[ ${1:-} == --case ]]; then
    case_root=$3
    mkdir -p "$case_root"
    # Source at top level so Bash's declared arrays are not local to fixture().
    # shellcheck source=/dev/null
    source "$release"
    "$2"
    exit
elif [[ ${1:-} == --signal-fixture ]]; then
    case_root=$3
    mkdir -p "$case_root"
    # shellcheck source=/dev/null
    source "$release"
    signal_fixture "$2"
    exit
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/my-equicord-uninstall-tests.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
passes=0 failures=0
for test in menu_help confirmation full_remove already_clean failed_uninjection unverified_restoration corrupt_backup missing_backup hash_mismatch dirty_workspace untracked_workspace ignored_plugin_edit unknown_plugin wrong_remote missing_owner invalid_manifest root_refusal symlink_root symlink_ancestor containment recorded_target missing_target flatpak_legacy flatpak_owned flatpak_new_override flatpak_changed_override flatpak_reinjection_does_not_claim_changes partial_cleanup_retry partial_cleanup_new_file repeated_and_fresh no_launcher_or_dependency_removal dependency_symlinks_do_not_escape official_command narrow_elevation default_xdg exact_processes unknown_config_preserved wrong_file_owner system_electron direct_release download_failure_cannot_execute_cache; do
    if bash "$0" --case "test_$test" "$temporary_root/$test" > "$temporary_root/$test.log" 2>&1; then
        printf 'ok - uninstall %s\n' "$test"; passes=$((passes+1))
    else
        printf 'not ok - uninstall %s\n' "$test"; cat "$temporary_root/$test.log"; failures=$((failures+1))
    fi
done
if python3 "$script_dir/Test-LinuxSignals.py" "$0" "$temporary_root/signals"; then passes=$((passes+6)); else failures=$((failures+1)); fi
printf '\nLinux uninstall tests: %d passed, %d failed.\n' "$passes" "$failures"
[[ $failures -eq 0 ]]
