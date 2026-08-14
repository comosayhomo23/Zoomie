<#
.SYNOPSIS
Runs the Zoomie Pester suite.
.DESCRIPTION
The suite runs on Windows and on Linux/macOS: Windows-only cmdlets are stubbed
and mocked by tests/ZoomieTestHelpers.psm1, and the handful of assertions that
need real Windows APIs are skipped elsewhere.
.EXAMPLE
./tests/Invoke-ZoomieTests.ps1 -CI
#>
[CmdletBinding()]
param(
    # Emit NUnit/JaCoCo files under tests/results and exit non-zero on failure.
    [switch]$CI,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 5.5.0

$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Output.Verbosity = $Output

# Pester's code coverage is not enabled: the scripts are single-file executables
# whose main block installs Zoom and creates accounts, so the tests evaluate
# function definitions extracted from the AST rather than the files themselves,
# and the breakpoints Pester sets on those files would never be hit.

if ($CI) {
    $resultsDir = Join-Path $PSScriptRoot 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $configuration.Run.Exit = $true
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = Join-Path $resultsDir 'testResults.xml'
}

Invoke-Pester -Configuration $configuration
