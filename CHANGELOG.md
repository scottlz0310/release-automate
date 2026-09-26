# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- GitHub App 鍵管理スクリプトの Pester 6.2.0 テスト、Windows CI、Codecov カバレッジ送信を追加。
- リリースコミットに固定した draft Release、同一 SHA の再実行、成果物検証後に公開する reusable workflow とモック検証を追加。

### Changed
- Pester の固定バージョンを共有 Renovate プリセットで追跡。

### Fixed
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

[Unreleased]: https://github.com/scottlz0310/release-automate/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/scottlz0310/release-automate/releases/tag/v1.0.0
