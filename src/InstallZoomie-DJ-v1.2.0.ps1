[CmdletBinding()]
param(
    [switch]$LaunchOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Zoomie-Engine.ps1')
Invoke-ZoomieEngine -Edition DJ -LaunchOnly:$LaunchOnly
