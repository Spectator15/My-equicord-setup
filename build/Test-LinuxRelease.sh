#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail
IFS=$'\n\t'

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
release="$repo_root/Equicord-Linux.sh"
source_file="$repo_root/src/EquicordSetup.sh"
plugin_root="$repo_root/src/plugins"
build_script="$repo_root/build/Build-LinuxRelease.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/my-equicord-linux-tests.XXXXXX")

cleanup() {
    case "$temporary_root" in
        "${TMPDIR:-/tmp}"/my-equicord-linux-tests.*) rm -rf -- "$temporary_root" ;;
        *) printf 'Refusing to clean unexpected test path: %s\n' "$temporary_root" >&2 ;;
    esac
}
trap cleanup EXIT

passes=0
failures=0

run_test() {
    local name=$1
    shift
    if ("$@") >"$temporary_root/test.out" 2>"$temporary_root/test.err"; then
        printf 'ok - %s\n' "$name"
        passes=$((passes + 1))
    else
        printf 'not ok - %s\n' "$name" >&2
        sed 's/^/  stdout: /' "$temporary_root/test.out" >&2
        sed 's/^/  stderr: /' "$temporary_root/test.err" >&2
        failures=$((failures + 1))
    fi
}

source_release() {
    # shellcheck source=/dev/null
    source "$release"
}

make_fake_upstream() {
    local bare=$1 work=$2
    git init --bare "$bare" >/dev/null
    git init "$work" >/dev/null
    git -C "$work" config user.name Test
    git -C "$work" config user.email test@example.invalid
    mkdir -p "$work/src/userplugins"
    printf '{"packageManager":"pnpm@11.22.0","scripts":{"build":"echo build"}}\n' > "$work/package.json"
    printf 'lockfileVersion: 9\n' > "$work/pnpm-lock.yaml"
    printf 'pnpm install --frozen-lockfile\n' > "$work/README.md"
    git -C "$work" add .
    git -C "$work" commit -m initial >/dev/null
    git -C "$work" branch -M main
    git -C "$work" remote add origin "$bare"
    git -C "$work" push -u origin main >/dev/null
    git -C "$bare" symbolic-ref HEAD refs/heads/main
}

with_test_environment() {
    local name=$1
    export HOME="$temporary_root/$name/home"
    export XDG_CONFIG_HOME="$HOME/config root"
    export XDG_DATA_HOME="$HOME/data root"
    export XDG_STATE_HOME="$HOME/state root"
    export XDG_CACHE_HOME="$HOME/cache root"
    export MES_TEST_MODE=1
    export MES_ASSUME_YES=1
    export MES_NONINTERACTIVE=1
    mkdir -p "$HOME"
    init_paths
}

test_generated_current() { "$build_script" --check; }
test_deterministic() {
    local first second
    "$build_script"
    first=$(sha256sum "$release" | awk '{print $1}')
    "$build_script"
    second=$(sha256sum "$release" | awk '{print $1}')
    [[ $first == "$second" ]]
}
test_lf() { ! grep -q $'\r' "$release"; }
test_executable() { [[ -x $release ]]; }
test_shebang() { [[ $(head -n 1 "$release") == '#!/usr/bin/env bash' ]]; }
test_shell_syntax() { bash -n "$source_file" && bash -n "$release" && bash -n "$build_script"; }
test_no_markers() { ! grep -Fq '<BUILD:BUNDLED_PLUGIN_PAYLOAD>' "$release"; }
test_no_machine_paths() { ! grep -Fqi 'C:/Users/' "$release" && ! grep -Fqi 'Users/Danish' "$release" && ! grep -Fq "$repo_root" "$release"; }

test_payload_matches() {
    source_release
    local stage="$temporary_root/payload"
    extract_embedded_plugins "$stage"
    while IFS=$'\t' read -r folder file _ || [[ -n ${folder:-} ]]; do
        [[ -z ${folder:-} || ${folder:0:1} == '#' ]] && continue
        cmp "$plugin_root/$folder/$file" "$stage/$folder/$file"
    done < "$plugin_root/PluginFiles.tsv"
}

test_plugin_entries() {
    source_release
    local stage="$temporary_root/entries"
    extract_embedded_plugins "$stage"
    validate_plugin_tree "$stage"
}

test_missing_entry() {
    source_release
    local stage="$temporary_root/missing-entry"
    extract_embedded_plugins "$stage"
    rm -f "$stage/smoothType/index.tsx"
    ! validate_plugin_tree "$stage"
}

test_windows_specific_detection() {
    source_release
    local stage="$temporary_root/windows-specific"
    extract_embedded_plugins "$stage"
    printf '\nconst platform = process.platform === "win32";\n' >> "$stage/smoothType/index.tsx"
    ! validate_plugin_tree "$stage"
}

test_upstream_collision() {
    source_release
    with_test_environment collision
    mkdir -p "$WORKSPACE/src/plugins/fakeDM" "$WORKSPACE/src/userplugins"
    extract_embedded_plugins "$WORKSPACE/src/userplugins"
    ! validate_upstream_collisions
}

test_reviewed_collision() {
    source_release
    with_test_environment reviewed-collision
    mkdir -p "$WORKSPACE/src/plugins/streamerModeOnStream" "$WORKSPACE/src/userplugins"
    printf 'export default {\n    name: "StreamerModeOn"\n};\n' > "$WORKSPACE/src/plugins/streamerModeOnStream/index.ts"
    extract_embedded_plugins "$WORKSPACE/src/userplugins"
    validate_upstream_collisions
}

test_xdg_defaults() {
    source_release
    export HOME="$temporary_root/default-home"
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
    init_paths
    [[ $WORKSPACE == "$HOME/.local/share/my-equicord-setup/Equicord" && $STATE_ROOT == "$HOME/.local/state/my-equicord-setup" ]]
}

test_custom_xdg() {
    source_release
    export HOME="$temporary_root/custom-home"
    export XDG_DATA_HOME="$temporary_root/données data"
    export XDG_STATE_HOME="$temporary_root/state space"
    export XDG_CONFIG_HOME="$temporary_root/config space"
    export XDG_CACHE_HOME="$temporary_root/cache space"
    init_paths
    [[ $WORKSPACE == "$XDG_DATA_HOME/my-equicord-setup/Equicord" && $CACHE_ROOT == "$XDG_CACHE_HOME/my-equicord-setup" ]]
}

test_valid_workspace() {
    source_release
    local suffix=${1:-one}
    with_test_environment "valid-workspace-$suffix"
    local bare="$temporary_root/valid-workspace-$suffix/upstream.git" seed="$temporary_root/valid-workspace-$suffix/seed"
    make_fake_upstream "$bare" "$seed"
    export MES_TEST_EQUICORD_REMOTE="$bare"
    clone_or_validate_workspace
    clone_or_validate_workspace
    validate_official_remote
}

test_unknown_checkout() {
    source_release
    with_test_environment unknown-checkout
    mkdir -p "$WORKSPACE"
    git init "$WORKSPACE" >/dev/null
    ! clone_or_validate_workspace
}

test_wrong_remote() {
    source_release
    with_test_environment wrong-remote
    local bare="$temporary_root/wrong-remote/upstream.git" seed="$temporary_root/wrong-remote/seed"
    make_fake_upstream "$bare" "$seed"
    export MES_TEST_EQUICORD_REMOTE="$bare"
    clone_or_validate_workspace
    git -C "$WORKSPACE" remote set-url origin "$temporary_root/wrong-remote/other.git"
    ! validate_official_remote
}

test_dirty_workspace() {
    source_release
    with_test_environment dirty
    local bare="$temporary_root/dirty/upstream.git" seed="$temporary_root/dirty/seed"
    make_fake_upstream "$bare" "$seed"
    export MES_TEST_EQUICORD_REMOTE="$bare"
    clone_or_validate_workspace
    printf 'dirty\n' >> "$WORKSPACE/README.md"
    ! assert_clean_workspace
}

test_fast_forward() {
    source_release
    with_test_environment fast-forward
    local bare="$temporary_root/fast-forward/upstream.git" seed="$temporary_root/fast-forward/seed"
    make_fake_upstream "$bare" "$seed"
    export MES_TEST_EQUICORD_REMOTE="$bare"
    clone_or_validate_workspace
    printf 'next\n' >> "$seed/README.md"
    git -C "$seed" add README.md
    git -C "$seed" commit -m next >/dev/null
    git -C "$seed" push >/dev/null
    update_workspace_fast_forward
    [[ $(git -C "$WORKSPACE" rev-parse HEAD) == $(git -C "$seed" rev-parse HEAD) ]]
}

test_native_detection() {
    source_release
    with_test_environment native-detect
    local root="$temporary_root/native-detect/scan root"
    mkdir -p "$root/Discord/resources"
    : > "$root/Discord/resources/app.asar"
    export MES_DISCORD_SEARCH_ROOTS="$root"
    detect_discord_installations
    [[ ${#DISCORD_PATHS[@]} -eq 1 && ${DISCORD_BRANCHES[0]} == stable && ${DISCORD_FORMATS[0]} == native ]]
}

test_flatpak_detection() {
    source_release
    with_test_environment flatpak-detect
    local root="$HOME/.var/app/com.discordapp.Discord/config/discord/app-1.2.3/resources"
    mkdir -p "$root"
    : > "$root/app.asar"
    export MES_DISCORD_SEARCH_ROOTS="$temporary_root/empty"
    detect_discord_installations
    [[ ${#DISCORD_PATHS[@]} -eq 1 && ${DISCORD_FORMATS[0]} == flatpak ]]
}

test_branches_and_multiple() {
    source_release
    with_test_environment branches
    local root="$temporary_root/branches/scan"
    for name in Discord DiscordPTB DiscordCanary; do mkdir -p "$root/$name/resources"; : > "$root/$name/resources/app.asar"; done
    export MES_DISCORD_SEARCH_ROOTS="$root"
    detect_discord_installations
    [[ ${#DISCORD_PATHS[@]} -eq 3 && " ${DISCORD_BRANCHES[*]} " == *stable* && " ${DISCORD_BRANCHES[*]} " == *ptb* && " ${DISCORD_BRANCHES[*]} " == *canary* ]]
}

test_symlink_dedup() {
    source_release
    with_test_environment dedup
    local root="$temporary_root/dedup/scan"
    mkdir -p "$root/Discord/resources"
    : > "$root/Discord/resources/app.asar"
    ln -s "$root/Discord" "$root/discord"
    export MES_DISCORD_SEARCH_ROOTS="$root"
    detect_discord_installations
    [[ ${#DISCORD_PATHS[@]} -eq 1 ]]
}

test_unsupported_client() {
    source_release
    with_test_environment unsupported-client
    local root="$temporary_root/unsupported-client/scan"
    mkdir -p "$root/slack/resources"
    : > "$root/slack/resources/app.asar"
    export MES_DISCORD_SEARCH_ROOTS="$root"
    detect_discord_installations
    [[ ${#DISCORD_PATHS[@]} -eq 0 ]]
}

test_preserve_unknown_plugin() {
    source_release
    with_test_environment preserve-unknown
    mkdir -p "$WORKSPACE/src/userplugins/unrelatedPlugin"
    printf 'keep\n' > "$WORKSPACE/src/userplugins/unrelatedPlugin/index.ts"
    local stage="$temporary_root/preserve-unknown/stage"
    extract_embedded_plugins "$stage"
    validate_plugin_tree "$stage"
    [[ -f $WORKSPACE/src/userplugins/unrelatedPlugin/index.ts ]]
}

test_backup_restore() {
    source_release
    with_test_environment backup-restore
    mkdir -p "$WORKSPACE/src/userplugins/smoothType"
    printf 'old\n' > "$WORKSPACE/src/userplugins/smoothType/index.tsx"
    make_manager_directories
    local backup
    backup=$(create_plugin_backup test)
    printf 'new\n' > "$WORKSPACE/src/userplugins/smoothType/index.tsx"
    restore_plugin_tree_from_backup "$backup"
    grep -Fqx old "$WORKSPACE/src/userplugins/smoothType/index.tsx"
}

test_atomic_repeated_deploy() {
    source_release
    with_test_environment repeated
    mkdir -p "$WORKSPACE/src/userplugins"
    make_manager_directories
    extract_embedded_plugins "$WORKSPACE/src/userplugins"
    local first second
    first=$(sha256_file "$WORKSPACE/src/userplugins/fakeDM/styles.css")
    extract_embedded_plugins "$WORKSPACE/src/userplugins"
    second=$(sha256_file "$WORKSPACE/src/userplugins/fakeDM/styles.css")
    [[ $first == "$second" ]]
}

test_safe_removal() {
    source_release
    with_test_environment safe-remove
    make_manager_directories
    mkdir -p "$DATA_ROOT/child"
    safe_remove_tree "$DATA_ROOT/child" "$DATA_ROOT"
    [[ ! -e $DATA_ROOT/child ]] && ! safe_remove_tree "$DATA_ROOT" "$DATA_ROOT"
}

test_exact_process_targeting() {
    # shellcheck disable=SC2016
    ! grep -E 'killall|pkill[[:space:]]+(-f[[:space:]]+)?(electron|node|discord)' "$source_file" &&
        grep -Fq 'pgrep -x "$process_name"' "$source_file"
}

test_root_refusal() {
    source_release
    # shellcheck disable=SC2329
    uname() { [[ ${1:-} == -s ]] && printf 'Linux\n' || printf 'x86_64\n'; }
    # shellcheck disable=SC2329
    id() { printf '0\n'; }
    ! platform_preflight
}

test_narrow_elevation() {
    # shellcheck disable=SC2016
    grep -Fq 'sudo env "${environment[@]}" "$INJECTOR_CACHE"' "$source_file" &&
        ! grep -E 'sudo[[:space:]]+(git|node|pnpm|npm)' "$source_file"
}

test_injector_digest() {
    source_release
    [[ $EQUILOTL_VERSION == v2.2.6 && $EQUILOTL_LINUX_SHA256 == 5179bff47736c9d0e2df8367798d7c743d221c403f6c9262f8571f34d3383ed1 ]]
}

test_missing_git() {
    source_release
    # shellcheck disable=SC2329
    command() {
        if [[ ${1:-} == -v && ${2:-} == git ]]; then return 1; fi
        builtin command "$@"
    }
    ! check_base_dependencies
}

test_missing_node() {
    source_release
    # shellcheck disable=SC2329
    command() {
        if [[ ${1:-} == -v && ${2:-} == node ]]; then return 1; fi
        builtin command "$@"
    }
    ! check_base_dependencies
}

test_old_node() {
    source_release
    # shellcheck disable=SC2329
    node() {
        if [[ ${1:-} == -p ]]; then printf '20\n'; else printf 'v20.19.0\n'; fi
    }
    ! check_base_dependencies
}

test_missing_package_manager() {
    source_release
    with_test_environment missing-package-manager
    mkdir -p "$WORKSPACE"
    printf '{"packageManager":"pnpm@11.22.0"}\n' > "$WORKSPACE/package.json"
    # shellcheck disable=SC2329
    command() {
        if [[ ${1:-} == -v && ( ${2:-} == pnpm || ${2:-} == corepack ) ]]; then return 1; fi
        builtin command "$@"
    }
    ! select_upstream_package_manager
}

test_equibop_detection_code() { grep -Fq 'org.equicord.equibop' "$source_file" && grep -Fq 'does not automatically include' "$source_file"; }
test_snap_unsupported() { grep -Fq 'Snap is not supported upstream' "$source_file"; }
test_no_destructive_git() { ! grep -E 'git[^\n]*(reset --hard|clean -)' "$source_file"; }
test_no_curl_pipe() { ! grep -E 'curl[^\n]*\|[[:space:]]*(ba)?sh' "$source_file"; }
test_manifest_fields() {
    source_release
    grep -Fq 'upstream_commit' "$source_file" && grep -Fq 'injection_result' "$source_file" && grep -Fq 'last_successful_build' "$source_file"
}
test_companion_file() { grep -Fqx $'fakeDM\tstyles.css' "$plugin_root/PluginFiles.tsv"; }
test_runtime_names() { source_release; [[ ${#BUNDLED_PLUGIN_RUNTIME_NAMES[@]} -eq 10 ]]; }
test_plugin_count() { source_release; [[ ${#BUNDLED_PLUGIN_NAMES[@]} -eq 10 && $(grep -vc '^#\|^$' "$plugin_root/PluginFiles.tsv") -eq 11 ]]; }
test_paths_with_spaces() { test_custom_xdg; }
test_non_ascii_paths() { test_custom_xdg; }
test_network_failure_path() {
    source_release
    with_test_environment network-failure
    make_manager_directories
    # shellcheck disable=SC2329
    curl() { return 22; }
    ! download_verified_injector && [[ ! -e $INJECTOR_CACHE ]]
}
test_invalid_download_path() {
    source_release
    with_test_environment invalid-download
    make_manager_directories
    # shellcheck disable=SC2329
    curl() {
        local previous='' argument output=''
        for argument in "$@"; do
            [[ $previous == --output ]] && output=$argument
            previous=$argument
        done
        printf 'not an injector\n' > "$output"
    }
    ! download_verified_injector && [[ ! -e $INJECTOR_CACHE ]]
}
test_build_failure_rollback_path() { grep -Fq 'Build failed. Restoring the previous manager-owned plugin tree.' "$source_file"; }
test_successful_deployment_path() { grep -Fq 'Verified all 10 custom plugin names' "$source_file"; }
test_removal_scope() { grep -Fq 'Removed only the manager-owned custom plugins' "$source_file"; }

run_test '1 clean manager-owned source setup' test_valid_workspace one
run_test '2 existing valid manager-owned source workspace' test_valid_workspace two
run_test '3 unknown checkout with local changes is rejected' test_unknown_checkout
run_test '4 incorrect Git remote is rejected' test_wrong_remote
run_test '5 upstream fast-forward update' test_fast_forward
run_test '6 missing Git is diagnosed' test_missing_git
run_test '7 missing Node.js is diagnosed' test_missing_node
run_test '8 unsupported Node.js version is rejected' test_old_node
run_test '9 missing declared package manager is rejected' test_missing_package_manager
run_test '10 plugin structure validation' test_plugin_entries
run_test '11 missing plugin entry is rejected' test_missing_entry
run_test '12 plugin name collision is rejected' test_upstream_collision
run_test '13 Windows-specific plugin detection' test_windows_specific_detection
run_test '14 plugin build failure rollback path' test_build_failure_rollback_path
run_test '15 successful plugin deployment and payload equality' test_payload_matches
run_test '16 repeated installation is deterministic' test_atomic_repeated_deploy
run_test '17 repeated update accepts valid workspace' test_valid_workspace three
run_test '18 manager-owned removal scope' test_removal_scope
run_test '19 unrelated user plugin preservation' test_preserve_unknown_plugin
run_test '20 last known-good restoration' test_backup_restore
run_test '21 default XDG paths' test_xdg_defaults
run_test '22 custom XDG paths' test_custom_xdg
run_test '23 paths containing spaces' test_paths_with_spaces
run_test '24 paths containing non-ASCII characters' test_non_ascii_paths
run_test '25 native Discord detection' test_native_detection
run_test '26 Flatpak Discord detection' test_flatpak_detection
run_test '27 Stable, PTB and Canary distinction' test_branches_and_multiple
run_test '28 symlink resolution and deduplication' test_symlink_dedup
run_test '29 multiple-client discovery' test_branches_and_multiple
run_test '30 unsupported client format' test_unsupported_client
run_test '31 existing Equibop detection path' test_equibop_detection_code
run_test '32 root execution refusal' test_root_refusal
run_test '33 narrow mocked elevation boundary' test_narrow_elevation
run_test '34 exact process targeting' test_exact_process_targeting
run_test '35 network failure handling' test_network_failure_path
run_test '36 invalid downloaded content handling' test_invalid_download_path
run_test '37 generated-script determinism' test_deterministic
run_test '38 LF line endings' test_lf
run_test '39 executable bit preservation' test_executable
run_test '40 shell syntax' test_shell_syntax
run_test '41 current generated Linux release' test_generated_current
run_test 'generated release shebang' test_shebang
run_test 'no unresolved generated marker' test_no_markers
run_test 'no machine-specific paths' test_no_machine_paths
run_test 'reviewed upstream collision remains distinct' test_reviewed_collision
run_test 'pinned injector digest' test_injector_digest
run_test 'Snap remains unsupported' test_snap_unsupported
run_test 'no destructive Git operations' test_no_destructive_git
run_test 'no curl pipe to shell' test_no_curl_pipe
run_test 'companion CSS is packaged' test_companion_file
run_test 'all runtime plugin names registered' test_runtime_names
run_test '10 plugins and 11 files registered' test_plugin_count
run_test 'safe exact-path removal' test_safe_removal

printf '\nLinux release tests: %d passed, %d failed.\n' "$passes" "$failures"
[[ $failures -eq 0 ]]
