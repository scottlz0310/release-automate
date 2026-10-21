# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.1.0] - 2026-10-21

### Added
- 自己リリース用 caller を追加。手動 prepare による準備 PR のマージ後、対象 SHA の CI 成功を確認して draft・公開・メジャータグ更新まで自動実行する。更新前 SHA の照合、古いコミットへの巻き戻し拒否、失敗時の再実行・既存 draft 再開とモック検証を含む（#42）。

## [3.0.0] - 2026-10-21

### Added
- actionlint の Ubuntu 26.04 限定除外について、CI と同じ固定イメージの除外なし診断を分類し、不要化時・想定外診断・実行障害時に CI を失敗させる検知とモック検証を追加（#39）。
- finalize に既定 false の `resume` を追加し、修正後の保護された既定ブランチの手動実行から既存 draft の公開を再開できるようにした。再開時は祖先関係・リリースコミット・タグ・Release 対象を検証し、公開後の Release 置換・記録対象変更も検出。既定の同一 SHA 契約は維持（#37）。

### Changed
- **破壊的変更（v3 向け）:** リリース準備の認証を必須の `RELEASE_BOT_CLIENT_ID` に移行し、旧 `RELEASE_BOT_APP_ID` への代替を廃止。secret 登録・鍵ローテーションにも `-ClientId` を必須化。数値 App ID による既存バックアップの照合と保存形式は維持し、旧 secret は更新・削除しない（#33）。
- Linux の CI 品質ゲートを Ubuntu 26.04 に先行移行。actionlint の未対応ラベル診断だけを CI 定義内で除外し、上流対応版への更新後に削除する。reusable workflows の `ubuntu-latest` と Windows の Pester は維持（#34）。

### Fixed
- README の draft 検証ジョブの権限を `contents: write` に修正し、draft の読み取り・reusable workflow 呼び出し元の権限と checkout なしでの `gh` の対象指定を説明（#30）。

## [2.1.0] - 2026-10-04

### Added
- リリース準備に `bump_strategy: tauri` を追加。`package.json`、`tauri.conf.json`、`Cargo.toml`、`Cargo.lock` の版を、まとめて更新する。更新の前に 3 つのファイルの版が一致していることを確認し、JSON は整形と改行コードを保ったまま版の値だけを置き換える。シナリオテスト `tests/tauri-prepare.sh` を CI に追加。
- lefthook による Git フック（`pre-commit` での actionlint によるワークフロー構文検証、`pre-push` での Pester テスト）を追加。
- README および設計書に Lefthook の導入手順と `lefthook install` によるフック有効化手順を追記。

## [2.0.0] - 2026-09-27

### Added
- GitHub App 鍵管理スクリプトの Pester 6.2.0 テスト、Windows CI、Codecov カバレッジ送信を追加。
- リリースコミットに固定した draft Release、同一 SHA の再実行、成果物検証後に公開する reusable workflow とモック検証を追加。

### Changed
- Pester の固定バージョンを共有 Renovate プリセットで追跡。
- Rust のリリース準備では、Git で追跡済みの workspace `Cargo.lock` を必須とする。

### Fixed
- Release 作成直後の一覧反映遅延で publish workflow が失敗する問題を修正。
- Rust のリリース準備で workspace の `Cargo.lock` を package version と同期し、`--locked` で検証するよう修正。
- DPAPI バックアップの ACL 設定が標準ユーザーで権限エラーになる問題、旧形式 Secure Note の App ID 不一致、secret 設定後の fingerprint 表示が二重接頭辞になる問題を修正。

## [1.0.0] - 2026-09-26

### Added
- GitHub App 鍵の Bitwarden / DPAPI バックアップ、ダウンロード PEM との復号照合、Organization Actions secrets 登録・ローテーション用 PowerShell スクリプトと手順を追加。
- Added CI workflow (`.github/workflows/ci.yml`) with `actionlint` and `shellcheck` static analysis.
- Added `rust` bump strategy in `reusable-prepare-release.yml` for updating package version in `Cargo.toml`.
- Added `dotnet` bump strategy in `reusable-prepare-release.yml` for updating `<Version>`, `<PackageVersion>`, `<AssemblyVersion>`, `<FileVersion>`, and `<InformationalVersion>` in `.csproj` or `Directory.Build.props`.
- Reusable Workflow: `reusable-prepare-release.yml` for automating release PR preparation using GitHub App token.
- Reusable Workflow: `reusable-publish-release.yml` for publishing GitHub Releases and git tags on squash merge.
- Architecture and operational design document for Organization-wide Reusable Workflows (`release_automation_github_app_design.md`).
- Project documentation and setup guide (`README.md`).
- Renovate configuration extending `@scottlz0310/renovate-config`.

### Changed
- Improved `go` bump strategy in `reusable-prepare-release.yml` with case-insensitive `version` matching and flexible whitespace handling.

### Removed
- Removed `poetry` bump strategy from `reusable-prepare-release.yml` and documentation.

### Security
- Hardened third-party GitHub Actions by pinning to full commit SHAs.
- Prevented command injection by replacing raw command execution with safe `bump_strategy` options and strict SemVer validation.

### Fixed
- Switched `ci.yml` to `docker://rhysd/actionlint` with digest pinning and `contents: read` permission, ensuring static analysis and annotations function in public fork PRs without write permissions.
- Resolved shellcheck SC2016 info warning in `reusable-prepare-release.yml` by using string concatenation in inline Node.js script.
- Fixed `dotnet` bump strategy in `reusable-prepare-release.yml` to support multiline XML property elements and fail if zero replacements occur.
- Added zero-replacement failure guards to `rust` and `go` bump strategies in `reusable-prepare-release.yml`.
- Fixed release branch name evaluation in `reusable-prepare-release.yml` to dynamically use generated tag name.
- Enforced `commit_message_prefix` check at the job level and pinned release checkout/target to trigger commit SHA in `reusable-publish-release.yml`.
- Aligned Organization secret names in design document with workflow implementation (`RELEASE_BOT_APP_ID`, `RELEASE_BOT_PRIVATE_KEY`).

[Unreleased]: https://github.com/scottlz0310/release-automate/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/scottlz0310/release-automate/compare/v3...v3.1.0
[3.0.0]: https://github.com/scottlz0310/release-automate/compare/v2.1.0...v3.0.0
[2.1.0]: https://github.com/scottlz0310/release-automate/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/scottlz0310/release-automate/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/scottlz0310/release-automate/releases/tag/v1.0.0
