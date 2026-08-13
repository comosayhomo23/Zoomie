[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
Set-Location $ScriptDir

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Initializing Zoomie GitHub Repository Structure..." -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Create required directories
$dirs = @(
    ".github\workflows",
    "assets",
    "dist",
    "src"
)

foreach ($dir in $dirs) {
    $targetPath = Join-Path $ScriptDir $dir
    if (-not (Test-Path $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        Write-Host "[CREATED] Directory: $dir" -ForegroundColor Green
    } else {
        Write-Host "[EXISTS]  Directory: $dir" -ForegroundColor Yellow
    }
}

# 2. Create core template files if missing
$files = @{
    ".gitignore" = @"
# Logs and state data
logs/
profiles/
*.log
*.meta
active_zoom_user.txt

# Temp installer downloads
ZoomInstallerFull.msi
CleanZoom.exe
CleanZoom.zip

# User-specific IDE files / OS metadata
.vs/
.vscode/
Thumbs.db
Desktop.ini
"@

    "README.md" = @"
# Zoomie

A secure, automated multi-instance Zoom profile isolation and cleanup utility for Windows.

## Editions
- **Standard Edition (\`InstallZoomie-v1.2.0.exe\`)**: Least-privilege standard user sandboxing for everyday privacy and isolation.
- **DJ & Webcam Edition (\`InstallZoomie-DJ-v1.2.0.exe\`)**: Administrative ephemeral sandboxing built for compatibility with tools like ManyCam and Virtual DJ.
"@

    "CHANGELOG.md" = @"
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-08-09
### Added
- Dynamic CDN downloading, SHA-256 integrity checks, least-privilege and admin ephemeral account rotation, and unified build scripts.
"@
}

foreach ($filePath in $files.Keys) {
    $fullPath = Join-Path $ScriptDir $filePath
    if (-not (Test-Path $fullPath)) {
        Set-Content -LiteralPath $fullPath -Value $files[$filePath] -Encoding utf8
        Write-Host "[CREATED] File: $filePath" -ForegroundColor Green
    } else {
        Write-Host "[EXISTS]  File: $filePath (Skipped)" -ForegroundColor Yellow
    }
}

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host " Repository Scaffolding Complete!" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan