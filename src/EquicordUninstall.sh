# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Full Linux removal and reversible Flatpak permission bookkeeping.
# Included in the self-contained release by Build-LinuxRelease.sh.

init_uninstall_paths() {
    UNINSTALL_STATE="$STATE_ROOT/uninstall.tsv"
    UNINSTALL_INVENTORY="$STATE_ROOT/uninstall-inventory"
    FLATPAK_RECORD="$STATE_ROOT/flatpak-override"
}

require_unlinked_path() {
    local path=$1 cursor
    [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* ]] || { fail "Invalid absolute path: $path"; return 1; }
    cursor=$path
    while [[ $cursor != / ]]; do
        [[ ! -L $cursor ]] || { fail "Refusing symlink traversal: $cursor"; return 1; }
        cursor=$(dirname -- "$cursor")
    done
    [[ $(realpath -ms -- "$path") == "$path" ]] || { fail "Path is not normalized: $path"; return 1; }
}

validate_removal_roots() {
    local root base other uid
    uid=$(id -u)
    local -a roots=("$DATA_ROOT" "$CONFIG_ROOT" "$CACHE_ROOT" "$STATE_ROOT")
    local -a bases=("$DATA_HOME" "$CONFIG_HOME" "$CACHE_HOME" "$STATE_HOME")
    local i
    for ((i=0; i<${#roots[@]}; i++)); do
        root=${roots[i]}; base=${bases[i]}
        [[ $root == "$base/my-equicord-setup" && $root != / && $root != "$HOME" && $root != "$base" ]] || return 1
        require_unlinked_path "$root" || return 1
        for other in "${roots[@]}"; do
            [[ $root == "$other" ]] && continue
            [[ $root != "$other"/* && $other != "$root"/* ]] || { fail "Overlapping manager roots require manual review."; return 1; }
        done
        [[ ! -e $root || ( -d $root && $(stat -c %u -- "$root") == "$uid" ) ]] || {
            fail "Manager directory is not owned by the current user: $root"; return 1;
        }
        if [[ -d $root ]] && [[ -n $(find -P "$root" ! -uid "$uid" -print -quit) ]]; then
            fail "Some manager files are owned by another user. They were preserved: $root"; return 1
        fi
    done
    [[ $(printf '%s\n' "${roots[@]}" | sort -u | wc -l) -eq 4 ]] || {
        fail "Full removal requires distinct XDG manager roots; no files were deleted."; return 1;
    }
    [[ $WORKSPACE == "$DATA_ROOT/Equicord" && $OWNER_MARKER == "$DATA_ROOT/manager-owned.tsv" ]] || return 1
}

tsv_value() {
    local file=$1 key=$2
    [[ -f $file && ! -L $file ]] || return 1
    awk -F '\t' -v key="$key" '$1 == key {sub(/^[^\t]*\t/, ""); print; exit}' "$file"
}

validate_removal_manifest() {
    [[ ${BUNDLED_PAYLOAD_FORMAT:-0} == 1 ]] || { fail "Unsupported bundled payload format. Use the generated release script."; return 1; }
    require_unlinked_path "$STATE_FILE" || return 1
    [[ -f $STATE_FILE && $(state_value format) == "$STATE_FORMAT" ]] || { fail "A valid install manifest is required for full removal."; return 1; }
    [[ $(normalize_git_remote "$(state_value upstream_remote)") == "$(normalize_git_remote "$(effective_equicord_remote)")" ]] || return 1
    [[ $(state_value upstream_commit) =~ ^[0-9a-f]{40}$ ]] || return 1
    local record plugin relative hash
    while IFS=$'\t' read -r record plugin relative hash; do
        if [[ $record == plugin || $record == file ]]; then
            is_bundled_plugin "$plugin" || { fail "Unknown plugin ownership record: $plugin"; return 1; }
        fi
        if [[ $record == file ]]; then
            [[ $relative =~ ^[A-Za-z0-9._-]+$ && $relative != . && $relative != .. && $hash =~ ^[0-9a-f]{64}$ ]] || return 1
        fi
    done < "$STATE_FILE"
    local key
    for key in format upstream_remote upstream_commit discord_branch discord_format discord_path; do
        [[ $(awk -F '\t' -v key="$key" '$1==key {n++} END {print n+0}' "$STATE_FILE") -eq 1 ]] || return 1
    done
}

select_recorded_removal_target() {
    local saved branch format i
    saved=$(state_value discord_path); branch=$(state_value discord_branch); format=$(state_value discord_format)
    detect_discord_installations
    for ((i=0; i<${#DISCORD_PATHS[@]}; i++)); do
        if [[ ${DISCORD_PATHS[i]} == "$saved" && ${DISCORD_BRANCHES[i]} == "$branch" && ${DISCORD_FORMATS[i]} == "$format" ]]; then
            SELECTED_TARGET_INDEX=$i
            validate_selected_removal_target
            return
        fi
    done
    print_discord_targets || true
    fail "The recorded Discord target is unavailable. No other installation was selected or changed: $saved"
}

validate_selected_removal_target() {
    local target=${DISCORD_PATHS[SELECTED_TARGET_INDEX]} resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]}
    local format=${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} branch=${DISCORD_BRANCHES[SELECTED_TARGET_INDEX]} name
    [[ $branch == stable || $branch == ptb || $branch == canary ]] || return 1
    case $format in native|flatpak|appimage-directory|system-electron) ;; *) fail "Unsupported removal format: $format"; return 1 ;; esac
    [[ $target != / && $target != "$HOME" && -d $target && -d $resources ]] || return 1
    require_unlinked_path "$target" && require_unlinked_path "$resources" || return 1
    [[ $resources == "$target"/resources || $resources == "$target"/app-*/resources ||
       ( $format == system-electron && $resources == "$target" ) ||
       ( $format == flatpak && $resources == "$target"/*/files/*/resources ) ]] || {
        fail "Discord resources do not match the recorded installation layout."; return 1;
    }
    for name in app.asar _app.asar app.asar.tmp app.asar.unpacked _app.asar.unpacked; do
        require_unlinked_path "$resources/$name" || return 1
    done
    if [[ $format == flatpak ]]; then flatpak_override_location >/dev/null || return 1; fi
}

# Parse the ASAR header rather than treating an arbitrary nonempty file as Discord.
# Node is already required by this source-built setup; pnpm is not needed to uninstall.
asar_kind() {
    node - "$1" "$WORKSPACE/dist/desktop" <<'__MES_ASAR_INSPECT__'
const fs = require("node:fs");
const [file, expected] = process.argv.slice(2);
try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.size < 16) throw Error("not an archive");
    const fd = fs.openSync(file, "r");
    try {
        const prefix = Buffer.alloc(16);
        fs.readSync(fd, prefix, 0, 16, 0);
        const size = prefix.readUInt32LE(12), offset = prefix.readUInt32LE(4) + 8;
        if (prefix.readUInt32LE(0) !== 4 || size > 16777216 || size < 2 || offset < size + 16 || offset > stat.size) throw Error("invalid header");
        const bytes = Buffer.alloc(size);
        fs.readSync(fd, bytes, 0, size, 16);
        const files = JSON.parse(bytes.toString("utf8")).files;
        if (!files || !files["package.json"]) throw Error("missing package");
        if (Object.keys(files).length > 2 && stat.size >= 4096) {
            console.log("original");
        } else {
            const entry = files["index.js"];
            if (!entry || entry.size > 131072 || !/^\d+$/.test(entry.offset)) throw Error("unknown loader");
            const code = Buffer.alloc(entry.size);
            fs.readSync(fd, code, 0, entry.size, offset + Number(entry.offset));
            console.log(code.toString("utf8").trim() === `require(${JSON.stringify(expected)})` ? "manager-loader" : "foreign-loader");
        }
    } finally { fs.closeSync(fd); }
} catch { console.log("invalid"); }
__MES_ASAR_INSPECT__
}

inspect_removal_injection() {
    local resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]} current backup
    current=$(asar_kind "$resources/app.asar") || return 1
    REMOVAL_INJECTION=clean
    if [[ -e $resources/_app.asar ]]; then
        backup=$(asar_kind "$resources/_app.asar") || return 1
        [[ $backup == original && ( $current == original || $current == manager-loader ) ]] || {
            fail "Missing/corrupt original backup or an unrecognized loader. Recovery files were preserved."; return 1;
        }
        REMOVAL_INJECTION=injected
        if [[ $current == manager-loader ]]; then
            ORIGINAL_ASAR_HASH=$(sha256_file "$resources/_app.asar")
        else
            ORIGINAL_ASAR_HASH=$(sha256_file "$resources/app.asar")
        fi
    else
        [[ $current == original ]] || { fail "Discord restoration cannot be verified; app.asar or its backup is invalid."; return 1; }
        ORIGINAL_ASAR_HASH=$(sha256_file "$resources/app.asar")
    fi
    if [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} == system-electron ]]; then
        local unpacked="$resources/app.asar.unpacked"
        [[ $current != manager-loader ]] || unpacked="$resources/_app.asar.unpacked"
        [[ -d $unpacked ]] || { fail "System Electron's original unpacked archive is missing."; return 1; }
    fi
}

verify_removal_restoration() {
    local resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]} name
    validate_selected_removal_target || return 1
    for name in _app.asar _app.asar.unpacked app.asar.tmp; do [[ ! -e $resources/$name && ! -L $resources/$name ]] || return 1; done
    [[ $(asar_kind "$resources/app.asar") == original && $(sha256_file "$resources/app.asar") == "$ORIGINAL_ASAR_HASH" ]] || return 1
    [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} != system-electron || -d $resources/app.asar.unpacked ]]
}

workspace_safe_for_full_removal() {
    local dirty file relative plugin expected
    [[ -d $WORKSPACE/.git && ! -L $WORKSPACE/.git ]] || return 1
    [[ $(git -C "$WORKSPACE" rev-parse --show-toplevel) == "$WORKSPACE" ]] || return 1
    validate_official_remote || return 1
    [[ -f $WORKSPACE/package.json && -f $WORKSPACE/pnpm-lock.yaml && -d $WORKSPACE/src ]] || return 1
    dirty=$(git -C "$WORKSPACE" status --porcelain=v1 --untracked-files=all) || return 1
    [[ -z $dirty ]] || { warn "Local edits or untracked files will be preserved with the entire workspace."; return 1; }
    while IFS= read -r -d '' file; do
        [[ ! -L $WORKSPACE/$file ]] || return 1
        [[ $file == src/userplugins/*/* ]] || { warn "Unexplained ignored content: $file"; return 1; }
        relative=${file#src/userplugins/}; plugin=${relative%%/*}; relative=${relative#*/}
        is_bundled_plugin "$plugin" || return 1
        expected=$(awk -F '\t' -v p="$plugin" -v f="$relative" '$1=="file" && $2==p && $3==f {print $4}' "$STATE_FILE")
        [[ $expected =~ ^[0-9a-f]{64}$ && $(sha256_file "$WORKSPACE/$file") == "$expected" ]] || return 1
    done < <(git -C "$WORKSPACE" ls-files -z --others --ignored --exclude-standard -- . ':!node_modules' ':!dist')
    if [[ -d $WORKSPACE/src/userplugins ]]; then
        while IFS= read -r -d '' file; do
            plugin=${file##*/}
            [[ ! -L $file ]] && is_bundled_plugin "$plugin" || return 1
            grep -Fqx $'plugin\t'"$plugin" "$STATE_FILE" || return 1
            plugin_changed_since_state "$plugin" && return 1
        done < <(find -P "$WORKSPACE/src/userplugins" -mindepth 1 -maxdepth 1 -print0)
    fi
    return 0
}

removal_tree_inventory() {
    local root=$1 file relative kind value
    [[ -d $root ]] || return 0
    while IFS= read -r -d '' file; do
        relative=${file#"$root/"}
        [[ $relative != *$'\n'* && $relative != *$'\t'* ]] || { fail "Unrepresentable filename retained: $file"; return 1; }
        if [[ -L $file ]]; then kind='link'; value=$(readlink -- "$file" | base64 -w0)
        elif [[ -d $file ]]; then kind='directory'; value='-'
        elif [[ -f $file ]]; then kind='file'; value=$(sha256_file "$file") || return 1
        else fail "Special file retained: $file"; return 1
        fi
        printf '%s\t%s\t%s\n' "$relative" "$kind" "$value"
    done < <(find -P "$root" -mindepth 1 -print0 | LC_ALL=C sort -z)
}

inventory_still_matches() {
    local root=$1 inventory=$2 line
    [[ -f $inventory && ! -L $inventory ]] || return 1
    local current
    current=$(removal_tree_inventory "$root") || return 1
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        grep -Fqx -- "$line" "$inventory" || return 1
    done <<< "$current"
}

removal_journal_valid() {
    [[ -f $UNINSTALL_STATE && ! -L $UNINSTALL_STATE ]] || return 1
    [[ $(tsv_value "$UNINSTALL_STATE" manager) == "$MANAGER_NAME" && $(tsv_value "$UNINSTALL_STATE" format) == 1 &&
       $(tsv_value "$UNINSTALL_STATE" data_root) == "$DATA_ROOT" && $(tsv_value "$UNINSTALL_STATE" config_root) == "$CONFIG_ROOT" &&
       $(tsv_value "$UNINSTALL_STATE" cache_root) == "$CACHE_ROOT" && $(tsv_value "$UNINSTALL_STATE" state_root) == "$STATE_ROOT" &&
       $(tsv_value "$UNINSTALL_STATE" remote) == "$(effective_equicord_remote)" &&
       $(tsv_value "$UNINSTALL_STATE" discord_path) == "$(state_value discord_path)" ]]
}

write_removal_stage() {
    local stage=$1 temporary
    REMOVAL_STAGE=$stage
    temporary=$(mktemp "$STATE_ROOT/.uninstall.XXXXXX") || return 1
    {
        printf 'format\t1\nmanager\t%s\nremote\t%s\n' "$MANAGER_NAME" "$(effective_equicord_remote)"
        printf 'data_root\t%s\nconfig_root\t%s\ncache_root\t%s\nstate_root\t%s\n' "$DATA_ROOT" "$CONFIG_ROOT" "$CACHE_ROOT" "$STATE_ROOT"
        printf 'discord_path\t%s\nstage\t%s\n' "${DISCORD_PATHS[SELECTED_TARGET_INDEX]}" "$stage"
        printf 'was_running\t%s\nrestart_exe\t%s\n' "$REMOVAL_WAS_RUNNING" "$REMOVAL_RESTART_EXE"
        printf 'original_hash\t%s\n' "$ORIGINAL_ASAR_HASH"
    } > "$temporary"
    atomic_write_text "$UNINSTALL_STATE" "$temporary" || return 1
    rm -f -- "$temporary"
}

selected_removal_pids() {
    local proc pid exe uid app_id=${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]} target=${DISCORD_PATHS[SELECTED_TARGET_INDEX]}
    local resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]} process_name
    process_name=$(selected_process_name)
    while IFS= read -r pid; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        proc="/proc/$pid"
        uid=$(stat -c %u -- "$proc" 2>/dev/null) || continue
        [[ $uid == "$(id -u)" ]] || continue
        exe=$(readlink -- "$proc/exe" 2>/dev/null) || continue
        if [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} == flatpak ]]; then
            [[ -f $proc/root/.flatpak-info ]] || continue
            grep -Fqx "name=$app_id" "$proc/root/.flatpak-info" || continue
        elif [[ $exe != "$target/$process_name" && $exe != "${resources%/resources}/$process_name" ]]; then
            continue
        fi
        printf '%s\n' "$pid"
    done < <(pgrep -x "$process_name" 2>/dev/null || true)
    if [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} == system-electron ]]; then
        local -a arguments
        for proc in /proc/[0-9]*; do
            [[ $(stat -c %u -- "$proc" 2>/dev/null) == "$(id -u)" ]] || continue
            arguments=(); mapfile -d '' -t arguments < "$proc/cmdline" 2>/dev/null || continue
            [[ ${arguments[1]:-} == "$target/app.asar" ]] || continue
            exe=$(readlink -- "$proc/exe" 2>/dev/null) || continue
            [[ ${exe##*/} =~ ^electron[0-9]*$ ]] || continue
            printf '%s\n' "${proc##*/}"
        done
    fi
}

capture_removal_processes() {
    REMOVAL_PIDS=()
    [[ ${MES_SKIP_PROCESS_MANAGEMENT:-0} != 1 ]] || return 0
    mapfile -t REMOVAL_PIDS < <(selected_removal_pids | sort -un)
    if ((${#REMOVAL_PIDS[@]})); then
        REMOVAL_WAS_RUNNING=1
        REMOVAL_RESTART_EXE=$(readlink -- "/proc/${REMOVAL_PIDS[0]}/exe") || return 1
    fi
}

close_removal_processes() {
    local pid deadline=$((SECONDS + 20)) running
    for pid in "${REMOVAL_PIDS[@]}"; do
        # Re-evaluate the exact executable immediately before sending a signal.
        selected_removal_pids | grep -Fx "$pid" >/dev/null || continue
        kill -TERM "$pid" || return 1
    done
    while ((SECONDS < deadline)); do
        running=0
        for pid in "${REMOVAL_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null && [[ $(awk '/^State:/ {print $2}' "/proc/$pid/status" 2>/dev/null) != Z ]]; then running=1; fi
        done
        [[ $running -eq 0 ]] && return 0
        wait_for_process_poll
    done
    fail "The selected Discord client is still running. No uninjection or cleanup was attempted."
}

restart_removal_client() {
    [[ $REMOVAL_WAS_RUNNING == 1 && ${MES_SKIP_PROCESS_MANAGEMENT:-0} != 1 ]] || return 0
    [[ -z $(selected_removal_pids) ]] || return 0
    local target=${DISCORD_PATHS[SELECTED_TARGET_INDEX]} resources=${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]}
    local format=${DISCORD_FORMATS[SELECTED_TARGET_INDEX]}
    if [[ $format == flatpak ]]; then
        nohup flatpak run "${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]}" >/dev/null 2>&1 &
    elif [[ $format == system-electron && -x $REMOVAL_RESTART_EXE && ${REMOVAL_RESTART_EXE##*/} =~ ^electron[0-9]*$ ]]; then
        nohup "$REMOVAL_RESTART_EXE" "$target/app.asar" >/dev/null 2>&1 &
    elif [[ -x $REMOVAL_RESTART_EXE && ( $REMOVAL_RESTART_EXE == "$target/"* || $REMOVAL_RESTART_EXE == "${resources%/resources}/"* ) ]]; then
        nohup "$REMOVAL_RESTART_EXE" >/dev/null 2>&1 &
    else
        warn "The exact previously running client could not be relaunched. Open that Discord branch manually."
        return 1
    fi
}

flatpak_override_location() {
    local app=${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]} branch=${DISCORD_BRANCHES[SELECTED_TARGET_INDEX]} expected
    case $branch in stable) expected=com.discordapp.Discord ;; ptb) expected=com.discordapp.DiscordPTB ;; canary) expected=com.discordapp.DiscordCanary ;; *) return 1 ;; esac
    [[ $app == "$expected" && ${DISCORD_PATHS[SELECTED_TARGET_INDEX]} == *"/$app/"* || $app == "$expected" && ${DISCORD_PATHS[SELECTED_TARGET_INDEX]} == *"/$app" ]] || return 1
    if [[ ${DISCORD_PATHS[SELECTED_TARGET_INDEX]} == /var/* ]]; then
        printf '/var/lib/flatpak/overrides/%s\n' "$app"
    else
        printf '%s/flatpak/overrides/%s\n' "$DATA_HOME" "$app"
    fi
}

record_flatpak_override_before() {
    [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} == flatpak ]] || return 0
    local path temporary before_hash=absent current=absent after
    path=$(flatpak_override_location) || return 1
    require_unlinked_path "$path" || return 1
    if [[ -f $FLATPAK_RECORD/record.tsv ]]; then
        [[ $(tsv_value "$FLATPAK_RECORD/record.tsv" path) == "$path" ]] || {
            fail "Another Flatpak permission recovery record exists. Remove that recorded setup before changing targets."; return 1;
        }
        [[ ! -f $path ]] || current=$(sha256_file "$path")
        after=$(tsv_value "$FLATPAK_RECORD/record.tsv" after_hash)
        if [[ $current != "$after" ]]; then
            warn "Flatpak overrides changed since the recorded injection. Automatic override restoration is disabled to preserve those changes."
            temporary=$(mktemp "$FLATPAK_RECORD/.record.XXXXXX") || return 1
            printf 'path\t%s\napp\t%s\nbefore_hash\tunattributable\nafter_hash\tpending\n' "$path" "${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]}" > "$temporary"
            atomic_write_text "$FLATPAK_RECORD/record.tsv" "$temporary" || return 1
            rm -f -- "$temporary"
        fi
        return 0
    fi
    require_unlinked_path "$FLATPAK_RECORD" || return 1
    mkdir -p -- "$FLATPAK_RECORD"
    if [[ -f $path ]]; then
        atomic_write_text "$FLATPAK_RECORD/before" "$path" || return 1
        before_hash=$(sha256_file "$path")
    fi
    temporary=$(mktemp "$FLATPAK_RECORD/.record.XXXXXX") || return 1
    printf 'path\t%s\napp\t%s\nbefore_hash\t%s\nafter_hash\tpending\n' "$path" "${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]}" "$before_hash" > "$temporary"
    atomic_write_text "$FLATPAK_RECORD/record.tsv" "$temporary"
    rm -f -- "$temporary"
}

record_flatpak_override_after() {
    [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} == flatpak ]] || return 0
    local path temporary after_hash=absent before_hash
    path=$(flatpak_override_location) || return 1
    require_unlinked_path "$path" || return 1
    before_hash=$(tsv_value "$FLATPAK_RECORD/record.tsv" before_hash) || return 1
    [[ ! -f $path ]] || after_hash=$(sha256_file "$path")
    temporary=$(mktemp "$FLATPAK_RECORD/.record.XXXXXX") || return 1
    printf 'path\t%s\napp\t%s\nbefore_hash\t%s\nafter_hash\t%s\n' "$path" "${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]}" "$before_hash" "$after_hash" > "$temporary"
    atomic_write_text "$FLATPAK_RECORD/record.tsv" "$temporary"
    rm -f -- "$temporary"
}

restore_owned_flatpak_override() {
    [[ ${DISCORD_FORMATS[SELECTED_TARGET_INDEX]} == flatpak ]] || return 0
    local path before after current=absent temporary
    path=$(flatpak_override_location) || return 1
    if [[ ! -f $FLATPAK_RECORD/record.tsv ]]; then
        warn "Legacy Flatpak override has no ownership snapshot. It was left unchanged; no broad override reset is used."
        return 0
    fi
    [[ $(tsv_value "$FLATPAK_RECORD/record.tsv" path) == "$path" && $(tsv_value "$FLATPAK_RECORD/record.tsv" app) == "${DISCORD_APP_IDS[SELECTED_TARGET_INDEX]}" ]] || return 1
    require_unlinked_path "$path" || return 1
    before=$(tsv_value "$FLATPAK_RECORD/record.tsv" before_hash); after=$(tsv_value "$FLATPAK_RECORD/record.tsv" after_hash)
    [[ ! -f $path ]] || current=$(sha256_file "$path")
    [[ $current != "$before" ]] || return 0
    if [[ $before == unattributable || $after == pending || $current != "$after" ]]; then
        warn "Flatpak overrides changed outside the recorded injection, or injection was interrupted. All current overrides were preserved."
        return 0
    fi
    [[ $before == absent || ( $before =~ ^[0-9a-f]{64}$ && $(sha256_file "$FLATPAK_RECORD/before") == "$before" ) ]] || return 1
    if [[ $path == /var/lib/flatpak/overrides/* ]]; then
        info "Requesting elevation only to restore this verified system Flatpak override: $path"
        if [[ $before == absent ]]; then sudo rm -- "$path" || return 1
        else
            temporary=$(sudo mktemp "${path}.mes-restore.XXXXXX") || return 1
            sudo install -m 0644 -- "$FLATPAK_RECORD/before" "$temporary" && sudo mv -f -- "$temporary" "$path" || return 1
        fi
    elif [[ $before == absent ]]; then
        rm -- "$path" || return 1
    else
        atomic_write_text "$path" "$FLATPAK_RECORD/before" || return 1
    fi
    success "Restored the provably manager-owned Flatpak override to its previous state."
}

cleanup_removal_roots() {
    validate_removal_roots || return 1
    validate_manager_cleanup_content || return 2
    if [[ $REMOVAL_KEEP_WORKSPACE == 1 ]]; then
        warn "Partial cleanup: Discord is restored, but the workspace and recovery state were retained for user-content review."
        return 2
    fi
    local root index=0 file
    if [[ $REMOVAL_RESUMING != 1 ]]; then
        workspace_safe_for_full_removal || { warn "Workspace changed after the preview; all manager files were retained."; return 2; }
        mkdir -p -- "$UNINSTALL_INVENTORY"
        for root in "$DATA_ROOT" "$CONFIG_ROOT" "$CACHE_ROOT"; do
            file="$UNINSTALL_INVENTORY/$index.tsv"
            local temporary
            temporary=$(mktemp "$UNINSTALL_INVENTORY/.inventory.XXXXXX") || return 1
            removal_tree_inventory "$root" > "$temporary" || return 1
            atomic_write_text "$file" "$temporary" || return 1
            rm -f -- "$temporary"
            index=$((index+1))
        done
        cp -- "$OWNER_MARKER" "$UNINSTALL_INVENTORY/owner.tsv" || return 1
    fi
    index=0
    for root in "$DATA_ROOT" "$CONFIG_ROOT" "$CACHE_ROOT"; do
        file="$UNINSTALL_INVENTORY/$index.tsv"
        inventory_still_matches "$root" "$file" || { fail "Cleanup inventory changed. Remaining files were preserved: $root"; return 2; }
        # The exact XDG roots were validated above. rm does not follow interior symlinks.
        remove_validated_manager_root "$root" || return 2
        index=$((index+1))
    done
    write_removal_stage cleanup-complete || return 1
    remove_validated_manager_root "$STATE_ROOT" || return 2
}

validate_manager_cleanup_content() {
    local file name
    # The current manager creates no configuration files in CONFIG_ROOT. Do not
    # claim an unrelated file merely because it occupies the expected directory.
    if [[ -d $CONFIG_ROOT && -n $(find -P "$CONFIG_ROOT" -mindepth 1 -print -quit) ]]; then
        fail "Unexpected configuration content was retained: $CONFIG_ROOT"; return 1
    fi
    for file in "$DATA_ROOT"/* "$DATA_ROOT"/.[!.]*; do
        [[ -e $file || -L $file ]] || continue
        name=${file##*/}
        case $name in Equicord|backups|manager-owned.tsv|.manager-owned.*|.my-equicord-write.*) ;; *) fail "Unknown data entry retained: $file"; return 1 ;; esac
    done
    for file in "$CACHE_ROOT"/* "$CACHE_ROOT"/.[!.]*; do
        [[ -e $file || -L $file ]] || continue
        name=${file##*/}
        case $name in EquilotlCli-linux-*|.equilotl-download.*|plugin-stage.*|.my-equicord-write.*) ;; *) fail "Unknown cache entry retained: $file"; return 1 ;; esac
    done
    for file in "$STATE_ROOT"/* "$STATE_ROOT"/.[!.]*; do
        [[ -e $file || -L $file ]] || continue
        name=${file##*/}
        case $name in manifest.tsv|logs|equilotl|uninstall.tsv|uninstall-inventory|flatpak-override|.manifest.*|.uninstall.*|.my-equicord-write.*) ;; *) fail "Unknown state entry retained: $file"; return 1 ;; esac
    done
}

remove_validated_manager_root() {
    local root=$1
    case $root in "$DATA_ROOT"|"$CONFIG_ROOT"|"$CACHE_ROOT"|"$STATE_ROOT") ;; *) return 1 ;; esac
    validate_removal_roots || return 1
    [[ ! -e $root ]] || rm -rf -- "$root"
}

removal_exit_handler() {
    local result=$1
    trap - EXIT INT TERM HUP
    if [[ $REMOVAL_CONFIRMED == 1 ]]; then
        if [[ $result -ne 0 && -d $STATE_ROOT ]]; then
            write_removal_stage "$REMOVAL_STAGE" || true
            if [[ $REMOVAL_RESTORED == 1 ]]; then
                warn "Partial cleanup: Discord was restored. Retained recovery state: $UNINSTALL_STATE. Resolve the reported issue and rerun --remove."
            else
                warn "Removal did not finish. Workspace, injector, backups, and recovery information were preserved for retry."
            fi
        fi
        if [[ $REMOVAL_STAGE != planned && $REMOVAL_WAS_RUNNING == 1 ]]; then restart_removal_client || true; fi
    fi
    return "$result"
}

perform_remove() (
    # A subshell contains traps so menu operations cannot inherit uninstall handlers.
    local confirmation=${1:-} command_name root owner
    REMOVAL_CONFIRMED=0 REMOVAL_RESTORED=0 REMOVAL_KEEP_WORKSPACE=0 REMOVAL_RESUMING=0
    REMOVAL_STAGE=planned REMOVAL_WAS_RUNNING=0 REMOVAL_RESTART_EXE='' ORIGINAL_ASAR_HASH=''
    REMOVAL_PIDS=()
    trap 'removal_exit_handler $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    platform_preflight || return 1
    for command_name in git node realpath stat find sha256sum base64 awk sort grep pgrep; do
        command -v "$command_name" >/dev/null 2>&1 || { fail "Full removal needs $command_name. No dependency was installed."; return 1; }
    done
    validate_removal_roots || return 1
    if [[ ! -e $DATA_ROOT && ! -e $STATE_ROOT && ! -e $CONFIG_ROOT && ! -e $CACHE_ROOT ]]; then
        success "No manager setup remains. Delete the downloaded Equicord-Linux.sh manually if desired."
        return 0
    fi
    validate_removal_manifest || return 1
    select_recorded_removal_target || return 1
    inspect_removal_injection || return 1
    if removal_journal_valid; then
        REMOVAL_STAGE=$(tsv_value "$UNINSTALL_STATE" stage)
        REMOVAL_WAS_RUNNING=$(tsv_value "$UNINSTALL_STATE" was_running)
        REMOVAL_RESTART_EXE=$(tsv_value "$UNINSTALL_STATE" restart_exe)
        if [[ $REMOVAL_STAGE == cleanup-started || $REMOVAL_STAGE == cleanup-complete ]]; then
            if [[ -f $UNINSTALL_INVENTORY/owner.tsv && -f $UNINSTALL_INVENTORY/0.tsv && -f $UNINSTALL_INVENTORY/1.tsv && -f $UNINSTALL_INVENTORY/2.tsv ]]; then REMOVAL_RESUMING=1; fi
            [[ $REMOVAL_INJECTION == clean ]] || { fail "Discord is injected again; recovery cleanup was stopped."; return 1; }
        fi
    fi
    owner=$OWNER_MARKER
    [[ $REMOVAL_RESUMING != 1 ]] || owner="$UNINSTALL_INVENTORY/owner.tsv"
    require_unlinked_path "$owner" || return 1
    [[ $(tsv_value "$owner" manager) == "$MANAGER_NAME" && $(tsv_value "$owner" workspace) == "$WORKSPACE" &&
       $(tsv_value "$owner" remote) == "$(effective_equicord_remote)" && $(tsv_value "$owner" format) == "$STATE_FORMAT" ]] || {
        fail "Manager ownership could not be verified. Nothing was removed."; return 1;
    }
    if [[ $REMOVAL_RESUMING != 1 ]]; then
        require_unlinked_path "$WORKSPACE" && require_unlinked_path "$WORKSPACE/.git" || return 1
        validate_official_remote || return 1
        workspace_safe_for_full_removal || REMOVAL_KEEP_WORKSPACE=1
    fi
    capture_removal_processes || return 1
    printf '\nFull removal preview\nBranch: %s\nFormat: %s\nDiscord: %s\nResources: %s\nInjection: %s\nPreviously running: %s\nOwnership: verified\n' \
        "${DISCORD_BRANCHES[SELECTED_TARGET_INDEX]}" "${DISCORD_FORMATS[SELECTED_TARGET_INDEX]}" "${DISCORD_PATHS[SELECTED_TARGET_INDEX]}" \
        "${DISCORD_RESOURCE_DIRS[SELECTED_TARGET_INDEX]}" "$REMOVAL_INJECTION" "$REMOVAL_WAS_RUNNING"
    if [[ $REMOVAL_KEEP_WORKSPACE == 1 ]]; then
        warn "The workspace and manager recovery files will be preserved because user content is present. Only Discord restoration will proceed."
    else
        printf 'After verified restoration, delete these exact manager roots (workspace, backups, state, logs, configuration, injector cache and temporary files):\n'
        for root in "$DATA_ROOT" "$CONFIG_ROOT" "$CACHE_ROOT" "$STATE_ROOT"; do printf '  %s\n' "$root"; done
    fi
    printf 'Preserve: Discord, login/account data, ordinary settings, other clients, shared dependencies, unrelated plugins/themes, and this downloaded launcher.\n'
    if [[ ${MES_NONINTERACTIVE:-0} == 1 ]]; then
        [[ $confirmation == --confirm-remove ]] || { fail "Noninteractive full removal requires both --remove and --confirm-remove. MES_ASSUME_YES cannot authorize it."; return 1; }
    else
        read -r -p 'Type REMOVE to continue: ' confirmation || return 1
        [[ $confirmation == REMOVE ]] || { info "Removal cancelled. Nothing was changed."; return 0; }
    fi
    REMOVAL_CONFIRMED=1
    # Keep a cleanup journal's authorization intact on an interrupted cleanup retry.
    if [[ $REMOVAL_RESUMING != 1 ]]; then write_removal_stage planned || return 1; fi
    if [[ $REMOVAL_INJECTION == injected ]]; then
        write_removal_stage discord-stopped || return 1
        close_removal_processes || return 1
        write_removal_stage uninjection-started || return 1
        execute_selected_injector uninstall || return 1
    fi
    verify_removal_restoration || { fail "Official uninjection did not restore the exact original Discord archive. No manager files were deleted."; return 1; }
    REMOVAL_RESTORED=1
    if [[ $REMOVAL_RESUMING != 1 ]]; then write_removal_stage discord-restored || return 1; fi
    restore_owned_flatpak_override || return 2
    if [[ $REMOVAL_KEEP_WORKSPACE == 1 ]]; then return 2; fi
    write_removal_stage cleanup-started || return 1
    cleanup_removal_roots || return $?
    success "Fully removed the verified manager-owned Equicord setup after restoring Discord. Shared dependencies remain installed."
    info "Equicord-Linux.sh was not deleted. Remove the downloaded launcher manually if desired."
)
