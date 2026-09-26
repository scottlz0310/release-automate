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

make_package() {
  local directory=$1 name=$2 version=${3:-0.1.0}
  mkdir -p "$directory/src"
  cat > "$directory/Cargo.toml" <<EOF
[package]
name = "$name"
version = "$version"
edition = "2021"
EOF
  echo 'pub fn example() {}' > "$directory/src/lib.rs"
}

run_bump() (
  cd "$1"
  VERSION=$2 STRATEGY=rust VERSION_FILE=$3 bash "$test_dir/bump.sh"
)

expect_failure() {
  local directory=$1 version=$2 manifest=$3 message=$4
  if run_bump "$directory" "$version" "$manifest" > "$test_dir/output" 2>&1; then
    echo "Expected failure: $message" >&2
    exit 1
  fi
  grep -Fq "$message" "$test_dir/output"
}

make_package "$test_dir/single" single
cargo generate-lockfile --offline --manifest-path "$test_dir/single/Cargo.toml"
git -C "$test_dir/single" init -q
git -C "$test_dir/single" add Cargo.toml Cargo.lock
run_bump "$test_dir/single" 0.2.0 ''
grep -q '^version = "0.2.0"$' "$test_dir/single/Cargo.toml"
grep -q '^version = "0.2.0"$' "$test_dir/single/Cargo.lock"
expect_failure "$test_dir/single" 0.2.0 '' 'already has version 0.2.0'

make_package "$test_dir/missing" missing
sed -i '/^version = /d' "$test_dir/missing/Cargo.toml"
expect_failure "$test_dir/missing" 0.2.0 '' 'needs a direct [package].version string'

make_package "$test_dir/untracked" untracked
cargo generate-lockfile --offline --manifest-path "$test_dir/untracked/Cargo.toml"
git -C "$test_dir/untracked" init -q
expect_failure "$test_dir/untracked" 0.2.0 '' 'Cargo.lock must be tracked by Git'

mkdir -p "$test_dir/workspace"
cat > "$test_dir/workspace/Cargo.toml" <<'EOF'
[workspace]
members = ["a", "b"]
resolver = "2"
EOF
make_package "$test_dir/workspace/a" a
make_package "$test_dir/workspace/b" b
cargo generate-lockfile --offline --manifest-path "$test_dir/workspace/Cargo.toml"
git -C "$test_dir/workspace" init -q
git -C "$test_dir/workspace" add Cargo.toml Cargo.lock a/Cargo.toml b/Cargo.toml
run_bump "$test_dir/workspace" 0.2.0 'a/Cargo.toml'
grep -A1 '^name = "a"$' "$test_dir/workspace/Cargo.lock" | grep -q '^version = "0.2.0"$'
grep -A1 '^name = "b"$' "$test_dir/workspace/Cargo.lock" | grep -q '^version = "0.1.0"$'

sed -i 's/version = "0.1.0"/version = "0.3.0"/' "$test_dir/workspace/b/Cargo.toml"
expect_failure "$test_dir/workspace" 0.4.0 'a/Cargo.toml' 'changed beyond a version'

mkdir -p "$test_dir/inherited"
cat > "$test_dir/inherited/Cargo.toml" <<'EOF'
[workspace]
members = ["member"]

[workspace.package]
version = "0.1.0"
EOF
make_package "$test_dir/inherited/member" member
sed -i 's/version = "0.1.0"/version.workspace = true/' "$test_dir/inherited/member/Cargo.toml"
expect_failure "$test_dir/inherited" 0.2.0 'member/Cargo.toml' 'needs a direct [package].version string'

echo 'Rust prepare scenarios passed'
