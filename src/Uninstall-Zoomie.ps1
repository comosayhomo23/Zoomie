[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Define paths for all Zoomie editions to be thorough
$GlobalStateDirs = @(
    Join-Path $env:ProgramData 'Zoom1132'      # Standard Edition
    Join-Path $env:ProgramData 'Zoom1132DJ'    # DJ Edition
)

function Write-Step {
    param([string]$Level, [string]$Message)
    $line = "[{0}] {1}" -f $Level.ToUpperInvariant(), $Message
    Write-Host $line
}

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevated {
    if (Test-IsAdmin) { return }
    $self = $PSCommandPath
    if (-not $self) { throw 'Could not determine script path for elevation.' }
    Write-Step INFO 'Not elevated. Relaunching with Administrator rights...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $self)
    exit 0
}

function Remove-AllSandboxAccounts {
    Write-Step INFO "Scanning for leftover Zoomie sandbox users..."
    $sandboxUsers = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Zoomie_\d{5}$' }
    
    foreach ($user in $sandboxUsers) {
        $UserName = $user.Name
        Write-Step ACTION ("Purging sandbox user: {0}" -f $UserName)
        
        try {
            Remove-LocalUser -Name $UserName -ErrorAction Stop
            Write-Step OK ("Removed local user {0}" -f $UserName)
        } catch {
            Write-Step WARN ("Failed removing user {0}: {1}" -f $UserName, $_.Exception.Message)
        }

        $profilePath = Join-Path $env:SystemDrive ("Users\{0}" -f $UserName)
        try {
            $escaped = $profilePath.Replace('\', '\\')
            $profile = Get-CimInstance Win32_UserProfile -Filter ("LocalPath='{0}'" -f $escaped) -ErrorAction SilentlyContinue
            if ($profile) {
                $profile | Remove-CimInstance -ErrorAction Stop
                Write-Step OK ("Purged WMI profile for {0}" -f $UserName)
            }
            if (Test-Path -LiteralPath $profilePath) {
                Write-Step INFO ("Deleting profile folder: {0}" -f $profilePath)
                Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop
            }
        } catch {
            Write-Step WARN ("Profile cleanup failed for {0}: {1}" -f $UserName, $_.Exception.Message)
        }
    }
    Write-Step OK "Sandbox user cleanup complete."
}

# ----------------- MAIN EXECUTION -----------------
try {
    Ensure-Elevated
    
    Write-Host "`n====================================================" -ForegroundColor Red
    Write-Host " UNINSTALLING / PURGING ZOOMIE ENVIRONMENT" -ForegroundColor Red
    Write-Host "====================================================`n" -ForegroundColor Red

    # 1. Remove all ephemeral users and profiles
    Remove-AllSandboxAccounts

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
    $shortcuts = @('Zoomie.lnk', 'Zoomie DJ.lnk', 'ZOOM.WTF.lnk')
    foreach ($sc in $shortcuts) {
        $linkPath = Join-Path $publicDesktop $sc
        if (Test-Path -LiteralPath $linkPath) {
            Write-Step ACTION ("Removing desktop shortcut: {0}" -f $sc)
            try { Remove-Item -LiteralPath $linkPath -Force -ErrorAction Stop }
            catch { Write-Step WARN ("Failed removing shortcut {0}: {1}" -f $sc, $_.Exception.Message) }
        }
    }

    Write-Host "`n====================================================" -ForegroundColor Green
    Write-Step DONE "Uninstallation Complete. System purged of Zoomie state."
    Write-Host "====================================================" -ForegroundColor Green

}
catch {
    Write-Step FATAL $_.Exception.Message
}
finally {
    Write-Host "`nPress any key to close this window..." -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}