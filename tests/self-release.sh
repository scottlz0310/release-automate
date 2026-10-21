#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export REAL_GIT
REAL_GIT=$(command -v git)
git init -q --bare "$test_dir/remote.git"
git init -q -b main "$test_dir/work"
cd "$test_dir/work"
git config user.name test
git config user.email test@example.invalid
git config commit.gpgsign false
git config core.hooksPath /dev/null
git commit -q --allow-empty -m 'chore(release): v3.0.0'
export OLD_SHA TARGET_SHA NEW_SHA
OLD_SHA=$(git rev-parse HEAD)
git commit -q --allow-empty -m 'chore(release): v3.1.0 (#43)'
TARGET_SHA=$(git rev-parse HEAD)
git commit -q --allow-empty -m 'chore(release): v3.2.0'
NEW_SHA=$(git rev-parse HEAD)
git remote add origin "$test_dir/remote.git"
git push -q origin main
mkdir "$test_dir/bin"
export MOCK_STATE="$test_dir/state"
export MOCK_REMOTE="$test_dir/remote.git"
mkdir "$MOCK_STATE"
cat > "$test_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -f "$MOCK_STATE/api-error" ]] || exit 1
case "$1 $2" in
  'run list')
    [[ "$*" == *'--workflow ci.yml'* && "$*" == *"--commit $TARGET_SHA"* && "$*" == *'--event push'* ]]
    mode=$(cat "$MOCK_STATE/mode")
    if [[ "$mode" == absent ]]; then
      echo '[]'
    elif [[ "$mode" == malformed ]]; then
      echo 'invalid JSON'
    elif [[ "$mode" == pending-once && ! -f "$MOCK_STATE/slept" ]]; then
      echo '[]'
    else
      sha=$TARGET_SHA
      [[ "$mode" != wrong-sha ]] || sha=$OLD_SHA
      conclusion=success
      [[ "$mode" != failed ]] || conclusion=failure
      jq -n --arg sha "$sha" --arg conclusion "$conclusion" \
        '[{headSha: $sha, status: "completed", conclusion: $conclusion, databaseId: 1}]'
    fi
    ;;
  'release view')
    mode=$(cat "$MOCK_STATE/mode")
    sha=$TARGET_SHA
    draft=false
    [[ "$mode" != wrong-release ]] || sha=$OLD_SHA
    [[ "$mode" != draft ]] || draft=true
    jq -n --arg sha "$sha" --argjson draft "$draft" \
      '{tagName: "v3.1.0", isDraft: $draft, targetCommitish: $sha}'
    ;;
  'api repos/example/release-automate/releases/latest')
    tag=v3.1.0
    [[ $(cat "$MOCK_STATE/mode") != wrong-latest ]] || tag=v3.0.0
    jq -n --arg tag "$tag" '{tag_name: $tag}'
    ;;
  *) echo "予期しない gh 呼び出し: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$test_dir/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
touch "$MOCK_STATE/slept"
MOCK
cat > "$test_dir/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == push && -f "$MOCK_STATE/race" ]]; then
  "$REAL_GIT" --git-dir="$MOCK_REMOTE" update-ref refs/tags/v3 "$NEW_SHA"
fi
exec "$REAL_GIT" "$@"
MOCK
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export GH_REPO=example/release-automate
export GITHUB_REF=refs/heads/main DEFAULT_BRANCH=main REF_PROTECTED=true
export GITHUB_SHA=$NEW_SHA GITHUB_OUTPUT="$test_dir/output"
export REQUESTED_TAG=v3.1.0 TAG=v3.1.0 EXPECTED_MAJOR_SHA=$OLD_SHA

reset_state() {
  find "$MOCK_STATE" -type f -delete
  echo success > "$MOCK_STATE/mode"
  : > "$GITHUB_OUTPUT"
  git --git-dir="$MOCK_REMOTE" update-ref refs/tags/v3 "$OLD_SHA"
  git --git-dir="$MOCK_REMOTE" update-ref refs/tags/v2 "$OLD_SHA"
  git --git-dir="$MOCK_REMOTE" update-ref refs/tags/v3.1.0 "$TARGET_SHA"
}

expect() {
  local outcome=$1 label=$2
  shift 2
  if "$@" > "$test_dir/log" 2>&1; then
    [[ "$outcome" == success ]] || { cat "$test_dir/log"; echo "失敗すべきケース: $label"; exit 1; }
  else
    [[ "$outcome" == failure ]] || { cat "$test_dir/log"; echo "成功すべきケース: $label"; exit 1; }
  fi
  echo "PASS: $label"
}

reset_state
expect success '準備と更新前 SHA の記録' bash "$repo_root/scripts/self-release.sh" preflight
[[ $(cat "$GITHUB_OUTPUT") == "tag_name=v3.1.0"$'\n'"target_sha=$TARGET_SHA"$'\n'"expected_major_sha=$OLD_SHA" ]]
for scenario in wrong-tag unprotected wrong-branch rollback; do
  reset_state
  case "$scenario" in
    wrong-tag) expect failure "$scenario" env REQUESTED_TAG=v3.9.0 bash "$repo_root/scripts/self-release.sh" preflight ;;
    unprotected) expect failure "$scenario" env REF_PROTECTED=false bash "$repo_root/scripts/self-release.sh" preflight ;;
    wrong-branch) expect failure "$scenario" env GITHUB_REF=refs/heads/topic bash "$repo_root/scripts/self-release.sh" preflight ;;
    rollback)
      git --git-dir="$MOCK_REMOTE" update-ref refs/tags/v3 "$NEW_SHA"
      expect failure "$scenario" bash "$repo_root/scripts/self-release.sh" preflight
      ;;
  esac
done
reset_state
expect failure '不正な対象 SHA' env TARGET_SHA=invalid bash "$repo_root/scripts/self-release.sh" preflight
expect failure '対象が実行コミットの祖先ではない' env GITHUB_SHA="$OLD_SHA" bash "$repo_root/scripts/self-release.sh" preflight
non_release=$(printf 'fix: unrelated\n' | git commit-tree 'HEAD^{tree}' -p "$NEW_SHA")
expect failure '通常コミットの公開拒否' env TARGET_SHA="$non_release" GITHUB_SHA="$non_release" bash "$repo_root/scripts/self-release.sh" preflight
expect failure 'プレリリースは自己リリースの対象外' env TAG=v3.1.0-rc.1 bash "$repo_root/scripts/self-release.sh" update-major
reset_state
git tag -a v3-annotated "$OLD_SHA" -m test
annotated=$(git rev-parse v3-annotated)
git push -q origin v3-annotated
git --git-dir="$MOCK_REMOTE" update-ref refs/tags/v3 "$annotated"
expect success '注釈付きメジャータグの祖先確認' bash "$repo_root/scripts/self-release.sh" preflight
[[ $(tail -n 1 "$GITHUB_OUTPUT") == "expected_major_sha=$annotated" ]]
reset_state
git --git-dir="$MOCK_REMOTE" update-ref -d refs/tags/v3
expect success '新しいメジャー系列' bash "$repo_root/scripts/self-release.sh" preflight
[[ $(tail -n 1 "$GITHUB_OUTPUT") == 'expected_major_sha=' ]]

for scenario in success pending-once failed wrong-sha malformed absent; do
  reset_state
  echo "$scenario" > "$MOCK_STATE/mode"
  outcome=failure
  [[ "$scenario" != success && "$scenario" != pending-once ]] || outcome=success
  expect "$outcome" "CI: $scenario" bash "$repo_root/scripts/self-release.sh" wait-ci
done
reset_state
touch "$MOCK_STATE/api-error"
expect failure 'CI API 障害' bash "$repo_root/scripts/self-release.sh" wait-ci

for scenario in success wrong-release draft wrong-latest fixed-mismatch changed-major race; do
  reset_state
  echo "$scenario" > "$MOCK_STATE/mode"
  case "$scenario" in
    fixed-mismatch) git --git-dir="$MOCK_REMOTE" update-ref refs/tags/v3.1.0 "$OLD_SHA" ;;
    changed-major) git --git-dir="$MOCK_REMOTE" update-ref refs/tags/v3 "$NEW_SHA" ;;
    race) touch "$MOCK_STATE/race" ;;
  esac
  outcome=failure
  [[ "$scenario" != success ]] || outcome=success
  expect "$outcome" "公開後の更新: $scenario" bash "$repo_root/scripts/self-release.sh" update-major
  major_sha=$(git --git-dir="$MOCK_REMOTE" rev-parse refs/tags/v3)
  case "$scenario" in
    success) [[ "$major_sha" == "$TARGET_SHA" ]] ;;
    changed-major|race) [[ "$major_sha" == "$NEW_SHA" ]] ;;
    *) [[ "$major_sha" == "$OLD_SHA" ]] ;;
  esac
  [[ $(git --git-dir="$MOCK_REMOTE" rev-parse refs/tags/v2) == "$OLD_SHA" ]]
done
reset_state
expect success '初回の更新' bash "$repo_root/scripts/self-release.sh" update-major
expect success '公開・更新済みの再実行' bash "$repo_root/scripts/self-release.sh" update-major
reset_state
git --git-dir="$MOCK_REMOTE" update-ref -d refs/tags/v3
expect success '新しいメジャータグを作成' env EXPECTED_MAJOR_SHA= bash "$repo_root/scripts/self-release.sh" update-major
reset_state
touch "$MOCK_STATE/api-error"
expect failure '公開結果の API 障害' bash "$repo_root/scripts/self-release.sh" update-major
echo '自己リリースの全シナリオが成功しました'
