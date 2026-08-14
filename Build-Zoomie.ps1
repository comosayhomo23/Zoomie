[CmdletBinding()]
param(
    [string]$Version = '1.2.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
Set-Location $ScriptDir

. (Join-Path $ScriptDir 'src\Zoomie.Common.ps1')

$SrcDir   = Join-Path $ScriptDir 'src'
$AssetDir = Join-Path $ScriptDir 'assets'
$DistDir  = Join-Path $ScriptDir 'dist'
$BuildDir = Join-Path $env:TEMP 'ZoomieBuild'

New-ZoomieDirectory -Path @($SrcDir, $AssetDir, $DistDir, $BuildDir)

function New-BundledScript {
    <#
        Replaces "# zoomie:inline" dot-source markers with the contents of the
        referenced file so ps2exe produces a self-contained executable.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$OutputDir)

    $bundled = foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match "^\s*\.\s*\(Join-Path .*?'([^']+)'\)\s*#\s*zoomie:inline\s*$") {
            $includePath = Join-Path (Split-Path $Path -Parent) $Matches[1]
            if (-not (Test-Path -LiteralPath $includePath)) { throw "Include not found: $includePath" }
            Write-Host ("[INLINE] {0} -> {1}" -f $Matches[1], (Split-Path $Path -Leaf)) -ForegroundColor DarkGray
            Get-Content -LiteralPath $includePath
        } else {
            $line
        }
    }

    $outputPath = Join-Path $OutputDir (Split-Path $Path -Leaf)
    Set-Content -LiteralPath $outputPath -Value $bundled -Encoding utf8 -Force
    return $outputPath
}

Write-Banner -Message ("Building Zoomie v{0} Suite..." -f $Version)

# 1. Verify/Install ps2exe module
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host '[INFO] Installing ps2exe module...' -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe -Force

# 2. Check for icon in assets/
$IconPath = Join-Path $AssetDir 'Zoomies.ico'
$IconParam = @{}
if (Test-Path -LiteralPath $IconPath) {
    $IconParam = @{ IconFile = $IconPath }
    Write-Host '[OK] Found custom icon: assets\Zoomies.ico' -ForegroundColor Green
} else {
    Write-Host "[WARN] Icon file not found at $IconPath. Compiling without custom icon." -ForegroundColor Yellow
}

# 3. Compile every edition from a single definition
$Targets = @(
    @{ Label = 'Standard Edition';   Script = "InstallZoomie-v$Version.ps1";    Title = 'Zoomie Standard Edition';   Product = 'Zoomie' }
    @{ Label = 'DJ Edition';         Script = "InstallZoomie-DJ-v$Version.ps1"; Title = 'Zoomie DJ/Webcam Edition';  Product = 'Zoomie DJ' }
    @{ Label = 'Uninstaller';        Script = 'Uninstall-Zoomie.ps1';           Title = 'Zoomie Uninstaller';        Product = 'Zoomie' }
)

foreach ($target in $Targets) {
    $sourcePath = Join-Path $SrcDir $target.Script
    $exeName = [System.IO.Path]::ChangeExtension($target.Script, 'exe')
    $exePath = Join-Path $DistDir $exeName

    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Host ("[WARN] Source script {0} not found in src\. Skipping." -f $target.Script) -ForegroundColor Yellow
        continue
    }

    Write-Host ("`n[BUILDING] {0} -> dist\{1}" -f $target.Label, $exeName) -ForegroundColor Green
    Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue

    $params = @{
        InputFile    = New-BundledScript -Path $sourcePath -OutputDir $BuildDir
        OutputFile   = $exePath
        RequireAdmin = $true
        Title        = $target.Title
        Company      = 'ComoLabs'
        Product      = $target.Product
        version      = "$Version.0"
    } + $IconParam

    Invoke-ps2exe @params
    Write-Host ("[OK] Successfully compiled dist\{0}" -f $exeName) -ForegroundColor Green
}

Write-Host ''
Write-Banner -Message 'Build Complete! All binaries located in /dist'
