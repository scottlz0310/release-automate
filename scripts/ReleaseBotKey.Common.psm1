Set-StrictMode -Version Latest

$script:ReleaseBotAppName = 'scottlz0310-release-bot'
$script:ReleaseBotOrganization = 'scottlz0310'
$script:ReleaseBotLegacyItemName = 'scottlz0310-release-bot private key'
$script:ReleaseBotDefaultAppId = '5074929'
$script:OwnedBitwardenSession = $false
$script:BitwardenPath = $null

function Assert-ReleaseBotPlatform {
    if ($PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'PowerShell 7.4 or later is required.'
    }
    if (-not $IsWindows) {
        throw 'These key-management scripts require Windows for DPAPI protection.'
    }
}

function Get-ReleaseBotExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        return $null
    }
    return $command.Source
}

function Invoke-ReleaseBotProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowNull()][AllowEmptyString()][string]$InputText
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    [void]$startInfo.Environment.Remove('GH_DEBUG')
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The external command could not be started.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) {
            $process.StandardInput.Write($InputText)
        }
        $process.StandardInput.Close()
        $process.WaitForExit()
        $output = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "The external command failed (exit code $($process.ExitCode))."
        }
        return $output
    }
    finally {
        $process.Dispose()
    }
}

function Get-ReleaseBotFingerprint {
    param([Parameter(Mandatory = $true)][string]$Pem)

    $rsa = [System.Security.Cryptography.RSA]::Create()
    $publicKey = $null
    $sha256 = $null
    $digest = $null
    try {
        $rsa.ImportFromPem($Pem)
        $publicKey = $rsa.ExportSubjectPublicKeyInfo()
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $digest = $sha256.ComputeHash($publicKey)
        return [Convert]::ToBase64String($digest)
    }
    finally {
        if ($digest) {
            [Array]::Clear($digest, 0, $digest.Length)
        }
        if ($publicKey) {
            [Array]::Clear($publicKey, 0, $publicKey.Length)
        }
        if ($sha256) {
            $sha256.Dispose()
        }
        $rsa.Dispose()
    }
}

function ConvertTo-ReleaseBotFingerprintValue {
    param([Parameter(Mandatory = $true)][string]$Fingerprint)

    $value = $Fingerprint.Trim()
    if ($value.StartsWith('SHA256:', [StringComparison]::Ordinal)) {
        $value = $value.Substring(7)
    }
    if ($value -cnotmatch '^[A-Za-z0-9+/]{43}=$') {
        throw 'The GitHub App fingerprint has an invalid format.'
    }
    return $value
}

function Format-ReleaseBotFingerprint {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "SHA256:$Value"
}

function Get-ReleaseBotItemName {
    param([Parameter(Mandatory = $true)][string]$FingerprintValue)
    return "$($script:ReleaseBotLegacyItemName) [$(Format-ReleaseBotFingerprint -Value $FingerprintValue)]"
}

function Get-ReleaseBotDefaultBackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$FingerprintValue
    )

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'The current Windows user profile path is unavailable.'
    }
    $safeFingerprint = $FingerprintValue.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return Join-Path $env:LOCALAPPDATA "release-automate\release-bot-keys\$AppId-$safeFingerprint.dpapi.json"
}

function Get-ReleaseBotPemFromText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $matches = [regex]::Matches(
        $Text,
        '(?ms)^-----BEGIN (?<kind>[A-Z0-9 ]*PRIVATE KEY)-----\r?\n.+?\r?\n-----END \k<kind>-----'
    )
    if ($matches.Count -ne 1) {
        throw 'The backup must contain exactly one PEM private key.'
    }
    return $matches[0].Value.Trim()
}

function Get-ReleaseBotVaultNote {
    param(
        [Parameter(Mandatory = $true)][string]$Pem,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$FingerprintValue
    )

    $fingerprint = Format-ReleaseBotFingerprint -Value $FingerprintValue
    $generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    return @"
GitHub App: $($script:ReleaseBotAppName)
App ID: $AppId
Fingerprint: $fingerprint
Generated (UTC): $generatedUtc
Private key:
$($Pem.Trim())
"@
}

function Get-ReleaseBotVaultMetadata {
    param([Parameter(Mandatory = $true)][string]$Note)

    $appNamePattern = [regex]::Escape($script:ReleaseBotAppName)
    $hasAppName = [regex]::IsMatch($Note, "(?m)^GitHub App: $appNamePattern\s*$")
    $appMatch = [regex]::Match($Note, '(?m)^App ID: (?<id>[0-9]+)\s*$')
    $fingerprintMatch = [regex]::Match($Note, '(?m)^Fingerprint: SHA256:(?<value>[A-Za-z0-9+/]{43}=)\s*$')
    if (-not $hasAppName -or -not $appMatch.Success) {
        throw 'The Bitwarden Secure Note metadata is invalid.'
    }
    $pem = Get-ReleaseBotPemFromText -Text $Note
    $computedFingerprint = Get-ReleaseBotFingerprint -Pem $pem
    if ($fingerprintMatch.Success -and -not [String]::Equals($computedFingerprint, $fingerprintMatch.Groups['value'].Value, [StringComparison]::Ordinal)) {
        throw 'The Bitwarden Secure Note fingerprint does not match its private key.'
    }
    return [pscustomobject]@{
        AppId = $appMatch.Groups['id'].Value
        Fingerprint = $computedFingerprint
        Pem = $pem
    }
}

function Get-ReleaseBotBitwarden {
    $path = Get-ReleaseBotExecutable -Name 'bw'
    if (-not $path) {
        return $null
    }

    $script:BitwardenPath = $path
    if (-not [string]::IsNullOrWhiteSpace($env:BW_SESSION)) {
        $statusJson = Invoke-ReleaseBotProcess -FilePath $path -Arguments @('status') -InputText $null
        $status = (ConvertFrom-Json -InputObject $statusJson -ErrorAction Stop).status
        if ($status -ne 'unlocked') {
            throw 'The supplied Bitwarden session is not unlocked.'
        }
        return $path
    }

    Write-Host 'このウィンドウで Bitwarden を解錠してください。マスターパスワードはローカルのプロンプトにだけ入力されます。'
    $sessionOutput = & $path unlock --raw
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($sessionOutput -join ''))) {
        $sessionOutput = $null
        throw 'Bitwarden unlock did not complete.'
    }
    $env:BW_SESSION = ($sessionOutput -join '').Trim()
    $sessionOutput = $null
    $script:OwnedBitwardenSession = $true
    return $path
}

function Close-ReleaseBotBitwarden {
    if ($script:OwnedBitwardenSession -and $env:BW_SESSION -and $script:BitwardenPath) {
        try {
            $null = Invoke-ReleaseBotProcess -FilePath $script:BitwardenPath -Arguments @('lock') -InputText $null
        }
        finally {
            Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
            $script:OwnedBitwardenSession = $false
            $script:BitwardenPath = $null
        }
    }
}

function Get-ReleaseBotBitwardenItem {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$IncludeLegacy
    )

    $path = Get-ReleaseBotBitwarden
    if (-not $path) {
        throw 'Bitwarden CLI is not available.'
    }

    $itemsJson = Invoke-ReleaseBotProcess -FilePath $path -Arguments @('list', 'items', '--search', $Name) -InputText $null
    $items = @(ConvertFrom-Json -InputObject $itemsJson -ErrorAction Stop)
    $exactMatches = @($items | Where-Object { $_.name -ceq $Name })
    $itemsJson = $null
    $items = $null
    if ($exactMatches.Count -eq 0 -and $IncludeLegacy -and $Name -cne $script:ReleaseBotLegacyItemName) {
        return Get-ReleaseBotBitwardenItem -Name $script:ReleaseBotLegacyItemName
    }
    if ($exactMatches.Count -gt 1) {
        throw 'Multiple Bitwarden Secure Notes match the expected key backup.'
    }
    if ($exactMatches.Count -eq 0) {
        return $null
    }
    if ($exactMatches[0].type -ne 2 -or [string]::IsNullOrWhiteSpace($exactMatches[0].id)) {
        throw 'The matching Bitwarden item is not a Secure Note.'
    }
    return [pscustomobject]@{ Id = [string]$exactMatches[0].id; Name = [string]$exactMatches[0].name }
}

function Get-ReleaseBotBitwardenNote {
    param([Parameter(Mandatory = $true)][string]$Id)
    $path = Get-ReleaseBotBitwarden
    return Invoke-ReleaseBotProcess -FilePath $path -Arguments @('get', 'notes', $Id) -InputText $null
}

function Save-ReleaseBotBitwardenBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Pem,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$FingerprintValue
    )

    $path = Get-ReleaseBotBitwarden
    if (-not $path) {
        throw 'Bitwarden CLI is not available.'
    }
    $itemName = Get-ReleaseBotItemName -FingerprintValue $FingerprintValue
    $item = Get-ReleaseBotBitwardenItem -Name $itemName -IncludeLegacy
    if ($item) {
        $existingNote = Get-ReleaseBotBitwardenNote -Id $item.Id
        $metadata = Get-ReleaseBotVaultMetadata -Note $existingNote
        $existingNote = $null
        # A legacy note holding the previous key must survive rotation, so only reuse it for the same key.
        $isOtherLegacyKey = $item.Name -ceq $script:ReleaseBotLegacyItemName -and $metadata.Fingerprint -cne $FingerprintValue
        if (-not $isOtherLegacyKey) {
            if ($metadata.AppId -cne $AppId -or $metadata.Fingerprint -cne $FingerprintValue) {
                throw 'The existing Bitwarden backup does not match the requested App ID and fingerprint.'
            }
            $metadata = $null
            return "Bitwarden Secure Note ($($item.Name))"
        }
        $metadata = $null
    }

    $note = Get-ReleaseBotVaultNote -Pem $Pem -AppId $AppId -FingerprintValue $FingerprintValue
    $templateJson = Invoke-ReleaseBotProcess -FilePath $path -Arguments @('get', 'template', 'item') -InputText $null
    $itemObject = ConvertFrom-Json -InputObject $templateJson -AsHashtable -ErrorAction Stop
    $templateJson = $null
    $itemObject['type'] = 2
    if (-not $itemObject.ContainsKey('secureNote') -or $null -eq $itemObject['secureNote']) {
        $itemObject['secureNote'] = @{ type = 0 }
    }
    else {
        $itemObject['secureNote']['type'] = 0
    }
    $itemObject['name'] = $itemName
    $itemObject['notes'] = $note
    $json = ConvertTo-Json -InputObject $itemObject -Depth 100 -Compress
    $encoded = Invoke-ReleaseBotProcess -FilePath $path -Arguments @('encode') -InputText $json
    $json = $null
    $note = $null
    $itemObject = $null
    $encoded = $encoded.Trim()
    if ([string]::IsNullOrWhiteSpace($encoded)) {
        throw 'Bitwarden did not encode the Secure Note.'
    }
    $createdJson = Invoke-ReleaseBotProcess -FilePath $path -Arguments @('create', 'item') -InputText "$encoded`n"
    $encoded = $null
    $createdItem = ConvertFrom-Json -InputObject $createdJson -ErrorAction Stop
    $createdJson = $null
    if ([string]::IsNullOrWhiteSpace($createdItem.id)) {
        throw 'Bitwarden did not return the created Secure Note identifier.'
    }
    $createdNote = Get-ReleaseBotBitwardenNote -Id ([string]$createdItem.id)
    $createdMetadata = Get-ReleaseBotVaultMetadata -Note $createdNote
    $createdNote = $null
    if ($createdMetadata.AppId -cne $AppId -or $createdMetadata.Fingerprint -cne $FingerprintValue) {
        throw 'The created Bitwarden Secure Note failed fingerprint verification.'
    }
    $createdMetadata = $null
    return "Bitwarden Secure Note ($itemName)"
}

function Set-ReleaseBotDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        $acl.RemoveAccessRuleAll($existingRule)
    }
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Set-ReleaseBotFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        $acl.RemoveAccessRuleAll($existingRule)
    }
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Protect-ReleaseBotPem {
    param([Parameter(Mandatory = $true)][string]$Pem)

    $secureString = ConvertTo-SecureString -String $Pem -AsPlainText -Force
    try {
        return ConvertFrom-SecureString -SecureString $secureString
    }
    finally {
        $secureString.Dispose()
    }
}

function Unprotect-ReleaseBotPem {
    param([Parameter(Mandatory = $true)][string]$CipherText)

    $secureString = $null
    $pointer = [IntPtr]::Zero
    try {
        $secureString = ConvertTo-SecureString -String $CipherText -ErrorAction Stop
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    catch {
        throw 'The DPAPI backup could not be decrypted for the current Windows user.'
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        if ($secureString) {
            $secureString.Dispose()
        }
    }
}

function Get-ReleaseBotDpapiBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprintValue
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if ($resolved.Provider.Name -ne 'FileSystem') {
        throw 'The DPAPI backup must be a local file.'
    }
    $fileInfo = Get-Item -LiteralPath $resolved.ProviderPath -Force -ErrorAction Stop
    if ($fileInfo.PSIsContainer -or ($fileInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The DPAPI backup must be a regular file.'
    }
    $document = Get-Content -LiteralPath $resolved.ProviderPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($document.version -ne 1 -or $document.appName -cne $script:ReleaseBotAppName -or $document.appId -cne $AppId) {
        throw 'The DPAPI backup metadata does not match the expected GitHub App.'
    }
    $storedFingerprint = ConvertTo-ReleaseBotFingerprintValue -Fingerprint ([string]$document.fingerprint)
    if ($storedFingerprint -cne $ExpectedFingerprintValue) {
        throw 'The DPAPI backup fingerprint does not match the requested key.'
    }
    $pem = Unprotect-ReleaseBotPem -CipherText ([string]$document.encryptedPem)
    $computedFingerprint = Get-ReleaseBotFingerprint -Pem $pem
    if ($computedFingerprint -cne $storedFingerprint) {
        $pem = $null
        throw 'The decrypted DPAPI backup does not match its fingerprint.'
    }
    return [pscustomobject]@{
        AppId = [string]$document.appId
        Fingerprint = $computedFingerprint
        Pem = $pem
        Path = [string]$resolved.ProviderPath
        Storage = 'DPAPI'
    }
}

function Save-ReleaseBotDpapiBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Pem,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$FingerprintValue,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    Set-ReleaseBotDirectoryAcl -Path $directory

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = Get-ReleaseBotDpapiBackup -Path $Path -AppId $AppId -ExpectedFingerprintValue $FingerprintValue
        $existing.Pem = $null
        return $Path
    }

    $cipherText = Protect-ReleaseBotPem -Pem $Pem
    $document = [ordered]@{
        version = 1
        appName = $script:ReleaseBotAppName
        appId = $AppId
        fingerprint = Format-ReleaseBotFingerprint -Value $FingerprintValue
        createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        encryptedPem = $cipherText
    }
    $json = ConvertTo-Json -InputObject $document -Depth 8
    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Set-ReleaseBotFileAcl -Path $temporaryPath
        [IO.File]::Move($temporaryPath, $Path)
        Set-ReleaseBotFileAcl -Path $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        $cipherText = $null
        $json = $null
        $document = $null
    }
    return $Path
}

function Get-ReleaseBotBackup {
    param(
        [Parameter(Mandatory = $true)][string]$FingerprintValue,
        [Parameter(Mandatory = $true)][string]$AppId,
        [string]$BackupPath
    )

    if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
        return Get-ReleaseBotDpapiBackup -Path $BackupPath -AppId $AppId -ExpectedFingerprintValue $FingerprintValue
    }

    $path = Get-ReleaseBotBitwarden
    if ($path) {
        $itemName = Get-ReleaseBotItemName -FingerprintValue $FingerprintValue
        $item = Get-ReleaseBotBitwardenItem -Name $itemName -IncludeLegacy
        if (-not $item) {
            throw 'The matching Bitwarden Secure Note was not found.'
        }
        $note = Get-ReleaseBotBitwardenNote -Id $item.Id
        $metadata = Get-ReleaseBotVaultMetadata -Note $note
        $note = $null
        if ($metadata.AppId -cne $AppId -or $metadata.Fingerprint -cne $FingerprintValue) {
            $metadata.Pem = $null
            throw 'The Bitwarden backup does not match the expected App ID and fingerprint.'
        }
        return [pscustomobject]@{
            AppId = $metadata.AppId
            Fingerprint = $metadata.Fingerprint
            Pem = $metadata.Pem
            Path = $null
            Storage = 'Bitwarden Secure Note'
        }
    }

    $defaultPath = Get-ReleaseBotDefaultBackupPath -AppId $AppId -FingerprintValue $FingerprintValue
    return Get-ReleaseBotDpapiBackup -Path $defaultPath -AppId $AppId -ExpectedFingerprintValue $FingerprintValue
}

function Set-ReleaseBotOrganizationSecrets {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$Pem,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $ghPath = Get-ReleaseBotExecutable -Name 'gh'
    if (-not $ghPath) {
        throw 'GitHub CLI (gh) is not available.'
    }
    $null = Invoke-ReleaseBotProcess -FilePath $ghPath -Arguments @('auth', 'status', '--hostname', 'github.com') -InputText $null
    $target = "Organization $($script:ReleaseBotOrganization) Actions secrets RELEASE_BOT_PRIVATE_KEY and RELEASE_BOT_APP_ID (all repositories)"
    if (-not $PSCmdlet.ShouldProcess($target, 'Create or update')) {
        return
    }

    $null = Invoke-ReleaseBotProcess -FilePath $ghPath -Arguments @(
        'secret', 'set', 'RELEASE_BOT_PRIVATE_KEY', '--org', $script:ReleaseBotOrganization,
        '--visibility', 'all', '--app', 'actions'
    ) -InputText $Pem
    $null = Invoke-ReleaseBotProcess -FilePath $ghPath -Arguments @(
        'secret', 'set', 'RELEASE_BOT_APP_ID', '--org', $script:ReleaseBotOrganization,
        '--visibility', 'all', '--app', 'actions'
    ) -InputText "$AppId`n"

    $verificationJson = Invoke-ReleaseBotProcess -FilePath $ghPath -Arguments @(
        'secret', 'list', '--org', $script:ReleaseBotOrganization, '--app', 'actions', '--json', 'name,visibility'
    ) -InputText $null
    $secrets = @(ConvertFrom-Json -InputObject $verificationJson -ErrorAction Stop)
    $keySecret = @($secrets | Where-Object { $_.name -ceq 'RELEASE_BOT_PRIVATE_KEY' })
    $appIdSecret = @($secrets | Where-Object { $_.name -ceq 'RELEASE_BOT_APP_ID' })
    $verificationJson = $null
    $secrets = $null
    if ($keySecret.Count -ne 1 -or $keySecret[0].visibility -cne 'all' -or
        $appIdSecret.Count -ne 1 -or $appIdSecret[0].visibility -cne 'all') {
        throw 'The organization Actions secrets were not verified with all-repository visibility.'
    }
    Write-Host "Organization Actions secrets are present with all-repository visibility. Fingerprint: $(Format-ReleaseBotFingerprint -Value $Fingerprint)"
}

Export-ModuleMember -Function @(
    'Assert-ReleaseBotPlatform',
    'Close-ReleaseBotBitwarden',
    'ConvertTo-ReleaseBotFingerprintValue',
    'Format-ReleaseBotFingerprint',
    'Get-ReleaseBotBackup',
    'Get-ReleaseBotBitwarden',
    'Get-ReleaseBotDefaultBackupPath',
    'Get-ReleaseBotExecutable',
    'Get-ReleaseBotFingerprint',
    'Save-ReleaseBotBitwardenBackup',
    'Save-ReleaseBotDpapiBackup',
    'Set-ReleaseBotOrganizationSecrets'
)
