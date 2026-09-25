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
