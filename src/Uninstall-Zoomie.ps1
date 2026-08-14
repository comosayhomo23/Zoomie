[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Define paths for all Zoomie editions to be thorough
$GlobalStateDirs = @(
    Join-Path $env:ProgramData 'Zoom1132'      # Standard Edition
    Join-Path $env:ProgramData 'Zoom1132DJ'    # DJ Edition
)

$script:ExitCode = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Write-Step {
    param([string]$Level, [string]$Message)
    $line = "[{0}] {1}" -f $Level.ToUpperInvariant(), $Message
    Write-Host $line
}

function Add-Failure {
    param([string]$Message)
    [void]$script:Failures.Add($Message)
    Write-Step WARN $Message
}

function Format-ErrorRecord {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $parts = [System.Collections.Generic.List[string]]::new()
    [void]$parts.Add($ErrorRecord.Exception.Message)
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) {
        [void]$parts.Add("caused by: {0}" -f $inner.Message)
        $inner = $inner.InnerException
    }
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        [void]$parts.Add($ErrorRecord.InvocationInfo.PositionMessage.Trim())
    }
    if ($ErrorRecord.ScriptStackTrace) {
        [void]$parts.Add($ErrorRecord.ScriptStackTrace)
    }
    return ($parts -join [Environment]::NewLine)
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
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $self) -ErrorAction Stop
    } catch {
        throw ("Elevation failed or was declined by the user: {0}" -f $_.Exception.Message)
    }
    exit 0
}

function Remove-AllSandboxAccounts {
    Write-Step INFO "Scanning for leftover Zoomie sandbox users..."
    try {
        $sandboxUsers = Get-LocalUser -ErrorAction Stop | Where-Object { $_.Name -match '^Zoomie_\d{5}$' }
    } catch {
        throw ("Could not enumerate local users, so sandbox accounts cannot be purged: {0}" -f $_.Exception.Message)
    }

    foreach ($user in $sandboxUsers) {
        $UserName = $user.Name
        Write-Step ACTION ("Purging sandbox user: {0}" -f $UserName)
        
        try {
            Remove-LocalUser -Name $UserName -ErrorAction Stop
            Write-Step OK ("Removed local user {0}" -f $UserName)
        } catch {
            Add-Failure ("Failed removing user {0}: {1}" -f $UserName, $_.Exception.Message)
        }

        $profilePath = Join-Path $env:SystemDrive ("Users\{0}" -f $UserName)
        try {
            $escaped = $profilePath.Replace('\', '\\')
            $userProfile = Get-CimInstance Win32_UserProfile -Filter ("LocalPath='{0}'" -f $escaped) -ErrorAction SilentlyContinue
            if ($userProfile) {
                $userProfile | Remove-CimInstance -ErrorAction Stop
                Write-Step OK ("Purged WMI profile for {0}" -f $UserName)
            }
            if (Test-Path -LiteralPath $profilePath) {
                Write-Step INFO ("Deleting profile folder: {0}" -f $profilePath)
                Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop
            }
        } catch {
            Add-Failure ("Profile cleanup failed for {0}: {1}" -f $UserName, $_.Exception.Message)
        }
    }
    if ($script:Failures.Count -eq 0) {
        Write-Step OK "Sandbox user cleanup complete."
    } else {
        Write-Step WARN "Sandbox user cleanup finished with errors; see the warnings above."
    }
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
                Add-Failure ("Failed deleting {0}: {1}" -f $stateDir, $_.Exception.Message)
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
            catch { Add-Failure ("Failed removing shortcut {0}: {1}" -f $sc, $_.Exception.Message) }
        }
    }

    if ($script:Failures.Count -gt 0) {
        $script:ExitCode = 1
        Write-Host "`n====================================================" -ForegroundColor Yellow
        Write-Step ERROR ("Uninstallation finished with {0} problem(s):" -f $script:Failures.Count)
        foreach ($failure in $script:Failures) { Write-Step ERROR (" - {0}" -f $failure) }
        Write-Step ERROR "Some Zoomie state remains on this system. Re-run as Administrator after closing Zoom."
        Write-Host "====================================================" -ForegroundColor Yellow
    } else {
        Write-Host "`n====================================================" -ForegroundColor Green
        Write-Step DONE "Uninstallation Complete. System purged of Zoomie state."
        Write-Host "====================================================" -ForegroundColor Green
    }
}
catch {
    $script:ExitCode = 1
    Write-Step FATAL (Format-ErrorRecord $_)
}
finally {
    Write-Host "`nPress any key to close this window..." -ForegroundColor Cyan
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Write-Host "(Non-interactive host; skipping keypress.)" -ForegroundColor DarkGray
    }
    exit $script:ExitCode
}