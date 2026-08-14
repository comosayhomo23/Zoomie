Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ZoomieTestHelpers.psm1') -Force
    Register-WindowsCommandStub

    $script:ScriptPath = Get-ZoomieScriptPath 'src/InstallZoomie-DJ-v1.2.0.ps1'
    $script:StandardPath = Get-ZoomieScriptPath 'src/InstallZoomie-v1.2.0.ps1'
    . (Get-ScriptFunctionDefinition -Path $script:ScriptPath)

    $script:Fake = Set-ZoomieFakeEnvironment -Root $TestDrive

    $script:StateDir    = Join-Path $script:Fake.ProgramData 'Zoom1132DJ'
    $script:LogDir      = Join-Path $script:StateDir 'logs'
    $script:ProfilesDir = Join-Path $script:StateDir 'profiles'
    $script:StateFile   = Join-Path $script:StateDir 'active_zoom_user.txt'
    $script:LogFile     = Join-Path $script:LogDir 'engine_dj_test.log'
    $script:ScriptDir   = Join-Path $TestDrive 'app'

    # Normally the -LaunchOnly switch parameter of the script itself.
    $script:LaunchOnly  = [switch]$false
}

Describe 'Ensure-AdminSandboxAccount' {
    BeforeEach {
        Mock Write-Step {}
        Mock New-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock Add-LocalGroupMember {}
        # An empty SecureString keeps the analyzer's plaintext-password rule quiet.
        $script:Password = [System.Security.SecureString]::new()
    }

    It 'creates a non-expiring sandbox account labelled for the DJ edition' {
        Ensure-AdminSandboxAccount -UserName 'Zoomie_12345' -Password $script:Password
        Should -Invoke New-LocalUser -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Zoomie_12345' -and
            $FullName -eq 'Zoom DJ Sandbox' -and
            $PasswordNeverExpires -and
            $AccountNeverExpires
        }
    }

    It 'elevates the sandbox account into the Administrators group' {
        Ensure-AdminSandboxAccount -UserName 'Zoomie_12345' -Password $script:Password
        Should -Invoke Add-LocalGroupMember -Times 1 -Exactly -ParameterFilter {
            $Group -eq 'Administrators' -and $Member -eq 'Zoomie_12345'
        }
    }

    It 'keeps the description within the 48 character account limit' {
        Ensure-AdminSandboxAccount -UserName 'Zoomie_12345' -Password $script:Password
        Should -Invoke New-LocalUser -ParameterFilter { $Description.Length -le 48 }
    }

    It 'warns instead of throwing when the group membership cannot be granted' {
        Mock Add-LocalGroupMember { throw 'group missing' }
        { Ensure-AdminSandboxAccount -UserName 'Zoomie_12345' -Password $script:Password } | Should -Not -Throw
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*group missing*' }
    }

    It 'propagates account creation failures' {
        Mock New-LocalUser { throw 'password policy' }
        { Ensure-AdminSandboxAccount -UserName 'Zoomie_12345' -Password $script:Password } | Should -Throw '*password policy*'
    }
}

Describe 'Ensure-DesktopShortcut' {
    BeforeEach {
        Mock Write-Step {}
        $script:FakeShell = New-FakeShortcutShell
        Mock New-Object { $script:FakeShell } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
    }

    It 'writes a separate "Zoomie DJ.lnk" so both editions can coexist' {
        Ensure-DesktopShortcut
        $script:FakeShell.RequestedPath |
            Should -Be (Join-Path (Join-Path $script:Fake.Public 'Desktop') 'Zoomie DJ.lnk')
        $script:FakeShell.Shortcut.TargetPath | Should -Be "$script:ScriptDir\InstallZoomie-DJ-v1.2.0.exe"
        $script:FakeShell.Shortcut.Arguments | Should -Be '-LaunchOnly'
        $script:FakeShell.Shortcut.IconLocation | Should -Be (Join-Path $script:ScriptDir 'Zoomies.ico')
        $script:FakeShell.Shortcut.Saved | Should -BeTrue
    }

    It 'warns instead of throwing when the COM object is unavailable' {
        Mock New-Object { throw 'COM not registered' } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
        { Ensure-DesktopShortcut } | Should -Not -Throw
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'WARN' }
    }
}

Describe 'Start-Logging' {
    BeforeEach {
        Mock Write-Step {}
        Mock Start-Transcript {}
    }

    It 'creates the state directories before starting the transcript' {
        Start-Logging
        Test-Path -LiteralPath $script:LogDir | Should -BeTrue
        Should -Invoke Start-Transcript -Times 1 -Exactly -ParameterFilter {
            $Path -eq $script:LogFile -and $Append
        }
    }

    It 'records the edition, user and mode in the log header' {
        Start-Logging
        Should -Invoke Write-Step -ParameterFilter { $Message -eq 'InstallZoomie-DJ-v1.2.0.ps1' }
        Should -Invoke Write-Step -ParameterFilter { $Message -like 'User=*Computer=TESTPC' }
        Should -Invoke Write-Step -ParameterFilter { $Message -like 'LaunchOnlyMode=*' }
    }
}

Describe 'Stop-Logging' {
    It 'ignores the error raised when no transcript is running' {
        Mock Stop-Transcript { throw 'no transcript' }
        { Stop-Logging } | Should -Not -Throw
    }
}

Describe 'Script layout' {
    It 'isolates DJ state from the standard edition' {
        Get-ScriptVariableValue -Path $script:ScriptPath -Name StateDir |
            Should -Be (Join-Path $script:Fake.ProgramData 'Zoom1132DJ')
    }

    It 'prefixes the DJ engine log so both editions keep separate logs' {
        Get-ScriptVariableValue -Path $script:ScriptPath -Name LogFile |
            Should -Match 'engine_dj_\d{4}-\d{2}-\d{2}_\d{6}\.log$'
    }
}

Describe 'Edition parity' {
    # Both editions ship as standalone single-file scripts, so the shared
    # helpers are copied verbatim. These tests fail when one copy drifts.
    It 'shares an identical <_> implementation with the standard edition' -ForEach @(
        'Write-Step'
        'Test-IsAdmin'
        'Ensure-Elevated'
        'Ensure-Dirs'
        'Stop-Logging'
        'Get-ZoomExePath'
        'Remove-AccountAndProfile'
        'Ensure-PathAclForUser'
        'Test-FileIntegrity'
        'Test-NeedsUpdate'
    ) {
        $dj = (Get-ScriptFunctionDefinition -Path $script:ScriptPath -Name $_).ToString()
        $standard = (Get-ScriptFunctionDefinition -Path $script:StandardPath -Name $_).ToString()
        $dj | Should -Be $standard
    }

    It 'provisions accounts through an edition specific function' {
        { Get-ScriptFunctionDefinition -Path $script:ScriptPath -Name 'Ensure-RestrictedLocalAccount' } |
            Should -Throw '*Ensure-RestrictedLocalAccount*'
        { Get-ScriptFunctionDefinition -Path $script:StandardPath -Name 'Ensure-AdminSandboxAccount' } |
            Should -Throw '*Ensure-AdminSandboxAccount*'
    }
}
