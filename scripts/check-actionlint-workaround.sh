#!/usr/bin/env bash
set -euo pipefail

diagnostics=$(mktemp)
trap 'rm -f "$diagnostics"' EXIT

status=0
"$@" -config-file /dev/null -format '{{json .}}' > "$diagnostics" || status=$?

if (( status == 0 )); then
  if ! jq -e -s 'length == 0 or (length == 1 and .[0] == [])' "$diagnostics" > /dev/null; then
    echo '::error::終了コード 0 の actionlint から矛盾した診断、または解析できない出力を受信しました。' >&2
    cat "$diagnostics" >&2
    exit 1
  fi
  echo '::error::actionlint の限定除外が不要になりました。#39 に従い除外と専用の検知処理・テストを同じ PR で撤去してください。' >&2
  exit 1
fi
if (( status != 1 )); then
  echo "::error::除外なし actionlint の実行に失敗しました（終了コード: $status）。除外が必要な証拠としては扱いません。" >&2
  exit 1
fi

# 空出力や複数の JSON 文書も、想定診断と誤認しない。
if ! jq -e -s '
  length == 1 and
  (.[0] | type == "array" and length > 0 and all(.[];
    .kind == "runner-label" and
    .filepath == ".github/workflows/ci.yml" and
    (.message | startswith("label \"ubuntu-26.04\" is unknown."))
  ))
' "$diagnostics" > /dev/null; then
  echo '::error::除外なし actionlint に想定外の診断、または解析できない出力があります。' >&2
  cat "$diagnostics" >&2
  exit 1
fi

echo 'actionlint の Ubuntu 26.04 限定除外は現在も必要です（追跡: #39）。'
