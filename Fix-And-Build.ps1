[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Define paths based on your current correctly organized layout
$ScriptDir = "C:\Project Files"
$SrcDir    = Join-Path $ScriptDir "src"
$AssetDir  = Join-Path $ScriptDir "assets"
$DistDir   = Join-Path $ScriptDir "dist"

Set-Location $ScriptDir

# Ensure output directory exists
if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Building Zoomie v1.2.0 Suite..." -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Verify/Install ps2exe module
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host "[INFO] Installing ps2exe module..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe -Force

# 2. Check for icon in assets/
$IconPath = Join-Path $AssetDir "Zoomies.ico"
$IconParam = @{}
if (Test-Path $IconPath) {
    $IconParam = @{ IconFile = $IconPath }
    Write-Host "[OK] Found custom icon: assets\Zoomies.ico" -ForegroundColor Green
} else {
    Write-Host "[WARN] Icon file not found in assets/. Compiling without custom icon." -ForegroundColor Yellow
}

# 3. Build Standard Edition
$StandardPs1 = Join-Path $SrcDir "InstallZoomie-v1.2.0.ps1"
$StandardExe = Join-Path $DistDir "InstallZoomie-v1.2.0.exe"

if (Test-Path $StandardPs1) {
    Write-Host "`n[BUILDING] Standard Edition -> dist\" -ForegroundColor Green
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
    Write-Host "[OK] Successfully compiled dist\InstallZoomie-v1.2.0.exe" -ForegroundColor Green
} else {
    Write-Host "[WARN] Source script $StandardPs1 not found in src\. Skipping." -ForegroundColor Yellow
}

# 4. Build DJ & Webcam Edition
$DjPs1 = Join-Path $SrcDir "InstallZoomie-DJ-v1.2.0.ps1"
$DjExe = Join-Path $DistDir "InstallZoomie-DJ-v1.2.0.exe"

if (Test-Path $DjPs1) {
    Write-Host "`n[BUILDING] DJ Edition -> dist\" -ForegroundColor Green
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
    Write-Host "[OK] Successfully compiled dist\InstallZoomie-DJ-v1.2.0.exe" -ForegroundColor Green
} else {
    Write-Host "[WARN] Source script $DjPs1 not found in src\. Skipping." -ForegroundColor Yellow
}

# 5. Build Dedicated Uninstaller
$UninstPs1 = Join-Path $SrcDir "Uninstall-Zoomie.ps1"
$UninstExe = Join-Path $DistDir "Uninstall-Zoomie.exe"

if (Test-Path $UninstPs1) {
    Write-Host "`n[BUILDING] Dedicated Uninstaller -> dist\" -ForegroundColor Green
    Remove-Item -LiteralPath $UninstExe -Force -ErrorAction SilentlyContinue
    
    $uninstParams = @{
        InputFile      = $UninstPs1
        OutputFile     = $UninstExe
        RequireAdmin   = $true
        Title          = "Zoomie Uninstaller"
        Company        = "ComoLabs"
        Product        = "Zoomie"
        version        = "1.2.0.0"
    } + $IconParam

    Invoke-ps2exe @uninstParams
    Write-Host "[OK] Successfully compiled dist\Uninstall-Zoomie.exe" -ForegroundColor Green
} else {
    Write-Host "[WARN] Source script $UninstPs1 not found in src\. Skipping Uninstaller build." -ForegroundColor Yellow
}

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host " Build Complete! All binaries located in /dist" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan