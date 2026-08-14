[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
Set-Location $ScriptDir

. (Join-Path $ScriptDir 'src\Zoomie.Common.ps1')

Write-Banner -Message 'Organizing Zoomie Repository Files...'

$SrcDir  = Join-Path $ScriptDir "src"
$AssetDir= Join-Path $ScriptDir "assets"
$DistDir = Join-Path $ScriptDir "dist"

New-ZoomieDirectory -Path @($SrcDir, $AssetDir, $DistDir)

# 1. Move source PowerShell scripts (excluding builder, init, and organizer scripts)
$psFiles = Get-ChildItem -Path $ScriptDir -Filter "*.ps1" -File
foreach ($file in $psFiles) {
    if ($file.Name -notin @('Build-Zoomie.ps1', 'Init-ZoomieRepo.ps1', 'Move-ZoomieFiles.ps1', 'Zoomie.Common.ps1')) {
        $dest = Join-Path $SrcDir $file.Name
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force
        Write-Host "[MOVED] Script -> src\$($file.Name)" -ForegroundColor Green
    }
}

# 2. Move icon files to assets/
$icoFiles = Get-ChildItem -Path $ScriptDir -Filter "*.ico" -File
foreach ($file in $icoFiles) {
    $dest = Join-Path $AssetDir $file.Name
    Move-Item -LiteralPath $file.FullName -Destination $dest -Force
    Write-Host "[MOVED] Icon -> assets\$($file.Name)" -ForegroundColor Green
}

# 3. Move compiled Zoomie executables to dist/
$exeFiles = Get-ChildItem -Path $ScriptDir -Filter "*.exe" -File
foreach ($file in $exeFiles) {
    if ($file.Name -match 'InstallZoomie') {
        $dest = Join-Path $DistDir $file.Name
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force
        Write-Host "[MOVED] Executable -> dist\$($file.Name)" -ForegroundColor Green
    }
}

Write-Host ''
Write-Banner -Message 'File Organization Complete!'