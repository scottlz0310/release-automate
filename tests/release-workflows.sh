#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

extract_step() {
  awk -v step="$2" '
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

mkdir "$test_dir/bin" "$test_dir/state"
cat > "$test_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state=$MOCK_STATE
tag=v1.2.3
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
    elif [[ "$1" == */git/matching-refs/tags/$tag ]]; then
      if [[ -f "$state/tag_sha" ]]; then
        printf '[{"ref":"refs/tags/%s","object":{"type":"commit","sha":"%s"}}]\n' \
          "$tag" "$(cat "$state/tag_sha")"
      else
        echo '[]'
      fi
    elif [[ "$1" == --paginate && "$2" == */releases\?per_page=100 ]]; then
      if [[ -f "$state/release_state" ]]; then
        draft=false
        if [[ $(cat "$state/release_state") == draft ]]; then
          draft=true
        fi
        recorded_target=$(cat "$state/release_target" 2>/dev/null || cat "$state/tag_sha" 2>/dev/null || echo '')
        printf '[{"tag_name":"%s","draft":%s,"target_commitish":"%s"}]\n' \
          "$tag" "$draft" "$recorded_target"
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
        ;;
      *) echo "Unexpected gh release: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "Unexpected gh command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$test_dir/bin/gh"

export PATH="$test_dir/bin:$PATH"
export MOCK_STATE="$test_dir/state"
export GITHUB_REPOSITORY=example/project
export RUNNER_TEMP="$test_dir"
export GITHUB_OUTPUT="$test_dir/output"
export TAG=v1.2.3
export TARGET_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export RUN_SHA=$TARGET_SHA
export DRAFT=true
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
    echo "Expected $2 calls to $1" >&2
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

echo 'Release workflow scenarios passed'
