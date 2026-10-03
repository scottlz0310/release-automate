#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

awk '
  { sub(/\r$/, "") }
  $0 == "      - name: Run Version Bump Strategy" { found = 1; next }
  found && /^        run: \|$/ { running = 1; next }
  running && /^      - / { exit }
  running { sub(/^          /, ""); print }
' "$repo_root/.github/workflows/reusable-prepare-release.yml" > "$test_dir/bump.sh"
[[ -s "$test_dir/bump.sh" ]]

# package.json と、$3（既定は src-tauri）の tauri.conf.json / Cargo.toml / Cargo.lock を持つ Tauri 風の
# プロジェクトを作る。最上位ではない "version" キー（9.9.9）は、書き換えの対象外であることを確かめる。
make_project() {
  local directory=$1 version=${2:-0.1.0} conf_dir=${3:-src-tauri}
  mkdir -p "$directory/$conf_dir/src"
  cat > "$directory/package.json" <<EOF
{
  "name": "example",
  "version": "$version",
  "private": true,
  "config": {
    "version": "9.9.9"
  }
}
EOF
  cat > "$directory/$conf_dir/tauri.conf.json" <<EOF
{
  "productName": "example",
  "version": "$version",
  "bundle": {
    "version": "9.9.9"
  }
}
EOF
  cat > "$directory/$conf_dir/Cargo.toml" <<EOF
[package]
name = "example"
version = "$version"
edition = "2021"
EOF
  echo 'pub fn example() {}' > "$directory/$conf_dir/src/lib.rs"
  cargo generate-lockfile --offline --manifest-path "$directory/$conf_dir/Cargo.toml"
  git -C "$directory" init -q
  git -C "$directory" add .
}

# shell を指定しない run のステップは、GitHub Actions では `bash -e {0}` で動く。同じ条件で動かす。
run_bump() (
  cd "$1"
  VERSION=$2 STRATEGY=tauri VERSION_FILE=${3:-} bash -e "$test_dir/bump.sh"
)

snapshot() (
  cd "$1"
  find . -path ./.git -prune -o -type f -print | sort | xargs sha256sum
)

# 失敗したときは、メッセージが出て、何も書き換えない（検査は、書き換えの前に終わる）。
expect_failure() {
  local directory=$1 version=$2 conf=$3 message=$4 before
  before=$(snapshot "$directory")
  if run_bump "$directory" "$version" "$conf" > "$test_dir/output" 2>&1; then
    echo "Expected failure: $message" >&2
    exit 1
  fi
  grep -Fq "$message" "$test_dir/output"
  [[ "$(snapshot "$directory")" == "$before" ]]
}

# 4 つのファイルが更新され、版の 1 行だけが変わる（整形は保たれる）。
make_project "$test_dir/ok"
run_bump "$test_dir/ok" 0.2.0 ''
grep -q '^  "version": "0.2.0",$' "$test_dir/ok/package.json"
grep -q '^  "version": "0.2.0",$' "$test_dir/ok/src-tauri/tauri.conf.json"
grep -q '^version = "0.2.0"$' "$test_dir/ok/src-tauri/Cargo.toml"
grep -q '^version = "0.2.0"$' "$test_dir/ok/src-tauri/Cargo.lock"
grep -q '^    "version": "9.9.9"$' "$test_dir/ok/package.json"
grep -q '^    "version": "9.9.9"$' "$test_dir/ok/src-tauri/tauri.conf.json"
[[ "$(git -C "$test_dir/ok" diff --numstat | awk '$1 == 1 && $2 == 1' | wc -l)" -eq 4 ]]
[[ "$(git -C "$test_dir/ok" diff --numstat | wc -l)" -eq 4 ]]
expect_failure "$test_dir/ok" 0.2.0 '' 'already have version 0.2.0'

# CRLF の JSON は、改行コードを保つ。
make_project "$test_dir/crlf"
sed -i 's/$/\r/' "$test_dir/crlf/package.json" "$test_dir/crlf/src-tauri/tauri.conf.json"
run_bump "$test_dir/crlf" 0.2.0 ''
for file in package.json src-tauri/tauri.conf.json; do
  [[ "$(grep -c $'\r$' "$test_dir/crlf/$file")" -eq "$(wc -l < "$test_dir/crlf/$file")" ]]
  grep -q '"version": "0.2.0",' "$test_dir/crlf/$file"
done

# version_file で tauri.conf.json の場所を指定する。Cargo.toml は同じディレクトリにある。
make_project "$test_dir/custom" 0.1.0 desktop
run_bump "$test_dir/custom" 0.2.0 desktop/tauri.conf.json
grep -q '^  "version": "0.2.0",$' "$test_dir/custom/desktop/tauri.conf.json"
grep -q '^version = "0.2.0"$' "$test_dir/custom/desktop/Cargo.toml"
grep -q '^version = "0.2.0"$' "$test_dir/custom/desktop/Cargo.lock"

# 版が食い違っているときは、止める。
make_project "$test_dir/disagree"
sed -i 's/"version": "0.1.0"/"version": "0.1.1"/' "$test_dir/disagree/src-tauri/tauri.conf.json"
expect_failure "$test_dir/disagree" 0.2.0 '' 'disagree before the bump'

# 最上位の "version" が無い、または複数あるときは、止める。
make_project "$test_dir/no-version"
sed -i '/^  "version"/d' "$test_dir/no-version/src-tauri/tauri.conf.json"
expect_failure "$test_dir/no-version" 0.2.0 '' 'needs exactly one top-level "version" string'

make_project "$test_dir/duplicate"
sed -i 's/^  "productName": "example",$/  "productName": "example",\n  "version": "0.1.0",/' "$test_dir/duplicate/src-tauri/tauri.conf.json"
expect_failure "$test_dir/duplicate" 0.2.0 '' 'needs exactly one top-level "version" string'

make_project "$test_dir/invalid-json"
echo '{ "version": ' > "$test_dir/invalid-json/package.json"
expect_failure "$test_dir/invalid-json" 0.2.0 '' 'is not valid JSON'

# ファイルが無いときは、止める。
make_project "$test_dir/no-package-json"
rm "$test_dir/no-package-json/package.json"
expect_failure "$test_dir/no-package-json" 0.2.0 '' 'Tauri version file not found: package.json'

make_project "$test_dir/no-cargo"
rm "$test_dir/no-cargo/src-tauri/Cargo.toml"
expect_failure "$test_dir/no-cargo" 0.2.0 '' 'Tauri version file not found'
grep -Fq 'Cargo.toml' "$test_dir/output"

# Cargo.lock が追跡されていないときは、JSON を書き換える前に止める。
make_project "$test_dir/untracked"
git -C "$test_dir/untracked" rm --cached -q src-tauri/Cargo.lock
expect_failure "$test_dir/untracked" 0.2.0 '' 'Cargo.lock must be tracked by Git'

echo 'Tauri prepare scenarios passed'
