<#
.SYNOPSIS
検証済みの新しい GitHub App 鍵で Organization Actions secrets をローテーションします。

.DESCRIPTION
バックアップと PEM 照合の後に実行します。鍵の生成は GitHub App 設定画面で行い、
このスクリプトは保存済みバックアップを使って Actions secrets を更新します。
旧 GitHub App 鍵の削除は行いません。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Fingerprint,

    [string]$BackupPath,

    [ValidatePattern('^[0-9]+$')]
    [string]$AppId = '5074929'
)

$ErrorActionPreference = 'Stop'
$arguments = @{
    Fingerprint = $Fingerprint
    AppId = $AppId
}
if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    $arguments.BackupPath = $BackupPath
}
& (Join-Path $PSScriptRoot 'set-release-bot-secrets.ps1') @arguments
