#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

extract_step() {
  awk -v step="$2" '
    { sub(/\r$/, "") }
    $0 == "      - name: " step { found = 1; next }
    found && /^        run: \|$/ { running = 1; next }
    running && /^      - / { exit }
    running { sub(/^          /, ""); print }
  ' "$1" > "$3"
  [[ -s "$3" ]]
}

extract_step "$repo_root/.github/workflows/reusable-publish-release.yml" \
  'Create Git Tag and GitHub Release' "$test_dir/publish.sh"
extract_step "$repo_root/.github/workflows/reusable-finalize-release.yml" \
  'Verify draft and publish Release' "$test_dir/finalize.sh"
extract_step "$repo_root/.github/workflows/reusable-publish-release.yml" \
  'Extract Tag and Release Notes' "$test_dir/notes.sh"

mkdir "$test_dir/bin" "$test_dir/state"
cat > "$test_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state=$MOCK_STATE
tag=$TAG
case "$1" in
  api)
    shift
    if [[ "$1" == -X ]]; then
      [[ "$2" == POST && "$3" == */git/refs ]]
      [[ ! -f "$state/tag_sha" ]]
      for arg in "$@"; do
        if [[ "$arg" == sha=* ]]; then
          printf '%s' "${arg#sha=}" > "$state/tag_sha"
        fi
      done
      echo create-tag >> "$state/calls"
      echo '{}'
    elif [[ "$1" == "repos/$GITHUB_REPOSITORY/compare/$TARGET_SHA...$RUN_SHA" ]]; then
      [[ ! -f "$state/fail_compare" ]]
      comparison_status=$(cat "$state/comparison_status" 2>/dev/null || echo ahead)
      merge_base=$(cat "$state/merge_base" 2>/dev/null || echo "$TARGET_SHA")
      printf '{"status":"%s","merge_base_commit":{"sha":"%s"}}\n' "$comparison_status" "$merge_base"
    elif [[ "$1" == "repos/$GITHUB_REPOSITORY/commits/$TARGET_SHA" ]]; then
      [[ ! -f "$state/fail_commit" ]]
      subject=$(cat "$state/subject" 2>/dev/null || echo 'chore(release): v1.2.3')
      commit_sha=$(cat "$state/commit_sha" 2>/dev/null || echo "$TARGET_SHA")
      jq -n --arg sha "$commit_sha" --arg message "$subject" '{sha: $sha, commit: {message: $message}}'
    elif [[ "$1" == */git/tags/cccccccccccccccccccccccccccccccccccccccc ]]; then
      printf '{"object":{"type":"commit","sha":"%s"}}\n' "$(cat "$state/tag_sha")"
    elif [[ "$1" == */git/matching-refs/tags/$tag ]]; then
      if [[ -f "$state/tag_sha" ]]; then
        if [[ -f "$state/annotated_tag" ]]; then
          printf '[{"ref":"refs/tags/%s","object":{"type":"tag","sha":"cccccccccccccccccccccccccccccccccccccccc"}}]\n' "$tag"
        else
          printf '[{"ref":"refs/tags/%s","object":{"type":"commit","sha":"%s"}}]\n' \
            "$tag" "$(cat "$state/tag_sha")"
        fi
      else
        echo '[]'
      fi
    elif [[ "$1" == --paginate && "$2" == */releases\?per_page=100 ]]; then
      [[ ! -f "$state/fail_list" ]]
      echo list-releases >> "$state/calls"
      if [[ -f "$state/list_lag" ]]; then
        remaining=$(cat "$state/list_lag")
        if (( remaining > 0 )); then
          printf '%s' "$((remaining - 1))" > "$state/list_lag"
          echo '[]'
          exit 0
        fi
      fi
      if [[ -f "$state/release_state" ]]; then
        draft=false
        if [[ $(cat "$state/release_state") == draft ]]; then
          draft=true
        fi
        if [[ -f "$state/list_draft_override" ]]; then
          draft=$(cat "$state/list_draft_override")
        fi
        recorded_target=$(cat "$state/release_target" 2>/dev/null || cat "$state/tag_sha" 2>/dev/null || echo '')
        release_id=$(cat "$state/release_id" 2>/dev/null || echo 1)
        release_json=$(printf '{"id":%s,"tag_name":"%s","draft":%s,"target_commitish":"%s"}' \
          "$release_id" "$tag" "$draft" "$recorded_target")
        if [[ -f "$state/list_duplicate" ]]; then
          printf '[%s,%s]\n' "$release_json" "$release_json"
        else
          printf '[%s]\n' "$release_json"
        fi
      else
        echo '[]'
      fi
    else
      echo "Unexpected gh api: $*" >&2
      exit 1
    fi
    ;;
  release)
    case "$2" in
      create)
        printf '%s\n' "$@" > "$state/create_args"
        [[ -f "$state/tag_sha" && ! -f "$state/release_state" ]]
        if [[ -f "$state/fail_create" ]]; then
          rm "$state/fail_create"
          echo 'Simulated release creation failure' >&2
          exit 1
        fi
        release_state=published
        for arg in "$@"; do
          if [[ "$arg" == --draft ]]; then
            release_state=draft
          fi
        done
        printf '%s' "$release_state" > "$state/release_state"
        echo create-release >> "$state/calls"
        if [[ -f "$state/list_lag_after_create" ]]; then
          cp "$state/list_lag_after_create" "$state/list_lag"
        fi
        if [[ -f "$state/fail_after_create" ]]; then
          rm "$state/fail_after_create"
          echo 'Simulated response failure after creation' >&2
          exit 1
        fi
        ;;
      edit)
        [[ -f "$state/release_state" && $(cat "$state/release_state") == draft ]]
        if [[ -f "$state/fail_edit" ]]; then
          rm "$state/fail_edit"
          echo 'Simulated publish failure' >&2
          exit 1
        fi
        printf published > "$state/release_state"
        echo publish-release >> "$state/calls"
        for field in tag_sha release_target release_id; do
          if [[ -f "$state/change_$field" ]]; then
            cp "$state/change_$field" "$state/$field"
          fi
        done
        if [[ -f "$state/duplicate_after_edit" ]]; then
          touch "$state/list_duplicate"
        fi
        if [[ -f "$state/draft_after_edit" ]]; then
          printf draft > "$state/release_state"
        fi
        ;;
      *) echo "Unexpected gh release: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "Unexpected gh command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$test_dir/bin/gh"
cat > "$test_dir/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
echo sleep >> "$MOCK_STATE/calls"
MOCK
chmod +x "$test_dir/bin/sleep"

export PATH="$test_dir/bin:$PATH"
export MOCK_STATE="$test_dir/state"
export GITHUB_REPOSITORY=example/project
export RUNNER_TEMP="$test_dir"
export GITHUB_OUTPUT="$test_dir/output"
export TAG=v1.2.3
export TARGET_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export RUN_SHA=$TARGET_SHA
export DRAFT=true
export RESUME=false
export COMMIT_MESSAGE_PREFIX='chore(release):'
export RUN_EVENT_NAME=workflow_dispatch
export RUN_REF=refs/heads/main
export RUN_REF_PROTECTED=true
export DEFAULT_BRANCH=main
: > "$GITHUB_OUTPUT"

reset_state() {
  rm -f "$MOCK_STATE"/* "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
}

count_calls() {
  if [[ -f "$MOCK_STATE/calls" ]]; then
    grep -c "^$1$" "$MOCK_STATE/calls" || true
  else
    echo 0
  fi
}

assert_count() {
  [[ $(count_calls "$1") == "$2" ]] || {
    echo "Expected $2 calls to $1, got $(count_calls "$1")" >&2
    exit 1
  }
}

run_publish() { bash "$test_dir/publish.sh" >/dev/null; }
run_finalize() { bash "$test_dir/finalize.sh" >/dev/null; }

# Draft creation, same-SHA retry, publish, and published retries are idempotent.
run_publish
[[ $(cat "$MOCK_STATE/release_state") == draft ]]
grep -q '^release_state=draft$' "$GITHUB_OUTPUT"
run_publish
assert_count create-tag 1
assert_count create-release 1
run_finalize
[[ $(cat "$MOCK_STATE/release_state") == published ]]
run_finalize
run_publish
assert_count publish-release 1
assert_count create-release 1

# A tag at another commit must not create or publish a Release.
reset_state
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$MOCK_STATE/tag_sha"
if run_publish 2>/dev/null || run_finalize 2>/dev/null; then
  echo 'Mismatched tag was accepted' >&2
  exit 1
fi
assert_count create-release 0

# A Release with a different recorded SHA or no tag is rejected.
reset_state
printf '%s' "$TARGET_SHA" > "$MOCK_STATE/tag_sha"
printf draft > "$MOCK_STATE/release_state"
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$MOCK_STATE/release_target"
if run_publish 2>/dev/null || run_finalize 2>/dev/null; then
  echo 'Mismatched Release target was accepted' >&2
  exit 1
fi
reset_state
printf draft > "$MOCK_STATE/release_state"
if run_publish 2>/dev/null; then
  echo 'Release without a tag was accepted' >&2
  exit 1
fi
assert_count create-tag 0

# The legacy default publishes immediately; a draft cannot bypass finalization.
reset_state
DRAFT=false run_publish
[[ $(cat "$MOCK_STATE/release_state") == published ]]
reset_state
DRAFT=true run_publish
if DRAFT=false run_publish 2>/dev/null; then
  echo 'Immediate publication accepted an existing draft' >&2
  exit 1
fi

# Failure after tag creation and failure before publish can both be retried.
reset_state
touch "$MOCK_STATE/fail_create"
if run_publish 2>/dev/null; then
  echo 'Simulated creation failure was ignored' >&2
  exit 1
fi
run_publish
assert_count create-tag 1
assert_count create-release 1
reset_state
touch "$MOCK_STATE/fail_after_create"
if run_publish 2>/dev/null; then
  echo 'Simulated response failure was ignored' >&2
  exit 1
fi
run_publish
assert_count create-tag 1
assert_count create-release 1
[[ $(cat "$MOCK_STATE/release_state") == draft ]]
touch "$MOCK_STATE/fail_edit"
if run_finalize 2>/dev/null; then
  echo 'Simulated publish failure was ignored' >&2
  exit 1
fi
[[ $(cat "$MOCK_STATE/release_state") == draft ]]
run_finalize
assert_count publish-release 1

# Finalization must remain in the original workflow run.
reset_state
run_publish
if RUN_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run_finalize 2>/dev/null; then
  echo 'Different workflow SHA was accepted' >&2
  exit 1
fi
assert_count publish-release 0

# A newly created Release may be absent from the list for a few reads.
for release_mode in true false; do
  reset_state
  printf 2 > "$MOCK_STATE/list_lag_after_create"
  DRAFT=$release_mode run_publish
  assert_count create-release 1
  assert_count sleep 2
  if [[ "$release_mode" == true ]]; then
    grep -q '^release_state=draft$' "$GITHUB_OUTPUT"
  else
    grep -q '^release_state=published$' "$GITHUB_OUTPUT"
  fi
done

# An absent, duplicate, or wrongly staged Release must still fail.
reset_state
printf 9 > "$MOCK_STATE/list_lag_after_create"
if run_publish 2>/dev/null; then
  echo 'Release list retry limit was ignored' >&2
  exit 1
fi
assert_count sleep 4
assert_count list-releases 7

reset_state
touch "$MOCK_STATE/list_duplicate"
if run_publish 2>/dev/null; then
  echo 'Duplicate Releases were accepted' >&2
  exit 1
fi
assert_count sleep 0

reset_state
printf false > "$MOCK_STATE/list_draft_override"
if run_publish 2>/dev/null; then
  echo 'Unexpected Release state was accepted' >&2
  exit 1
fi
assert_count sleep 0

# 修正後の手動実行から、元の draft の公開を再開できる。
prepare_resume() { reset_state; run_publish; }
run_resume() { RESUME=true RUN_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run_finalize; }
expect_resume_failure() {
  if run_resume > "$test_dir/resume-error" 2>&1; then
    echo '拒否すべき再開が成功しました' >&2
    exit 1
  fi
  assert_count publish-release 0
}

for subject in 'chore(release): v1.2.3' 'chore(release): v1.2.3 (#42)'; do
  prepare_resume
  printf '%s' "$subject" > "$MOCK_STATE/subject"
  run_resume
  run_resume
  assert_count publish-release 1
  grep -q '^release_state=published$' "$GITHUB_OUTPUT"
done

# 通常経路には再開専用の手動実行・保護ブランチ条件を課さない。
prepare_resume
RUN_EVENT_NAME=push RUN_REF_PROTECTED=false DEFAULT_BRANCH='' run_finalize
assert_count publish-release 1

prepare_resume
printf identical > "$MOCK_STATE/comparison_status"
RESUME=true run_finalize
assert_count publish-release 1

prepare_resume
touch "$MOCK_STATE/annotated_tag"
run_resume
run_resume
assert_count publish-release 1

prepare_resume
printf 'release: v1.2.3' > "$MOCK_STATE/subject"
COMMIT_MESSAGE_PREFIX=release: run_resume
assert_count publish-release 1

# 手動実行・保護された既定ブランチ以外からの再開を拒否する。
for event in push pull_request workflow_call; do
  prepare_resume
  RUN_EVENT_NAME=$event expect_resume_failure
done
for ref in refs/heads/feature refs/tags/v1.2.3 refs/pull/1/merge; do
  prepare_resume
  RUN_REF=$ref expect_resume_failure
done
prepare_resume
RUN_REF_PROTECTED=false expect_resume_failure
prepare_resume
DEFAULT_BRANCH='' expect_resume_failure
prepare_resume
if RESUME=true RUN_SHA=invalid run_finalize > "$test_dir/resume-error" 2>&1; then
  echo '不正な実行 SHA が受け付けられました' >&2
  exit 1
fi
assert_count publish-release 0

for tag in v1.2 invalid-tag; do
  prepare_resume
  TAG=$tag expect_resume_failure
done

# 非祖先・別コミット・不正なコミット件名・取得エラーで公開しない。
for status in behind diverged unknown; do
  prepare_resume
  printf '%s' "$status" > "$MOCK_STATE/comparison_status"
  expect_resume_failure
done
for field in merge_base commit_sha tag_sha; do
  prepare_resume
  printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$MOCK_STATE/$field"
  expect_resume_failure
done
for subject in 'fix: v1.2.3' 'chore(release): v1.2.4' 'chore(release): v1.2.30' \
  'chore(release): v1.2.3 unexpected' 'chore(release): v1.2.3 (#abc)'; do
  prepare_resume
  printf '%s' "$subject" > "$MOCK_STATE/subject"
  expect_resume_failure
done
prepare_resume
COMMIT_MESSAGE_PREFIX='' expect_resume_failure
for failure in fail_compare fail_commit fail_list list_duplicate; do
  prepare_resume
  touch "$MOCK_STATE/$failure"
  expect_resume_failure
done
for target in bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb main ''; do
  prepare_resume
  printf '%s' "$target" > "$MOCK_STATE/release_target"
  expect_resume_failure
done
prepare_resume
printf null > "$MOCK_STATE/list_draft_override"
expect_resume_failure

# 公開後のタグ・記録 SHA・Release 置換・状態不整合も検出する。
for field in tag_sha release_target release_id; do
  prepare_resume
  if [[ "$field" == release_id ]]; then
    printf 2 > "$MOCK_STATE/change_$field"
  else
    printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$MOCK_STATE/change_$field"
  fi
  if run_resume > "$test_dir/resume-error" 2>&1; then
    echo "公開後の $field 変更を見落としました" >&2
    exit 1
  fi
  assert_count publish-release 1
done
for failure in duplicate_after_edit draft_after_edit; do
  prepare_resume
  touch "$MOCK_STATE/$failure"
  if run_resume > "$test_dir/resume-error" 2>&1; then
    echo "公開後の $failure を見落としました" >&2
    exit 1
  fi
done

# 既存 repo の RC 公開を維持し、build metadata のハイフンは RC と誤認しない。
for variant in v1.2.3-rc.1 v1.2.3+build.1 v1.2.3+build-feature v1.2.3-rc.1+build.1; do
  reset_state
  TAG=$variant run_publish
  if [[ "${variant%%+*}" == *-* ]]; then
    grep -qx -- --prerelease "$MOCK_STATE/create_args"
  elif grep -qx -- --prerelease "$MOCK_STATE/create_args"; then
    echo 'build metadata を prerelease と誤認しました' >&2
    exit 1
  fi
  TAG=$variant run_finalize
  assert_count publish-release 1
  mkdir -p "$test_dir/notes"
  (
    cd "$test_dir/notes"
    printf '## [%s] - 2026-10-26\n\n対象の変更\n\n## [1.0.0]\n隣接版の変更\n' "${variant#v}" > CHANGELOG.md
    COMMIT_MSG="chore(release): $variant" PREFIX='chore(release):' CHANGELOG_PATH=CHANGELOG.md \
      bash "$test_dir/notes.sh" > /dev/null
    grep -q '対象の変更' RELEASE_NOTES.md
    if grep -q '隣接版の変更' RELEASE_NOTES.md; then exit 1; fi
    grep -qxF "tag_name=$variant" "$GITHUB_OUTPUT"
  )
done

echo 'Release workflow scenarios passed'
