Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ZoomieTestHelpers.psm1') -Force
    Register-WindowsCommandStub

    $script:ScriptPath = Get-ZoomieScriptPath 'src/Uninstall-Zoomie.ps1'
    . (Get-ScriptFunctionDefinition -Path $script:ScriptPath)

    $script:Fake = Set-ZoomieFakeEnvironment -Root $TestDrive
}

Describe 'Remove-AllSandboxAccounts' {
    BeforeAll {
        $script:Users = @(
            [pscustomobject]@{ Name = 'Administrator' }
            [pscustomobject]@{ Name = 'Zoomie_12345' }
            [pscustomobject]@{ Name = 'Zoomie_1234' }
            [pscustomobject]@{ Name = 'Zoomie_123456' }
            [pscustomobject]@{ Name = 'zoomie_54321' }
            [pscustomobject]@{ Name = 'Zoomie_abcde' }
            [pscustomobject]@{ Name = 'Zoomie_99999' }
        )
    }

    BeforeEach {
        Mock Write-Step {}
        Mock Get-LocalUser { $script:Users }
        Mock Remove-LocalUser {}
        Mock Get-CimInstance { $null }
        Mock Remove-CimInstance {}
        Mock Remove-Item {}
        Mock Test-Path { $false }
    }

    It 'purges exactly the five digit Zoomie_ sandbox accounts' {
        Remove-AllSandboxAccounts
        Should -Invoke Remove-LocalUser -Times 3 -Exactly
        foreach ($expected in 'Zoomie_12345', 'zoomie_54321', 'Zoomie_99999') {
            Should -Invoke Remove-LocalUser -Times 1 -Exactly -ParameterFilter { $Name -eq $expected }
        }
    }

    It 'leaves non-sandbox and malformed account names untouched' {
        Remove-AllSandboxAccounts
        foreach ($unexpected in 'Administrator', 'Zoomie_1234', 'Zoomie_123456', 'Zoomie_abcde') {
            Should -Invoke Remove-LocalUser -Times 0 -Exactly -ParameterFilter { $Name -eq $unexpected }
        }
    }

    It 'keeps purging the remaining accounts after one removal fails' {
        Mock Remove-LocalUser { throw 'account in use' } -ParameterFilter { $Name -eq 'Zoomie_12345' }
        Remove-AllSandboxAccounts
        Should -Invoke Remove-LocalUser -Times 3 -Exactly
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*Zoomie_12345*' }
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'OK' -and $Message -eq 'Sandbox user cleanup complete.' }
    }

    It 'removes the WMI profile and profile folder of each sandbox account' {
        Mock Get-CimInstance { [pscustomobject]@{ LocalPath = 'stub' } }
        Mock Test-Path { $true }
        Remove-AllSandboxAccounts
        Should -Invoke Remove-CimInstance -Times 3 -Exactly
        Should -Invoke Remove-Item -Times 3 -Exactly -ParameterFilter { $Recurse -and $Force }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq (Join-Path $script:Fake.SystemDrive 'Users\Zoomie_12345')
        }
    }

    It 'doubles every backslash in the WMI profile filter' {
        Remove-AllSandboxAccounts
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_UserProfile' -and
            $Filter -eq ("LocalPath='{0}'" -f (Join-Path $script:Fake.SystemDrive 'Users\Zoomie_12345').Replace('\', '\\'))
        }
    }

    It 'warns instead of throwing when a profile folder cannot be deleted' {
        Mock Test-Path { $true }
        Mock Remove-Item { throw 'folder locked' }
        { Remove-AllSandboxAccounts } | Should -Not -Throw
        Should -Invoke Write-Step -Times 3 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -like 'Profile cleanup failed for *folder locked*'
        }
    }

    It 'completes quietly when no sandbox accounts are left' {
        Mock Get-LocalUser { @() }
        Remove-AllSandboxAccounts
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
        Should -Invoke Write-Step -ParameterFilter { $Level -eq 'OK' -and $Message -eq 'Sandbox user cleanup complete.' }
    }

    It 'tolerates a local user database that returns nothing' {
        Mock Get-LocalUser { }
        { Remove-AllSandboxAccounts } | Should -Not -Throw
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
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
    }

    It 'does not forward a -LaunchOnly switch, unlike the installers' {
        Get-ScriptFunctionDefinition -Path $script:ScriptPath -Name 'Ensure-Elevated' |
            Should -Not -Match 'LaunchOnly'
    }
}

Describe 'Purge targets' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
    }

    It 'purges the state directories of both editions' {
        $assignment = $script:Ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
              $args[0].Left.Extent.Text -eq '$GlobalStateDirs' }, $true) | Select-Object -First 1
        $dirs = & ([scriptblock]::Create($assignment.Right.Extent.Text))
        $dirs | Should -HaveCount 2
        $dirs | Should -Contain (Join-Path $script:Fake.ProgramData 'Zoom1132')
        $dirs | Should -Contain (Join-Path $script:Fake.ProgramData 'Zoom1132DJ')
    }

    It 'removes the desktop shortcuts of every edition, including the legacy name' {
        $assignment = $script:Ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
              $args[0].Left.Extent.Text -eq '$shortcuts' }, $true) | Select-Object -First 1
        $shortcuts = & ([scriptblock]::Create($assignment.Right.Extent.Text))
        $shortcuts | Should -Be @('Zoomie.lnk', 'Zoomie DJ.lnk', 'ZOOM.WTF.lnk')
    }
}
