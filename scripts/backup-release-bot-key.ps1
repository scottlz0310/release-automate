<#
.SYNOPSIS
GitHub App の秘密鍵を Bitwarden または DPAPI 暗号化ファイルへバックアップします。

.DESCRIPTION
bw が利用可能な場合は fingerprint ごとの Bitwarden Secure Note に保存します。
bw がない場合は、現在の Windows ユーザーだけが復号できる DPAPI ファイルへ保存します。
元のダウンロード PEM は削除しません。保存先と fingerprint のみ表示します。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PemPath,

    [ValidatePattern('^[0-9]+$')]
    [string]$AppId = '5074929'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseBotKey.Common.psm1') -Force
Assert-ReleaseBotPlatform

$pem = $null
$storage = $null
$ownedSession = $false
$stage = 'preflight'
try {
    $stage = 'read-source'
    $resolved = Resolve-Path -LiteralPath $PemPath -ErrorAction Stop
    if ($resolved.Provider.Name -ne 'FileSystem') {
        throw 'The source PEM must be a local file.'
    }
    $sourceFile = Get-Item -LiteralPath $resolved.ProviderPath -Force -ErrorAction Stop
    if ($sourceFile.PSIsContainer -or ($sourceFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The source PEM must be a regular file.'
    }
    $pem = [IO.File]::ReadAllText($resolved.ProviderPath)
    $fingerprintValue = Get-ReleaseBotFingerprint -Pem $pem
    $fingerprint = Format-ReleaseBotFingerprint -Value $fingerprintValue

    $stage = 'backup'
    $bw = Get-ReleaseBotBitwarden
    if ($bw) {
        $ownedSession = $true
        $storage = Save-ReleaseBotBitwardenBackup -Pem $pem -AppId $AppId -FingerprintValue $fingerprintValue
    }
    else {
        $backupPath = Get-ReleaseBotDefaultBackupPath -AppId $AppId -FingerprintValue $fingerprintValue
        $storage = Save-ReleaseBotDpapiBackup -Pem $pem -AppId $AppId -FingerprintValue $fingerprintValue -Path $backupPath
        Write-Host "DPAPI バックアップ: $storage"
    }
    Write-Host "対象鍵の fingerprint: $fingerprint"
    Write-Host "保存先: $storage"
}
catch {
    throw "GitHub App 鍵のバックアップは $stage ($($_.Exception.GetType().Name)) で停止しました: $($_.Exception.Message) 鍵の内容は表示していません。"
}
finally {
    $pem = $null
    if ($ownedSession) {
        Close-ReleaseBotBitwarden
    }
}
