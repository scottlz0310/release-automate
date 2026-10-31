#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

extract_step() {
  awk -v step="$2" '
    { sub(/\r$/, "") }
    $0 == "      - name: " step { found=1; next }
    found && /^        run: \|$/ { running=1; next }
    running && /^      - / { exit }
    running { sub(/^          /, ""); print }
  ' "$1" > "$3"
  [[ -s "$3" ]]
}
extract_step "$repo_root/.github/workflows/reusable-prepare-release.yml" 'Update Changelog' "$test_dir/changelog.sh"
extract_step "$repo_root/.github/workflows/reusable-finalize-release.yml" 'Prepare release evidence' "$test_dir/prepare.sh"
extract_step "$repo_root/.github/workflows/reusable-finalize-release.yml" 'Append release evidence' "$test_dir/append.sh"

mkdir "$test_dir/work" "$test_dir/bin"
cd "$test_dir/work"
git init -q
git -c user.name=test -c user.email=test@example.invalid commit -qm initial --allow-empty
git tag v1.2.2-rc.1
git -c user.name=test -c user.email=test@example.invalid commit -qm stable --allow-empty
git tag v1.2.2
git tag v1
export VERSION=1.2.3 TAG_NAME=v1.2.3 REPOSITORY=owner/repo CHANGELOG_PATH=CHANGELOG.md
export ADDITIONAL_CHANGELOG_PATHS='["CHANGELOG.ja.md"]'

fixture() {
  printf '# Changelog\r\n\r\n## [Unreleased]\r\n\r\n- 更新内容\r\n\r\n## [1.2.2] - 2026-01-01\r\n\r\n[Unreleased]: https://github.com/owner/repo/compare/v1.2.2...HEAD\r\n' > CHANGELOG.md
  cp CHANGELOG.md CHANGELOG.ja.md
  cp CHANGELOG.md original.md
}
fixture
bash "$test_dir/changelog.sh"
cmp CHANGELOG.md CHANGELOG.ja.md
grep -Fq '[1.2.3]: https://github.com/owner/repo/compare/v1.2.2...v1.2.3' CHANGELOG.md
python3 - <<'PY'
from pathlib import Path
raw = Path('CHANGELOG.md').read_bytes()
assert b'## [1.2.3] - ' in raw
assert b'\n' not in raw.replace(b'\r\n', b'')
PY

# 翻訳の欠落・見出し不正・版の重複で主原稿も変更しない。
for failure in missing header duplicate link; do
  fixture
  case "$failure" in
    missing) rm CHANGELOG.ja.md ;;
    header) sed -i 's/Unreleased/Pending/g' CHANGELOG.ja.md ;;
    duplicate) printf '\n## [1.2.3]\n' >> CHANGELOG.ja.md ;;
    link) sed -i '/^\[Unreleased\]:/d' CHANGELOG.ja.md ;;
  esac
  if bash "$test_dir/changelog.sh" > "$test_dir/error" 2>&1; then
    echo "不正な翻訳原稿を受け付けました: $failure" >&2
    exit 1
  fi
  cmp CHANGELOG.md original.md
done
for invalid in '{}' '[null]' '[""]'; do
  fixture
  if ADDITIONAL_CHANGELOG_PATHS=$invalid bash "$test_dir/changelog.sh" > "$test_dir/error" 2>&1; then
    echo '不正な追加原稿指定を受け付けました' >&2
    exit 1
  fi
  cmp CHANGELOG.md original.md
done
fixture
ADDITIONAL_CHANGELOG_PATHS='["CHANGELOG.md","CHANGELOG.ja.md"]' bash "$test_dir/changelog.sh"
fixture
ADDITIONAL_CHANGELOG_PATHS='[]' bash "$test_dir/changelog.sh"
cmp CHANGELOG.ja.md original.md
CHANGELOG_PATH=absent ADDITIONAL_CHANGELOG_PATHS='[]' bash "$test_dir/changelog.sh"
git tag -d v1.2.2 > /dev/null
git tag v1.2.2-rc.2
git tag v1.2.2-rc.10
fixture
bash "$test_dir/changelog.sh"
grep -Fq '[1.2.3]: https://github.com/owner/repo/compare/v1.2.2-rc.10...v1.2.3' CHANGELOG.md
git tag -d v1.2.2-rc.1 v1.2.2-rc.2 v1.2.2-rc.10 > /dev/null
fixture
bash "$test_dir/changelog.sh"
grep -Fq '[1.2.3]: https://github.com/owner/repo/releases/tag/v1.2.3' CHANGELOG.md

# 実際のタグと分岐履歴で、対象版未満かつ到達可能な比較元だけを選ぶ。
python3 - "$test_dir/changelog.sh" "$test_dir" <<'PY'
import os
import pathlib
import subprocess
import sys

script, root = map(pathlib.Path, sys.argv[1:])
cases = [
    ("旧系列混在", "0.7.0", ["v3.2.0", "v3.1.0", "v0.6.0", "v0.5.0"], [], "v0.6.0"),
    ("対象版以上のみ", "0.7.0", ["v3.2.0", "v0.7.0", "v0.7.0+build.1"], [], None),
    ("対象版と同順位", "1.2.3+build.2", ["v1.2.3", "v1.2.3+build.1", "v1.2.2"], [], "v1.2.2"),
    ("RCの数値順", "1.2.3-rc.11", ["v1.2.3-rc.2", "v1.2.3-rc.10", "v1.2.3", "v1.2.4-rc.1"], [], "v1.2.3-rc.10"),
    ("RCの文字列順", "1.2.3-rc.1", ["v1.2.3-alpha.1", "v1.2.3-beta.2", "v1.2.3-rc.2"], [], "v1.2.3-beta.2"),
    ("安定版の前のRC", "1.2.3", ["v1.2.2", "v1.2.3-rc.10"], [], "v1.2.3-rc.10"),
    ("比較元のmetadata", "1.2.3", ["v1.2.2+build.1", "v1.2.4+build.1"], [], "v1.2.2+build.1"),
    ("初回リリース", "1.0.0", [], [], None),
    ("固定タグ以外", "1.0.0", ["v1", "v1.0", "nightly", "other-v0.9.0"], [], None),
    ("未マージのタグ", "1.2.3", ["v1.2.1"], ["v1.2.2"], "v1.2.1"),
]
for index, (name, version, tags, unmerged, expected) in enumerate(cases):
    work = root / f"previous-tag-{index}"
    work.mkdir()

    def git(*args):
        return subprocess.run(["git", *args], cwd=work, check=True, capture_output=True, text=True).stdout.strip()

    git("init", "-q")
    git("-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial", "--allow-empty")
    base = git("rev-parse", "HEAD")
    for tag in tags:
        git("tag", tag)
    if unmerged:
        git("checkout", "-qb", "unmerged")
        git("-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-qm", "unmerged", "--allow-empty")
        for tag in unmerged:
            git("tag", tag)
        git("checkout", "--detach", base)
    fixture = "# Changelog\n\n## [Unreleased]\n\n- 更新内容\n\n[Unreleased]: https://github.com/owner/repo/compare/main...HEAD\n"
    for path in ("CHANGELOG.md", "CHANGELOG.ja.md"):
        (work / path).write_text(fixture, encoding="utf-8")
    env = dict(os.environ, VERSION=version, TAG_NAME=f"v{version}",
               ADDITIONAL_CHANGELOG_PATHS='["CHANGELOG.ja.md"]')
    subprocess.run(["bash", str(script)], cwd=work, env=env, check=True)
    destination = f"compare/{expected}...v{version}" if expected else f"releases/tag/v{version}"
    link = f"[{version}]: https://github.com/owner/repo/{destination}"
    for path in ("CHANGELOG.md", "CHANGELOG.ja.md"):
        assert link in (work / path).read_text(encoding="utf-8").splitlines(), (name, path, link)
    print(f"比較元タグ: {name} 成功")
PY

cat > "$test_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'release view')
    [[ ! -f fail-view ]]
    python3 -c 'import json,pathlib; print(json.dumps({"body":pathlib.Path("body.md").read_text()}))'
    ;;
  'release edit')
    [[ ! -f fail-edit ]]
    cp RELEASE_NOTES.md body.md
    echo edit >> calls
    if [[ -f mismatch ]]; then echo changed >> body.md; fi
    ;;
  *) echo "予期しない gh 呼び出し: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$test_dir/bin/gh"
export PATH="$test_dir/bin:$PATH"
export GITHUB_REPOSITORY=owner/repo TAG=v1.2.3
export TARGET_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export RUN_URL=https://github.com/owner/repo/actions/runs/123
export DOCKER_IMAGE=ghcr.io/owner/repo DOCKER_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export VERIFICATION_RESULTS='{"build":{"result":"success","outputs":{"digest":"unused"}},"verify":{"result":"success","outputs":{}}}'
bash "$test_dir/prepare.sh"
printf '# 日本語の変更内容\n\n既存本文\n' > body.md
bash "$test_dir/append.sh"
cp body.md once.md
bash "$test_dir/append.sh"
cmp body.md once.md
grep -Fq "\`$DOCKER_IMAGE@$DOCKER_DIGEST\`" body.md
grep -Fq '既存本文' body.md
[[ $(grep -c '^## 検証$' body.md) == 1 ]]
[[ $(grep -c '^## Docker$' body.md) == 1 ]]
printf '\n後から書いた説明\n' >> body.md
bash "$test_dir/append.sh"
grep -Fq '後から書いた説明' body.md
DOCKER_IMAGE='' DOCKER_DIGEST='' bash "$test_dir/prepare.sh"
bash "$test_dir/append.sh"
if grep -q '^## Docker$' body.md; then
  echo 'Docker を省略した証跡に Docker 節が残っています' >&2
  exit 1
fi

# 証跡の不正入力は公開処理より前に失敗させる。
for invalid in '{}' '[]' '{"build":{"result":"failure"}}' '{"build":{"result":"skipped"}}' '{"build":null}'; do
  if VERIFICATION_RESULTS=$invalid bash "$test_dir/prepare.sh" > "$test_dir/error" 2>&1; then
    echo '不正な検証結果を受け付けました' >&2
    exit 1
  fi
done
for invalid in '' sha256:invalid; do
  if DOCKER_DIGEST=$invalid bash "$test_dir/prepare.sh" > "$test_dir/error" 2>&1; then
    echo '不正な digest を受け付けました' >&2
    exit 1
  fi
done
for failure in fail-view fail-edit mismatch marker; do
  rm -f fail-view fail-edit mismatch calls
  printf '既存本文\n' > body.md
  if [[ "$failure" == marker ]]; then
    echo '<!-- release-automate:evidence:start -->' >> body.md
  else
    touch "$failure"
  fi
  if bash "$test_dir/append.sh" > "$test_dir/error" 2>&1; then
    echo "証跡更新の失敗を成功扱いしました: $failure" >&2
    exit 1
  fi
done
echo 'Release adoption scenarios passed'
