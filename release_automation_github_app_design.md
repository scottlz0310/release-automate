# GitHub Actionsによるリリース自動化設計書（GitHub App 連携・Reusable Workflow 共通ライブラリ方式）

`main` ブランチの直接 push 禁止（保護ルール）環境において、人手によるバージョン確定、CHANGELOG 更新、PR 起票、タグ打ち・リリース公開作業を安全に自動化・共通ライブラリ化するための設計ドキュメントです。

Organization (`scottlz0310`) 内の全リポジトリで共通利用できるよう、**Reusable Workflows (`workflow_call`)** として切り出し、各リポジトリ側は最小限の呼び出し定義（10〜15行程度）を配置するだけで利用可能にします。
また、PR 起票時の CI 発火と属人化排除のため、**専用の GitHub App (Bot)** を認証基盤として採用し、Organization Secrets により各リポジトリへの一括配布を実現します。

---

## 1. 全体アーキテクチャ

```text
[個別リポジトリ (Caller)]                     [共通リポジトリ: release-automate (Reusable)]
      │
      ▼ 1. 手動実行 (workflow_dispatch)
[.github/workflows/prepare-release.yml]
      │ uses (secrets: inherit)
      └───────────────────────────────────► [.github/workflows/reusable-prepare-release.yml]
                                                  │
                                                  ├─ target_version のセマンティックバリデーション
                                                  ├─ GitHub App トークンを発行 (短寿命 Installation Token)
                                                  ├─ 指定ブランチ (main) をチェックアウト
                                                  ├─ bump_strategy 実行 (安全な固定操作: npm, rust, dotnet, go)
                                                  ├─ CHANGELOG.md の [Unreleased] 確定・比較リンク更新
                                                  └─ release/vX.Y.Z ブランチを push して PR 起票 (Bot 名義)
      ┌───────────────────────────────────────────┘
      ▼
[PR 作成検知: 各リポジトリのテスト/検証 CI が自動発火]
      │
      ▼ 2. PR レビュー & main ブランチへマージ (Squash and merge)
[.github/workflows/publish-release.yml]
      │ uses
      └───────────────────────────────────► [.github/workflows/reusable-publish-release.yml]
                                                  │
                                                  ├─ prefix 一致条件をジョブ単位で強制
                                                  ├─ トリガーコミット (${{ github.sha }}) をチェックアウト
                                                  ├─ マージコミットからバージョン / CHANGELOG 抽出
                                                  ├─ git タグ発行 (vX.Y.Z @ ${{ github.sha }})
                                                  └─ GitHub Release 作成 (Release Notes 添付) & 公開
```

---

## 2. GitHub App の作成と Organization 設定

Organization 単位で設定することで、リポジトリごとの個別シークレット登録を不要にします。

### 2.1. GitHub App の作成手順
1. GitHub の **Organization Settings (`https://github.com/organizations/scottlz0310/settings/apps`) → Developer settings → GitHub Apps → New GitHub App** を開きます。
2. 以下の項目を設定します：
   * **GitHub App name:** `scottlz0310-release-bot`（一意な名称）
   * **Homepage URL:** 任意のリポジトリ URL（例: `https://github.com/scottlz0310/release-automate`）
   * **Webhook:** **「Active」のチェックを外す**（イベント受信は不要）
   * **Permissions (Repository permissions):**
     * `Contents`: **Read and write**（ブランチ作成・ファイル push・タグ用）
     * `Pull requests`: **Read and write**（PR 作成・更新用）
   * **Where can this GitHub App be installed?:** `Only on this organization`
3. **Create GitHub App** をクリックします。
4. 作成後の画面から以下を取得・保存します：
   * **App ID**: 画面上部の数値を控える。
   * **Private key**: ページ下部の「Generate a private key」をクリックして `.pem` ファイルを保存。

### 2.2. アプリのインストール
1. App 設定画面の左メニューから **Install App** を開きます。
2. `scottlz0310` の **Install** をクリックします。
3. **All repositories**（またはリリース自動化を適用したいリポジトリ）を選択して保存します。

### 2.3. Organization Secrets の一括登録
Organization の **Settings → Secrets and variables → Actions** に以下を登録し、`Repository access` を `All repositories` に設定します：
* `RELEASE_BOT_APP_ID`: 控えた App ID（数値）
* `RELEASE_BOT_PRIVATE_KEY`: `.pem` ファイルの中身をヘッダー・フッター・改行を含めすべて貼り付け

---

## 3. 共通ワークフロー仕様（`release-automate`）

### 3.1. リリース準備 PR 起票 (`reusable-prepare-release.yml`)

#### 入力パラメータ (`inputs`)
| パラメータ名 | 型 | 必須 | デフォルト値 | 説明 |
| :--- | :--- | :--- | :--- | :--- |
| `target_version` | string | **Yes** | - | リリース対象バージョン（例: `1.2.0` または `v1.2.0`）。SemVer 形式を厳格に検証 |
| `bump_strategy` | string | No | `none` | バージョンファイル更新戦略 (`none`, `npm`, `rust`, `dotnet`, `go`) |
| `version_file` | string | No | `""` | `bump_strategy` が `go` または `dotnet` の場合の対象ファイルパス（`rust` では任意指定） |
| `changelog_path` | string | No | `CHANGELOG.md` | CHANGELOG ファイルの相対パス |
| `base_branch` | string | No | `main` | PR のマージ先ベースブランチ |
| `branch_prefix` | string | No | `release/` | 作成するリリースブランチの接頭辞 |
| `commit_prefix` | string | No | `chore(release):` | コミットおよび PR タイトルの接頭辞 |

#### シークレット (`secrets`)
| シークレット名 | 必須 | 説明 |
| :--- | :--- | :--- |
| `RELEASE_BOT_APP_ID` | **Yes** | GitHub App の App ID |
| `RELEASE_BOT_PRIVATE_KEY` | **Yes** | GitHub App の秘密鍵（PEM 形式） |

#### 処理の流れ
1. `target_version` を正規表現でバリデーション（SemVer 以外の不正文字列やコマンドインジェクションを遮断）。
2. `actions/create-github-app-token`（SHA 固定）で短寿命トークンを取得。
3. ベースブランチをチェックアウトし、Git ユーザーを Bot 名義（`${app-slug}[bot]`）に設定。
4. `bump_strategy` に応じた固定コマンドを実行（`eval` は使用せず、安全に正規化されたバージョンデータを渡す）。
5. `changelog_path` の `[Unreleased]` セクションを `[X.Y.Z] - YYYY-MM-DD` に確定し、最上部に新しい空の `[Unreleased]` を挿入。末尾の比較リンク（GitHub diff リンク）を更新。
6. `peter-evans/create-pull-request`（SHA 固定）により、Bot トークンを用いて `release/vX.Y.Z` ブランチを作成し PR を起票。

---

### 3.2. 本番リリース発行 (`reusable-publish-release.yml`)

#### 入力パラメータ (`inputs`)
| パラメータ名 | 型 | 必須 | デフォルト値 | 説明 |
| :--- | :--- | :--- | :--- | :--- |
| `commit_message_prefix` | string | No | `chore(release):` | リリースマージコミットを検知するための接頭辞 |
| `changelog_path` | string | No | `CHANGELOG.md` | リリースノート抽出対象の CHANGELOG パス |

#### 必要な権限 (`permissions`)
* `contents: write`（タグのプッシュおよび GitHub Release の作成）

#### 処理の流れ
1. `publish` ジョブレベルで `startsWith(github.event.head_commit.message, inputs.commit_message_prefix)` を強制評価。
2. トリガーイベントの正確なコミット SHA (`${{ github.sha }}`) をチェックアウト（可変ブランチへの依存を排除）。
3. コミットメッセージからタグ名（`vX.Y.Z`）を抽出。
4. `changelog_path` から該当バージョンの変更履歴本文（Markdown）を抽出。
5. `gh release create` を実行し、該当コミット SHA に対して Git タグ作成と Release Notes 添付・公開を同時に完了。

---

## 4. 各リポジトリでの利用方法（呼び出し側実装）

各リポジトリの `.github/workflows/` に以下の 2 つの YAML ファイルを配置するだけで展開が完了します。
Organization Secrets を使用しているため、`secrets: inherit` でシークレットの引き継ぎが可能です。

### 4.1. `.github/workflows/prepare-release.yml`

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
      # 言語に応じた安全な bump_strategy を指定（不要なら省略可）
      bump_strategy: "npm"
```

#### 言語別設定例
- **Node.js**:
  ```yaml
  bump_strategy: "npm"
  ```
- **Rust**:
  ```yaml
  bump_strategy: "rust"
  # Cargo.toml 以外のファイルパスを更新する場合のみ指定（省略時は Cargo.toml）
  # version_file: "crates/app/Cargo.toml"
  ```
- **.NET / C#**:
  ```yaml
  bump_strategy: "dotnet"
  version_file: "src/MyApp/MyApp.csproj"
  ```
- **Go**:
  ```yaml
  bump_strategy: "go"
  version_file: "internal/version/version.go"
  ```
- **なし（CHANGELOG のみ管理）**:
  `bump_strategy` を省略（既定値: `none`）

### 4.2. `.github/workflows/publish-release.yml`

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

---

## 5. 運用フローまとめ

1. **リリース PR 起票:**
   個別リポジトリの Actions タブから `Prepare Release` を起動し、バージョン番号を入力（例: `1.0.0`）。
2. **レビュー & マージ:**
   GitHub App により自動作成された PR を確認し、`Squash and merge` を実行。
3. **自動リリース完了:**
   `main` へのマージコミットを検知して `Publish Release` が自動で発火し、該当コミットへの Git タグ付与および GitHub Release ページへの公開が完了。
