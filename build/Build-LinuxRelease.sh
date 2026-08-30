#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
IFS=$'\n\t'

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
source_file="$repo_root/src/EquicordSetup.sh"
manifest_file="$repo_root/src/plugins/PluginFiles.tsv"
plugins_root="$repo_root/src/plugins"
output_file="$repo_root/Equicord-Linux.sh"
payload_marker='# <BUILD:BUNDLED_PLUGIN_PAYLOAD>'
check_only=0

if [[ ${1:-} == "--check" ]]; then
    check_only=1
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--check]\n' "$0" >&2
    exit 2
fi

for command_name in base64 mktemp sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Required build command is missing: %s\n' "$command_name" >&2
        exit 1
    }
done

[[ -f $source_file ]] || { printf 'Missing Linux installer source: %s\n' "$source_file" >&2; exit 1; }
[[ -f $manifest_file ]] || { printf 'Missing plugin file manifest: %s\n' "$manifest_file" >&2; exit 1; }

marker_count=$(grep -Fxc "$payload_marker" "$source_file" || true)
[[ $marker_count -eq 1 ]] || {
    printf 'Expected exactly one payload marker in %s, found %s.\n' "$source_file" "$marker_count" >&2
    exit 1
}

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/my-equicord-linux-build.XXXXXX")
trap 'rm -rf -- "$temporary_dir"' EXIT
payload_file="$temporary_dir/payload.sh"
generated_file="$temporary_dir/Equicord-Linux.sh"
seen_files="$temporary_dir/seen-files"
seen_folders="$temporary_dir/seen-folders"
: > "$seen_files"
: > "$seen_folders"

# The following single-quoted strings are generated source and must not expand here.
# shellcheck disable=SC2016
{
    printf '%s\n' '# Generated bundled plugin payload. Do not edit this block directly.'
    printf '%s\n' 'readonly BUNDLED_PAYLOAD_FORMAT=1'
    printf '%s\n' 'embedded_plugin_manifest() {'
    printf '%s\n' "    cat <<'__MY_EQUICORD_PLUGIN_MANIFEST__'"
} > "$payload_file"

entry_count=0
while IFS=$'\t' read -r folder file extra || [[ -n ${folder:-} ]]; do
    [[ -z ${folder:-} || ${folder:0:1} == '#' ]] && continue
    [[ -z ${extra:-} ]] || { printf 'Malformed manifest line for %s/%s.\n' "$folder" "$file" >&2; exit 1; }
    [[ $folder =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { printf 'Unsafe plugin folder: %s\n' "$folder" >&2; exit 1; }
    [[ $file =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'Unsafe plugin file: %s/%s\n' "$folder" "$file" >&2; exit 1; }
    plugin_path="$plugins_root/$folder/$file"
    [[ -f $plugin_path && ! -L $plugin_path ]] || { printf 'Missing or linked plugin source: %s\n' "$plugin_path" >&2; exit 1; }
    key="$folder/$file"
    grep -Fxq "$key" "$seen_files" && { printf 'Duplicate plugin file: %s\n' "$key" >&2; exit 1; }
    printf '%s\n' "$key" >> "$seen_files"
    grep -Fxq "$folder" "$seen_folders" || printf '%s\n' "$folder" >> "$seen_folders"
    hash=$(sha256sum "$plugin_path" | awk '{print $1}')
    printf '%s\t%s\t%s\n' "$folder" "$file" "$hash" >> "$payload_file"
    entry_count=$((entry_count + 1))
done < "$manifest_file"

[[ $entry_count -gt 0 ]] || { printf 'Plugin file manifest contains no entries.\n' >&2; exit 1; }
# shellcheck disable=SC2016
{
    printf '%s\n' '__MY_EQUICORD_PLUGIN_MANIFEST__'
    printf '%s\n' '}'
    printf '%s\n' 'extract_embedded_plugins() {'
    printf '%s\n' '    local destination=$1 relative_path expected_hash actual_hash'
    printf '%s\n' '    mkdir -p -- "$destination"'
    printf '%s\n' '    while IFS=$'"'"'\t'"'"' read -r folder file expected_hash; do'
    printf '%s\n' '        relative_path="$folder/$file"'
    printf '%s\n' '        mkdir -p -- "$destination/$folder"'
    printf '%s\n' '        case "$relative_path" in'
} >> "$payload_file"

payload_index=0
while IFS=$'\t' read -r folder file extra || [[ -n ${folder:-} ]]; do
    [[ -z ${folder:-} || ${folder:0:1} == '#' ]] && continue
    plugin_path="$plugins_root/$folder/$file"
    delimiter="__MY_EQUICORD_PAYLOAD_${payload_index}__"
    {
        printf '            %q)\n' "$folder/$file"
        printf '%s\n' "                base64 --decode > \"\$destination/\$relative_path\" <<'$delimiter'"
        base64 "$plugin_path"
        printf '%s\n' "$delimiter"
        printf '%s\n' '                ;;'
    } >> "$payload_file"
    payload_index=$((payload_index + 1))
done < "$manifest_file"

# shellcheck disable=SC2016
{
    printf '%s\n' '            *) fail "Generated payload manifest referenced an unknown file: $relative_path" ;;'
    printf '%s\n' '        esac'
    printf '%s\n' '        actual_hash=$(sha256_file "$destination/$relative_path")'
    printf '%s\n' '        [[ $actual_hash == "$expected_hash" ]] || fail "Embedded payload hash mismatch: $relative_path"'
    printf '%s\n' '    done < <(embedded_plugin_manifest)'
    printf '%s\n' '}'
} >> "$payload_file"

while IFS= read -r directory; do
    folder=${directory##*/}
    grep -Fxq "$folder" "$seen_folders" || {
        printf 'Plugin source directory is missing from PluginFiles.tsv: %s\n' "$folder" >&2
        exit 1
    }
done < <(find "$plugins_root" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)

awk -v marker="$payload_marker" -v payload="$payload_file" '
    $0 == marker {
        while ((getline line < payload) > 0) print line
        close(payload)
        next
    }
    { print }
' "$source_file" > "$generated_file"

if grep -Fq "$payload_marker" "$generated_file"; then
    printf 'Generated Linux script contains an unresolved payload marker.\n' >&2
    exit 1
fi
if grep -q $'\r' "$generated_file"; then
    printf 'Generated Linux script contains CRLF or bare CR line endings.\n' >&2
    exit 1
fi
[[ $(head -n 1 "$generated_file") == '#!/usr/bin/env bash' ]] || {
    printf 'Generated Linux script has no valid Bash shebang.\n' >&2
    exit 1
}
bash -n "$generated_file"
chmod 0755 "$generated_file"

if [[ $check_only -eq 1 ]]; then
    [[ -f $output_file ]] || { printf 'Generated Linux release is missing: %s\n' "$output_file" >&2; exit 1; }
    cmp -s "$generated_file" "$output_file" || {
        printf 'Equicord-Linux.sh is stale. Run ./build/Build-LinuxRelease.sh and commit it.\n' >&2
        exit 1
    }
    [[ -x $output_file ]] || { printf 'Equicord-Linux.sh is not executable.\n' >&2; exit 1; }
    printf 'Equicord-Linux.sh matches the organised source files.\n'
    exit 0
fi

if [[ -f $output_file ]] && cmp -s "$generated_file" "$output_file"; then
    chmod 0755 "$output_file"
    printf 'Equicord-Linux.sh is already current.\n'
    exit 0
fi

temporary_output="$repo_root/.Equicord-Linux.sh.$$.tmp"
cp -- "$generated_file" "$temporary_output"
chmod 0755 "$temporary_output"
mv -f -- "$temporary_output" "$output_file"
printf 'Built Equicord-Linux.sh from the organised source files.\n'
