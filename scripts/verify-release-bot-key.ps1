<#
.SYNOPSIS
保存した GitHub App 秘密鍵を、ダウンロード PEM または GitHub fingerprint と照合します。

.DESCRIPTION
Bitwarden Secure Note または DPAPI ファイルから鍵をメモリ上で復号します。
ダウンロード PEM を指定した場合は照合成功後に削除するか y/N で確認します。
鍵本文は表示せず、GitHub の設定も変更しません。
#>
[CmdletBinding(DefaultParameterSetName = 'Fingerprint')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Pem')]
    [ValidateNotNullOrEmpty()]
    [string]$PemPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Fingerprint')]
    [Parameter(ParameterSetName = 'Pem')]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedFingerprint,

    [string]$BackupPath,

    [ValidatePattern('^[0-9]+$')]
    [string]$AppId = '5074929'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseBotKey.Common.psm1') -Force
Assert-ReleaseBotPlatform

$sourcePem = $null
$backup = $null
$ownedSession = $false
$stage = 'preflight'
try {
    $stage = 'read-source'
    if ($PSCmdlet.ParameterSetName -eq 'Pem') {
        $resolved = Resolve-Path -LiteralPath $PemPath -ErrorAction Stop
        if ($resolved.Provider.Name -ne 'FileSystem') {
            throw 'The comparison PEM must be a local file.'
        }
        $sourceFile = Get-Item -LiteralPath $resolved.ProviderPath -Force -ErrorAction Stop
        if ($sourceFile.PSIsContainer -or ($sourceFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The comparison PEM must be a regular file.'
        }
        $sourcePem = [IO.File]::ReadAllText($resolved.ProviderPath)
        $sourceFingerprintValue = Get-ReleaseBotFingerprint -Pem $sourcePem
        if (-not [string]::IsNullOrWhiteSpace($ExpectedFingerprint)) {
            $expectedValue = ConvertTo-ReleaseBotFingerprintValue -Fingerprint $ExpectedFingerprint
            if ($sourceFingerprintValue -cne $expectedValue) {
                throw 'The downloaded PEM does not match the GitHub fingerprint.'
            }
        }
        $fingerprintValue = $sourceFingerprintValue
    }
    else {
        $fingerprintValue = ConvertTo-ReleaseBotFingerprintValue -Fingerprint $ExpectedFingerprint
    }

    if ([string]::IsNullOrWhiteSpace($BackupPath) -and (Get-ReleaseBotExecutable -Name 'bw')) {
        $stage = 'unlock-vault'
        $null = Get-ReleaseBotBitwarden
        $ownedSession = $true
    }
    $stage = 'read-backup'
    $backup = Get-ReleaseBotBackup -FingerprintValue $fingerprintValue -AppId $AppId -BackupPath $BackupPath
    if ($backup.Fingerprint -cne $fingerprintValue) {
        throw 'The backup fingerprint does not match the requested GitHub App key.'
    }

    if ($PSCmdlet.ParameterSetName -eq 'Pem') {
        $stage = 'compare'
        if ($backup.Pem -cne $sourcePem) {
            throw 'The saved backup does not match the supplied download file.'
        }
        Write-Host "バックアップの復号とダウンロード PEM の照合に成功しました: $(Format-ReleaseBotFingerprint -Value $fingerprintValue)"
        $stage = 'delete-prompt'
        $answer = Read-Host "照合済みのダウンロードファイルを削除しますか？ y/N ($($resolved.ProviderPath))"
        if ($answer -ieq 'y') {
            $stage = 'delete-download'
            Remove-Item -LiteralPath $resolved.ProviderPath -Force -ErrorAction Stop
            Write-Host 'ダウンロード PEM を削除しました。バックアップは保持されています。'
        }
        else {
            Write-Host 'ダウンロード PEM は保持しました。'
        }
    }
    else {
        Write-Host "保存したバックアップを復号し、fingerprint を確認しました: $(Format-ReleaseBotFingerprint -Value $fingerprintValue)"
    }
    Write-Host "バックアップ: $($backup.Storage)"
    if ($backup.Path) {
        Write-Host "バックアップファイル: $($backup.Path)"
    }
}
catch {
    throw "GitHub App 鍵の照合は $stage ($($_.Exception.GetType().Name)) で停止しました: $($_.Exception.Message) 鍵の内容は表示していません。"
}
finally {
    if ($backup) {
        $backup.Pem = $null
    }
    $backup = $null
    $sourcePem = $null
    if ($ownedSession) {
        Close-ReleaseBotBitwarden
    }
}
