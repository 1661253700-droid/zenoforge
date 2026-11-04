#!/usr/bin/env bash
set -euo pipefail
usage() { echo 'usage: hf-supersede.sh [--dry-run] <registry> <pr> <main-sha>' >&2; exit 2; }
dry=0
if [[ ${1:-} == --dry-run ]]; then dry=1; shift; fi
[[ $# == 3 && $2 =~ ^[1-9][0-9]*$ && $3 =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ && -f $1 && -r $1 ]] || usage
registry=$1 pr=$2 sha=$3
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
config=$(zf_config_file hotfix.json) || { echo 'hf-supersede: hotfix.json unavailable' >&2; exit 1; }
jq -e '.apply_dist | (.repo_env | type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.repo_home_relative | type == "string" and test("^[A-Za-z0-9_./-]+$") and (startswith("/") | not)) and (.package_dir | type == "string" and test("^[A-Za-z0-9_./-]+$") and (startswith("/") | not)) and (.container_path | type == "string" and test("^/[A-Za-z0-9_./-]+$")) and ([.install,.build] | all(.[]; type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))))' "$config" >/dev/null || { echo 'hf-supersede: invalid build configuration' >&2; exit 1; }
mapfile -t fields < <(jq -r '.apply_dist | .repo_env,.repo_home_relative,.package_dir,.container_path' "$config")
repo_env=${fields[0]} repo_relative=${fields[1]} package=${fields[2]} target=${fields[3]%/}
[[ /$repo_relative/ != */../* && /$package/ != */../* && /$target/ != */../* ]] || { echo 'hf-supersede: invalid path' >&2; exit 1; }
repo=${!repo_env:-$HOME/$repo_relative}
mapfile -t install < <(jq -r '.apply_dist.install[]' "$config")
mapfile -t build < <(jq -r '.apply_dist.build[]' "$config")
git -C "$repo" fetch -q origin main
git -C "$repo" merge-base --is-ancestor "$sha" origin/main || { echo 'hf-supersede: SHA is not on main' >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hf-supersede.XXXXXX")
cleanup() { git -C "$repo" worktree remove --force "$work/tree" >/dev/null 2>&1 || true; rm -rf -- "$work"; }
trap cleanup EXIT
cp -p -- "$registry" "$work/original"
git -C "$repo" worktree add -q --detach "$work/tree" "$sha"
(cd "$work/tree" && "${install[@]}" >/dev/null && "${build[@]}" >/dev/null)
remaining=0 matched=0 changed=0
: > "$work/result"
while :; do
  line=
  if IFS= read -r line; then newline=1; else newline=0; [[ -n $line ]] || break; fi
  tabs=${line//[^$'\t']/}
  IFS=$'\t' read -r container path carrier copy extra <<< "$line"
  if [[ ${#tabs} == 3 && $container != image && $carrier == "$pr" ]]; then
    matched=1
    [[ $container =~ ^[A-Za-z0-9_.-]+$ && $path == "$target/"* && /${path#"$target/"}/ != */../* && $copy == /* ]] || { echo "hf-supersede: invalid or out-of-scope row: $line" >&2; exit 1; }
    built="$work/tree/$package/dist/${path#"$target/"}"
    if [[ ! -f $built ]]; then
      printf 'DIFFERENT\t%s\t%s\n' "$container" "$path"; remaining=1
    elif ! docker exec "$container" cat -- "$path" > "$work/live"; then
      echo "hf-supersede: cannot read $container:$path" >&2; exit 1
    elif cmp -s -- "$work/live" "$built"; then
      printf 'IDENTICAL\t%s\t%s\n' "$container" "$path"
      line="$container"$'\t'"$path"$'\t'"carried_by=$sha"$'\t'"$copy"
      changed=1
    else
      printf 'DIFFERENT\t%s\t%s\n' "$container" "$path"; remaining=1
    fi
  fi
  if (( newline )); then printf '%s\n' "$line" >> "$work/result"; else printf '%s' "$line" >> "$work/result"; fi
done < "$work/original"
(( matched )) || { echo 'hf-supersede: no matching PR rows' >&2; exit 1; }
if (( ! dry && changed )); then
  cmp -s -- "$registry" "$work/original" || { echo 'hf-supersede: registry changed during comparison' >&2; exit 1; }
  backup=$(mktemp "${registry}.backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
  cp -p -- "$work/original" "$backup"
  tmp=$(mktemp "${registry}.tmp.XXXXXX")
  cp -p -- "$registry" "$tmp"
  cat "$work/result" > "$tmp"
  cmp -s -- "$registry" "$work/original" || { rm -f -- "$tmp"; echo 'hf-supersede: registry changed during comparison' >&2; exit 1; }
  mv -f -- "$tmp" "$registry"
fi
(( remaining == 0 )) || exit 3
