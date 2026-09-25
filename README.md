# release-automate

GitHub Organization (`scottlz0310`) 向けのリリース自動化 Reusable Workflows 集です。

`main` ブランチの直接 push 禁止環境において、手動バージョン指定によるリリース準備 PR 起票と、PR マージ後のタグ打ち・GitHub Release 公開を安全に自動化します。

---

## 提供する Reusable Workflows

1. [`.github/workflows/reusable-prepare-release.yml`](.github/workflows/reusable-prepare-release.yml)
   - 手動トリガー (`workflow_dispatch`) を受け、GitHub App 名義でリリース準備 PR を自動起票。
   - `target_version` の正規表現バリデーション（SemVer 検証、コマンドインジェクション防止）。
   - 事前定義された安全な `bump_strategy`（`npm`, `rust`, `dotnet`, `go`, `none`）によるバージョン定義ファイル更新。
   - `CHANGELOG.md` の `[Unreleased]` 確定および比較リンク更新。
   - サードパーティ Actions を完全なコミット SHA にピン留め。
2. [`.github/workflows/reusable-publish-release.yml`](.github/workflows/reusable-publish-release.yml)
   - `main` への Squash merge コミットをジョブレベルで検知・強制。
   - リリースコミット SHA (`github.sha`) をピン留めして Git タグ作成および GitHub Release 公開（CHANGELOG からリリースノート自動抽出）。

---

## セットアップ手順（初回のみ）

### 1. GitHub App の作成と Organization へのインストール
1. `https://github.com/organizations/scottlz0310/settings/apps` で GitHub App を作成（詳細は [release_automation_github_app_design.md](release_automation_github_app_design.md) 参照）。
   - 権限: `Contents: Read and write`, `Pull requests: Read and write`
2. App を Organization (`scottlz0310`) の対象リポジトリにインストール。
3. Organization Secrets (`https://github.com/organizations/scottlz0310/settings/secrets/actions`) に以下を一括登録：
   - `RELEASE_BOT_APP_ID`: GitHub App ID
   - `RELEASE_BOT_PRIVATE_KEY`: GitHub App の秘密鍵（PEM 形式）

---

## 各リポジトリでの利用方法

各リポジトリの `.github/workflows/` に以下の 2 つの YAML を配置します。

### 1. `.github/workflows/prepare-release.yml`

```yaml
name: Prepare Release

on:
  workflow_dispatch:
    inputs:
      target_version:
        description: 'Release version (e.g. 1.2.0)'
        required: true
        type: string

jobs:
  prepare:
    uses: scottlz0310/release-automate/.github/workflows/reusable-prepare-release.yml@v1
    secrets: inherit
    with:
      target_version: ${{ inputs.target_version }}
      # 言語に応じた bump_strategy を指定 (npm, rust, dotnet, go, none)
      bump_strategy: "npm"
```

### 2. `.github/workflows/publish-release.yml`

```yaml
name: Publish Release

on:
  push:
    branches:
      - main

jobs:
  publish:
    uses: scottlz0310/release-automate/.github/workflows/reusable-publish-release.yml@v1
    permissions:
      contents: write
    with:
      commit_message_prefix: "chore(release):"
```
