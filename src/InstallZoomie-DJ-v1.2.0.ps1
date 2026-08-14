[CmdletBinding()]
param(
    [switch]$LaunchOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }

. (Join-Path $ScriptDir 'Zoomie.Common.ps1') # zoomie:inline

$Paths = Get-ZoomiePath -StateDirName 'Zoom1132DJ' -LogPrefix 'engine_dj'

# ----------------- MAIN EXECUTION -----------------
try {
    Confirm-Elevation -ScriptPath $PSCommandPath -ExtraArguments @(if ($LaunchOnly) { '-LaunchOnly' })
    Start-ZoomieLog -Paths $Paths -ScriptName 'InstallZoomie-DJ-v1.2.0.ps1' -Context @{ LaunchOnlyMode = $LaunchOnly }

    if (-not $LaunchOnly) {
        New-ZoomieDesktopShortcut -Name 'Zoomie DJ.lnk' -TargetPath (Join-Path $ScriptDir 'InstallZoomie-DJ-v1.2.0.exe') -IconPath (Join-Path $ScriptDir 'Zoomies.ico')
        Install-ZoomieRuntime -ScriptDir $ScriptDir -StateDir $Paths.StateDir
    } else {
        Write-Step INFO 'LaunchOnly mode active. Skipping installation sequence.'
    }

    # DJ EDITION: sandbox account is a local administrator; description stays under the 48-character limit
    Start-ZoomieInstance -Paths $Paths -FullName 'Zoom DJ Sandbox' -Description 'Zoom Sandbox Admin' -Group 'Administrators'

    Write-Step DONE 'Completed successfully.'
}
catch {
    Write-Step FATAL $_.Exception.Message
    Write-Step FATAL ("See log: {0}" -f $Paths.LogFile)
}
finally {
    Stop-ZoomieLog
    Wait-ForKeyPress
}
