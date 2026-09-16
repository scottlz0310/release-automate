# release-automate

GitHub Organization (`scottlz0310`) 向けのリリース自動化 Reusable Workflows 集です。

`main` ブランチの直接 push 禁止環境において、手動バージョン指定によるリリース準備 PR 起票と、PR マージ後のタグ打ち・GitHub Release 公開を自動化します。

---

## 提供する Reusable Workflows

1. [`.github/workflows/reusable-prepare-release.yml`](.github/workflows/reusable-prepare-release.yml)
   - 手動トリガー (`workflow_dispatch`) を受け、GitHub App 名義でリリース準備 PR を自動起票。
   - バージョン定義ファイルの更新コマンド実行（任意）。
   - `CHANGELOG.md` の `[Unreleased]` 確定および比較リンク更新。
2. [`.github/workflows/reusable-publish-release.yml`](.github/workflows/reusable-publish-release.yml)
   - `main` への Squash merge コミットを検知。
   - Git タグの作成と GitHub Release ページの公開（CHANGELOG からリリースノート自動抽出）。

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
      # 必要に応じてバージョン更新コマンドを指定（例: Node.js の場合）
      bump_command: "npm version ${{ inputs.target_version }} --no-git-tag-version"
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
    if: startsWith(github.event.head_commit.message, 'chore(release):')
    uses: scottlz0310/release-automate/.github/workflows/reusable-publish-release.yml@v1
    permissions:
      contents: write
    with:
      commit_message_prefix: "chore(release):"
```
