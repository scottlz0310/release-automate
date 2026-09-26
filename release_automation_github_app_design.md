# GitHub Actionsによるリリース自動化設計書（GitHub App 連携・Reusable Workflow 共通ライブラリ方式）

`main` ブランチの直接 push 禁止（保護ルール）環境において、人手によるバージョン確定、CHANGELOG 更新、PR 起票、タグ打ち・リリース公開作業を安全に自動化・共通ライブラリ化するための設計ドキュメントです。

Organization (`scottlz0310`) 内の全リポジトリで共通利用できるよう、**Reusable Workflows (`workflow_call`)** として切り出し、各リポジトリ側は最小限の呼び出し定義（10〜15行程度）を配置するだけで利用可能にします。
また、PR 起票時の CI 発火と属人化排除のため、**専用の GitHub App (Bot)** を認証基盤として採用し、Organization Secrets により各リポジトリへの一括配布を実現します。

このリポジトリは Public caller からも利用するため Public を維持します。GitHub のアクセス規則では、Public caller は Private reusable workflow を利用できません。App の秘密鍵は Organization Actions secrets と Vault に保存し、このリポジトリには含めません（[GitHub Docs: reusable workflow access](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows)）。

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
                                                  └─ GitHub Release 作成 (既定は即時公開、draft 指定も可能)
      │
      └─ draft 指定時: 同一 caller の成果物添付 → 再取得・検証 →
         [.github/workflows/reusable-finalize-release.yml] で公開
```

---

## 2. GitHub App の作成と Organization 設定

鍵は GitHub App が発行した PEM を Bitwarden または DPAPI 暗号化ファイルに保管し、そのバックアップを検証してから Organization Actions secrets に登録します。秘密鍵を GitHub の Web フォームへ貼り付けず、スクリプトから `gh secret set` の標準入力へ渡します。

### 2.1. GitHub App の作成

1. GitHub の **Organization Settings (`https://github.com/organizations/scottlz0310/settings/apps`) → Developer settings → GitHub Apps → New GitHub App** を開きます。
2. 次を設定します。
   * **GitHub App name:** `scottlz0310-release-bot`
   * **Homepage URL:** `https://github.com/scottlz0310/release-automate`
   * **Webhook:** **Active** を無効にする
   * **Repository permissions:** `Contents: Read and write`、`Pull requests: Read and write`
   * **Where can this GitHub App be installed?:** `Only on this organization`
3. App を作成し、画面上部の **App ID** を控えます。

### 2.2. 秘密鍵の生成とバックアップ

GitHub App 設定の **Private keys → Generate a private key** から PEM をダウンロードし、同画面の fingerprint を控えます。GitHub は秘密鍵ではなく公開部分だけを保持するため、ダウンロード直後に以下のバックアップを行います。

PowerShell 7.4 以降で、リポジトリのルートから実行します。

```powershell
$pem = "$env:USERPROFILE\Downloads\scottlz0310-release-bot.private-key.pem"
pwsh ./scripts/backup-release-bot-key.ps1 -PemPath $pem -AppId 5074929
```

* `bw` が PATH 上にある場合、Bitwarden をローカルプロンプトで解錠し、fingerprint ごとの Secure Note に保存します。既存の同一鍵は照合して再利用します。fingerprint を含まない旧形式名の Secure Note は同じ鍵の場合だけ再利用し、別の鍵を保持している場合は残したまま新しい項目を作成します。`bw` が存在しても解錠や保存に失敗した場合、別形式へ自動フォールバックせず停止します。
* `bw` がない場合、`ConvertFrom-SecureString` の Windows DPAPI 保護を使って `%LOCALAPPDATA%\release-automate\release-bot-keys` に保存し、ファイルと保存先ディレクトリの ACL を現在の Windows ユーザーに限定します。ファイルは同じ Windows ユーザーのプロファイルからのみ復号できます。
* PEM はバックアップ時には削除しません。出力された `SHA256:...` fingerprint と、DPAPI 保存時は表示されたバックアップファイルパスを控えます。

### 2.3. バックアップの復号・照合

ダウンロードした PEM と GitHub 設定画面の fingerprint を指定して、保存した鍵を復号し、両方を照合します。

```powershell
pwsh ./scripts/verify-release-bot-key.ps1 `
  -PemPath $pem `
  -ExpectedFingerprint 'SHA256:<GitHub settings の fingerprint>'
```

Bitwarden バックアップは同じコマンドで照合できます。Bitwarden がない場合は、バックアップ時に表示された DPAPI ファイルを明示します。

```powershell
pwsh ./scripts/verify-release-bot-key.ps1 `
  -PemPath $pem `
  -ExpectedFingerprint 'SHA256:<GitHub settings の fingerprint>' `
  -BackupPath "$env:LOCALAPPDATA\release-automate\release-bot-keys\<AppId>-<fingerprint>.dpapi.json"
```

照合が成功した後にのみ、スクリプトがダウンロード PEM の削除を `y/N` で尋ねます。`y` で指定ファイルだけを削除し、それ以外は保持します。ファイル削除は媒体上の安全な完全消去を保証するものではありません。

### 2.4. App のインストールと Organization Actions secrets の初回登録

バックアップ照合が成功した後、App 設定の **Install App** から Organization `scottlz0310` にインストールし、現在の運用では **All repositories** を選択します。その後、照合した fingerprint を使ってスクリプトを実行します。Bitwarden がない場合は DPAPI バックアップパスも指定します。

```powershell
pwsh ./scripts/set-release-bot-secrets.ps1 `
  -Fingerprint 'SHA256:<backup が表示した fingerprint>'
```

スクリプトは実行前に確認を求め、`RELEASE_BOT_PRIVATE_KEY` と `RELEASE_BOT_APP_ID` を Organization `scottlz0310` の Actions secrets として全リポジトリ向けに作成または更新します。`gh auth status` に加え、更新後に名前と可視性が `all` であることを確認します。権限エラー時は `gh auth refresh -h github.com -s admin:org` で認証スコープを更新してください。

### 2.5. 鍵ローテーション

GitHub App は新旧複数の鍵を同時に保持できるため、次の順で停止時間を避けてローテーションします。

1. App 設定で **Generate a private key** を実行し、新しい PEM をダウンロードします。旧鍵は削除しません。
2. 新しい PEM に `backup-release-bot-key.ps1` を実行し、バックアップ先と fingerprint を記録します。
3. `verify-release-bot-key.ps1 -PemPath ... -ExpectedFingerprint ...` を実行します。指定したダウンロードファイルと GitHub settings の fingerprint の照合成功後、表示される質問に `y` と答えると、そのファイルを削除できます。
4. `rotate-release-bot-key.ps1 -Fingerprint ...` を実行し、確認プロンプトを承認します。DPAPI 保存なら `-BackupPath ...` も指定します。このスクリプトは `gh secret set` の upsert を使うため、同じ引数での再実行が可能です。
5. 新しい Organization secret を使うワークフローを実行し、成功を確認します。GitHub は Actions secret の値を読み返せないため、名前・可視性確認と実ワークフロー実行で確認します。
6. 新鍵での動作確認後に限り、GitHub App 設定画面で旧鍵を手動削除します。スクリプトは旧鍵を削除しません。

GitHub の鍵ローテーション手順は[公式ドキュメント](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)を参照してください。

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
| `draft` | boolean | No | `false` | `true` なら draft 作成のみ行い、成果物検証後に finalize を呼ぶ |

出力は `tag_name`、`target_sha`、`release_state`（`draft` または `published`）。リリースコミット以外でジョブがスキップされた場合は空になります。

#### 必要な権限 (`permissions`)
* `contents: write`（タグのプッシュおよび GitHub Release の作成）

#### 処理の流れ
1. `publish` ジョブレベルで `startsWith(github.event.head_commit.message, inputs.commit_message_prefix)` を強制評価。
2. トリガーイベントの正確なコミット SHA (`${{ github.sha }}`) をチェックアウト（可変ブランチへの依存を排除）。
3. コミットメッセージからタグ名（`vX.Y.Z`）を抽出。
4. `changelog_path` から該当バージョンの変更履歴本文（Markdown）を抽出。
5. タグ参照をコミット SHA に固定し、既存タグの解決先も確認する。同じ SHA の既存 Release は再利用し、異なる SHA は失敗する。
6. `gh release create --verify-tag` で Release Notes を付けて作成する。既定では公開し、`draft: true` では draft のまま残す。公開済み Release は再実行で変更しない。

### 3.3. draft Release の公開 (`reusable-finalize-release.yml`)

| 入力 | 型 | 説明 |
| :--- | :--- | :--- |
| `tag_name` | string | publish workflow の同名出力 |
| `target_sha` | string | publish workflow の同名出力 |

`contents: write` を持つ finalize job は、同じ caller run の `github.sha`、タグの解決先 SHA、Release の draft 状態を確認して公開する。公開に成功したが後続確認に失敗した場合も、同じ run の再実行では公開済み状態を無変更で確認できる。利用側は成果物を Release から再取得・検証する job を置き、その成功を `needs` で finalize の前提にする。タグ push イベントから別 workflow を起動しない。caller の具体例は [README](README.md#draft-作成後に成果物を検証して公開する場合) を参照。

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
