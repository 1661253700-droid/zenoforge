#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
here=$(cd "$(dirname "$0")" && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/repo/pkg" "$t/bin" "$t/config" "$t/live"
git init -q --bare "$t/origin.git"
git init -q -b main "$t/repo"
git -C "$t/repo" config user.name fixture
git -C "$t/repo" config user.email fixture@example.invalid
printf 'same\n' > "$t/repo/pkg/a.js"
printf 'map\n' > "$t/repo/pkg/a.js.map"
git -C "$t/repo" add .
git -C "$t/repo" commit -qm fixture
git -C "$t/repo" remote add origin "$t/origin.git"
git -C "$t/repo" push -q -u origin main
sha=$(git -C "$t/repo" rev-parse HEAD)
cat > "$t/bin/build-fixture" <<'SH'
#!/usr/bin/env bash
mkdir -p pkg/dist
cp pkg/a.js pkg/a.js.map pkg/dist/
SH
cat > "$t/bin/docker" <<'SH'
#!/usr/bin/env bash
[[ $1 == exec && $2 == service && $3 == cat && $4 == -- ]]
cat "$LIVE/${5##*/}"
SH
chmod +x "$t/bin/"*
export PATH="$t/bin:$PATH" ZF_CONFIG_ROOT="$t/config" FIXTURE_REPO="$t/repo" LIVE="$t/live"
cat > "$t/config/hotfix.json" <<'JSON'
{"apply_dist":{"repo_env":"FIXTURE_REPO","repo_home_relative":"checkout","package_dir":"pkg","container_path":"/app/dist","install":["true"],"build":["build-fixture"]}}
JSON
cp "$t/repo/pkg/a.js" "$t/live/a.js"
cp "$t/repo/pkg/a.js.map" "$t/live/a.js.map"
registry="$t/registry"
rows() { printf 'service\t/app/dist/a.js\t123\t/copy/a.js\nservice\t/app/dist/a.js.map\t123\t/copy/a.js.map\nother\t/app/dist/a.js\t456\t/copy/other\n' > "$registry"; }
# Stub the product resolver's PR-blocking contract; ancestry is tested in that product.
resolver() { awk -F '\t' '$3 == "123" { found=1 } END { exit !found }' "$registry"; }
run() { bash "$here/hf-supersede.sh" "$@"; }
rows
run "$registry" 123 "$sha" > "$t/out"
[[ $(grep -c "carried_by=$sha" "$registry") == 2 ]]
[[ $(find "$t" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 1 ]]
! resolver
printf 'ok: identical rows replaced and resolver stub accepts\n'
rm "$t"/registry.backup-*
rows
printf 'different\n' > "$t/live/a.js.map"
set +e
run "$registry" 123 "$sha" > "$t/out"
rc=$?
set -e
[[ $rc == 3 ]]
grep -Fq "carried_by=$sha" "$registry"
grep -Fq $'service\t/app/dist/a.js.map\t123\t/copy/a.js.map' "$registry"
grep -Fq $'DIFFERENT\tservice\t/app/dist/a.js.map' "$t/out"
resolver
[[ $(find "$t" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 1 ]]
printf 'ok: mixed rows retain and report differing map\n'
rm "$t"/registry.backup-*
rows
cp "$registry" "$t/before"
set +e
run --dry-run "$registry" 123 "$sha" > "$t/out"
rc=$?
set -e
[[ $rc == 3 ]]
cmp "$registry" "$t/before"
[[ $(find "$t" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 0 ]]
grep -q '^IDENTICAL' "$t/out"
grep -q '^DIFFERENT' "$t/out"
printf 'ok: dry run leaves registry and backups unchanged\n'
