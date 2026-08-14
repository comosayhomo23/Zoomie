# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Fixed
- Installers now fail loudly instead of silently: msiexec and CleanZoom exit codes are checked, failed ACL hardening (`icacls`) aborts the run, sandbox group membership failures are propagated, downloads clean up partial files, and both installers plus the uninstaller exit with code 1 on failure while logging the full error record (inner exceptions, position, stack trace).
- Uninstaller aggregates per-item cleanup failures and reports them instead of always printing "Uninstallation Complete".
- Build scripts verify that ps2exe actually produced each executable and exit non-zero when a build fails; fixed the `$ErrorActionPreferAence` typo that disabled error handling in `Build-Zoomie.ps1`.

## [1.2.0] - 2026-08-09
### Added
- Dynamic CDN downloading, SHA-256 integrity checks, least-privilege and admin ephemeral account rotation, and unified build scripts.
