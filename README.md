# release-automate

GitHub Organization (`scottlz0310`) 向けのリリース自動化 Reusable Workflows 集です。

`main` ブランチの直接 push 禁止環境において、手動バージョン指定によるリリース準備 PR 起票と、PR マージ後のタグ打ち・GitHub Release 公開を安全に自動化します。成果物の検証が必要なリポジトリでは draft 作成と公開を分けられます。

---

## 提供する Reusable Workflows

1. [`.github/workflows/reusable-prepare-release.yml`](.github/workflows/reusable-prepare-release.yml)
   - 手動トリガー (`workflow_dispatch`) を受け、GitHub App 名義でリリース準備 PR を自動起票。
   - `target_version` の正規表現バリデーション（SemVer 検証、コマンドインジェクション防止）。
   - 事前定義された安全な `bump_strategy`（`npm`, `rust`, `dotnet`, `go`, `none`）によるバージョン定義ファイル更新。
   - `rust` は対象 package の `Cargo.toml` と workspace ルートの `Cargo.lock` を同期し、`--locked` で整合を確認。
   - `CHANGELOG.md` の `[Unreleased]` 確定および比較リンク更新。
   - サードパーティ Actions を完全なコミット SHA にピン留め。
2. [`.github/workflows/reusable-publish-release.yml`](.github/workflows/reusable-publish-release.yml)
   - `main` への Squash merge コミットをジョブレベルで検知・強制。
   - リリースコミット SHA (`github.sha`) をピン留めして Git タグと GitHub Release を作成（CHANGELOG からリリースノート自動抽出）。`draft` の既定値は `false` で、従来どおり即時公開。
   - `draft: true` は draft を作成し、`tag_name` / `target_sha` / `release_state` を出力。
3. [`.github/workflows/reusable-finalize-release.yml`](.github/workflows/reusable-finalize-release.yml)
   - 同じ workflow run の SHA、タグが指すコミット、draft 状態を再確認して公開。公開済みの同一 SHA なら変更せず成功。

---

## GitHub App のセットアップと鍵管理

セットアップの全手順、初回登録、鍵ローテーションは [設計・運用手順書](release_automation_github_app_design.md) を参照してください。スクリプトは Windows の PowerShell 7.4 以降で実行します。

1. GitHub App を作成します。
2. GitHub App 設定画面から秘密鍵 PEM を生成・ダウンロードし、表示された GitHub fingerprint を控えます。
3. `scripts/backup-release-bot-key.ps1` を実行します。`bw` があれば fingerprint ごとの Bitwarden Secure Note に保存し、`bw` がなければ DPAPI で暗号化したファイルを `%LOCALAPPDATA%` 配下に保存します。バックアップ後もダウンロードファイルは残ります。
4. `scripts/verify-release-bot-key.ps1 -PemPath <ダウンロードした PEM> -ExpectedFingerprint <GitHub fingerprint>` でバックアップを復号し、PEM と GitHub fingerprint の両方を照合します。DPAPI 保存先を使う場合は、バックアップ時に表示されたパスを `-BackupPath` に指定してください。照合成功後、ダウンロードファイルを削除するか `y/N` で選べます。
5. GitHub App を Organization `scottlz0310` の All repositories にインストールし、`scripts/set-release-bot-secrets.ps1 -Fingerprint <SHA256 fingerprint>` を実行します。確認プロンプトに同意すると、Actions secrets `RELEASE_BOT_PRIVATE_KEY` と `RELEASE_BOT_APP_ID` が全リポジトリ向けに作成または更新されます。Bitwarden がない環境では `-BackupPath <DPAPI バックアップ>` も指定します。

```powershell
$pem = "$env:USERPROFILE\Downloads\scottlz0310-release-bot.private-key.pem"
pwsh ./scripts/backup-release-bot-key.ps1 -PemPath $pem -AppId 5074929
pwsh ./scripts/verify-release-bot-key.ps1 -PemPath $pem -ExpectedFingerprint 'SHA256:<GitHub settings の fingerprint>'
pwsh ./scripts/set-release-bot-secrets.ps1 -Fingerprint 'SHA256:<backup が表示した fingerprint>'
```

Bitwarden CLI がない場合は、バックアップ時に表示された DPAPI ファイルのパスを照合・登録コマンドの `-BackupPath` に指定します。DPAPI ファイルは作成した Windows ユーザーのプロファイルに依存し、別ユーザーや別 PC では復号できません。Bitwarden が利用可能なら Vault を主バックアップとして使ってください。

鍵ローテーションでは、新鍵を生成して同じバックアップ・照合を行い、`scripts/rotate-release-bot-key.ps1` を実行します。新鍵でワークフローが成功するまで旧鍵は GitHub App 設定から削除しません。スクリプトは GitHub App の鍵自体を削除しません。

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
    uses: scottlz0310/release-automate/.github/workflows/reusable-prepare-release.yml@v1
    secrets: inherit
    with:
      target_version: ${{ inputs.target_version }}
      # 言語に応じた bump_strategy を指定 (npm, rust, dotnet, go, none)
      bump_strategy: "npm"
```

`bump_strategy: "rust"` では、既定の `Cargo.toml`、または `version_file` で指定した workspace member の manifest にある直接指定の `[package].version` を更新します。対象の manifest と workspace ルートの `Cargo.lock` は Git で追跡されている必要があります。複数 package の workspace では指定した package だけを更新し、他の package や依存関係の版が変わる場合は失敗します。`[workspace.package].version` を継承する package、版の記載がない package、既に対象版の package は対象外として失敗します。実行環境には Cargo と Python 3.11 以降が必要です。

```yaml
with:
  target_version: "0.2.0"
  bump_strategy: "rust"
  version_file: "crates/my-app/Cargo.toml" # ルート package なら省略
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

### draft 作成後に成果物を検証して公開する場合

以下の `build-and-upload-release-assets.sh` と `verify-release-assets.sh` は利用側が実装するスクリプトの例です。前者は draft Release に成果物を添付し、後者は Release から成果物を再取得して必要な名前・種類・checksum・内容を検証します。後者が失敗すると `finalize` は実行されません。

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
      contents: read
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

`<固定コミットSHA>` はこの 2 つの reusable workflow を含む `release-automate` の同一コミット、および利用側で採用する checkout のコミットに置き換えます。現行の `@v1` は新しい finalize workflow を含まないため、そのままでは段階的公開に使えません。タグは `GITHUB_TOKEN` で作るため、タグ push を起点とする別 workflow に依存せず、この caller の `needs` で接続してください。

再実行では、同じ SHA の draft は再利用されます。添付ジョブは既存 asset を確認して重複添付を避け、検証ジョブは毎回 Release 上の asset を確認してください。公開失敗後は同じ run を再実行できます。異なる SHA の既存タグは失敗し、公開済み Release は再実行でも変更されません。`release_state` が `published` の再実行では添付・検証・公開ジョブをスキップします。
