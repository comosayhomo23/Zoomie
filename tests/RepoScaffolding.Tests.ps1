Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ZoomieTestHelpers.psm1') -Force

    function New-ScriptCopy {
        <# Copies a repository script into an isolated root so its side effects stay there. #>
        param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $destination = Join-Path $Root (Split-Path $Script -Leaf)
        Copy-Item -LiteralPath (Get-ZoomieScriptPath $Script) -Destination $destination -Force
        $destination
    }
}

Describe 'Move-ZoomieFiles.ps1' {
    BeforeEach {
        Mock Write-Host {}
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $script:Organize = New-ScriptCopy -Script 'Move-ZoomieFiles.ps1' -Root $script:Root
        foreach ($name in 'InstallZoomie-v1.2.0.ps1', 'InstallZoomie-DJ-v1.2.0.ps1', 'Uninstall-Zoomie.ps1',
                          'Build-Zoomie.ps1', 'Init-ZoomieRepo.ps1',
                          'Zoomies.ico', 'InstallZoomie-v1.2.0.exe', 'CleanZoom.exe') {
            Set-Content -LiteralPath (Join-Path $script:Root $name) -Value 'payload'
        }
        Push-Location $TestDrive
    }

    AfterEach { Pop-Location }

    It 'creates the src, assets and dist directories' {
        . $script:Organize
        foreach ($dir in 'src', 'assets', 'dist') {
            Join-Path $script:Root $dir | Should -Exist
        }
    }

    It 'moves the product scripts into src' {
        . $script:Organize
        foreach ($name in 'InstallZoomie-v1.2.0.ps1', 'InstallZoomie-DJ-v1.2.0.ps1', 'Uninstall-Zoomie.ps1') {
            Join-Path $script:Root "src/$name" | Should -Exist
            Join-Path $script:Root $name | Should -Not -Exist
        }
    }

    It 'keeps the build and repository tooling scripts in the root' {
        . $script:Organize
        foreach ($name in 'Build-Zoomie.ps1', 'Init-ZoomieRepo.ps1', 'Move-ZoomieFiles.ps1') {
            Join-Path $script:Root $name | Should -Exist
            Join-Path $script:Root "src/$name" | Should -Not -Exist
        }
    }

    It 'moves icons into assets' {
        . $script:Organize
        Join-Path $script:Root 'assets/Zoomies.ico' | Should -Exist
        Join-Path $script:Root 'Zoomies.ico' | Should -Not -Exist
    }

    It 'moves only the InstallZoomie executables into dist' {
        . $script:Organize
        Join-Path $script:Root 'dist/InstallZoomie-v1.2.0.exe' | Should -Exist
        Join-Path $script:Root 'CleanZoom.exe' | Should -Exist
        Join-Path $script:Root 'dist/CleanZoom.exe' | Should -Not -Exist
    }

    It 'overwrites a stale copy already present in src' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'src/Uninstall-Zoomie.ps1') -Value 'stale'
        . $script:Organize
        Get-Content -LiteralPath (Join-Path $script:Root 'src/Uninstall-Zoomie.ps1') -Raw |
            Should -Match 'payload'
    }

    It 'is idempotent when there is nothing left to organize' {
        . $script:Organize
        { . $script:Organize } | Should -Not -Throw
        Get-ChildItem -Path (Join-Path $script:Root 'src') -Filter '*.ps1' -File |
            Should -HaveCount 3
    }
}

Describe 'Init-ZoomieRepo.ps1' {
    BeforeEach {
        Mock Write-Host {}
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $script:Init = New-ScriptCopy -Script 'Init-ZoomieRepo.ps1' -Root $script:Root
        Push-Location $TestDrive
    }

    AfterEach { Pop-Location }

    It 'scaffolds the workflow, assets, dist and src directories' {
        . $script:Init
        foreach ($dir in '.github\workflows', 'assets', 'dist', 'src') {
            Join-Path $script:Root $dir | Should -Exist
        }
    }

    It 'creates the .gitignore, README.md and CHANGELOG.md templates' {
        . $script:Init
        foreach ($file in '.gitignore', 'README.md', 'CHANGELOG.md') {
            Join-Path $script:Root $file | Should -Exist
        }
    }

    It 'ignores the runtime state that the installers write' {
        . $script:Init
        $gitignore = Get-Content -LiteralPath (Join-Path $script:Root '.gitignore') -Raw
        foreach ($pattern in 'logs/', 'profiles/', '*.log', '*.meta', 'active_zoom_user.txt',
                             'ZoomInstallerFull.msi', 'CleanZoom.exe', 'CleanZoom.zip') {
            $gitignore | Should -BeLike ("*{0}*" -f $pattern)
        }
    }

    It 'documents both editions in the generated README' {
        . $script:Init
        $readme = Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Raw
        $readme | Should -BeLike '*InstallZoomie-v1.2.0.exe*'
        $readme | Should -BeLike '*InstallZoomie-DJ-v1.2.0.exe*'
    }

    It 'never overwrites existing files or directories' {
        $existing = Join-Path $script:Root 'README.md'
        Set-Content -LiteralPath $existing -Value 'hand written'
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'src/keep.ps1') -Value 'keep'

        . $script:Init

        Get-Content -LiteralPath $existing -Raw | Should -Match 'hand written'
        Join-Path $script:Root 'src/keep.ps1' | Should -Exist
        Should -Invoke Write-Host -ParameterFilter { $Object -like '`[EXISTS`]*README.md*' }
    }

    It 'is safe to re-run on an already scaffolded repository' {
        . $script:Init
        { . $script:Init } | Should -Not -Throw
    }
}
