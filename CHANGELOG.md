# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed
- Extracted the logic shared by the Standard, DJ and uninstaller scripts into `src/Zoomie.Common.ps1`; `Build-Zoomie.ps1` inlines it at compile time so the executables stay self-contained.
- Consolidated `Build-Zoomie.ps1`, `src/Build-Zoomie.ps1` and `Fix-And-Build.ps1` into a single table-driven `Build-Zoomie.ps1` that also builds the uninstaller.
- Sandbox passwords are now built directly as a `SecureString` instead of via `ConvertTo-SecureString -AsPlainText`.

## [1.2.0] - 2026-08-09
### Added
- Dynamic CDN downloading, SHA-256 integrity checks, least-privilege and admin ephemeral account rotation, and unified build scripts.
