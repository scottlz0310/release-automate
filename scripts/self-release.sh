#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

stable_tag() {
  [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail '自己リリースのタグは安定版 vMAJOR.MINOR.PATCH に限定します'
}

verify_published() {
  local release fixed_ref fixed_sha latest
  release=$(gh release view "$TAG" --repo "$GH_REPO" --json tagName,isDraft,targetCommitish)
  jq -e --arg tag "$TAG" --arg sha "$TARGET_SHA" \
    '.tagName == $tag and .isDraft == false and .targetCommitish == $sha' <<< "$release" >/dev/null ||
    fail '公開済み Release のタグ・状態・記録 SHA が一致しません'
  fixed_ref=$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}")
  fixed_sha=$(awk '/\^\{\}$/ { peeled=$1 } { direct=$1 } END { print peeled ? peeled : direct }' <<< "$fixed_ref")
  [[ "$fixed_sha" == "$TARGET_SHA" ]] || fail '固定タグの対象 SHA が一致しません'
  latest=$(gh api "repos/$GH_REPO/releases/latest")
  [[ $(jq -r '.tag_name' <<< "$latest") == "$TAG" ]] || fail 'Latest Release が対象版と一致しません'
}

case "$1" in
  preflight)
    [[ "$GITHUB_REF" == "refs/heads/$DEFAULT_BRANCH" && "$REF_PROTECTED" == true ]] ||
      fail '自己リリースは保護された既定ブランチから実行してください'
    [[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] || fail '公開対象には完全なコミット SHA が必要です'
    git merge-base --is-ancestor "$TARGET_SHA" "$GITHUB_SHA" ||
      fail '公開対象は実行コミットと同一またはその祖先である必要があります'
    subject=$(git show -s --format=%s "$TARGET_SHA")
    if [[ ! "$subject" =~ ^chore\(release\):\ (v[0-9]+\.[0-9]+\.[0-9]+)(\ \(\#[0-9]+\))?$ ]]; then
      fail '公開対象の件名は chore(release): vMAJOR.MINOR.PATCH である必要があります'
    fi
    tag=${BASH_REMATCH[1]}
    stable_tag "$tag"
    [[ -z "$REQUESTED_TAG" || "$REQUESTED_TAG" == "$tag" ]] || fail '要求タグとリリースコミットの版が一致しません'
    major=${tag%%.*}
    remote_ref=$(git ls-remote --refs origin "refs/tags/$major")
    expected=${remote_ref%%$'\t'*}
    if [[ -n "$expected" ]]; then
      # 注釈付きタグの lease にはタグオブジェクト、祖先確認にはコミットを使う。
      git fetch --no-tags origin "$expected"
      previous=$(git rev-parse "$expected^{commit}")
      git merge-base --is-ancestor "$previous" "$TARGET_SHA" ||
        fail 'メジャータグを古いコミットまたは別系統へ戻すことはできません'
    fi
    {
      echo "tag_name=$tag"
      echo "target_sha=$TARGET_SHA"
      echo "expected_major_sha=$expected"
    } >> "$GITHUB_OUTPUT"
    ;;
  wait-ci)
    # PR の成功ではなく、公開するマージコミットの push CI を照合する。
    for ((attempt=1; attempt<=180; attempt++)); do
      runs=$(gh run list --repo "$GH_REPO" --workflow ci.yml --commit "$TARGET_SHA" \
        --event push --limit 1 --json headSha,status,conclusion,databaseId)
      count=$(jq 'length' <<< "$runs")
      if [[ "$count" == 1 ]]; then
        [[ $(jq -r '.[0].headSha' <<< "$runs") == "$TARGET_SHA" ]] || fail 'CI の対象 SHA が一致しません'
        if [[ $(jq -r '.[0].status' <<< "$runs") == completed ]]; then
          [[ $(jq -r '.[0].conclusion' <<< "$runs") == success ]] ||
            fail "対象 SHA の CI が成功していません: $(jq -r '.[0].conclusion' <<< "$runs")"
          echo "公開対象 $TARGET_SHA の CI 成功を確認しました"
          exit 0
        fi
      elif [[ "$count" != 0 ]]; then
        fail 'CI の取得結果が想定と異なります'
      fi
      sleep 10
    done
    fail '公開対象 SHA の CI が30分以内に成功しませんでした'
    ;;
  update-major)
    stable_tag "$TAG"
    [[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] || fail '公開対象 SHA が不正です'
    [[ -z "$EXPECTED_MAJOR_SHA" || "$EXPECTED_MAJOR_SHA" =~ ^[0-9a-f]{40}$ ]] || fail '更新前 SHA が不正です'
    verify_published
    major=${TAG%%.*}
    current_ref=$(git ls-remote --refs origin "refs/tags/$major")
    current=${current_ref%%$'\t'*}
    if [[ "$current" != "$TARGET_SHA" ]]; then
      [[ "$current" == "$EXPECTED_MAJOR_SHA" ]] || fail '検証開始後にメジャータグが変更されました'
      git push "--force-with-lease=refs/tags/$major:$EXPECTED_MAJOR_SHA" origin "$TARGET_SHA:refs/tags/$major"
    fi
    confirmed=$(git ls-remote --refs origin "refs/tags/$major")
    [[ "${confirmed%%$'\t'*}" == "$TARGET_SHA" ]] || fail 'メジャータグの更新結果が一致しません'
    verify_published
    echo "$TAG / $major / 公開済み Release が $TARGET_SHA に一致しました"
    ;;
  *) fail "不明な操作: $1" ;;
esac
