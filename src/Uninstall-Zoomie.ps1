[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }

. (Join-Path $ScriptDir 'Zoomie.Common.ps1') # zoomie:inline

# State directories for all Zoomie editions
$GlobalStateDirs = @(
    (Get-ZoomiePath -StateDirName 'Zoom1132').StateDir      # Standard Edition
    (Get-ZoomiePath -StateDirName 'Zoom1132DJ').StateDir    # DJ Edition
)

# ----------------- MAIN EXECUTION -----------------
try {
    Confirm-Elevation -ScriptPath $PSCommandPath

    Write-Banner -Message 'UNINSTALLING / PURGING ZOOMIE ENVIRONMENT' -Color Red

    # 1. Remove all ephemeral users and profiles
    Write-Step INFO 'Scanning for leftover Zoomie sandbox users...'
    foreach ($user in (Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Zoomie_\d{5}$' })) {
        Write-Step ACTION ("Purging sandbox user: {0}" -f $user.Name)
        Remove-ZoomieSandboxUser -UserName $user.Name
    }
    Write-Step OK 'Sandbox user cleanup complete.'

    # 2. Purge ProgramData state directories
    foreach ($stateDir in $GlobalStateDirs) {
        if (Test-Path -LiteralPath $stateDir) {
            Write-Step ACTION ("Deleting state directory: {0}" -f $stateDir)
            try {
                Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction Stop
                Write-Step OK ("Purged {0}" -f (Split-Path $stateDir -Leaf))
            } catch {
                Write-Step WARN ("Failed deleting {0}: {1}" -f $stateDir, $_.Exception.Message)
            }
        }
    }

    # 3. Cleanup Shortcuts
    $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
    foreach ($sc in @('Zoomie.lnk', 'Zoomie DJ.lnk', 'ZOOM.WTF.lnk')) {
        $linkPath = Join-Path $publicDesktop $sc
        if (Test-Path -LiteralPath $linkPath) {
            Write-Step ACTION ("Removing desktop shortcut: {0}" -f $sc)
            try { Remove-Item -LiteralPath $linkPath -Force -ErrorAction Stop }
            catch { Write-Step WARN ("Failed removing shortcut {0}: {1}" -f $sc, $_.Exception.Message) }
        }
    }

    Write-Step DONE 'Uninstallation Complete. System purged of Zoomie state.'
}
catch {
    Write-Step FATAL $_.Exception.Message
}
finally {
    Wait-ForKeyPress
}
