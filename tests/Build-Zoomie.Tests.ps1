Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ZoomieTestHelpers.psm1') -Force
    Register-WindowsCommandStub
    Import-Module PowerShellGet -ErrorAction SilentlyContinue

    function New-BuildSandbox {
        <# Lays out a repository copy (script + src/assets) under the test drive. #>
        param(
            [Parameter(Mandatory)][string]$Script,
            [Parameter(Mandatory)][string]$Root,
            [string[]]$Source = @('InstallZoomie-v1.2.0.ps1', 'InstallZoomie-DJ-v1.2.0.ps1', 'Uninstall-Zoomie.ps1'),
            [switch]$WithIcon
        )

        New-Item -ItemType Directory -Path (Join-Path $Root 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root 'assets') -Force | Out-Null
        Copy-Item -LiteralPath (Get-ZoomieScriptPath $Script) -Destination (Join-Path $Root (Split-Path $Script -Leaf)) -Force
        foreach ($name in $Source) {
            Set-Content -LiteralPath (Join-Path $Root "src/$name") -Value '# placeholder'
        }
        if ($WithIcon) {
            Set-Content -LiteralPath (Join-Path $Root 'assets/Zoomies.ico') -Value 'icon'
        }
        Join-Path $Root (Split-Path $Script -Leaf)
    }
}

Describe 'src/Build-Zoomie.ps1' {
    BeforeEach {
        Mock Write-Host {}
        Mock Install-Module {}
        Mock Import-Module {}
        Mock Invoke-ps2exe {}
        # Mocked last: the mock hides PowerShellGet from Pester's own lookups.
        Mock Get-Module { $null }

        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $script:Build = New-BuildSandbox -Script 'src/Build-Zoomie.ps1' -Root $script:Root
        Push-Location $TestDrive
    }

    AfterEach { Pop-Location }

    It 'creates the src, assets and dist directories' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'assets') -Recurse -Force
        . $script:Build
        foreach ($dir in 'src', 'assets', 'dist') {
            Join-Path $script:Root $dir | Should -Exist
        }
    }

    It 'installs ps2exe only when the module is missing' {
        . $script:Build
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'ps2exe' }

        Mock Get-Module { [pscustomobject]@{ Name = 'ps2exe' } }
        . $script:Build
        Should -Invoke Install-Module -Times 1 -Exactly
    }

    It 'imports ps2exe before compiling' {
        . $script:Build
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'ps2exe' -and $Force }
    }

    It 'compiles the standard and DJ editions into dist' {
        . $script:Build
        Should -Invoke Invoke-ps2exe -Times 2 -Exactly
        Should -Invoke Invoke-ps2exe -Times 1 -Exactly -ParameterFilter {
            $InputFile -eq (Join-Path $script:Root 'src/InstallZoomie-v1.2.0.ps1') -and
            $OutputFile -eq (Join-Path $script:Root 'dist/InstallZoomie-v1.2.0.exe') -and
            $Title -eq 'Zoomie Standard Edition' -and $Product -eq 'Zoomie'
        }
        Should -Invoke Invoke-ps2exe -Times 1 -Exactly -ParameterFilter {
            $InputFile -eq (Join-Path $script:Root 'src/InstallZoomie-DJ-v1.2.0.ps1') -and
            $OutputFile -eq (Join-Path $script:Root 'dist/InstallZoomie-DJ-v1.2.0.exe') -and
            $Title -eq 'Zoomie DJ/Webcam Edition' -and $Product -eq 'Zoomie DJ'
        }
    }

    It 'requires administrator rights and stamps the version on every binary' {
        . $script:Build
        Should -Invoke Invoke-ps2exe -Times 2 -Exactly -ParameterFilter {
            $RequireAdmin -and $Version -eq '1.2.0.0' -and $Company -eq 'ComoLabs'
        }
    }

    It 'passes the custom icon only when assets/Zoomies.ico exists' {
        . $script:Build
        Should -Invoke Invoke-ps2exe -Times 0 -Exactly -ParameterFilter { $IconFile }

        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $script:Build = New-BuildSandbox -Script 'src/Build-Zoomie.ps1' -Root $script:Root -WithIcon
        . $script:Build
        Should -Invoke Invoke-ps2exe -Times 2 -Exactly -ParameterFilter {
            $IconFile -eq (Join-Path $script:Root 'assets/Zoomies.ico')
        }
    }

    It 'replaces a stale executable before compiling' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'dist') -Force | Out-Null
        $stale = Join-Path $script:Root 'dist/InstallZoomie-v1.2.0.exe'
        Set-Content -LiteralPath $stale -Value 'old build'
        . $script:Build
        $stale | Should -Not -Exist
    }

    It 'skips an edition whose source script is missing instead of failing the build' {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $script:Build = New-BuildSandbox -Script 'src/Build-Zoomie.ps1' -Root $script:Root -Source @('InstallZoomie-v1.2.0.ps1')
        { . $script:Build } | Should -Not -Throw
        Should -Invoke Invoke-ps2exe -Times 1 -Exactly
        Should -Invoke Write-Host -ParameterFilter { $Object -like '`[WARN`] Source script*not found*' }
    }
}

Describe 'Fix-And-Build.ps1' {
    BeforeEach {
        Mock Write-Host {}
        Mock Install-Module {}
        Mock Import-Module {}
        Mock Invoke-ps2exe {}
        # Mocked last: the mock hides PowerShellGet from Pester's own lookups.
        Mock Get-Module { $null }

        # The script hard-codes C:\Project Files as the repository root.
        Register-FakeSystemDrive -Root (Join-Path $TestDrive 'cdrive')
        $script:Root = 'C:\Project Files'
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        $script:Build = New-BuildSandbox -Script 'Fix-And-Build.ps1' -Root $script:Root
        Push-Location $TestDrive
    }

    AfterEach { Pop-Location }

    It 'also compiles the dedicated uninstaller, unlike src/Build-Zoomie.ps1' {
        . $script:Build
        Should -Invoke Invoke-ps2exe -Times 3 -Exactly
        Should -Invoke Invoke-ps2exe -Times 1 -Exactly -ParameterFilter {
            $InputFile -eq (Join-Path $script:Root 'src/Uninstall-Zoomie.ps1') -and
            $OutputFile -eq (Join-Path $script:Root 'dist/Uninstall-Zoomie.exe') -and
            $Title -eq 'Zoomie Uninstaller' -and $RequireAdmin
        }
    }

    It 'creates the dist directory under the hard-coded project root' {
        . $script:Build
        Join-Path $script:Root 'dist' | Should -Exist
    }

    It 'skips the uninstaller build when its source is missing' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'src/Uninstall-Zoomie.ps1') -Force
        . $script:Build
        Should -Invoke Invoke-ps2exe -Times 2 -Exactly
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Skipping Uninstaller build.*' }
    }
}
