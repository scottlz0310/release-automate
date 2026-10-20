# release-automate

GitHub Organization (`scottlz0310`) 向けのリリース自動化 Reusable Workflows 集です。

`main` ブランチの直接 push 禁止環境において、手動バージョン指定によるリリース準備 PR 起票と、PR マージ後のタグ打ち・GitHub Release 公開を安全に自動化します。成果物の検証が必要なリポジトリでは draft 作成と公開を分けられます。

---

## 提供する Reusable Workflows

1. [`.github/workflows/reusable-prepare-release.yml`](.github/workflows/reusable-prepare-release.yml)
   - 手動トリガー (`workflow_dispatch`) を受け、GitHub App 名義でリリース準備 PR を自動起票。
   - `target_version` の正規表現バリデーション（SemVer 検証、コマンドインジェクション防止）。
   - 事前定義された安全な `bump_strategy`（`npm`, `rust`, `dotnet`, `go`, `tauri`, `none`）によるバージョン定義ファイル更新。
   - `rust` は対象 package の `Cargo.toml` と workspace ルートの `Cargo.lock` を同期し、`--locked` で整合を確認。
   - `tauri` は `package.json`、`tauri.conf.json`、`Cargo.toml`、`Cargo.lock` の版を、同じ版にそろえて更新。
   - `CHANGELOG.md` の `[Unreleased]` 確定および比較リンク更新。
   - サードパーティ Actions を完全なコミット SHA にピン留め。
2. [`.github/workflows/reusable-publish-release.yml`](.github/workflows/reusable-publish-release.yml)
   - `main` への Squash merge コミットをジョブレベルで検知・強制。
   - リリースコミット SHA (`github.sha`) をピン留めして Git タグと GitHub Release を作成（CHANGELOG からリリースノート自動抽出）。`draft` の既定値は `false` で、従来どおり即時公開。
   - `draft: true` は draft を作成し、`tag_name` / `target_sha` / `release_state` を出力。
3. [`.github/workflows/reusable-finalize-release.yml`](.github/workflows/reusable-finalize-release.yml)
   - 同じ workflow run の SHA、タグが指すコミット、draft 状態を再確認して公開。公開済みの同一 SHA なら変更せず成功。
   - 明示的な `resume: true` では、保護された既定ブランチの手動実行から、追加検査を経て過去の draft の公開を再開。

---

## GitHub App のセットアップと鍵管理

以下は v3 向けの認証契約です。v3 は公開準備中のため、公開前に試す場合はレビュー済みの対応コミット SHA を指定してください。既存の `@v2` 利用者は後述の移行手順で切り替えます。

セットアップの全手順、初回登録、鍵ローテーションは [設計・運用手順書](release_automation_github_app_design.md) を参照してください。スクリプトは Windows の PowerShell 7.4 以降で実行します。

1. GitHub App を作成し、設定画面の数値の **App ID** と、認証用の **Client ID** を控えます。鍵バックアップの識別には App ID、workflow の認証には Client ID を使います。
2. GitHub App 設定画面から秘密鍵 PEM を生成・ダウンロードし、表示された GitHub fingerprint を控えます。
3. `scripts/backup-release-bot-key.ps1` を実行します。`bw` があれば fingerprint ごとの Bitwarden Secure Note に保存し、`bw` がなければ DPAPI で暗号化したファイルを `%LOCALAPPDATA%` 配下に保存します。バックアップ後もダウンロードファイルは残ります。
4. `scripts/verify-release-bot-key.ps1 -PemPath <ダウンロードした PEM> -ExpectedFingerprint <GitHub fingerprint>` でバックアップを復号し、PEM と GitHub fingerprint の両方を照合します。DPAPI 保存先を使う場合は、バックアップ時に表示されたパスを `-BackupPath` に指定してください。照合成功後、ダウンロードファイルを削除するか `y/N` で選べます。
5. GitHub App を Organization `scottlz0310` の All repositories にインストールし、`scripts/set-release-bot-secrets.ps1 -Fingerprint <SHA256 fingerprint> -ClientId <GitHub App の Client ID>` を実行します。確認プロンプトに同意すると、Actions secrets `RELEASE_BOT_PRIVATE_KEY` と `RELEASE_BOT_CLIENT_ID` が全リポジトリ向けに作成または更新されます。Bitwarden がない環境では `-BackupPath <DPAPI バックアップ>` も指定します。

```powershell
$pem = "$env:USERPROFILE\Downloads\scottlz0310-release-bot.private-key.pem"
pwsh ./scripts/backup-release-bot-key.ps1 -PemPath $pem -AppId 5074929
pwsh ./scripts/verify-release-bot-key.ps1 -PemPath $pem -ExpectedFingerprint 'SHA256:<GitHub settings の fingerprint>'
pwsh ./scripts/set-release-bot-secrets.ps1 -Fingerprint 'SHA256:<backup が表示した fingerprint>' -ClientId '<GitHub App の Client ID>'
```

Bitwarden CLI がない場合は、バックアップ時に表示された DPAPI ファイルのパスを照合・登録コマンドの `-BackupPath` に指定します。DPAPI ファイルは作成した Windows ユーザーのプロファイルに依存し、別ユーザーや別 PC では復号できません。Bitwarden が利用可能なら Vault を主バックアップとして使ってください。

鍵ローテーションでは、新鍵を生成して同じバックアップ・照合を行い、`scripts/rotate-release-bot-key.ps1 -Fingerprint <SHA256 fingerprint> -ClientId <GitHub App の Client ID>` を実行します。新鍵でワークフローが成功するまで旧鍵は GitHub App 設定から削除しません。スクリプトは GitHub App の鍵自体を削除しません。

### v2 から v3 への認証移行

v3 の prepare workflow は `RELEASE_BOT_CLIENT_ID` を必須とし、旧 `RELEASE_BOT_APP_ID` への代替は行いません。[GitHub は JWT の発行元に Client ID を推奨](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)しています。数値 App ID の secret を改名するだけでは移行になりません。

1. App 設定の Client ID を確認し、上記スクリプトで `RELEASE_BOT_CLIENT_ID` を登録します。秘密鍵は既存バックアップをそのまま使えます。既定以外の App ID で作成したバックアップは `-AppId` も指定します。
2. v3 公開後、caller の参照を v3 の固定コミット SHA（または `@v3`）に切り替えます。`secrets: inherit` は維持でき、個別指定の場合は `RELEASE_BOT_CLIENT_ID: ${{ secrets.RELEASE_BOT_CLIENT_ID }}` と既存の秘密鍵を渡します。
3. caller の prepare が成功することを確認します。`RELEASE_BOT_PRIVATE_KEY` は v2 と共通で、既存の App ID を持つ鍵バックアップの形式も変わりません。

登録・ローテーションスクリプトは旧 `RELEASE_BOT_APP_ID` を更新・削除しません。旧 v2 caller が残る間は旧 secret を保持し、撤去は全 caller の移行確認後に別途判断します。Client ID の登録、caller の変更、v3 の公開はそれぞれ運用時に実施する作業です。

### 開発セットアップと品質ゲート（Lefthook）

本リポジトリの開発では [Lefthook](https://github.com/evilmartians/lefthook) を使用してコミット前・プッシュ前の品質ゲートを管理しています。

1. **Lefthook のインストール**（未導入の場合）:
   ```powershell
   go install github.com/evilmartians/lefthook@latest
   # または scoop install lefthook / winget install EvilMartians.Lefthook
   ```

2. **Git hooks のセットアップ**:
   クローン後、リポジトリルートで以下を実行して Git hooks を有効化します。
   ```powershell
   lefthook install
   ```
   - `pre-commit`: ワークフロー定義ファイル（`.github/workflows/*.yml`）変更時に `actionlint` で構文チェック
   - `pre-push`: プッシュ前に Pester テストを自動実行

### actionlint の一時除外の追跡

CI は通常の actionlint に加え、同じ `uses` 宣言の固定 Docker イメージで除外なしの検査を行います。`ci.yml` の Ubuntu 26.04 未認識診断だけなら継続し、診断がなくなれば撤去を促して失敗します。他の診断・実行障害・解析できない出力も失敗として扱います。

[Issue #39](https://github.com/scottlz0310/release-automate/issues/39) は検知導入後も閉じず、2026-11-20（日本時間）に上流を再評価します。対応版への更新後、`.github/actionlint.yaml` の対象除外、CI の専用確認ステップ、`scripts/check-actionlint-workaround.sh`、`tests/actionlint-workaround.sh` とその CI 呼び出しを同じ PR で撤去し、除外なしの lint と関連 CI の成功を確認します。

判定のモックは `bash tests/actionlint-workaround.sh` で実行できます。CLI は引数で差し替え、実行結果・構造化診断の分類を検証します。

### 鍵管理スクリプトのテスト

Windows の PowerShell 7.4 以降で Pester 6.2.0 を使います。テストでは一時的に生成した鍵と模擬 CLI を使い、実際の Bitwarden Vault と GitHub Secrets には接続しません。

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
Import-Module Pester -RequiredVersion 6.2.0
Invoke-Pester -Path ./tests
```

PR と `main` の CI は Windows 上で JaCoCo カバレッジを生成し、OIDC 認証で Codecov に送信します。Codecov 側でこのリポジトリを有効にすると、PR のカバレッジを確認できます。

---

## 各リポジトリでの利用方法

各リポジトリの `.github/workflows/` に prepare と publish の caller を配置します。成果物の添付・検証を挟む場合は、publish caller に後述のジョブを追加します。

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
    uses: scottlz0310/release-automate/.github/workflows/reusable-prepare-release.yml@v3
    secrets: inherit
    with:
      target_version: ${{ inputs.target_version }}
      # 言語に応じた bump_strategy を指定 (npm, rust, dotnet, go, tauri, none)
      bump_strategy: "npm"
```

`bump_strategy: "rust"` では、既定の `Cargo.toml`、または `version_file` で指定した workspace member の manifest にある直接指定の `[package].version` を更新します。対象の manifest と workspace ルートの `Cargo.lock` は Git で追跡されている必要があります。複数 package の workspace では指定した package だけを更新し、他の package や依存関係の版が変わる場合は失敗します。`[workspace.package].version` を継承する package、版の記載がない package、既に対象版の package は対象外として失敗します。実行環境には Cargo と Python 3.11 以降が必要です。

```yaml
with:
  target_version: "0.2.0"
  bump_strategy: "rust"
  version_file: "crates/my-app/Cargo.toml" # ルート package なら省略
```

`bump_strategy: "tauri"` は、リポジトリルートの `package.json`、`version_file` で指定した `tauri.conf.json`（既定は `src-tauri/tauri.conf.json`）、その同じディレクトリの `Cargo.toml`（と、workspace ルートの `Cargo.lock`）の版を、まとめて更新します。次の規則に従い、満たさなければ何も書き換えずに失敗します。

- 3 つのファイル（`package.json`、`tauri.conf.json`、`Cargo.toml`）が、すべて存在し、更新の前に同じ版であること（食い違いを黙って揃えません）。
- `package.json` と `tauri.conf.json` に、最上位の `"version"` が 1 つだけあること。入れ子の `version` キーは書き換えません。
- JSON は再出力せず、版の値の文字列だけを置き換えます（整形と改行コードを保ちます）。`package-lock.json` などのロックファイルは更新しません（`Cargo.lock` を除く）。
- `Cargo.toml` と `Cargo.lock` の扱いは `rust` と同じです（Git で追跡されていること、`[package].version` を直接指定していること、依存関係の版が変わらないこと）。

```yaml
with:
  target_version: "0.2.0"
  bump_strategy: "tauri"
  version_file: "src-tauri/tauri.conf.json" # 既定の場所なら省略
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
    uses: scottlz0310/release-automate/.github/workflows/reusable-publish-release.yml@v2
    permissions:
      contents: write
    with:
      commit_message_prefix: "chore(release):"
```

### draft 作成後に成果物を検証して公開する場合

以下の `build-and-upload-release-assets.sh` と `verify-release-assets.sh` は利用側が実装するスクリプトの例です。前者は draft Release に成果物を添付し、後者は Release から成果物を再取得して必要な名前・種類・checksum・内容を検証します。後者が失敗すると `finalize` は実行されません。

draft Release を読むジョブは、読み取りだけを行う場合も `GITHUB_TOKEN` に `contents: write` が必要です（[draft の一覧取得には push 権限が必要](https://docs.github.com/en/rest/releases/releases#list-releases)）。reusable workflow を呼ぶ場合は、呼び出し元のジョブにも必要な `permissions` を指定してください。呼び出し先で呼び出し元の権限を引き上げることはできません（[reusable workflow の権限制約](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#nesting-reusable-workflows)）。

```yaml
name: Publish Release After Verification

on:
  push:
    branches: [main]

jobs:
  draft:
    uses: scottlz0310/release-automate/.github/workflows/reusable-publish-release.yml@<固定コミットSHA>
    permissions:
      contents: write
    with:
      draft: true

  attach:
    needs: draft
    if: needs.draft.outputs.release_state == 'draft'
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@<固定コミットSHA>
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ needs.draft.outputs.tag_name }}
        run: ./scripts/build-and-upload-release-assets.sh "$TAG"

  verify:
    needs: [draft, attach]
    if: needs.draft.outputs.release_state == 'draft'
    runs-on: ubuntu-latest
    permissions:
      # 読み取りだけでも、draft Release の取得には push 権限が必要。
      contents: write
    steps:
      - uses: actions/checkout@<固定コミットSHA>
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ needs.draft.outputs.tag_name }}
        run: ./scripts/verify-release-assets.sh "$TAG"

  finalize:
    needs: [draft, verify]
    if: needs.draft.outputs.release_state == 'draft' && needs.verify.result == 'success'
    uses: scottlz0310/release-automate/.github/workflows/reusable-finalize-release.yml@<固定コミットSHA>
    permissions:
      contents: write
    with:
      tag_name: ${{ needs.draft.outputs.tag_name }}
      target_sha: ${{ needs.draft.outputs.target_sha }}
```

`<固定コミットSHA>` はこの 2 つの reusable workflow を含む `release-automate` の同一コミット、および利用側で採用する checkout のコミットに置き換えます。`@v1` は finalize workflow を含まないため、段階的公開には v2 以降を使用します。タグは `GITHUB_TOKEN` で作るため、タグ push を起点とする別 workflow に依存せず、この caller の `needs` で接続してください。

checkout しないジョブで `gh` を使う場合は、[`GH_REPO`](https://cli.github.com/manual/gh_help_environment) に `${{ github.repository }}` を設定するか、`--repo owner/repo` で対象を指定してください。`GITHUB_REPOSITORY` だけでは `gh` の対象リポジトリは指定されません。

再実行では、同じ SHA の draft は再利用されます。添付ジョブは既存 asset を確認して重複添付を避け、検証ジョブは毎回 Release 上の asset を確認してください。公開失敗後は同じ run を再実行できます。異なる SHA の既存タグは失敗し、公開済み Release は再実行でも変更されません。`release_state` が `published` の再実行では添付・検証・公開ジョブをスキップします。

### caller の修正後に既存 draft の公開を再開する場合

リリースコミットの後で caller の不具合を修正した場合、元の run の再実行では修正後の定義を使えません。修正後の保護された既定ブランチで `workflow_dispatch` を実行し、元のタグの成果物を再取得・検証してから `resume: true` を指定します。入力省略時の `resume: false` は従来どおり実行 SHA と対象 SHA の一致を要求します。

再開では以下をすべて確認し、不一致や API エラーなら停止します。

- 手動実行の ref が保護された既定ブランチであること。タグ・feature branch・push・PR イベントからの再開はできません。
- `target_sha` が実行 SHA と同一、またはその祖先であること。
- 対象コミットの件名が `chore(release): vX.Y.Z` と一致すること。Squash merge の ` (#番号)` は許容します。publish の接頭辞を変更している場合は、finalize の `commit_message_prefix` にも同じ値を指定します。
- タグが対象 SHA を指し、同じタグの Release が1件だけで、`target_commitish` が対象 SHA と完全一致すること。branch 名や不明値は受け付けません。
- 公開後もタグ・Release の ID・記録対象・公開状態が一致すること。既に公開済みの同一対象なら更新せず確認します。

以下はこの機能を含む対応コミット SHA を固定して利用する caller 例です。`verify-release-assets.sh` は利用側が実装する、元の Release からの再取得・検証処理です。公開済み対象の再実行でも同じ検証を行います。

```yaml
name: Resume Release

on:
  workflow_dispatch:
    inputs:
      tag_name:
        description: '再検証して公開する既存 Release のタグ'
        required: true
        type: string

jobs:
  verify:
    if: github.ref == format('refs/heads/{0}', github.event.repository.default_branch) && github.ref_protected
    runs-on: ubuntu-latest
    permissions:
      # 元の draft を再取得するため、読み取りでも write が必要。
      contents: write
    outputs:
      tag_name: ${{ steps.verify.outputs.tag_name }}
      target_sha: ${{ steps.verify.outputs.target_sha }}
    steps:
      - uses: actions/checkout@<固定コミットSHA>
        with:
          ref: ${{ github.sha }}
          fetch-depth: 0
          persist-credentials: false
      - id: verify
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ inputs.tag_name }}
        run: |
          set -euo pipefail
          if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
            echo '::error::再開するタグの形式が不正です'
            exit 1
          fi
          target_sha=$(git rev-parse --verify "refs/tags/$TAG^{commit}")
          ./scripts/verify-release-assets.sh "$TAG"
          echo "tag_name=$TAG" >> "$GITHUB_OUTPUT"
          echo "target_sha=$target_sha" >> "$GITHUB_OUTPUT"

  finalize:
    needs: verify
    if: needs.verify.result == 'success'
    uses: scottlz0310/release-automate/.github/workflows/reusable-finalize-release.yml@<固定コミットSHA>
    permissions:
      contents: write
    with:
      tag_name: ${{ needs.verify.outputs.tag_name }}
      target_sha: ${{ needs.verify.outputs.target_sha }}
      resume: true
```

成果物の妥当性は caller の責務です。`resume: true` 自体が検証済みの証明になるわけではなく、同一 run の検証ジョブへの `needs` が必要です。write 権限者が caller 自体を改変できることを、この reusable workflow だけで防ぐものではありません。
