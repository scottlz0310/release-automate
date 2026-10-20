#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/actionlint" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 4 && "$1" == -config-file && "$2" == /dev/null && "$3" == -format && "$4" == '{{json .}}' ]]
printf '%s' "$MOCK_DIAGNOSTICS"
if (( MOCK_STATUS > 1 )); then
  echo '模擬 actionlint 実行障害' >&2
fi
exit "$MOCK_STATUS"
MOCK
chmod +x "$test_dir/actionlint"

expected=$(jq -nc '{kind: "runner-label", filepath: ".github/workflows/ci.yml", message: "label \"ubuntu-26.04\" is unknown. available labels are ..."}')
export MOCK_DIAGNOSTICS="[$expected]"
export MOCK_STATUS=1

run_check() {
  bash "$repo_root/scripts/check-actionlint-workaround.sh" "$test_dir/actionlint" > "$test_dir/output" 2>&1
}

expect_failure() {
  if run_check; then
    echo "拒否すべき結果が成功しました: $1" >&2
    exit 1
  fi
  grep -Fq "$1" "$test_dir/output"
}

# 実際の CI では同じ診断が2ジョブ分出るため、単一・複数の双方を確認する。
for diagnostics in "[$expected]" "[$expected,$expected]"; do
  MOCK_DIAGNOSTICS=$diagnostics run_check
  grep -Fq '現在も必要' "$test_dir/output"
done

MOCK_STATUS=0 MOCK_DIAGNOSTICS='' expect_failure '限定除外が不要'
MOCK_STATUS=0 MOCK_DIAGNOSTICS='[]' expect_failure '限定除外が不要'
for diagnostics in 'invalid-json' "[$expected]" '[] []'; do
  MOCK_STATUS=0 MOCK_DIAGNOSTICS=$diagnostics expect_failure '矛盾した診断、または解析できない出力'
done

for diagnostics in \
  '' '[]' 'null' '{}' 'invalid-json' \
  "$expected" \
  "[$expected] [$expected]" \
  "[$expected,null]" \
  "[$expected,$(jq -nc '{kind: "syntax-check", filepath: ".github/workflows/ci.yml", message: "unexpected key"}')]" \
  "$(jq -nc --argjson e "$expected" '[$e | .filepath = ".github/workflows/other.yml"]')" \
  "$(jq -nc --argjson e "$expected" '[$e | .kind = "expression"]')" \
  "$(jq -nc --argjson e "$expected" '[$e | .message = "label \"ubuntu-unknown\" is unknown."]')"; do
  MOCK_DIAGNOSTICS=$diagnostics expect_failure '想定外の診断、または解析できない出力'
done

for status in 2 3 125 127; do
  MOCK_STATUS=$status expect_failure "終了コード: $status"
  grep -Fq '模擬 actionlint 実行障害' "$test_dir/output"
done

echo 'actionlint 限定除外の判定シナリオが成功しました。'
