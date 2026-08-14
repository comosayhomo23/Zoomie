Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ZoomieTestHelpers.psm1') -Force
    Register-WindowsCommandStub

    $script:ScriptPath = Get-ZoomieScriptPath 'src/InstallZoomie-v1.2.0.ps1'
    . (Get-ScriptFunctionDefinition -Path $script:ScriptPath)

    $script:Fake = Set-ZoomieFakeEnvironment -Root $TestDrive
    Register-FakeSystemDrive -Root (Join-Path $TestDrive 'cdrive')

    # The extracted functions read these from the script scope, which the main
    # block would normally populate.
    $script:StateDir    = Join-Path $script:Fake.ProgramData 'Zoom1132'
    $script:LogDir      = Join-Path $script:StateDir 'logs'
    $script:ProfilesDir = Join-Path $script:StateDir 'profiles'
    $script:StateFile   = Join-Path $script:StateDir 'active_zoom_user.txt'
    $script:LogFile     = Join-Path $script:LogDir 'engine_test.log'
    $script:ScriptDir   = Join-Path $TestDrive 'app'
}

Describe 'Write-Step' {
    It 'formats the level in upper case regardless of input casing' {
        $output = Write-Step 'warn' 'disk almost full' 6>&1
        $output | Should -Be '[WARN] disk almost full'
    }

    It 'keeps the message verbatim' {
        $output = Write-Step INFO 'User=bob Computer=PC-1' 6>&1
        $output | Should -Be '[INFO] User=bob Computer=PC-1'
    }
}

Describe 'Ensure-Dirs' {
    It 'creates the state, log and profile directories' {
        Ensure-Dirs
        Test-Path -LiteralPath $script:StateDir | Should -BeTrue
        Test-Path -LiteralPath $script:LogDir | Should -BeTrue
        Test-Path -LiteralPath $script:ProfilesDir | Should -BeTrue
    }

    It 'is idempotent and does not recreate existing directories' {
        New-Item -ItemType Directory -Path $script:StateDir, $script:LogDir, $script:ProfilesDir -Force | Out-Null
        Mock New-Item {}
        Ensure-Dirs
        Should -Invoke New-Item -Times 0 -Exactly
    }
}

Describe 'Ensure-Elevated' {
    It 'returns without relaunching when already elevated' {
        Mock Test-IsAdmin { $true }
        Mock Start-Process {}
        Ensure-Elevated
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'throws when the script path cannot be determined' {
        Mock Test-IsAdmin { $false }
        Mock Start-Process {}
        $PSCommandPath = ''
        { Ensure-Elevated } | Should -Throw '*script path for elevation*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}

Describe 'Get-ZoomExePath' {
    BeforeAll {
        $script:ProgramFilesZoom = Join-Path (Join-Path $script:Fake.ProgramFiles 'Zoom') 'bin/Zoom.exe'
    }

    BeforeEach {
        Mock Get-ItemProperty { throw 'no such registry key' }
        Mock Test-Path { $false }
    }

    It 'prefers the App Paths registry value' {
        Mock Get-ItemProperty { [pscustomobject]@{ '(default)' = 'D:\Zoom\bin\Zoom.exe' } }
        Mock Test-Path { $true }
        Get-ZoomExePath | Should -Be 'D:\Zoom\bin\Zoom.exe'
    }

    It 'falls back to the Program Files install when the registry lookup fails' {
        Mock Test-Path { $LiteralPath -eq $script:ProgramFilesZoom }
        Get-ZoomExePath | Should -Be $script:ProgramFilesZoom
    }

    It 'ignores an empty registry default value' {
        Mock Get-ItemProperty { [pscustomobject]@{ '(default)' = '' } }
        Mock Test-Path { $LiteralPath -eq $script:ProgramFilesZoom }
        Get-ZoomExePath | Should -Be $script:ProgramFilesZoom
    }

    It 'returns null when no candidate exists' {
        Get-ZoomExePath | Should -BeNullOrEmpty
    }

    It 'searches per-user install locations under C:\Users' {
        $userZoom = Join-Path 'C:\Users\bob' 'AppData\Local\Programs\Zoom\bin\Zoom.exe'
        Mock Get-ChildItem { @([pscustomobject]@{ FullName = 'C:\Users\bob' }) }
        Mock Test-Path { $LiteralPath -eq $userZoom }
        Get-ZoomExePath | Should -Be $userZoom
    }
}

Describe 'Remove-AccountAndProfile' {
    BeforeAll {
        $script:SandboxProfile = Join-Path $script:Fake.SystemDrive 'Users\Zoomie_12345'
    }

    BeforeEach {
        Mock Write-Step {}
        Mock Get-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock Remove-LocalUser {}
        Mock Get-CimInstance { $null }
        Mock Remove-CimInstance -RemoveParameterType InputObject {}
        Mock Remove-Item {}
        Mock Test-Path { $false }
    }

    It 'refuses to touch accounts outside the Zoomie_ namespace' -ForEach @(
        @{ UserName = 'Administrator' }
        @{ UserName = 'bob' }
        @{ UserName = 'NotZoomie_12345' }
        @{ UserName = '' }
    ) {
        Remove-AccountAndProfile -UserName $UserName
        Should -Invoke Get-LocalUser -Times 0 -Exactly
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'removes a sandbox local user' {
        Remove-AccountAndProfile -UserName 'Zoomie_12345'
        Should -Invoke Remove-LocalUser -Times 1 -Exactly -ParameterFilter { $Name -eq 'Zoomie_12345' }
    }

    It 'skips user removal when the account no longer exists' {
        Mock Get-LocalUser { $null }
        Remove-AccountAndProfile -UserName 'Zoomie_12345'
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
    }

    It 'warns instead of throwing when the account cannot be removed' {
        Mock Remove-LocalUser { throw 'account in use' }
        { Remove-AccountAndProfile -UserName 'Zoomie_12345' } | Should -Not -Throw
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*account in use*' }
    }

    It 'doubles every backslash in the WMI profile filter' {
        Remove-AccountAndProfile -UserName 'Zoomie_12345'
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_UserProfile' -and
            $Filter -eq ("LocalPath='{0}'" -f $script:SandboxProfile.Replace('\', '\\')) -and
            $Filter -notmatch '(?<!\\)\\(?!\\)'
        }
    }

    It 'purges the WMI profile and the profile folder' {
        Mock Get-CimInstance { [pscustomobject]@{ LocalPath = $script:SandboxProfile } }
        Mock Test-Path { $true }
        Remove-AccountAndProfile -UserName 'Zoomie_12345'
        Should -Invoke Remove-CimInstance -Times 1 -Exactly
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq $script:SandboxProfile -and $Recurse -and $Force
        }
    }

    It 'leaves the profile folder alone when it is already gone' {
        Remove-AccountAndProfile -UserName 'Zoomie_12345'
        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'warns instead of throwing when profile cleanup fails' {
        Mock Test-Path { $true }
        Mock Remove-Item { throw 'folder locked' }
        { Remove-AccountAndProfile -UserName 'Zoomie_12345' } | Should -Not -Throw
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*folder locked*' }
    }
}

Describe 'Ensure-RestrictedLocalAccount' {
    BeforeEach {
        Mock Write-Step {}
        Mock New-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock Add-LocalGroupMember -RemoveParameterType Member {}
        # An empty SecureString keeps the analyzer's plaintext-password rule quiet.
        $script:Password = [System.Security.SecureString]::new()
    }

    It 'creates a non-expiring sandbox account' {
        Ensure-RestrictedLocalAccount -UserName 'Zoomie_12345' -Password $script:Password
        Should -Invoke New-LocalUser -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Zoomie_12345' -and
            $FullName -eq 'Zoom Sandbox' -and
            $PasswordNeverExpires -and
            $AccountNeverExpires
        }
    }

    It 'keeps the account least privileged by joining only the Users group' {
        Ensure-RestrictedLocalAccount -UserName 'Zoomie_12345' -Password $script:Password
        Should -Invoke Add-LocalGroupMember -Times 1 -Exactly -ParameterFilter { $Group -eq 'Users' }
        Should -Invoke Add-LocalGroupMember -Times 0 -Exactly -ParameterFilter { $Group -eq 'Administrators' }
    }

    It 'keeps the description within the 48 character account limit' {
        Ensure-RestrictedLocalAccount -UserName 'Zoomie_12345' -Password $script:Password
        Should -Invoke New-LocalUser -ParameterFilter { $Description.Length -le 48 }
    }

    It 'swallows a failure to join the Users group' {
        Mock Add-LocalGroupMember -RemoveParameterType Member { throw 'group missing' }
        { Ensure-RestrictedLocalAccount -UserName 'Zoomie_12345' -Password $script:Password } | Should -Not -Throw
    }

    It 'propagates account creation failures' {
        Mock New-LocalUser { throw 'password policy' }
        { Ensure-RestrictedLocalAccount -UserName 'Zoomie_12345' -Password $script:Password } | Should -Throw '*password policy*'
    }
}

Describe 'Ensure-PathAclForUser' {
    BeforeEach {
        Mock Write-Step {}
        Mock icacls {}
    }

    It 'creates the sandbox directory when missing' {
        $target = Join-Path $TestDrive 'profiles/Zoomie_12345'
        Ensure-PathAclForUser -Path $target -UserName 'Zoomie_12345'
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It 'grants the sandbox user modify rights and administrators full control' {
        $target = Join-Path $TestDrive 'profiles/acl'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Ensure-PathAclForUser -Path $target -UserName 'Zoomie_12345'
        Should -Invoke icacls -Times 1 -Exactly -ParameterFilter {
            $args -contains 'TESTPC\Zoomie_12345:(OI)(CI)M' -and
            $args -contains 'Administrators:(OI)(CI)F' -and
            $args -contains '/inheritance:e' -and
            $args -contains '/grant:r'
        }
    }
}

Describe 'Ensure-DesktopShortcut' {
    BeforeEach {
        Mock Write-Step {}
        $script:FakeShell = New-FakeShortcutShell
        Mock New-Object { $script:FakeShell } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
    }

    It 'writes a Zoomie.lnk on the public desktop that relaunches in LaunchOnly mode' {
        Ensure-DesktopShortcut
        $script:FakeShell.RequestedPath |
            Should -Be (Join-Path (Join-Path $script:Fake.Public 'Desktop') 'Zoomie.lnk')
        $script:FakeShell.Shortcut.TargetPath | Should -Be "$script:ScriptDir\InstallZoomie-v1.2.0.exe"
        $script:FakeShell.Shortcut.Arguments | Should -Be '-LaunchOnly'
        $script:FakeShell.Shortcut.WindowStyle | Should -Be 1
        $script:FakeShell.Shortcut.Saved | Should -BeTrue
    }

    It 'replaces a stale shortcut before writing a new one' {
        $desktop = Join-Path $script:Fake.Public 'Desktop'
        New-Item -ItemType Directory -Path $desktop -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $desktop 'Zoomie.lnk') -Value 'stale'
        Mock Remove-Item {}
        Ensure-DesktopShortcut
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*Zoomie.lnk' }
    }

    It 'warns instead of throwing when the COM object is unavailable' {
        Mock New-Object { throw 'COM not registered' } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
        { Ensure-DesktopShortcut } | Should -Not -Throw
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'WARN' }
    }
}

Describe 'Test-FileIntegrity' {
    BeforeEach { Mock Write-Step {} }

    It 'returns false for a missing file' {
        Test-FileIntegrity -Path (Join-Path $TestDrive 'nope.msi') | Should -BeFalse
    }

    It 'reports the SHA-256 hash of an existing file' {
        $file = Join-Path $TestDrive 'payload.msi'
        Set-Content -LiteralPath $file -Value 'zoomie' -NoNewline
        $expected = (Get-FileHash -Path $file -Algorithm SHA256).Hash
        Test-FileIntegrity -Path $file | Should -BeTrue
        Should -Invoke Write-Step -ParameterFilter { $Message -eq "Computed SHA-256: $expected" }
    }
}

Describe 'Test-NeedsUpdate' {
    BeforeEach {
        Mock Write-Step {}
        $script:LocalFile = Join-Path $TestDrive 'ZoomInstallerFull.msi'
        $script:MetaFile = Join-Path $TestDrive 'zoom_msi.meta'
        Set-Content -LiteralPath $script:LocalFile -Value 'binary' -NoNewline
    }

    It 'needs an update when the local file is missing' {
        Mock Invoke-WebRequest {}
        Test-NeedsUpdate -Url 'https://zoom.us/x.msi' -LocalPath (Join-Path $TestDrive 'absent.msi') -MetaFile $script:MetaFile |
            Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'needs an update when no metadata has been recorded yet' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{ 'Last-Modified' = 'Mon, 01 Jan 2024 00:00:00 GMT' } } }
        Test-NeedsUpdate -Url 'https://zoom.us/x.msi' -LocalPath $script:LocalFile -MetaFile $script:MetaFile |
            Should -BeTrue
    }

    It 'needs an update when the CDN Last-Modified differs from the recorded value' {
        Set-Content -LiteralPath $script:MetaFile -Value 'Mon, 01 Jan 2024 00:00:00 GMT'
        Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{ 'Last-Modified' = 'Tue, 02 Jan 2024 00:00:00 GMT' } } }
        Test-NeedsUpdate -Url 'https://zoom.us/x.msi' -LocalPath $script:LocalFile -MetaFile $script:MetaFile |
            Should -BeTrue
    }

    It 'skips the download when the recorded value matches, ignoring surrounding whitespace' {
        Set-Content -LiteralPath $script:MetaFile -Value "  Mon, 01 Jan 2024 00:00:00 GMT `n"
        Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{ 'Last-Modified' = 'Mon, 01 Jan 2024 00:00:00 GMT' } } }
        Test-NeedsUpdate -Url 'https://zoom.us/x.msi' -LocalPath $script:LocalFile -MetaFile $script:MetaFile |
            Should -BeFalse
    }

    It 'issues a HEAD request rather than downloading the payload' {
        Set-Content -LiteralPath $script:MetaFile -Value 'Mon, 01 Jan 2024 00:00:00 GMT'
        Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{ 'Last-Modified' = 'Mon, 01 Jan 2024 00:00:00 GMT' } } }
        Test-NeedsUpdate -Url 'https://zoom.us/x.msi' -LocalPath $script:LocalFile -MetaFile $script:MetaFile | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Head' -and $UseBasicParsing
        }
    }

    It 'falls back to the local file when the CDN is unreachable' {
        Mock Invoke-WebRequest { throw 'DNS failure' }
        Test-NeedsUpdate -Url 'https://zoom.us/x.msi' -LocalPath $script:LocalFile -MetaFile $script:MetaFile |
            Should -BeFalse
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*CDN headers*' }
    }
}

Describe 'Script layout' {
    It 'keeps standard edition state separate from the DJ edition' {
        Get-ScriptVariableValue -Path $script:ScriptPath -Name StateDir |
            Should -Be (Join-Path $script:Fake.ProgramData 'Zoom1132')
    }

    It 'stores logs, profiles and the active user marker beneath the state directory' {
        $stateDir = Get-ScriptVariableValue -Path $script:ScriptPath -Name StateDir
        Get-ScriptVariableValue -Path $script:ScriptPath -Name LogDir | Should -Be (Join-Path $stateDir 'logs')
        Get-ScriptVariableValue -Path $script:ScriptPath -Name ProfilesDir | Should -Be (Join-Path $stateDir 'profiles')
        Get-ScriptVariableValue -Path $script:ScriptPath -Name StateFile | Should -Be (Join-Path $stateDir 'active_zoom_user.txt')
    }

    It 'timestamps the engine log file' {
        Get-ScriptVariableValue -Path $script:ScriptPath -Name LogFile |
            Should -Match 'engine_\d{4}-\d{2}-\d{2}_\d{6}\.log$'
    }
}

Describe 'Test-IsAdmin' -Skip:(-not $IsWindows) {
    It 'returns a boolean for the current identity' {
        Test-IsAdmin | Should -BeOfType [bool]
    }
}
