[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
Set-Location $ScriptDir

$script:Failures = [System.Collections.Generic.List[string]]::new()

function Invoke-Ps2ExeBuild {
    param(
        [hashtable]$Parameters,
        [string]$Label
    )
    try {
        Invoke-ps2exe @Parameters
    } catch {
        throw ("{0}: ps2exe failed: {1}" -f $Label, $_.Exception.Message)
    }
    if (-not (Test-Path -LiteralPath $Parameters.OutputFile)) {
        throw ("{0}: ps2exe reported no error but {1} was not produced." -f $Label, $Parameters.OutputFile)
    }
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Building Zoomie v1.2.0 Executables..." -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Verify/Install ps2exe module
try {
    if (-not (Get-Module -ListAvailable ps2exe)) {
        Write-Host "[INFO] Installing ps2exe module..." -ForegroundColor Yellow
        Install-Module ps2exe -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module ps2exe -Force -ErrorAction Stop
} catch {
    Write-Host ("[FATAL] ps2exe is unavailable, so nothing can be compiled: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

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

    try {
        Invoke-Ps2ExeBuild -Parameters $params -Label 'Standard Edition'
        Write-Host "[OK] Successfully compiled $StandardExe" -ForegroundColor Green
    } catch {
        [void]$script:Failures.Add($_.Exception.Message)
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
} else {
    [void]$script:Failures.Add("Source script $StandardPs1 not found.")
    Write-Host "[ERROR] Source script $StandardPs1 not found. Skipping." -ForegroundColor Red
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

    try {
        Invoke-Ps2ExeBuild -Parameters $params -Label 'DJ Edition'
        Write-Host "[OK] Successfully compiled $DjExe" -ForegroundColor Green
    } catch {
        [void]$script:Failures.Add($_.Exception.Message)
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
} else {
    [void]$script:Failures.Add("Source script $DjPs1 not found.")
    Write-Host "[ERROR] Source script $DjPs1 not found. Skipping." -ForegroundColor Red
}

if ($script:Failures.Count -gt 0) {
    Write-Host "`n====================================================" -ForegroundColor Red
    Write-Host (" Build FAILED with {0} problem(s):" -f $script:Failures.Count) -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host (" - {0}" -f $failure) -ForegroundColor Red }
    Write-Host "====================================================" -ForegroundColor Red
    exit 1
}

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host " Build Process Complete!" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan