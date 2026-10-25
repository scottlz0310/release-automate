#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
awk '
  { sub(/\r$/, "") }
  $0 == "      - name: Run Version Bump Strategy" { found=1; next }
  found && /^        run: \|$/ { running=1; next }
  running && /^      - / { exit }
  running { sub(/^          /, ""); print }
' "$repo_root/.github/workflows/reusable-prepare-release.yml" > "$test_dir/bump.sh"
[[ -s "$test_dir/bump.sh" ]]

for version in 1.2.3 1.2.3-rc.1 1.2.3+build-feature 1.2.3-rc.1+build-feature; do
  mkdir -p "$test_dir/$version"
  (
    cd "$test_dir/$version"
    printf '<Project><PropertyGroup><Version>1.0.0</Version><AssemblyVersion>1.0.0.0</AssemblyVersion><FileVersion>1.0.0.0</FileVersion><InformationalVersion>1.0.0</InformationalVersion></PropertyGroup></Project>\n' > app.props
    VERSION=$version STRATEGY=dotnet VERSION_FILE=app.props bash "$test_dir/bump.sh"
    python3 - "$version" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse('app.props').getroot()
assert root.findtext('.//Version') == sys.argv[1]
assert root.findtext('.//InformationalVersion') == sys.argv[1]
assert root.findtext('.//AssemblyVersion') == '1.2.3.0'
assert root.findtext('.//FileVersion') == '1.2.3.0'
PY
    printf '{"name":"fixture","private":true,"version":"1.0.0"}\n' > package.json
    cp package.json original.json
    if [[ "$version" == *+* ]]; then
      if VERSION=$version STRATEGY=npm VERSION_FILE='' bash "$test_dir/bump.sh" > error.log 2>&1; then
        echo 'npm が metadata を失ったまま成功しました' >&2
        exit 1
      fi
      grep -q 'build metadata' error.log
      cmp package.json original.json
    else
      VERSION=$version STRATEGY=npm VERSION_FILE='' bash "$test_dir/bump.sh"
      test "$(node -p "require('./package.json').version")" = "$version"
    fi
  )
done
echo 'npm/dotnet prepare scenarios passed'
