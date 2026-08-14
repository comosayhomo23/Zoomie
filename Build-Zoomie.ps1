[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
Set-Location $ScriptDir

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Building Zoomie v1.2.0 Executables..." -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Verify/Install ps2exe module
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host "[INFO] Installing ps2exe module..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe -Force

# 2. Check for icon
$IconPath = Join-Path $ScriptDir "Zoomies.ico"
$IconParam = @{}
if (Test-Path $IconPath) {
    $IconParam = @{ IconFile = $IconPath }
    Write-Host "[OK] Found custom icon: Zoomies.ico" -ForegroundColor Green
} else {
    Write-Host "[WARN] Icon file not found. Compiling without custom icon." -ForegroundColor Yellow
}

# 3. Build Standard Edition
$StandardPs1 = "InstallZoomie-v1.2.0.ps1"
$StandardExe = "InstallZoomie-v1.2.0.exe"

if (Test-Path $StandardPs1) {
    Write-Host "`n[BUILDING] $StandardExe..." -ForegroundColor Green
    Remove-Item -LiteralPath $StandardExe -Force -ErrorAction SilentlyContinue
    
    $params = @{
        InputFile      = $StandardPs1
        OutputFile     = $StandardExe
        RequireAdmin   = $true
        Title          = "Zoomie Standard Edition"
        Company        = "ComoLabs"
        Product        = "Zoomie"
        version        = "1.2.0.0"
    } + $IconParam

    Invoke-ps2exe @params
    Write-Host "[OK] Successfully compiled $StandardExe" -ForegroundColor Green
} else {
    Write-Host "[WARN] Source script $StandardPs1 not found. Skipping." -ForegroundColor Yellow
}

# 4. Build DJ & Webcam Edition
$DjPs1 = "InstallZoomie-DJ-v1.2.0.ps1"
$DjExe = "InstallZoomie-DJ-v1.2.0.exe"

if (Test-Path $DjPs1) {
    Write-Host "`n[BUILDING] $DjExe..." -ForegroundColor Green
    Remove-Item -LiteralPath $DjExe -Force -ErrorAction SilentlyContinue
    
    $params = @{
        InputFile      = $DjPs1
        OutputFile     = $DjExe
        RequireAdmin   = $true
        Title          = "Zoomie DJ/Webcam Edition"
        Company        = "ComoLabs"
        Product        = "Zoomie DJ"
        version        = "1.2.0.0"
    } + $IconParam

    Invoke-ps2exe @params
    Write-Host "[OK] Successfully compiled $DjExe" -ForegroundColor Green
} else {
    Write-Host "[WARN] Source script $DjPs1 not found. Skipping." -ForegroundColor Yellow
}

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host " Build Process Complete!" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan