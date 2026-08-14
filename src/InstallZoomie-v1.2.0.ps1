[CmdletBinding()]
param(
    [switch]$LaunchOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }

. (Join-Path $ScriptDir 'Zoomie.Common.ps1') # zoomie:inline

$Paths = Get-ZoomiePath -StateDirName 'Zoom1132' -LogPrefix 'engine'

# ----------------- MAIN EXECUTION -----------------
try {
    Confirm-Elevation -ScriptPath $PSCommandPath -ExtraArguments @(if ($LaunchOnly) { '-LaunchOnly' })
    Start-ZoomieLog -Paths $Paths -ScriptName 'InstallZoomie-v1.2.0.ps1' -Context @{ LaunchOnlyMode = $LaunchOnly }

    # Only run the full clean install if NOT in LaunchOnly mode
    if (-not $LaunchOnly) {
        New-ZoomieDesktopShortcut -Name 'Zoomie.lnk' -TargetPath (Join-Path $ScriptDir 'InstallZoomie-v1.2.0.exe') -IconPath (Join-Path $ScriptDir 'ZOOM.WTF_icon.ico')
        Install-ZoomieRuntime -ScriptDir $ScriptDir -StateDir $Paths.StateDir
    } else {
        Write-Step INFO 'LaunchOnly mode active. Skipping installation sequence.'
    }

    # STANDARD EDITION: sandbox account is a least-privilege standard user
    Start-ZoomieInstance -Paths $Paths -FullName 'Zoom Sandbox' -Description 'Restricted ephemeral Zoom instance' -Group 'Users'

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
