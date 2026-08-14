Set-StrictMode -Version Latest

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'ZoomieTestHelpers.psm1') -Force
    $root = Get-ZoomieRepoRoot
    $script:Scripts = @(
        Get-ChildItem -Path $root -Filter '*.ps1' -File
        Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.ps1' -File
    ) | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

Describe 'Repository script conventions' -ForEach $script:Scripts {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $script:ParseErrors = $errors
        $script:Assignments = @($script:Ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    }

    It '<Name> parses without errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It '<Name> runs under Set-StrictMode -Version Latest' {
        $script:Ast.Extent.Text | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
    }

    It '<Name> makes every error terminating' {
        # A typo in this variable name silently degrades the scripts to
        # non-terminating errors, so assert on the assignment target itself.
        $preference = @($script:Assignments | Where-Object {
            $_.Left.Extent.Text -eq '$ErrorActionPreference' })
        $preference | Should -Not -BeNullOrEmpty
        $preference[0].Right.Extent.Text | Should -Be "'Stop'"
    }
}
