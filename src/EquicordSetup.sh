#!/usr/bin/env bash
# My Equicord Setup for Linux
# Copyright (C) 2026 Spectator15
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This project contains modified third-party GPL-licensed plugin code.
# Original copyright and authorship remain with the respective upstream contributors.
#
# GENERATED RELEASE NOTE: Equicord-Linux.sh is generated from this file and
# src/plugins by build/Build-LinuxRelease.sh. Edit the organised sources instead.

set -euo pipefail
IFS=$'\n\t'

readonly MANAGER_NAME="My Equicord Setup"
readonly MANAGER_VERSION="1.1.0-beta.2"
readonly STATE_FORMAT="1"
readonly EQUICORD_REMOTE="https://github.com/Equicord/Equicord.git"
readonly TESTED_EQUICORD_COMMIT="0d27aec1ab604f1c0d7f7eb9114114e71da93573"
readonly EQUILOTL_VERSION="v2.2.6"
readonly EQUILOTL_LINUX_SHA256="5179bff47736c9d0e2df8367798d7c743d221c403f6c9262f8571f34d3383ed1"
readonly EQUILOTL_LINUX_URL="https://github.com/Equicord/Equilotl/releases/download/${EQUILOTL_VERSION}/EquilotlCli-linux"

readonly -a BUNDLED_PLUGIN_NAMES=(
    smoothType
    streamerModeOnStream
    exportDM
    serverCloner
    antiDeleteMessage
    lastSeen
    streamProof
    fakePerm
    fakeDM
    antiMoveDeco
)
readonly -a BUNDLED_PLUGIN_RUNTIME_NAMES=(
    SmoothType
    StreamerModeOnStream
    ExportDM
    ServerCloner
    AntiDeleteMessage
    LastSeen
    StreamProof
    FakePerm
    FakeDM
    AntiMoveDeco
)

# <BUILD:BUNDLED_PLUGIN_PAYLOAD>

COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_RESET=''

if [[ -t 1 && ${NO_COLOR:-} == "" ]]; then
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BLUE=$'\033[36m'
    COLOR_RESET=$'\033[0m'
fi

info() { printf '%s[INFO]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"; }
success() { printf '%s[OK]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
fail() { printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; return 1; }

trim_trailing_slash() {
    local value=$1
    while [[ $value != "/" && $value == */ ]]; do value=${value%/}; done
    printf '%s\n' "$value"
}

init_paths() {
    : "${HOME:?HOME is not set}"
    CONFIG_HOME=$(trim_trailing_slash "${XDG_CONFIG_HOME:-$HOME/.config}")
    DATA_HOME=$(trim_trailing_slash "${XDG_DATA_HOME:-$HOME/.local/share}")
    STATE_HOME=$(trim_trailing_slash "${XDG_STATE_HOME:-$HOME/.local/state}")
    CACHE_HOME=$(trim_trailing_slash "${XDG_CACHE_HOME:-$HOME/.cache}")
    CONFIG_ROOT="$CONFIG_HOME/my-equicord-setup"
    DATA_ROOT="$DATA_HOME/my-equicord-setup"
    STATE_ROOT="$STATE_HOME/my-equicord-setup"
    CACHE_ROOT="$CACHE_HOME/my-equicord-setup"
    WORKSPACE="$DATA_ROOT/Equicord"
    BACKUP_ROOT="$DATA_ROOT/backups"
    OWNER_MARKER="$DATA_ROOT/manager-owned.tsv"
    STATE_FILE="$STATE_ROOT/manifest.tsv"
    LOG_ROOT="$STATE_ROOT/logs"
    INJECTOR_CACHE="$CACHE_ROOT/EquilotlCli-linux-${EQUILOTL_VERSION}"
    local managed_path
    for managed_path in "$CONFIG_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$CACHE_ROOT" "$WORKSPACE" "$BACKUP_ROOT"; do
        [[ $managed_path != *$'\t'* && $managed_path != *$'\n'* ]] || {
            fail "XDG and HOME paths containing tabs or newlines are not supported by the state manifest."
            return 1
        }
    done
}

effective_equicord_remote() {
    if [[ ${MES_TEST_MODE:-0} == 1 && -n ${MES_TEST_EQUICORD_REMOTE:-} ]]; then
        printf '%s\n' "$MES_TEST_EQUICORD_REMOTE"
    else
        printf '%s\n' "$EQUICORD_REMOTE"
    fi
}

sha256_file() {
    sha256sum -- "$1" | awk '{print $1}'
}

safe_remove_tree() {
    local target=$1 allowed_root=$2 resolved_target resolved_root
    [[ -n $target && -n $allowed_root ]] || { fail "Refusing to remove an empty path."; return 1; }
    resolved_target=$(realpath -m -- "$target")
    resolved_root=$(realpath -m -- "$allowed_root")
    [[ $resolved_target == "$resolved_root"/* && $resolved_target != "$resolved_root" ]] || {
        fail "Refusing to remove a path outside the manager root: $resolved_target"
        return 1
    }
    rm -rf -- "$resolved_target"
}

make_manager_directories() {
    mkdir -p -- "$CONFIG_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$CACHE_ROOT" "$BACKUP_ROOT" "$LOG_ROOT"
}

atomic_write_text() {
    local destination=$1 source=$2 parent temporary
    parent=$(dirname -- "$destination")
    mkdir -p -- "$parent"
    temporary=$(mktemp "$parent/.my-equicord-write.XXXXXX")
    cp -- "$source" "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$destination"
}

state_value() {
    local key=$1
    [[ -f $STATE_FILE ]] || return 1
    awk -F '\t' -v wanted="$key" '$1 == wanted { sub(/^[^\t]*\t/, ""); print; exit }' "$STATE_FILE"
}

is_bundled_plugin() {
    local candidate=$1 plugin
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        [[ $candidate == "$plugin" ]] && return 0
    done
    return 1
}

write_owner_marker() {
    local temporary remote
    remote=$(effective_equicord_remote)
    temporary=$(mktemp "$DATA_ROOT/.manager-owned.XXXXXX")
    {
        printf 'format\t%s\n' "$STATE_FORMAT"
        printf 'manager\t%s\n' "$MANAGER_NAME"
        printf 'remote\t%s\n' "$remote"
        printf 'workspace\t%s\n' "$WORKSPACE"
    } > "$temporary"
    atomic_write_text "$OWNER_MARKER" "$temporary"
    rm -f -- "$temporary"
}

validate_owner_marker() {
    local remote
    remote=$(effective_equicord_remote)
    [[ -f $OWNER_MARKER ]] || { fail "The existing Equicord directory is not marked as manager-owned: $WORKSPACE"; return 1; }
    grep -Fqx $'remote\t'"$remote" "$OWNER_MARKER" || {
        fail "The manager ownership marker does not match the official Equicord remote."
        return 1
    }
    grep -Fqx $'workspace\t'"$WORKSPACE" "$OWNER_MARKER" || {
        fail "The manager ownership marker points to a different workspace."
        return 1
    }
}

normalize_git_remote() {
    local value=${1%/}
    if command -v cygpath >/dev/null 2>&1 && [[ $value == /* || $value =~ ^[A-Za-z]:/ ]]; then
        value=$(cygpath -m "$value")
    fi
    value=${value%.git}
    value=${value#git@github.com:}
    value=${value#ssh://git@github.com/}
    value=${value#https://github.com/}
    value=${value#http://github.com/}
    printf '%s\n' "${value,,}"
}

validate_official_remote() {
    local actual expected
    actual=$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null) || { fail "The Equicord workspace has no origin remote."; return 1; }
    expected=$(normalize_git_remote "$(effective_equicord_remote)")
    [[ $(normalize_git_remote "$actual") == "$expected" ]] || {
        fail "The Equicord workspace origin is not official upstream: $actual"
        return 1
    }
}

assert_clean_workspace() {
    local dirty
    dirty=$(git -C "$WORKSPACE" status --porcelain=v1 --untracked-files=all)
    if [[ -n $dirty ]]; then
        printf '%s\n' "$dirty" >&2
        fail "The manager-owned Equicord checkout has local changes. Preserve or remove them before updating."
        return 1
    fi
}

clone_or_validate_workspace() {
    local remote
    remote=$(effective_equicord_remote)
    if [[ ! -e $WORKSPACE ]]; then
        info "Cloning official Equicord into $WORKSPACE"
        git clone --origin origin -- "$remote" "$WORKSPACE"
        write_owner_marker
    elif [[ ! -d $WORKSPACE/.git ]]; then
        fail "A non-Git path already exists at the manager workspace: $WORKSPACE"
        return 1
    else
        validate_owner_marker
        validate_official_remote
    fi
}

update_workspace_fast_forward() {
    validate_owner_marker
    validate_official_remote
    assert_clean_workspace
    info "Fetching official Equicord updates."
    git -C "$WORKSPACE" fetch --prune origin
    local remote_head current
    remote_head=$(git -C "$WORKSPACE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [[ -n $remote_head ]] || remote_head="origin/main"
    current=$(git -C "$WORKSPACE" rev-parse HEAD)
    if [[ $current == "$(git -C "$WORKSPACE" rev-parse "$remote_head")" ]]; then
        info "Equicord source is already current."
        return 0
    fi
    git -C "$WORKSPACE" merge-base --is-ancestor HEAD "$remote_head" ||
        fail "The Equicord checkout has diverged or contains local commits. No update was applied."
    git -C "$WORKSPACE" merge --ff-only "$remote_head"
}

distribution_name() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${PRETTY_NAME:-${ID:-Linux}}"
    else
        printf 'Linux\n'
    fi
}

print_dependency_install_help() {
    local id_like=''
    [[ -r /etc/os-release ]] && id_like=$(awk -F= '$1 == "ID" || $1 == "ID_LIKE" {gsub(/"/, "", $2); printf "%s ", $2}' /etc/os-release)
    case " $id_like " in
        *" debian "*|*" ubuntu "*)
            printf 'Install base tools with: sudo apt update && sudo apt install git curl coreutils build-essential procps\n' >&2
            ;;
        *" fedora "*|*" rhel "*)
            printf 'Install base tools with: sudo dnf install git curl coreutils gcc-c++ make procps-ng\n' >&2
            ;;
        *" arch "*)
            printf 'Install base tools with: sudo pacman -S --needed git curl coreutils base-devel procps-ng\n' >&2
            ;;
        *" suse "*)
            printf 'Install base tools with: sudo zypper install git curl coreutils gcc-c++ make procps\n' >&2
            ;;
        *)
            printf 'Install Git, curl, coreutils, a C/C++ build toolchain, Node.js 22 or newer, and pnpm/Corepack, then rerun this script.\n' >&2
            ;;
    esac
    printf 'Install a current Node.js LTS release from a trusted distribution source. Equicord currently requires Node.js 22 or newer.\n' >&2
}

workspace_is_valid_for_dependency_check() {
    [[ -d $WORKSPACE/.git && -f $OWNER_MARKER && -f $WORKSPACE/package.json ]] || return 1
    validate_owner_marker >/dev/null 2>&1 || return 1
    validate_official_remote >/dev/null 2>&1 || return 1
}

check_dependencies() {
    local -a errors=() notes=()
    local command_name node_major='0' has_npm=0 has_corepack=0 has_pnpm=0
    info "Checking Linux build dependencies."
    info "The exact package-manager name and version will be read from Equicord's package.json after its source is available."
    for command_name in git node curl sha256sum base64 mktemp realpath awk sed grep find pgrep nohup; do
        command -v "$command_name" >/dev/null 2>&1 || errors+=("Missing required command: $command_name")
    done

    command -v npm >/dev/null 2>&1 && has_npm=1
    command -v corepack >/dev/null 2>&1 && has_corepack=1
    command -v pnpm >/dev/null 2>&1 && has_pnpm=1

    if command -v node >/dev/null 2>&1; then
        node_major=$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0')
        if [[ ! $node_major =~ ^[0-9]+$ || $node_major -lt 22 ]]; then
            errors+=("Node.js 22 or newer is required; found $(node --version 2>/dev/null || printf unknown)")
        fi
    fi

    if [[ $has_pnpm -eq 0 && $has_corepack -eq 0 ]]; then
        errors+=("Neither pnpm nor Corepack is available to run Equicord's declared package manager")
    elif [[ $has_pnpm -eq 0 ]]; then
        notes+=("pnpm is not installed directly; Corepack can provide the exact upstream-declared version after confirmation")
    elif [[ $has_corepack -eq 0 ]]; then
        notes+=("Corepack is unavailable; the installed pnpm must exactly match the upstream declaration")
    fi
    if [[ $has_npm -eq 0 ]]; then
        notes+=("npm is unavailable; it is not needed when Corepack or an exact matching pnpm can satisfy upstream")
    fi

    if ((${#errors[@]})); then
        warn "Dependency check found ${#errors[@]} blocking issue(s):"
        printf '  - %s\n' "${errors[@]}" >&2
        if ((${#notes[@]})); then
            printf 'Additional dependency notes:\n' >&2
            printf '  - %s\n' "${notes[@]}" >&2
        fi
        print_dependency_install_help
        return 1
    fi

    if ((${#notes[@]})); then
        warn "Dependency notes:"
        printf '  - %s\n' "${notes[@]}" >&2
    fi

    if workspace_is_valid_for_dependency_check; then
        info "A valid manager-owned Equicord checkout exists, so its declared package manager will be validated now."
        select_upstream_package_manager
    else
        info "No valid existing manager workspace is available yet; exact package-manager validation will follow source acquisition."
    fi
}

declare -a PACKAGE_MANAGER_COMMAND=()
PACKAGE_MANAGER_DECLARATION=''
select_upstream_package_manager() {
    local declaration manager required_version available_version
    declaration=$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.packageManager || "")' "$WORKSPACE/package.json")
    if [[ $declaration == "$PACKAGE_MANAGER_DECLARATION" && ${#PACKAGE_MANAGER_COMMAND[@]} -gt 0 ]]; then
        return 0
    fi
    PACKAGE_MANAGER_COMMAND=()
    PACKAGE_MANAGER_DECLARATION=''
    manager=${declaration%@*}
    required_version=${declaration##*@}
    [[ $manager == "pnpm" && -n $required_version && $required_version != "$declaration" ]] || {
        fail "Unsupported or missing upstream packageManager declaration: $declaration"
        return 1
    }
    if command -v pnpm >/dev/null 2>&1; then
        available_version=$(pnpm --version)
        if [[ $available_version == "$required_version" ]]; then
            PACKAGE_MANAGER_COMMAND=(pnpm)
        elif command -v corepack >/dev/null 2>&1; then
            ask_yes_no "Use Corepack to obtain Equicord's declared pnpm $required_version if needed?" || return 1
            PACKAGE_MANAGER_COMMAND=(corepack pnpm)
            available_version=$(cd "$WORKSPACE" && corepack pnpm --version)
        else
            fail "Equicord declares pnpm $required_version, but pnpm $available_version is active and Corepack is unavailable."
            return 1
        fi
    elif command -v corepack >/dev/null 2>&1; then
        ask_yes_no "Use Corepack to obtain Equicord's declared pnpm $required_version if needed?" || return 1
        PACKAGE_MANAGER_COMMAND=(corepack pnpm)
        available_version=$(cd "$WORKSPACE" && corepack pnpm --version)
    else
        fail "Equicord declares pnpm $required_version, but neither pnpm nor Corepack is available."
        return 1
    fi
    [[ $available_version == "$required_version" ]] || {
        fail "Equicord declares pnpm $required_version, but pnpm $available_version is active."
        return 1
    }
    PACKAGE_MANAGER_DECLARATION=$declaration
    info "Using pnpm $available_version from Equicord's packageManager declaration ($declaration)."
}

install_upstream_dependencies() {
    local -a install_args=(install)
    if [[ -f $WORKSPACE/pnpm-lock.yaml ]]; then
        if grep -Fq 'pnpm install --frozen-lockfile' "$WORKSPACE/README.md"; then
            install_args+=(--frozen-lockfile)
        elif grep -Fq 'pnpm install --no-frozen-lockfile' "$WORKSPACE/README.md"; then
            install_args+=(--no-frozen-lockfile)
        else
            warn "The checked-out README declares no lockfile flag. Running the package manager's normal install command."
        fi
    fi
    info "Installing source dependencies with: ${PACKAGE_MANAGER_COMMAND[*]} ${install_args[*]}"
    (cd "$WORKSPACE" && "${PACKAGE_MANAGER_COMMAND[@]}" "${install_args[@]}")
}

extract_plugin_runtime_name() {
    local entry=$1
    grep -m1 -E '^[[:space:]]*name:' "$entry" | sed -E 's/^[^"]*"([^"]+)".*/\1/'
}

validate_upstream_collisions() {
    local bundled_root=${1:-$WORKSPACE/src/userplugins}
    local plugin upstream_dir upstream_entry bundled_entry upstream_name bundled_name
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        upstream_dir=''
        if [[ -d $WORKSPACE/src/plugins/$plugin ]]; then
            upstream_dir="$WORKSPACE/src/plugins/$plugin"
        elif [[ -d $WORKSPACE/src/equicordplugins/$plugin ]]; then
            upstream_dir="$WORKSPACE/src/equicordplugins/$plugin"
        else
            continue
        fi
        if [[ $plugin != "streamerModeOnStream" ]]; then
            fail "Bundled plugin folder collides with current upstream Equicord: $plugin"
            return 1
        fi
        upstream_entry=$(find "$upstream_dir" -maxdepth 1 -type f \( -name 'index.ts' -o -name 'index.tsx' \) -print -quit)
        bundled_entry="$bundled_root/$plugin/index.ts"
        upstream_name=$(extract_plugin_runtime_name "$upstream_entry")
        bundled_name=$(extract_plugin_runtime_name "$bundled_entry")
        [[ -n $upstream_name && $bundled_name == "StreamerModeOnStream" && $upstream_name != "$bundled_name" ]] || {
            fail "The reviewed streamerModeOnStream collision is no longer safely distinct."
            return 1
        }
        warn "Upstream also has a streamerModeOnStream folder, but its runtime plugin is '$upstream_name'. The bundled '$bundled_name' plugin remains separate."
    done
}

warn_windows_specific_plugin_code() {
    local root=$1 plugin=$2 file line lowered line_number
    local platform_pattern='process[.]platform[[:space:]]*(===|==)[[:space:]]*"win32"'
    local command_pattern='(exec|execfile|execsync|execfilesync|spawn|spawnsync|bun[.]spawn|deno[.]command)[[:space:]]*[(].*(powershell|cmd[.]exe)'
    while IFS= read -r file; do
        line_number=0
        while IFS= read -r line || [[ -n $line ]]; do
            line_number=$((line_number + 1))
            [[ $line =~ ^[[:space:]]*(//|/\*|\*|\*/) ]] && continue
            lowered=${line,,}
            if [[ $line =~ $platform_pattern || $lowered =~ $command_pattern ]]; then
                warn "Compatibility heuristic warning for $plugin at ${file#"$root/"}:$line_number: possible Windows-only executable code."
                warn "This is not a confirmed incompatibility and does not block deployment. Linux Equicord compilation is the automated compatibility gate; runtime incompatibility requires separate confirmation."
                return 0
            fi
        done < "$file"
    done < <(find "$root/$plugin" -maxdepth 2 -type f \( -name '*.ts' -o -name '*.tsx' \) -print | LC_ALL=C sort)
}

validate_plugin_tree() {
    local root=$1 plugin entries file_count
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        [[ -d $root/$plugin && ! -L $root/$plugin ]] || { fail "Bundled plugin directory is missing or linked: $plugin"; return 1; }
        entries=()
        [[ -f $root/$plugin/index.ts ]] && entries+=(index.ts)
        [[ -f $root/$plugin/index.tsx ]] && entries+=(index.tsx)
        ((${#entries[@]} == 1)) || { fail "Plugin $plugin must contain exactly one index.ts or index.tsx entry."; return 1; }
        file_count=$(find "$root/$plugin" -type f | wc -l | tr -d ' ')
        [[ $file_count -ge 1 ]] || { fail "Plugin $plugin contains no source files."; return 1; }
        warn_windows_specific_plugin_code "$root" "$plugin"
    done
}

create_plugin_backup() {
    local reason=$1 timestamp backup plugin
    timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    backup=$(mktemp -d "$BACKUP_ROOT/${timestamp}-${reason}.XXXXXX")
    mkdir -p -- "$backup/plugins"
    : > "$backup/absent.txt"
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        if [[ -d $WORKSPACE/src/userplugins/$plugin ]]; then
            cp -a -- "$WORKSPACE/src/userplugins/$plugin" "$backup/plugins/$plugin"
        else
            printf '%s\n' "$plugin" >> "$backup/absent.txt"
        fi
    done
    [[ -f $STATE_FILE ]] && cp -- "$STATE_FILE" "$backup/manifest.before.tsv"
    printf '%s\n' "$backup"
}

restore_plugin_tree_from_backup() {
    local backup=$1 plugin destination temporary
    [[ -d $backup/plugins && -f $backup/absent.txt ]] || fail "Invalid manager backup: $backup"
    mkdir -p -- "$WORKSPACE/src/userplugins"
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        destination="$WORKSPACE/src/userplugins/$plugin"
        if [[ -d $backup/plugins/$plugin ]]; then
            temporary="$WORKSPACE/src/userplugins/.${plugin}.restore.$$"
            cp -a -- "$backup/plugins/$plugin" "$temporary"
            [[ ! -e $destination ]] || safe_remove_tree "$destination" "$WORKSPACE/src/userplugins"
            mv -- "$temporary" "$destination"
        else
            [[ ! -e $destination ]] || safe_remove_tree "$destination" "$WORKSPACE/src/userplugins"
        fi
    done
}

plugin_changed_since_state() {
    local plugin=$1 file relative expected current
    [[ -f $STATE_FILE && -d $WORKSPACE/src/userplugins/$plugin ]] || return 1
    while IFS=$'\t' read -r record record_plugin relative expected; do
        [[ $record == file && $record_plugin == "$plugin" ]] || continue
        file="$WORKSPACE/src/userplugins/$plugin/$relative"
        [[ -f $file ]] || return 0
        current=$(sha256_file "$file")
        [[ $current == "$expected" ]] || return 0
    done < "$STATE_FILE"
    return 1
}

confirm_overwrites() {
    local plugin
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        if [[ -L $WORKSPACE/src/userplugins/$plugin ]]; then
            fail "Refusing to replace a symlinked user-plugin directory: $plugin"
            return 1
        fi
        if plugin_changed_since_state "$plugin"; then
            warn "Manager-owned plugin $plugin was edited since the last successful build."
            ask_yes_no "Back it up and replace it with the bundled version?" || return 1
        elif [[ -d $WORKSPACE/src/userplugins/$plugin ]] && ! grep -Fq $'plugin\t'"$plugin" "$STATE_FILE" 2>/dev/null; then
            warn "An untracked user plugin already uses the managed folder $plugin."
            ask_yes_no "Back it up and replace it with this setup's bundled version?" || return 1
        fi
    done
}

deploy_bundled_plugins() {
    local stage backup plugin destination incoming previous
    mkdir -p -- "$WORKSPACE/src/userplugins" "$CACHE_ROOT"
    stage=$(mktemp -d "$CACHE_ROOT/plugin-stage.XXXXXX")
    extract_embedded_plugins "$stage"
    validate_plugin_tree "$stage"
    validate_upstream_collisions "$stage"
    confirm_overwrites
    backup=$(create_plugin_backup deploy)
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        destination="$WORKSPACE/src/userplugins/$plugin"
        incoming="$WORKSPACE/src/userplugins/.${plugin}.incoming.$$"
        previous="$WORKSPACE/src/userplugins/.${plugin}.previous.$$"
        cp -a -- "$stage/$plugin" "$incoming"
        if [[ -e $destination ]]; then mv -- "$destination" "$previous"; fi
        if ! mv -- "$incoming" "$destination"; then
            [[ ! -e $previous ]] || mv -- "$previous" "$destination"
            restore_plugin_tree_from_backup "$backup"
            safe_remove_tree "$stage" "$CACHE_ROOT"
            fail "Atomic deployment failed for $plugin. The previous plugin set was restored."
        fi
        [[ ! -e $previous ]] || safe_remove_tree "$previous" "$WORKSPACE/src/userplugins"
    done
    safe_remove_tree "$stage" "$CACHE_ROOT"
    printf '%s\n' "$backup"
}

verify_plugin_bundle() {
    local runtime_name found candidate
    [[ -d $WORKSPACE/dist ]] || fail "Equicord build did not create dist/."
    for runtime_name in "${BUNDLED_PLUGIN_RUNTIME_NAMES[@]}"; do
        found=0
        while IFS= read -r candidate; do
            if grep -aFq "$runtime_name" "$candidate"; then found=1; break; fi
        done < <(find "$WORKSPACE/dist" -maxdepth 3 -type f \( -name '*.js' -o -name '*.asar' \) -print)
        [[ $found -eq 1 ]] || {
            fail "Compatibility gate failed: the Equicord output does not contain bundled plugin $runtime_name."
            return 1
        }
    done
    success "Verified all 10 custom plugin names in the generated Equicord bundle."
}

build_equicord() {
    select_upstream_package_manager
    [[ -d $WORKSPACE/node_modules ]] || install_upstream_dependencies
    info "Building Equicord from source."
    if ! (cd "$WORKSPACE" && "${PACKAGE_MANAGER_COMMAND[@]}" build); then
        fail "Equicord compilation failed. This is a blocking automated compatibility failure, not a heuristic warning."
        return 1
    fi
    verify_plugin_bundle
}

declare -a DISCORD_BRANCHES=()
declare -a DISCORD_FORMATS=()
declare -a DISCORD_PATHS=()
declare -a DISCORD_RESOURCE_DIRS=()
declare -a DISCORD_STATUSES=()
declare -a DISCORD_APP_IDS=()

branch_from_name() {
    local lowered=${1,,}
    case "$lowered" in
        *canary*) printf 'canary\n' ;;
        *ptb*) printf 'ptb\n' ;;
        *development*|*dev*) printf 'development\n' ;;
        *) printf 'stable\n' ;;
    esac
}

add_discord_candidate() {
    local branch=$1 format=$2 target=$3 resources=$4 app_id=${5:-} resolved_target resolved_resources status='not injected' existing
    [[ -e $target || -d $target ]] || return 0
    resolved_target=$(readlink -f -- "$target" 2>/dev/null || realpath -m -- "$target")
    resolved_resources=$(readlink -f -- "$resources" 2>/dev/null || realpath -m -- "$resources")
    for existing in "${DISCORD_PATHS[@]}"; do [[ $existing == "$resolved_target" ]] && return 0; done
    if [[ -e $resolved_resources/_app.asar || -e $resolved_resources/_app.asar.unpacked ]]; then status='Equicord injected'; fi
    DISCORD_BRANCHES+=("$branch")
    DISCORD_FORMATS+=("$format")
    DISCORD_PATHS+=("$resolved_target")
    DISCORD_RESOURCE_DIRS+=("$resolved_resources")
    DISCORD_STATUSES+=("$status")
    DISCORD_APP_IDS+=("$app_id")
}

scan_versioned_discord() {
    local root=$1 branch=$2 format=$3 app_id=${4:-} best='' version_dir
    [[ -d $root ]] || return 0
    while IFS= read -r version_dir; do best=$version_dir; done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'app-*' -print | LC_ALL=C sort -V)
    if [[ -n $best && -d $best/resources && ( -f $best/resources/app.asar || -f $best/resources/_app.asar ) ]]; then
        add_discord_candidate "$branch" "$format" "$root" "$best/resources" "$app_id"
    fi
}

scan_discord_root() {
    local root=$1 child name branch format resources
    [[ -d $root ]] || return 0
    while IFS= read -r child; do
        name=${child##*/}
        case "$name" in
            Discord|DiscordPTB|DiscordCanary|DiscordDevelopment|discord|discordptb|discordcanary|discorddevelopment|discord-ptb|discord-canary|discord-development)
                branch=$(branch_from_name "$name")
                format='native'
                [[ $root == *AppImage* || $root == */Applications ]] && format='appimage-directory'
                if [[ -d $child/resources && ( -f $child/resources/app.asar || -f $child/resources/_app.asar ) ]]; then
                    add_discord_candidate "$branch" "$format" "$child" "$child/resources"
                elif [[ -f $child/app.asar || -d $child/_app.asar.unpacked ]]; then
                    add_discord_candidate "$branch" 'system-electron' "$child" "$child"
                else
                    scan_versioned_discord "$child" "$branch" "$format"
                fi
                ;;
        esac
    done < <(find -L "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort)
}

detect_discord_installations() {
    DISCORD_BRANCHES=(); DISCORD_FORMATS=(); DISCORD_PATHS=(); DISCORD_RESOURCE_DIRS=(); DISCORD_STATUSES=(); DISCORD_APP_IDS=()
    local -a roots
    local root branch name app_id flatpak_base native_config
    if [[ -n ${MES_DISCORD_SEARCH_ROOTS:-} ]]; then
        IFS=':' read -r -a roots <<< "$MES_DISCORD_SEARCH_ROOTS"
    else
        roots=(/usr/share /usr/lib /usr/lib64 /opt "$HOME/Applications" "$HOME/AppImages" "$HOME/.local/share" "$HOME/.local/bin" "$HOME/.dvm" "$HOME/.config" "$HOME/.var/app" /var/lib/flatpak/app "$HOME/.local/share/flatpak/app")
    fi
    for root in "${roots[@]}"; do scan_discord_root "$root"; done
    for name in discord discordptb discordcanary; do
        native_config="$CONFIG_HOME/$name"
        scan_versioned_discord "$native_config" "$(branch_from_name "$name")" native
    done
    for name in Discord DiscordPTB DiscordCanary; do
        branch=$(branch_from_name "$name")
        app_id="com.discordapp.$name"
        flatpak_base="$HOME/.var/app/$app_id/config/discord"
        scan_versioned_discord "$flatpak_base" "$branch" flatpak "$app_id"
        for root in /var/lib/flatpak/app "$HOME/.local/share/flatpak/app"; do
            [[ -d $root/$app_id/current/active/files ]] || continue
            case "$branch" in
                stable) name=discord ;;
                ptb) name=discord-ptb ;;
                canary) name=discord-canary ;;
            esac
            if [[ -d $root/$app_id/current/active/files/$name/resources ]]; then
                add_discord_candidate "$branch" flatpak "$root/$app_id" "$root/$app_id/current/active/files/$name/resources" "$app_id"
            fi
        done
    done
}

detect_equibop() {
    local found=1
    if command -v equibop >/dev/null 2>&1; then
        printf 'Equibop detected at %s.\n' "$(command -v equibop)"
        found=0
    fi
    if command -v flatpak >/dev/null 2>&1 && flatpak info org.equicord.equibop >/dev/null 2>&1; then
        printf "%s\n" "Equibop Flatpak detected (org.equicord.equibop)."
        found=0
    fi
    return "$found"
}

print_discord_targets() {
    local i
    if ((${#DISCORD_PATHS[@]} == 0)); then
        warn "No supported Discord Stable, PTB, or Canary installation was found. Snap is not supported upstream."
        return 1
    fi
    printf '%-4s %-9s %-20s %-18s %s\n' '#' 'Branch' 'Format' 'Status' 'Resolved path'
    for ((i=0; i<${#DISCORD_PATHS[@]}; i++)); do
        printf '%-4s %-9s %-20s %-18s %s\n' "$((i+1))" "${DISCORD_BRANCHES[i]}" "${DISCORD_FORMATS[i]}" "${DISCORD_STATUSES[i]}" "${DISCORD_PATHS[i]}"
    done
}

SELECTED_TARGET_INDEX=''
select_discord_target() {
    detect_discord_installations
    print_discord_targets || return 1
    local saved choice
    saved=$(state_value discord_path 2>/dev/null || true)
    if [[ -n $saved ]]; then
        for ((choice=0; choice<${#DISCORD_PATHS[@]}; choice++)); do
            if [[ ${DISCORD_PATHS[choice]} == "$saved" ]]; then
                SELECTED_TARGET_INDEX=$choice
                info "Using the previously selected ${DISCORD_BRANCHES[choice]} target: $saved"
                return 0
            fi
        done
    fi
    if ((${#DISCORD_PATHS[@]} == 1)); then SELECTED_TARGET_INDEX=0; return 0; fi
    if [[ ${MES_NONINTERACTIVE:-0} == 1 ]]; then fail "Multiple Discord installations require an explicit selection."; return 1; fi
    while true; do
        read -r -p "Choose a Discord installation [1-${#DISCORD_PATHS[@]}]: " choice
        [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#DISCORD_PATHS[@]} ]] || { warn "Invalid selection."; continue; }
        SELECTED_TARGET_INDEX=$((choice-1)); break
    done
    if [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} == flatpak ]]; then
        warn "Flatpak injection is supported by current Equilotl but remains experimental in this project until real GUI testing is complete."
        ask_yes_no "Continue with this Flatpak target?" || return 1
    fi
}

ask_yes_no() {
    local prompt=$1 response
    [[ ${MES_ASSUME_YES:-0} == 1 ]] && return 0
    [[ ${MES_NONINTERACTIVE:-0} != 1 ]] || return 1
    read -r -p "$prompt [y/N] " response
    [[ ${response,,} == y || ${response,,} == yes ]]
}

selected_process_name() {
    case ${DISCORD_BRANCHES[SELECTED_TARGET_INDEX]} in
        stable) printf 'Discord\n' ;;
        ptb) printf 'DiscordPTB\n' ;;
        canary) printf 'DiscordCanary\n' ;;
        *) printf 'Discord\n' ;;
    esac
}

wait_for_process_poll() {
    if [[ ${MES_TEST_MODE:-0} == 1 ]]; then
        return 0
    fi
    sleep 1 || true
}

close_selected_discord() {
    [[ ${MES_SKIP_PROCESS_MANAGEMENT:-0} == 1 ]] && return 0
    local process_name pid deadline
    process_name=$(selected_process_name)
    mapfile -t pids < <(pgrep -x "$process_name" 2>/dev/null || true)
    ((${#pids[@]})) || return 0
    ask_yes_no "Close the selected $process_name process before injection?" || fail "Discord must be closed before this injection target can be changed."
    for pid in "${pids[@]}"; do kill -TERM "$pid"; done
    deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        local running=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && running=1; done
        [[ $running -eq 0 ]] && return 0
        wait_for_process_poll
    done
    fail "The selected Discord process did not exit. No broad process kill was used."
}

offer_restart_selected_discord() {
    [[ ${MES_SKIP_PROCESS_MANAGEMENT:-0} == 1 ]] && return 0
    ask_yes_no "Start the selected Discord client now?" || return 0
    local format=${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} branch=${DISCORD_BRANCHES[SELECTED_TARGET_INDEX]}
    local app_id=${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]} target=${DISCORD_PATHS[SELECTED_TARGET_INDEX]} executable=''
    if [[ $format == flatpak && -n $app_id ]]; then
        command -v flatpak >/dev/null 2>&1 || { warn "Flatpak is unavailable, so Discord was not restarted."; return 0; }
        nohup flatpak run "$app_id" >/dev/null 2>&1 &
        return 0
    fi
    case $branch in
        stable) executable=$(command -v discord 2>/dev/null || true) ;;
        ptb) executable=$(command -v discord-ptb 2>/dev/null || command -v discordptb 2>/dev/null || true) ;;
        canary) executable=$(command -v discord-canary 2>/dev/null || command -v discordcanary 2>/dev/null || true) ;;
    esac
    if [[ -z $executable ]]; then
        for executable in "$target/Discord" "$target/DiscordPTB" "$target/DiscordCanary"; do
            [[ -x $executable ]] && break
            executable=''
        done
    fi
    if [[ -n $executable ]]; then
        nohup "$executable" >/dev/null 2>&1 &
    else
        warn "The exact selected client executable could not be resolved, so it was not restarted."
    fi
}

verify_selected_injection() {
    local resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]}
    [[ -e $resources/_app.asar || -e $resources/_app.asar.unpacked ]] || {
        fail "Equilotl returned without the expected injection backup marker at $resources."
        return 1
    }
    success "Verified Equicord injection for ${DISCORD_BRANCHES[SELECTED_TARGET_INDEX]} at ${DISCORD_PATHS[SELECTED_TARGET_INDEX]}."
}

download_verified_injector() {
    mkdir -p -- "$CACHE_ROOT"
    if [[ -f $INJECTOR_CACHE && $(sha256_file "$INJECTOR_CACHE") == "$EQUILOTL_LINUX_SHA256" ]]; then
        chmod 0755 "$INJECTOR_CACHE"
        return 0
    fi
    local temporary
    temporary=$(mktemp "$CACHE_ROOT/.equilotl-download.XXXXXX")
    info "Downloading official Equilotl $EQUILOTL_VERSION Linux CLI."
    if ! curl --proto '=https' --tlsv1.2 --fail --location --output "$temporary" "$EQUILOTL_LINUX_URL"; then
        rm -f -- "$temporary"
        fail "Equilotl download failed."
        return 1
    fi
    if [[ $(sha256_file "$temporary") != "$EQUILOTL_LINUX_SHA256" ]]; then
        rm -f -- "$temporary"
        fail "The downloaded Equilotl asset did not match its published GitHub SHA-256 digest."
        return 1
    fi
    chmod 0755 "$temporary"
    mv -f -- "$temporary" "$INJECTOR_CACHE"
}

run_injector() {
    local action=${1:-install} target resources
    target=${DISCORD_PATHS[SELECTED_TARGET_INDEX]}
    resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]}
    close_selected_discord
    download_verified_injector
    local -a environment=(
        "HOME=$HOME"
        "XDG_CONFIG_HOME=$CONFIG_HOME"
        "XDG_DATA_HOME=$DATA_HOME"
        "XDG_STATE_HOME=$STATE_HOME"
        "XDG_CACHE_HOME=$CACHE_HOME"
        "EQUICORD_USER_DATA_DIR=$STATE_ROOT/equilotl"
        "EQUICORD_DIRECTORY=$WORKSPACE/dist/desktop"
        "EQUICORD_DEV_INSTALL=1"
    )
    local flag='--install'
    [[ $action == repair ]] && flag='--repair'
    if [[ -w $resources ]]; then
        env "${environment[@]}" "$INJECTOR_CACHE" "$flag" --location "$target"
    else
        command -v sudo >/dev/null 2>&1 || fail "This system-owned Discord target needs sudo for the injector only, but sudo is unavailable."
        info "Requesting elevation only for the verified Equilotl injector and selected system target."
        sudo env "${environment[@]}" "$INJECTOR_CACHE" "$flag" --location "$target"
    fi
    verify_selected_injection
    offer_restart_selected_discord
}

write_state_manifest() {
    local injection_result=$1 backup=${2:-} temporary commit now plugin file relative
    mkdir -p -- "$STATE_ROOT"
    temporary=$(mktemp "$STATE_ROOT/.manifest.XXXXXX")
    commit=$(git -C "$WORKSPACE" rev-parse HEAD)
    now=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    {
        printf 'format\t%s\n' "$STATE_FORMAT"
        printf 'manager_version\t%s\n' "$MANAGER_VERSION"
        printf 'upstream_remote\t%s\n' "$(effective_equicord_remote)"
        printf 'upstream_commit\t%s\n' "$commit"
        printf 'discord_branch\t%s\n' "${DISCORD_BRANCHES[SELECTED_TARGET_INDEX]:-none}"
        printf 'discord_format\t%s\n' "${DISCORD_FORMATS[SELECTED_TARGET_INDEX]:-none}"
        printf 'discord_path\t%s\n' "${DISCORD_PATHS[SELECTED_TARGET_INDEX]:-none}"
        printf 'last_successful_build\t%s\n' "$now"
        printf 'backup\t%s\n' "$backup"
        printf 'injection_result\t%s\n' "$injection_result"
        for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
            [[ -d $WORKSPACE/src/userplugins/$plugin ]] || continue
            printf 'plugin\t%s\n' "$plugin"
            while IFS= read -r file; do
                relative=${file#"$WORKSPACE/src/userplugins/$plugin/"}
                printf 'file\t%s\t%s\t%s\n' "$plugin" "$relative" "$(sha256_file "$file")"
            done < <(find "$WORKSPACE/src/userplugins/$plugin" -type f -print | LC_ALL=C sort)
        done
    } > "$temporary"
    atomic_write_text "$STATE_FILE" "$temporary"
    rm -f -- "$temporary"
}

perform_install() {
    local update_source=${1:-0} backup
    platform_preflight
    check_dependencies
    make_manager_directories
    clone_or_validate_workspace
    [[ $update_source -eq 0 ]] || update_workspace_fast_forward
    select_upstream_package_manager
    install_upstream_dependencies
    select_discord_target
    if ! backup=$(deploy_bundled_plugins); then return 1; fi
    if ! build_equicord; then
        warn "Build failed. Restoring the previous manager-owned plugin tree."
        restore_plugin_tree_from_backup "$backup"
        if ! build_equicord; then
            warn "The previous plugin source was restored, but its build output could not be regenerated. The backup remains at $backup."
        fi
        return 1
    fi
    if run_injector install; then
        write_state_manifest success "$backup"
        success "The source-built Equicord bundle, all custom plugins, and injection were verified."
    else
        write_state_manifest failed "$backup"
        fail "The custom bundle built successfully, but Discord injection failed."
    fi
}

perform_rebuild() {
    local backup
    platform_preflight
    check_dependencies
    make_manager_directories
    clone_or_validate_workspace
    select_discord_target
    backup=$(deploy_bundled_plugins)
    if ! build_equicord; then restore_plugin_tree_from_backup "$backup"; return 1; fi
    if run_injector repair; then write_state_manifest success "$backup"; else write_state_manifest failed "$backup"; return 1; fi
}

perform_remove() {
    local backup plugin
    platform_preflight
    check_dependencies
    make_manager_directories
    clone_or_validate_workspace
    select_discord_target
    backup=$(create_plugin_backup remove)
    for plugin in "${BUNDLED_PLUGIN_NAMES[@]}"; do
        if [[ -d $WORKSPACE/src/userplugins/$plugin ]]; then
            if plugin_changed_since_state "$plugin"; then
                warn "$plugin has local edits; it has been backed up to $backup."
                ask_yes_no "Remove this manager-owned plugin copy?" || continue
            fi
            safe_remove_tree "$WORKSPACE/src/userplugins/$plugin" "$WORKSPACE/src/userplugins"
        fi
    done
    if ! build_equicord; then
        warn "The build without the custom plugins failed. Restoring the previous plugin set."
        restore_plugin_tree_from_backup "$backup"
        return 1
    fi
    run_injector repair
    write_state_manifest removed "$backup"
    success "Removed only the manager-owned custom plugins and rebuilt Equicord."
}

perform_restore() {
    local -a backups=()
    local backup choice
    platform_preflight
    check_dependencies
    make_manager_directories
    clone_or_validate_workspace
    while IFS= read -r backup; do backups+=("$backup"); done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort -r)
    ((${#backups[@]})) || fail "No manager backup is available."
    printf 'Available backups:\n'
    for ((choice=0; choice<${#backups[@]}; choice++)); do printf '  %d. %s\n' "$((choice+1))" "${backups[choice]}"; done
    if [[ ${MES_NONINTERACTIVE:-0} == 1 ]]; then choice=1; else read -r -p "Choose a backup [1-${#backups[@]}]: " choice; fi
    [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#backups[@]} ]] || fail "Invalid backup selection."
    backup=${backups[choice-1]}
    restore_plugin_tree_from_backup "$backup"
    select_discord_target
    build_equicord
    run_injector repair
    write_state_manifest restored "$backup"
    success "Restored and rebuilt backup: $backup"
}

status_and_diagnostics() {
    init_paths
    printf '%s %s\n' "$MANAGER_NAME" "$MANAGER_VERSION"
    printf 'System: %s (%s)\n' "$(distribution_name)" "$(uname -m)"
    printf 'Upstream compatibility baseline: %s\n' "$TESTED_EQUICORD_COMMIT"
    printf 'Workspace: %s\n' "$WORKSPACE"
    printf 'State: %s\n' "$STATE_FILE"
    printf 'Backups: %s\n' "$BACKUP_ROOT"
    if [[ -d $WORKSPACE/.git ]]; then
        printf 'Equicord commit: %s\n' "$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || printf unknown)"
        printf 'Equicord remote: %s\n' "$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null || printf unknown)"
        if [[ -d $WORKSPACE/dist ]]; then verify_plugin_bundle || true; else warn "No Equicord build output exists yet."; fi
    else
        warn "No manager-owned Equicord source workspace exists yet."
    fi
    detect_discord_installations
    print_discord_targets || true
    if detect_equibop; then
        warn "Packaged Equibop does not automatically include this repository's custom plugins. This manager does not alter Equibop settings."
    fi
    command -v node >/dev/null 2>&1 && printf 'Node.js: %s\n' "$(node --version)" || printf 'Node.js: missing\n'
    command -v git >/dev/null 2>&1 && printf 'Git: %s\n' "$(git --version)" || printf 'Git: missing\n'
    [[ -f $STATE_FILE ]] && printf 'Last build: %s\nInjection result: %s\n' "$(state_value last_successful_build || true)" "$(state_value injection_result || true)"
}

platform_preflight() {
    [[ $(uname -s) == Linux ]] || { fail "Equicord-Linux.sh supports Linux only."; return 1; }
    [[ $(id -u) -ne 0 ]] || { fail "Do not run this script with sudo or as root. Rerun it as your normal user."; return 1; }
    if [[ -e /dev/.cros_milestone ]] || grep -qi chromeos /etc/lsb-release 2>/dev/null; then
        fail "ChromeOS native Linux is not supported by the current upstream workflow."
        return 1
    fi
    if [[ -e /etc/NIXOS ]]; then
        warn "NixOS detected. The official Equibop Nix package is currently documented as outdated, and this manager does not claim full NixOS support."
    fi
    [[ $(uname -m) == x86_64 ]] || { fail "This beta supports x86_64 Linux only because the verified Equilotl Linux CLI asset is x86_64."; return 1; }
}

print_menu() {
    printf '\n%s %s\n\n' "$MANAGER_NAME" "$MANAGER_VERSION"
    printf '  1. Install or repair my Equicord setup\n'
    printf '  2. Update Equicord and my plugins\n'
    printf '  3. Rebuild and reapply my plugins\n'
    printf '  4. Remove only my custom plugin setup\n'
    printf '  5. Restore a backup\n'
    printf '  6. Status and diagnostics\n'
    printf '  7. Exit\n\n'
}

main() {
    init_paths
    case ${1:-} in
        --install|--repair) perform_install 0; return ;;
        --update) perform_install 1; return ;;
        --rebuild) perform_rebuild; return ;;
        --remove) perform_remove; return ;;
        --restore) perform_restore; return ;;
        --status) status_and_diagnostics; return ;;
        --help|-h)
            printf 'Usage: %s [--install|--update|--rebuild|--remove|--restore|--status]\n' "$0"
            return
            ;;
        '') ;;
        *) fail "Unknown option: $1"; return 2 ;;
    esac
    while true; do
        print_menu
        local choice
        read -r -p 'Choose an option [1-7]: ' choice
        case $choice in
            1) perform_install 0 ;;
            2) perform_install 1 ;;
            3) perform_rebuild ;;
            4) perform_remove ;;
            5) perform_restore ;;
            6) status_and_diagnostics ;;
            7) return 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
