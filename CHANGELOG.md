# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Security
- Verify the Authenticode signature and publisher of the Zoom MSI and CleanZoom.exe before executing them; the previous SHA-256 "integrity check" only printed a hash and never validated it.
- Generate sandbox account names and passwords with a cryptographic RNG instead of `Get-Random`, and build the password directly as a `SecureString`.
- Validate the sandbox user name read from `active_zoom_user.txt` against `^Zoomie_\d{5}$` before it is used in a WMI filter, `Remove-LocalUser`, or a recursive profile delete.
- Create sandbox profile directories with inheritance removed so other local users can no longer read isolated Zoom profile data.
- Download and extract CleanZoom into a private per-run temp directory.

## [1.2.0] - 2026-08-09
### Added
- Dynamic CDN downloading, SHA-256 integrity checks, least-privilege and admin ephemeral account rotation, and unified build scripts.
