<#
.SYNOPSIS
Bitwarden に保存した GitHub App 秘密鍵を、PEM ファイルまたは GitHub fingerprint と照合します。

.DESCRIPTION
Bitwarden Secure Note から鍵をメモリ上に読み込みます。秘密鍵の内容は表示・保存せず、GitHub の設定も変更しません。

.PARAMETER PemPath
照合対象の GitHub App PEM ファイル。

.PARAMETER ExpectedFingerprint
GitHub App 設定画面に表示される SHA256 fingerprint。

.EXAMPLE
./scripts/verify-release-bot-key.ps1 -PemPath "$env:USERPROFILE/Downloads/scottlz0310-release-bot.private-key.pem"

.EXAMPLE
./scripts/verify-release-bot-key.ps1 -ExpectedFingerprint 'SHA256:BASE64_FINGERPRINT='
#>
[CmdletBinding(DefaultParameterSetName = 'Fingerprint')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'PemPath')]
    [ValidateNotNullOrEmpty()]
    [string]$PemPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Fingerprint')]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedFingerprint
)

$ErrorActionPreference = 'Stop'
$appName = 'scottlz0310-release-bot'
$appId = '5074929'
$itemName = 'scottlz0310-release-bot private key'
$stage = 'preflight'
$failureInfo = $null
$ownsSession = $false
$originalSession = $env:BW_SESSION
$sessionOutput = $null
$itemsOutput = $null
$vaultItems = $null
$matchingItems = $null
$noteOutput = $null
$noteText = $null
$pem = $null
$candidatePem = $null
$pemMatches = $null
$candidateFingerprint = $null
$expectedFingerprintValue = $null

function Get-GitHubAppKeyFingerprint {
    param([Parameter(Mandatory = $true)][string]$PrivatePem)

    $rsa = [System.Security.Cryptography.RSA]::Create()
    $publicDer = $null
    $sha256 = $null
    $digest = $null
    try {
        $rsa.ImportFromPem($PrivatePem)
        $publicDer = $rsa.ExportSubjectPublicKeyInfo()
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $digest = $sha256.ComputeHash($publicDer)
        [Convert]::ToBase64String($digest)
    }
    finally {
        if ($digest) {
            [Array]::Clear($digest, 0, $digest.Length)
        }
        if ($publicDer) {
            [Array]::Clear($publicDer, 0, $publicDer.Length)
        }
        if ($sha256) {
            $sha256.Dispose()
        }
        $rsa.Dispose()
    }
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'PemPath') {
        $resolvedPath = Resolve-Path -LiteralPath $PemPath -ErrorAction Stop
        if ($resolvedPath.Provider.Name -ne 'FileSystem' -or -not (Test-Path -LiteralPath $resolvedPath.ProviderPath -PathType Leaf)) {
            throw 'The comparison PEM file was not found.'
        }
        $candidatePem = [System.IO.File]::ReadAllText($resolvedPath.ProviderPath)
    }
    else {
        $expectedFingerprintValue = $ExpectedFingerprint.Trim()
        if ($expectedFingerprintValue.StartsWith('SHA256:', [StringComparison]::Ordinal)) {
            $expectedFingerprintValue = $expectedFingerprintValue.Substring(7)
        }
        if ($expectedFingerprintValue -cnotmatch '^[A-Za-z0-9+/]{43}=$') {
            throw 'The expected GitHub fingerprint has an invalid format.'
        }
    }

    if (-not (Get-Command bw -ErrorAction SilentlyContinue)) {
        throw 'Bitwarden CLI (bw) is not available.'
    }

    $stage = 'unlock'
    if ([string]::IsNullOrWhiteSpace($originalSession)) {
        Write-Host 'このウィンドウで Bitwarden を解錠してください。マスターパスワードはローカルのプロンプトにだけ入力されます。'
        $sessionOutput = & bw unlock --raw
        $bwExitCode = $LASTEXITCODE
        if ($bwExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($sessionOutput -join ''))) {
            throw 'Bitwarden unlock did not complete.'
        }
        $env:BW_SESSION = ($sessionOutput -join '').Trim()
        $ownsSession = $true
        $sessionOutput = $null
    }
    else {
        $statusOutput = & bw status 2>$null
        $bwExitCode = $LASTEXITCODE
        if ($bwExitCode -ne 0) {
            throw 'Bitwarden status could not be read.'
        }
        $status = (($statusOutput -join '') | ConvertFrom-Json -ErrorAction Stop).status
        $statusOutput = $null
        if ($status -ne 'unlocked') {
            throw 'The supplied Bitwarden session is not unlocked.'
        }
    }

    $stage = 'vault-search'
    $itemsOutput = & bw list items --search $itemName 2>$null
    $bwExitCode = $LASTEXITCODE
    if ($bwExitCode -ne 0) {
        throw 'Bitwarden Secure Notes could not be searched.'
    }
    $itemsJson = $itemsOutput -join "`n"
    if ([string]::IsNullOrWhiteSpace($itemsJson)) {
        throw 'The target Bitwarden Secure Note was not found.'
    }
    $vaultItems = @(ConvertFrom-Json -InputObject $itemsJson -ErrorAction Stop)
    $matchingItems = @($vaultItems | Where-Object { $_.name -ceq $itemName })
    if ($matchingItems.Count -ne 1 -or $matchingItems[0].type -ne 2 -or -not $matchingItems[0].id) {
        throw 'Exactly one target Bitwarden Secure Note is required.'
    }

    $stage = 'vault-read'
    $noteOutput = & bw get notes $matchingItems[0].id 2>$null
    $bwExitCode = $LASTEXITCODE
    if ($bwExitCode -ne 0) {
        throw 'The Bitwarden Secure Note could not be read.'
    }
    $noteText = $noteOutput -join "`n"
    $noteOutput = $null
    if (-not $noteText.Contains("GitHub App: $appName") -or -not $noteText.Contains("App ID: $appId")) {
        throw 'The Secure Note does not describe the expected GitHub App.'
    }

    $stage = 'key-extract'
    $pemMatches = [regex]::Matches($noteText, '(?ms)^-----BEGIN (?<kind>[A-Z0-9 ]*PRIVATE KEY)-----\r?\n.+?\r?\n-----END \k<kind>-----')
    if ($pemMatches.Count -ne 1) {
        throw 'Exactly one PEM private key is required in the Secure Note.'
    }
    $pem = $pemMatches[0].Value.Trim()
    $noteText = $null
    $vaultItems = $null
    $matchingItems = $null
    $itemsOutput = $null
    $itemsJson = $null

    $stage = 'compare'
    $vaultFingerprint = Get-GitHubAppKeyFingerprint -PrivatePem $pem
    if ($PSCmdlet.ParameterSetName -eq 'PemPath') {
        $candidateFingerprint = Get-GitHubAppKeyFingerprint -PrivatePem $candidatePem
        if (-not [String]::Equals($vaultFingerprint, $candidateFingerprint, [StringComparison]::Ordinal)) {
            throw 'The Bitwarden key does not match the supplied PEM file.'
        }
        Write-Host 'Bitwarden の鍵と指定 PEM ファイルは一致しました。'
    }
    elseif (-not [String]::Equals($vaultFingerprint, $expectedFingerprintValue, [StringComparison]::Ordinal)) {
        throw 'The Bitwarden key does not match the supplied GitHub fingerprint.'
    }
    else {
        Write-Host 'Bitwarden の鍵 fingerprint と指定した GitHub fingerprint は一致しました。'
    }
}
catch {
    $failureInfo = "$stage ($($_.Exception.GetType().Name))"
}
finally {
    $pem = $null
    $candidatePem = $null
    $noteText = $null
    $noteOutput = $null
    $pemMatches = $null
    $itemsJson = $null
    $itemsOutput = $null
    $vaultItems = $null
    $matchingItems = $null
    $sessionOutput = $null
    $candidateFingerprint = $null
    $expectedFingerprintValue = $null
    if ($ownsSession -and $env:BW_SESSION) {
        & bw lock 2>$null | Out-Null
        $lockExitCode = $LASTEXITCODE
        Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
        if ($lockExitCode -ne 0 -and -not $failureInfo) {
            $failureInfo = 'vault-lock (NativeCommandError)'
        }
    }
}

if ($failureInfo) {
    throw "照合は $failureInfo で停止しました。鍵の内容は表示・保存していません。"
}
