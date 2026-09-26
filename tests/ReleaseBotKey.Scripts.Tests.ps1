BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/ReleaseBotKey.Common.psm1') -Force
    $scripts = Join-Path $PSScriptRoot '../scripts'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $pem = $rsa.ExportRSAPrivateKeyPem()
        $fingerprint = [Convert]::ToBase64String(
            [Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())
        )
    }
    finally {
        $rsa.Dispose()
    }
    $global:releaseBotScriptPem = $pem
    $global:releaseBotScriptFingerprint = $fingerprint
}

AfterAll {
    Remove-Variable releaseBotScriptPem, releaseBotScriptFingerprint -Scope Global
}

Describe 'Backup and verification scripts' {
    BeforeEach {
        Mock Import-Module { }
    }

    It 'routes a downloaded PEM to DPAPI when Bitwarden is absent without logging the key' {
        $source = Join-Path $TestDrive 'download.pem'
        [IO.File]::WriteAllText($source, $pem)
        Mock Get-ReleaseBotBitwarden { $null }
        Mock Get-ReleaseBotDefaultBackupPath { Join-Path $TestDrive 'backup.dpapi.json' }
        Mock Save-ReleaseBotDpapiBackup { $Path }

        $output = & (Join-Path $scripts 'backup-release-bot-key.ps1') -PemPath $source -AppId '123' 6>&1 | Out-String
        $output | Should -Match ([regex]::Escape("SHA256:$fingerprint"))
        $output | Should -Not -Match ([regex]::Escape($pem.Substring(0, 80)))
        Should -Invoke Save-ReleaseBotDpapiBackup -Times 1 -ParameterFilter {
            $AppId -eq '123' -and $FingerprintValue -eq $fingerprint -and $Pem -eq $pem
        }
    }

    It 'does not include a PEM in a backup failure message' {
        $source = Join-Path $TestDrive 'download.pem'
        [IO.File]::WriteAllText($source, $pem)
        Mock Get-ReleaseBotBitwarden { $null }
        Mock Get-ReleaseBotDefaultBackupPath { Join-Path $TestDrive 'backup.dpapi.json' }
        Mock Save-ReleaseBotDpapiBackup { throw 'Synthetic storage failure.' }

        $failure = { & (Join-Path $scripts 'backup-release-bot-key.ps1') -PemPath $source -AppId '123' } |
            Should -Throw -PassThru
        $failure.Exception.Message | Should -Match 'backup.*Synthetic storage failure'
        $failure.Exception.Message | Should -Not -Match ([regex]::Escape($pem.Substring(0, 80)))
    }

    It 'verifies a restored key by fingerprint without opening the vault' {
        Mock Get-ReleaseBotBackup {
            [pscustomobject]@{
                AppId = '123'; Fingerprint = $global:releaseBotScriptFingerprint; Pem = $global:releaseBotScriptPem; Path = 'fake.dpapi.json'; Storage = 'DPAPI'
            }
        }
        $output = & (Join-Path $scripts 'verify-release-bot-key.ps1') -ExpectedFingerprint "SHA256:$fingerprint" -BackupPath 'fake.dpapi.json' -AppId '123' 6>&1 | Out-String
        $output | Should -Match 'fingerprint'
        $output | Should -Not -Match ([regex]::Escape($pem.Substring(0, 80)))
        Should -Invoke Get-ReleaseBotBackup -Times 1 -ParameterFilter {
            $AppId -eq '123' -and $FingerprintValue -eq $fingerprint -and $BackupPath -eq 'fake.dpapi.json'
        }
    }
}

Describe 'Secret setup and rotation scripts' {
    BeforeEach {
        Mock Import-Module { }
        Mock Get-ReleaseBotBackup {
            [pscustomobject]@{
                AppId = '123'; Fingerprint = $global:releaseBotScriptFingerprint; Pem = $global:releaseBotScriptPem; Path = 'fake.dpapi.json'; Storage = 'DPAPI'
            }
        }
        Mock Set-ReleaseBotOrganizationSecrets { }
    }

    It 'passes an unprefixed fingerprint to secret setup' {
        & (Join-Path $scripts 'set-release-bot-secrets.ps1') -Fingerprint "SHA256:$fingerprint" -BackupPath 'fake.dpapi.json' -AppId '123'
        Should -Invoke Set-ReleaseBotOrganizationSecrets -Times 1 -ParameterFilter {
            $AppId -eq '123' -and $Fingerprint -eq $fingerprint -and $Pem -eq $pem
        }
    }

    It 'routes rotation through the same secret setup path' {
        & (Join-Path $scripts 'rotate-release-bot-key.ps1') -Fingerprint "SHA256:$fingerprint" -BackupPath 'fake.dpapi.json' -AppId '123'
        Should -Invoke Set-ReleaseBotOrganizationSecrets -Times 1 -ParameterFilter {
            $AppId -eq '123' -and $Fingerprint -eq $fingerprint -and $Pem -eq $pem
        }
    }

    It 'does not include a restored PEM in a secret setup failure' {
        Mock Set-ReleaseBotOrganizationSecrets { throw 'Synthetic gh failure.' }
        $failure = { & (Join-Path $scripts 'set-release-bot-secrets.ps1') -Fingerprint "SHA256:$fingerprint" -BackupPath 'fake.dpapi.json' -AppId '123' } |
            Should -Throw -PassThru
        $failure.Exception.Message | Should -Match 'github-secrets.*Synthetic gh failure'
        $failure.Exception.Message | Should -Not -Match ([regex]::Escape($pem.Substring(0, 80)))
    }
}
