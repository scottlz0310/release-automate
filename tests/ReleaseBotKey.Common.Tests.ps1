BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/ReleaseBotKey.Common.psm1') -Force

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $otherRsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $pem = $rsa.ExportRSAPrivateKeyPem()
        $otherPem = $otherRsa.ExportRSAPrivateKeyPem()
        $fingerprint = [Convert]::ToBase64String(
            [Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())
        )
        $otherFingerprint = [Convert]::ToBase64String(
            [Security.Cryptography.SHA256]::HashData($otherRsa.ExportSubjectPublicKeyInfo())
        )
    }
    finally {
        $rsa.Dispose()
        $otherRsa.Dispose()
    }

    function New-TestVaultNote {
        param([string]$Key, [string]$AppId, [string]$Fingerprint, [string]$AppName = 'scottlz0310-release-bot')
        return "GitHub App: $AppName`nApp ID: $AppId`nFingerprint: SHA256:$Fingerprint`nPrivate key:`n$Key"
    }
}

Describe 'Fingerprint and PEM parsing' {
    It 'matches the SHA-256 of the DER SubjectPublicKeyInfo' {
        Get-ReleaseBotFingerprint -Pem $pem | Should -BeExactly $fingerprint
    }

    It 'accepts a prefixed or bare fingerprint' -ForEach @(
        @{ Prefix = '' }
        @{ Prefix = 'SHA256:' }
    ) {
        ConvertTo-ReleaseBotFingerprintValue -Fingerprint "$Prefix$fingerprint" | Should -BeExactly $fingerprint
    }

    It 'rejects an invalid fingerprint without echoing it' {
        $message = { ConvertTo-ReleaseBotFingerprintValue -Fingerprint 'private-sentinel' } | Should -Throw -PassThru
        $message.Exception.Message | Should -Not -Match 'private-sentinel'
    }

    It 'extracts exactly one private key' {
        $note = "header`n$pem`nfooter"
        $result = InModuleScope ReleaseBotKey.Common -Parameters @{ Note = $note } {
            Get-ReleaseBotPemFromText -Text $Note
        }
        $result | Should -BeExactly $pem
    }

    It 'rejects zero or multiple PEM blocks' -ForEach @(
        @{ Count = 0 }
        @{ Count = 2 }
    ) {
        $text = if ($Count -eq 0) { 'no private key' } else { "$pem`n$otherPem" }
        { InModuleScope ReleaseBotKey.Common -Parameters @{ Text = $text } {
            Get-ReleaseBotPemFromText -Text $Text
        } } | Should -Throw '*exactly one PEM private key*'
    }
}

Describe 'Bitwarden Secure Note metadata' {
    It 'accepts matching App name, ID and fingerprint' {
        $note = New-TestVaultNote -Key $pem -AppId '123' -Fingerprint $fingerprint
        $metadata = InModuleScope ReleaseBotKey.Common -Parameters @{ Note = $note } {
            Get-ReleaseBotVaultMetadata -Note $Note
        }
        $metadata.AppId | Should -BeExactly '123'
        $metadata.Fingerprint | Should -BeExactly $fingerprint
        $metadata.Pem | Should -BeExactly $pem
    }

    It 'rejects invalid metadata' -ForEach @(
        @{ Case = 'app name' }
        @{ Case = 'app ID' }
        @{ Case = 'fingerprint' }
    ) {
        $note = New-TestVaultNote -Key $pem -AppId '123' -Fingerprint $fingerprint
        switch ($Case) {
            'app name' { $note = $note.Replace('scottlz0310-release-bot', 'another-app') }
            'app ID' { $note = $note.Replace('App ID: 123', 'App ID: missing') }
            'fingerprint' { $note = $note.Replace($fingerprint, $otherFingerprint) }
        }
        $failure = { InModuleScope ReleaseBotKey.Common -Parameters @{ Note = $note } {
            Get-ReleaseBotVaultMetadata -Note $Note
        } } | Should -Throw -PassThru
        $failure.Exception.Message | Should -Not -Match ([regex]::Escape($pem.Substring(0, 80)))
    }
}

Describe 'Save-ReleaseBotBitwardenBackup' {
    BeforeEach {
        Mock Get-ReleaseBotBitwarden -ModuleName ReleaseBotKey.Common { 'bw.exe' }
        $global:releaseBotProcessCalls = [Collections.Generic.List[object]]::new()
    }

    AfterEach {
        Remove-Variable releaseBotProcessCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'creates or reuses the correct Secure Note' -ForEach @(
        @{ Case = 'new'; Existing = $false; Legacy = $false; OtherKey = $false; Creates = $true }
        @{ Case = 'fingerprint name'; Existing = $true; Legacy = $false; OtherKey = $false; Creates = $false }
        @{ Case = 'matching legacy'; Existing = $true; Legacy = $true; OtherKey = $false; Creates = $false }
        @{ Case = 'other legacy key'; Existing = $true; Legacy = $true; OtherKey = $true; Creates = $true }
    ) {
        $name = "scottlz0310-release-bot private key [SHA256:$fingerprint]"
        $existingName = if ($Legacy) { 'scottlz0310-release-bot private key' } else { $name }
        $existingItem = if ($Existing) { [pscustomobject]@{ Id = 'old'; Name = $existingName } } else { $null }
        $existingNote = if ($OtherKey) {
            New-TestVaultNote -Key $otherPem -AppId '123' -Fingerprint $otherFingerprint
        } else {
            New-TestVaultNote -Key $pem -AppId '123' -Fingerprint $fingerprint
        }
        $createdNote = New-TestVaultNote -Key $pem -AppId '123' -Fingerprint $fingerprint
        Mock Get-ReleaseBotBitwardenItem -ModuleName ReleaseBotKey.Common { $existingItem }
        Mock Get-ReleaseBotBitwardenNote -ModuleName ReleaseBotKey.Common {
            if ($Id -eq 'new') { return $createdNote }
            return $existingNote
        }
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common {
            $global:releaseBotProcessCalls.Add([pscustomobject]@{ Arguments = $Arguments; InputText = $InputText })
            switch ($Arguments[0]) {
                'get' { return '{"secureNote":{"type":0}}' }
                'encode' { return 'encoded-note' }
                'create' { return '{"id":"new"}' }
                default { throw 'Unexpected fake Bitwarden command.' }
            }
        }

        $result = Save-ReleaseBotBitwardenBackup -Pem $pem -AppId '123' -FingerprintValue $fingerprint
        $result | Should -Match 'Bitwarden Secure Note'
        @($global:releaseBotProcessCalls | Where-Object { $_.Arguments[0] -eq 'create' }).Count | Should -Be ([int]$Creates)
        if ($Creates) {
            @($global:releaseBotProcessCalls | Where-Object { $_.Arguments[0] -eq 'encode' }).Count | Should -Be 1
        }
    }

    It 'rejects an existing item with another App ID without creating one' {
        $existingNote = New-TestVaultNote -Key $pem -AppId '999' -Fingerprint $fingerprint
        Mock Get-ReleaseBotBitwardenItem -ModuleName ReleaseBotKey.Common {
            [pscustomobject]@{ Id = 'old'; Name = "scottlz0310-release-bot private key [SHA256:$fingerprint]" }
        }
        Mock Get-ReleaseBotBitwardenNote -ModuleName ReleaseBotKey.Common { $existingNote }
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common {
            throw 'No create call is expected.'
        }
        { Save-ReleaseBotBitwardenBackup -Pem $pem -AppId '123' -FingerprintValue $fingerprint } |
            Should -Throw '*App ID*'
        Should -Invoke Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common -Times 0
    }

    It 'rejects a legacy item belonging to another App ID during rotation' {
        $existingNote = New-TestVaultNote -Key $otherPem -AppId '999' -Fingerprint $otherFingerprint
        Mock Get-ReleaseBotBitwardenItem -ModuleName ReleaseBotKey.Common {
            [pscustomobject]@{ Id = 'old'; Name = 'scottlz0310-release-bot private key' }
        }
        Mock Get-ReleaseBotBitwardenNote -ModuleName ReleaseBotKey.Common { $existingNote }
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common {
            throw 'No create call is expected.'
        }
        { Save-ReleaseBotBitwardenBackup -Pem $pem -AppId '123' -FingerprintValue $fingerprint } |
            Should -Throw '*App ID*'
        Should -Invoke Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common -Times 0
    }
}

Describe 'Bitwarden session ownership' {
    BeforeEach {
        $global:priorBwSession = $env:BW_SESSION
        Mock Get-ReleaseBotExecutable -ModuleName ReleaseBotKey.Common { 'bw.exe' }
    }

    AfterEach {
        if ($null -eq $global:priorBwSession) {
            Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
        }
        else {
            $env:BW_SESSION = $global:priorBwSession
        }
        Remove-Variable priorBwSession -Scope Global
    }

    It 'preserves an existing unlocked session' {
        $env:BW_SESSION = 'existing-session'
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common { '{"status":"unlocked"}' }
        Get-ReleaseBotBitwarden | Should -BeExactly 'bw.exe'
        Close-ReleaseBotBitwarden
        $env:BW_SESSION | Should -BeExactly 'existing-session'
        Should -Invoke Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common -Times 0 -ParameterFilter { $Arguments[0] -eq 'lock' }
    }

    It 'rejects a supplied session that is locked' {
        $env:BW_SESSION = 'stale-session'
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common { '{"status":"locked"}' }
        { Get-ReleaseBotBitwarden } | Should -Throw '*not unlocked*'
        $env:BW_SESSION | Should -BeExactly 'stale-session'
        Should -Invoke Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common -Times 0 -ParameterFilter { $Arguments[0] -eq 'lock' }
    }

    It 'locks and clears only a session owned by this module' {
        $env:BW_SESSION = 'owned-session'
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common { '' }
        InModuleScope ReleaseBotKey.Common {
            $script:OwnedBitwardenSession = $true
            $script:BitwardenPath = 'bw.exe'
        }
        Close-ReleaseBotBitwarden
        $env:BW_SESSION | Should -BeNullOrEmpty
        Should -Invoke Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common -Times 1 -ParameterFilter { $Arguments[0] -eq 'lock' }
    }

    It 'unlocks with a fake CLI and then locks its own session' {
        Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
        $fakeBw = Join-Path $TestDrive 'bw.cmd'
        [IO.File]::WriteAllText($fakeBw, "@echo off`r`necho temporary-session`r`n")
        Mock Get-ReleaseBotExecutable -ModuleName ReleaseBotKey.Common { $fakeBw }
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common { '' }

        Get-ReleaseBotBitwarden | Should -BeExactly $fakeBw
        $env:BW_SESSION | Should -BeExactly 'temporary-session'
        Close-ReleaseBotBitwarden
        $env:BW_SESSION | Should -BeNullOrEmpty
        Should -Invoke Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common -Times 1 -ParameterFilter { $Arguments[0] -eq 'lock' }
    }
}

Describe 'Bitwarden item lookup' {
    BeforeEach {
        Mock Get-ReleaseBotBitwarden -ModuleName ReleaseBotKey.Common { 'bw.exe' }
    }

    It 'selects the exact Secure Note from a broader search result' {
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common {
            '[{"id":"fuzzy","name":"key suffix","type":2},{"id":"exact","name":"key","type":2}]'
        }
        $item = InModuleScope ReleaseBotKey.Common {
            Get-ReleaseBotBitwardenItem -Name 'key'
        }
        $item.Id | Should -BeExactly 'exact'
    }

    It 'rejects duplicate exact matches or a non-Secure-Note item' -ForEach @(
        @{ Items = '[{"id":"a","name":"key","type":2},{"id":"b","name":"key","type":2}]' }
        @{ Items = '[{"id":"a","name":"key","type":1}]' }
    ) {
        $response = $Items
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common { $response }
        { InModuleScope ReleaseBotKey.Common { Get-ReleaseBotBitwardenItem -Name 'key' } } | Should -Throw
    }
}

Describe 'DPAPI backup and ACL' {
    It 'round trips the key and restricts directory and file ACLs' {
        $path = Join-Path $TestDrive 'keys/key.dpapi.json'
        Save-ReleaseBotDpapiBackup -Pem $pem -AppId '123' -FingerprintValue $fingerprint -Path $path |
            Should -BeExactly $path
        $backup = Get-ReleaseBotBackup -AppId '123' -FingerprintValue $fingerprint -BackupPath $path
        $backup.Pem | Should -BeExactly $pem
        $backup.Storage | Should -BeExactly 'DPAPI'

        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $document.encryptedPem | Should -Not -Match 'PRIVATE KEY'
        foreach ($target in @((Split-Path -Parent $path), $path)) {
            $acl = Get-Acl -LiteralPath $target
            $acl.AreAccessRulesProtected | Should -BeTrue
            @($acl.Access).Count | Should -Be 1
            $acl.Access[0].IdentityReference.Value | Should -BeExactly ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        }
    }

    It 'rejects a mismatched App ID or fingerprint' -ForEach @(
        @{ AppId = '999'; FingerprintKind = 'same' }
        @{ AppId = '123'; FingerprintKind = 'other' }
    ) {
        $path = Join-Path $TestDrive 'keys/key.dpapi.json'
        $null = Save-ReleaseBotDpapiBackup -Pem $pem -AppId '123' -FingerprintValue $fingerprint -Path $path
        $requestedFingerprint = if ($FingerprintKind -eq 'other') { $otherFingerprint } else { $fingerprint }
        { Get-ReleaseBotBackup -AppId $AppId -FingerprintValue $requestedFingerprint -BackupPath $path } |
            Should -Throw
    }

    It 'reuses an existing encrypted backup for the same key' {
        $path = Join-Path $TestDrive 'keys/key.dpapi.json'
        $null = Save-ReleaseBotDpapiBackup -Pem $pem -AppId '123' -FingerprintValue $fingerprint -Path $path
        $firstCipher = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).encryptedPem
        $null = Save-ReleaseBotDpapiBackup -Pem $pem -AppId '123' -FingerprintValue $fingerprint -Path $path
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).encryptedPem | Should -BeExactly $firstCipher
    }
}

Describe 'Organization Actions secrets' {
    BeforeEach {
        $global:releaseBotProcessCalls = [Collections.Generic.List[object]]::new()
        Mock Get-ReleaseBotExecutable -ModuleName ReleaseBotKey.Common { 'gh.exe' }
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common {
            $global:releaseBotProcessCalls.Add([pscustomobject]@{ Arguments = $Arguments; InputText = $InputText })
            if ($Arguments[0] -eq 'secret' -and $Arguments[1] -eq 'list') {
                return '[{"name":"RELEASE_BOT_PRIVATE_KEY","visibility":"all"},{"name":"RELEASE_BOT_APP_ID","visibility":"all"}]'
            }
            return ''
        }
    }

    AfterEach {
        Remove-Variable releaseBotProcessCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'sends both values over stdin and verifies all-repository visibility' {
        Set-ReleaseBotOrganizationSecrets -Pem $pem -AppId '123' -Fingerprint $fingerprint -Confirm:$false
        $setCalls = @($global:releaseBotProcessCalls | Where-Object { $_.Arguments[0] -eq 'secret' -and $_.Arguments[1] -eq 'set' })
        $setCalls.Count | Should -Be 2
        $setCalls[0].Arguments | Should -Be @('secret', 'set', 'RELEASE_BOT_PRIVATE_KEY', '--org', 'scottlz0310', '--visibility', 'all', '--app', 'actions')
        $setCalls[0].InputText | Should -BeExactly $pem
        $setCalls[1].Arguments | Should -Be @('secret', 'set', 'RELEASE_BOT_APP_ID', '--org', 'scottlz0310', '--visibility', 'all', '--app', 'actions')
        $setCalls[1].InputText | Should -BeExactly "123`n"
        @($global:releaseBotProcessCalls | Where-Object { $_.Arguments[0] -eq 'secret' -and $_.Arguments[1] -eq 'list' }).Count |
            Should -Be 1
    }

    It 'throws when either secret is not visible to all repositories' {
        Mock Invoke-ReleaseBotProcess -ModuleName ReleaseBotKey.Common {
            if ($Arguments[0] -eq 'secret' -and $Arguments[1] -eq 'list') {
                return '[{"name":"RELEASE_BOT_PRIVATE_KEY","visibility":"private"},{"name":"RELEASE_BOT_APP_ID","visibility":"all"}]'
            }
            return ''
        }
        $failure = { Set-ReleaseBotOrganizationSecrets -Pem $pem -AppId '123' -Fingerprint $fingerprint -Confirm:$false } |
            Should -Throw -PassThru
        $failure.Exception.Message | Should -Not -Match ([regex]::Escape($pem.Substring(0, 80)))
    }
}
