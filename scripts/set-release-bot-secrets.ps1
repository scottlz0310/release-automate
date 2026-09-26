<#
.SYNOPSIS
検証済みの鍵バックアップを使って Organization Actions secrets を作成または更新します。

.DESCRIPTION
鍵は Bitwarden または DPAPI バックアップからメモリ上で復号し、gh secret set の標準入力へ渡します。
secret の値を表示・一時ファイル保存せず、既存 secret は fingerprint ごとの鍵で安全に置き換えます。
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
Import-Module (Join-Path $PSScriptRoot 'ReleaseBotKey.Common.psm1') -Force
Assert-ReleaseBotPlatform

$backup = $null
$ownedSession = $false
$stage = 'preflight'
try {
    $stage = 'fingerprint'
    $fingerprintValue = ConvertTo-ReleaseBotFingerprintValue -Fingerprint $Fingerprint
    if ([string]::IsNullOrWhiteSpace($BackupPath) -and (Get-ReleaseBotExecutable -Name 'bw')) {
        $stage = 'unlock-vault'
        $null = Get-ReleaseBotBitwarden
        $ownedSession = $true
    }
    $stage = 'read-backup'
    $backup = Get-ReleaseBotBackup -FingerprintValue $fingerprintValue -AppId $AppId -BackupPath $BackupPath
    if ($backup.Fingerprint -cne $fingerprintValue -or $backup.AppId -cne $AppId) {
        throw 'The backup does not match the requested App ID and fingerprint.'
    }

    $stage = 'github-secrets'
    Set-ReleaseBotOrganizationSecrets -Pem $backup.Pem -AppId $AppId -Fingerprint $fingerprintValue
}
catch {
    throw "Organization Actions secrets の更新は $stage ($($_.Exception.GetType().Name)) で停止しました: $($_.Exception.Message) 鍵の内容は表示していません。"
}
finally {
    if ($backup) {
        $backup.Pem = $null
    }
    $backup = $null
    if ($ownedSession) {
        Close-ReleaseBotBitwarden
    }
}
