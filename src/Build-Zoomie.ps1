[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
$repoDir = if ((Split-Path -Leaf $scriptDir) -ieq 'src') { Split-Path -Parent $scriptDir } else { $scriptDir }
Set-Location -LiteralPath $repoDir

$srcDir = Join-Path $repoDir 'src'
$assetDir = Join-Path $repoDir 'assets'
$distDir = Join-Path $repoDir 'dist'
foreach ($directory in @($srcDir, $assetDir, $distDir)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -LiteralPath $directory -Force | Out-Null
    }
}

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe -Force

$enginePath = Join-Path $srcDir 'Zoomie-Engine.ps1'
$iconPath = Join-Path $assetDir 'Zoomies.ico'
$iconParameters = @{}
if (Test-Path -LiteralPath $iconPath) {
    $iconParameters = @{ IconFile = $iconPath }
}

function Set-CompiledInput {
    param(
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $header = "[CmdletBinding()]`r`nparam([switch]`$LaunchOnly)`r`n"
    $engine = Get-Content -LiteralPath $enginePath -Raw
    $entry = "`r`nInvoke-ZoomieEngine -Edition '$Edition' -LaunchOnly:`$LaunchOnly`r`n"
    Set-Content -LiteralPath $OutputPath -Value ($header + $engine + $entry) -Encoding utf8
}

function Invoke-EditionBuild {
    param(
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)][string]$OutputName,
        [Parameter(Mandatory)][hashtable]$Metadata
    )
    $outputPath = Join-Path $distDir $OutputName
    $temporaryPath = Join-Path $env:TEMP ("Zoomie-{0}.ps1" -f $Edition)
    try {
        Set-CompiledInput -Edition $Edition -OutputPath $temporaryPath
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        $parameters = @{
            InputFile = $temporaryPath
            OutputFile = $outputPath
            RequireAdmin = $true
            Title = $Metadata.Title
            Company = 'ComoLabs'
            Product = $Metadata.Product
            Version = '1.2.0.0'
        } + $iconParameters
        Invoke-ps2exe @parameters
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

Invoke-EditionBuild -Edition Standard -OutputName 'InstallZoomie-v1.2.0.exe' -Metadata @{
    Title = 'Zoomie Standard Edition'
    Product = 'Zoomie'
}
Invoke-EditionBuild -Edition DJ -OutputName 'InstallZoomie-DJ-v1.2.0.exe' -Metadata @{
    Title = 'Zoomie DJ/Webcam Edition'
    Product = 'Zoomie DJ'
}
