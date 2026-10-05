#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# All package-manager executables and HOME are disposable fixtures, never real installs.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
release="$script_dir/../Equicord-Linux.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/my-equicord-pnpm-tests.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
original_path=$PATH

fixture() {
    export HOME="$case_root/home données with spaces"
    export XDG_CONFIG_HOME="$HOME/config" XDG_DATA_HOME="$HOME/data"
    export XDG_STATE_HOME="$HOME/state" XDG_CACHE_HOME="$HOME/cache"
    export MES_TEST_MODE=1 MES_NONINTERACTIVE=1
    unset MES_ASSUME_YES
    init_paths
    mkdir -p "$HOME" "$WORKSPACE" "$case_root/tools" "$case_root/system/bin"
    export MOCK_ROOT="$case_root" MOCK_VERSION=11.22.0 MOCK_COREPACK=modern MOCK_NPM=ok
    local tool executable
    # No real npm, pnpm, or Corepack is reachable on the fixture PATH.
    for tool in bash node git curl sha256sum base64 mktemp realpath awk sed grep find pgrep nohup \
        cat dirname stat id chmod mkdir ln rm mv cp sort wc tr uname; do
        executable=$(PATH="$original_path" type -P "$tool")
        ln -s "$executable" "$case_root/tools/$tool"
    done
    export PATH="$case_root/system/bin:$case_root/tools"
    printf '{"packageManager":"pnpm@11.22.0"}\n' > "$WORKSPACE/package.json"
    : > "$case_root/calls"
    cat > "$case_root/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
tool=${0##*/}
printf '%s' "$tool" >> "$MOCK_ROOT/calls"
printf ' <%s>' "$@" >> "$MOCK_ROOT/calls"
printf '\n' >> "$MOCK_ROOT/calls"
case $tool in
    corepack)
        case ${1:-} in
            install)
                [[ $MOCK_COREPACK == modern || $MOCK_COREPACK == wrong ]] || exit 2
                printf '%s\n' "${3#*@}" > "$MOCK_ROOT/corepack-version"
                ;;
            prepare)
                [[ $MOCK_COREPACK == legacy ]] || exit 3
                printf '%s\n' "${2#*@}" > "$MOCK_ROOT/corepack-version"
                ;;
            pnpm@*)
                [[ -f $MOCK_ROOT/corepack-version ]] || exit 4
                [[ ${1#*@} == "$(cat "$MOCK_ROOT/corepack-version")" ]] || exit 5
                if [[ ${2:-} == --version ]]; then
                    if [[ $MOCK_COREPACK == wrong ]]; then printf '1.0.0\n'; else cat "$MOCK_ROOT/corepack-version"; fi
                fi
                ;;
            *) exit 6 ;;
        esac
        ;;
    npm)
        [[ $* == "install --global --prefix $HOME/.local pnpm@$MOCK_VERSION" ]] || exit 7
        [[ $MOCK_NPM != fail ]] || exit 8
        version=$MOCK_VERSION
        [[ $MOCK_NPM != wrong ]] || version=1.0.0
        prefix="$HOME/.local"
        mkdir -p "$prefix/bin" "$prefix/lib/node_modules/pnpm/bin"
        printf '#!/usr/bin/env bash\nif [[ ${1:-} == --version ]]; then printf "%%s\\n" %q; else printf "local %%s\\n" "$*" >> "$MOCK_ROOT/calls"; fi\n' "$version" > "$prefix/lib/node_modules/pnpm/bin/pnpm.cjs"
        chmod 0755 "$prefix/lib/node_modules/pnpm/bin/pnpm.cjs"
        ln -sfn ../lib/node_modules/pnpm/bin/pnpm.cjs "$prefix/bin/pnpm"
        ;;
    *) exit 9 ;;
esac
MOCK
    chmod +x "$case_root/mock"
}

add_tool() { ln -s "$case_root/mock" "$case_root/tools/$1"; }
system_pnpm() {
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nif [[ ${1:-} == --version ]]; then printf "%%s\\n" %q; else printf "system %%s\\n" "$*" >> "$MOCK_ROOT/calls"; fi\n' "$1" > "$case_root/system/bin/pnpm"
    chmod +x "$case_root/system/bin/pnpm"
}
must_fail() { if "$@"; then printf 'Expected failure: %s\n' "$*" >&2; return 1; fi; }
selected_local() {
    [[ ${PACKAGE_MANAGER_COMMAND[*]} == "$HOME/.local/bin/pnpm" ]]
    [[ $(package_manager_version "${PACKAGE_MANAGER_COMMAND[@]}") == "$MOCK_VERSION" ]]
}
no_provisioning() { ! grep -Eq '^(npm|corepack) <(install|prepare)>' "$case_root/calls"; }

test_exact() {
    fixture; system_pnpm "$MOCK_VERSION"; add_tool npm; add_tool corepack
    select_upstream_package_manager
    [[ ${PACKAGE_MANAGER_COMMAND[0]} == "$case_root/system/bin/pnpm" && $PACKAGE_MANAGER_METHOD == 'already correct' ]]
    no_provisioning
}
test_mismatch() {
    fixture; system_pnpm "$1"; add_tool npm
    local before
    before=$(sha256_file "$case_root/system/bin/pnpm")
    select_upstream_package_manager
    selected_local
    [[ $(sha256_file "$case_root/system/bin/pnpm") == "$before" ]]
    # Install/build must keep using the pinned path even if PATH is changed later.
    export PATH="$case_root/system/bin:$case_root/tools"
    install_upstream_dependencies
    mkdir -p "$WORKSPACE/node_modules"
    verify_plugin_bundle() { :; }
    build_equicord
    grep -Fxq 'local install' "$case_root/calls"
    grep -Fxq 'local build' "$case_root/calls"
    ! grep -q '^system ' "$case_root/calls"
}
test_no_system() { fixture; add_tool npm; select_upstream_package_manager; selected_local; }
test_corepack() {
    fixture; system_pnpm 11.26.0; add_tool corepack; add_tool npm
    MOCK_COREPACK=$1
    select_upstream_package_manager
    [[ ${PACKAGE_MANAGER_COMMAND[0]} == "$case_root/tools/corepack" && ${PACKAGE_MANAGER_COMMAND[1]} == pnpm@11.22.0 ]]
    grep -Fxq 'corepack <install> <--global> <pnpm@11.22.0>' "$case_root/calls"
    if [[ $1 == legacy ]]; then grep -Fxq 'corepack <prepare> <pnpm@11.22.0> <--activate>' "$case_root/calls"; fi
    must_fail grep -q '^npm ' "$case_root/calls"
    : > "$case_root/calls"
    select_upstream_package_manager
    [[ $PACKAGE_MANAGER_METHOD == 'Corepack (cached)' ]]
    no_provisioning
}
test_corepack_unusable() {
    fixture; add_tool corepack; add_tool npm; MOCK_COREPACK=${1:-broken}
    select_upstream_package_manager; selected_local
    grep -q '^corepack <install>' "$case_root/calls"
    grep -q '^corepack <prepare>' "$case_root/calls"
    grep -q '^npm <install>' "$case_root/calls"
}
test_no_provisioner() {
    fixture; system_pnpm 11.26.0
    must_fail select_upstream_package_manager > "$case_root/report" 2>&1
    grep -Fq 'Corepack: unavailable' "$case_root/report"
    grep -Fq 'npm fallback: not attempted' "$case_root/report"
}
test_npm_failure() {
    fixture; add_tool npm; MOCK_NPM=$1
    must_fail select_upstream_package_manager > "$case_root/report" 2>&1
    [[ -z ${PACKAGE_MANAGER_COMMAND[*]-} ]]
    grep -Fq 'exact upstream package manager could not be executed' "$case_root/report"
    grep -Fq 'Last executable checked:' "$case_root/report"
}
test_declaration() {
    fixture; add_tool npm; add_tool corepack
    printf '%s\n' "$1" > "$WORKSPACE/package.json"
    must_fail select_upstream_package_manager > "$case_root/report" 2>&1
    grep -Fq "$2" "$case_root/report"
    [[ ! -s $case_root/calls ]]
}
test_resolution_failure_blocks_build() {
    fixture; system_pnpm 11.26.0
    install_upstream_dependencies() { printf 'unexpected install\n' > "$case_root/unexpected"; }
    must_fail build_equicord
    [[ ! -e $case_root/unexpected && -z ${PACKAGE_MANAGER_COMMAND[*]-} ]]
}
test_changed_invalid_declaration() {
    fixture; system_pnpm "$MOCK_VERSION"
    select_upstream_package_manager
    printf '{"packageManager":"npm@11.0.0"}\n' > "$WORKSPACE/package.json"
    must_fail select_upstream_package_manager
    [[ -z ${PACKAGE_MANAGER_COMMAND[*]-} && -z $PACKAGE_MANAGER_DECLARATION ]]
    must_fail install_upstream_dependencies
}
test_precedence_and_hash() {
    fixture; system_pnpm 11.26.0; add_tool npm
    "$case_root/tools/npm" install --global --prefix "$HOME/.local" "pnpm@$MOCK_VERSION"
    hash -p "$case_root/system/bin/pnpm" pnpm
    : > "$case_root/calls"
    select_upstream_package_manager
    selected_local
    no_provisioning
    [[ $PACKAGE_MANAGER_METHOD == 'user-local npm (reused)' ]]
    [[ ${PATH%%:*} == "$HOME/.local/bin" ]]
}
test_idempotent_and_changed() {
    fixture; add_tool npm
    select_upstream_package_manager; selected_local
    local selected_path=$PATH
    : > "$case_root/calls"
    select_upstream_package_manager; selected_local; no_provisioning
    [[ $PATH == "$selected_path" ]]
    MOCK_VERSION=11.30.0
    printf '{"packageManager":"pnpm@%s"}\n' "$MOCK_VERSION" > "$WORKSPACE/package.json"
    select_upstream_package_manager; selected_local
    [[ $(grep -c '^npm <install>' "$case_root/calls") -eq 1 ]]
    [[ $PACKAGE_MANAGER_DECLARATION == pnpm@11.30.0 ]]
}
test_diagnostics() {
    fixture; system_pnpm 11.26.0; add_tool npm
    select_upstream_package_manager > "$case_root/report"
    grep -Fq 'PATH pnpm version        : 11.26.0' "$case_root/report"
    grep -Fq 'Provisioning method      : user-local npm' "$case_root/report"
    grep -Fq 'Active version           : 11.22.0' "$case_root/report"
    grep -Fq "Executable               : $HOME/.local/bin/pnpm" "$case_root/report"
}
test_readonly_preflight() {
    fixture; system_pnpm 11.26.0; add_tool npm
    workspace_is_valid_for_dependency_check() { return 0; }
    check_dependencies
    [[ ! -d $HOME/.local && -z ${PACKAGE_MANAGER_COMMAND[*]-} ]]
    no_provisioning
    # Acquisition/update occurs before provisioning, so an old requirement is not installed.
    MOCK_VERSION=11.30.0
    printf '{"packageManager":"pnpm@%s"}\n' "$MOCK_VERSION" > "$WORKSPACE/package.json"
    select_upstream_package_manager
    grep -q '^npm .*<pnpm@11.30.0>$' "$case_root/calls"
    ! grep -q '^npm .*<pnpm@11.22.0>$' "$case_root/calls"
}
test_readonly_status() {
    fixture; system_pnpm 11.26.0; add_tool npm
    workspace_is_valid_for_dependency_check() { return 0; }
    detect_discord_installations() { :; }
    print_discord_targets() { :; }
    detect_equibop() { return 1; }
    # The existing status function returns the result of its optional state-file check.
    status_and_diagnostics > "$case_root/report" || true
    grep -Fq 'provisioning deferred' "$case_root/report"
    [[ ! -d $HOME/.local ]]
    no_provisioning
}
test_distro() {
    fixture; system_pnpm 11.26.0; add_tool npm
    export MES_TEST_OS_RELEASE="$case_root/os-release"
    printf '%s\n' "$1" > "$MES_TEST_OS_RELEASE"
    print_dependency_install_help > "$case_root/help" 2>&1
    grep -Fq "$2" "$case_root/help"
    if [[ $2 == apt ]]; then must_fail grep -Eq 'pacman|dnf|zypper' "$case_root/help"; fi
    if [[ $2 == pacman ]]; then must_fail grep -Eq 'apt |dnf|zypper' "$case_root/help"; fi
    check_dependencies
    select_upstream_package_manager; selected_local
}
test_ubuntu_prerequisites() {
    fixture
    export MES_TEST_OS_RELEASE="$case_root/os-release"
    printf 'ID=ubuntu\nID_LIKE=debian\n' > "$MES_TEST_OS_RELEASE"
    rm "$case_root/tools/node"
    must_fail check_dependencies > "$case_root/report" 2>&1
    grep -Fq 'Missing required command: node' "$case_root/report"
    grep -Fq 'sudo apt install nodejs npm' "$case_root/report"
    must_fail grep -Eq 'pacman|dnf|zypper' "$case_root/report"
    ln -s "$(PATH="$original_path" type -P node)" "$case_root/tools/node"
    add_tool npm
    check_dependencies
    select_upstream_package_manager; selected_local
}
test_unsafe_prefix() {
    fixture; add_tool npm
    mkdir "$case_root/elsewhere"
    ln -s "$case_root/elsewhere" "$HOME/.local"
    must_fail select_upstream_package_manager
    no_provisioning
    [[ -z $(find "$case_root/elsewhere" -mindepth 1 -print -quit) ]]
}
test_unsafe_executable() {
    fixture; add_tool npm; system_pnpm 11.26.0
    mkdir -p "$HOME/.local/bin"
    ln -s "$case_root/system/bin/pnpm" "$HOME/.local/bin/pnpm"
    must_fail select_upstream_package_manager
    no_provisioning
    [[ $("$case_root/system/bin/pnpm" --version) == 11.26.0 ]]
}
test_broadly_writable() {
    fixture; add_tool npm
    mkdir -p "$HOME/.local/bin"
    chmod 0777 "$HOME/.local/bin"
    must_fail select_upstream_package_manager
    no_provisioning
}
test_no_profile_or_prefix_changes() {
    fixture; add_tool npm
    printf 'prefix=/untouched\n' > "$HOME/.npmrc"
    printf 'untouched\n' > "$HOME/.profile"
    select_upstream_package_manager
    grep -Fxq 'prefix=/untouched' "$HOME/.npmrc"
    grep -Fxq untouched "$HOME/.profile"
    [[ ! -e $HOME/.bashrc && ! -e $HOME/.zshrc ]]
}
test_safe_creation_mask() {
    fixture; add_tool npm
    umask 0002
    select_upstream_package_manager
    selected_local
    # npm's executable symlink has nominal 0777 link mode; only target permissions matter.
    [[ -z $(find "$HOME/.local" ! -type l -perm /022 -print -quit) ]]
}

passes=0 failures=0
run_test() {
    local name=$1
    shift
    case_root=$(mktemp -d "$temporary_root/case.XXXXXX")
    # A separate Bash process preserves errexit so no intermediate assertion is ignored.
    if bash "$0" --case "$case_root" "$@" > "$case_root/output" 2>&1; then
        printf 'ok - package manager %s\n' "$name"
        passes=$((passes + 1))
    else
        printf 'not ok - package manager %s\n' "$name" >&2
        cat "$case_root/output" >&2
        failures=$((failures + 1))
    fi
}
if [[ ${1:-} == --case ]]; then
    case_root=$2
    shift 2
    # shellcheck source=/dev/null
    source "$release"
    "$@"
    exit
fi

run_test 'exact active version reused' test_exact
run_test 'newer distro pnpm preserved; selected binary installs/builds' test_mismatch 11.26.0
run_test 'older distro pnpm preserved; selected binary installs/builds' test_mismatch 11.21.0
run_test 'no pnpm, no Corepack, npm available' test_no_system
run_test 'modern Corepack and cached rerun' test_corepack modern
run_test 'legacy Corepack fallback and cached rerun' test_corepack legacy
run_test 'unusable Corepack falls back to npm' test_corepack_unusable
run_test 'Corepack succeeds but reports wrong version; npm fallback' test_corepack_unusable wrong
run_test 'neither Corepack nor npm' test_no_provisioner
run_test 'npm install fails' test_npm_failure fail
run_test 'npm reports success but wrong version' test_npm_failure wrong
run_test 'missing declaration' test_declaration '{}' 'Missing Equicord packageManager'
run_test 'malformed declaration' test_declaration '{"packageManager":"pnpm@latest"}' 'Malformed Equicord packageManager'
run_test 'unsupported manager' test_declaration '{"packageManager":"yarn@4.0.0"}' 'Unsupported Equicord package manager'
run_test 'invalid JSON' test_declaration '{' 'Cannot read Equicord package.json as JSON'
run_test 'untrusted command fragment rejected' test_declaration '{"packageManager":"pnpm@11.22.0;touch /tmp/unsafe"}' 'Malformed Equicord packageManager'
run_test 'non-string declaration' test_declaration '{"packageManager":{}}' 'Malformed Equicord packageManager'
run_test 'resolution failure blocks dependency install and build' test_resolution_failure_blocks_build
run_test 'changed invalid declaration clears stale selected command' test_changed_invalid_declaration
run_test 'PATH precedence and cached wrong executable' test_precedence_and_hash
run_test 'idempotent rerun and new upstream requirement' test_idempotent_and_changed
run_test 'accurate method/version/executable diagnostics' test_diagnostics
run_test 'read-only preflight and changed checkout requirement' test_readonly_preflight
run_test 'status never provisions' test_readonly_status
run_test 'CachyOS/Arch guidance and common npm fallback' test_distro $'ID=cachyos\nID_LIKE=arch' pacman
run_test 'Ubuntu guidance and common npm fallback' test_distro $'ID=ubuntu\nID_LIKE=debian' apt
run_test 'Debian guidance and common npm fallback' test_distro 'ID=debian' apt
run_test 'Ubuntu missing prerequisites then npm fallback' test_ubuntu_prerequisites
run_test 'Fedora guidance and common npm fallback' test_distro 'ID=fedora' dnf
run_test 'openSUSE guidance and common npm fallback' test_distro 'ID=opensuse-tumbleweed' zypper
run_test 'unknown distro generic guidance' test_distro 'ID=unknown' 'trusted source'
run_test 'symlinked prefix rejected' test_unsafe_prefix
run_test 'external pnpm symlink preserved' test_unsafe_executable
run_test 'broadly writable prefix rejected' test_broadly_writable
run_test 'no persistent shell/npm configuration changes' test_no_profile_or_prefix_changes
run_test 'new npm prefix stays safe with group-writable caller umask' test_safe_creation_mask
printf '\nLinux package-manager tests: %d passed, %d failed.\n' "$passes" "$failures"
[[ $failures -eq 0 ]]
