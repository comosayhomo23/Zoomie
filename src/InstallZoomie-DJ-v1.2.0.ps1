[CmdletBinding()]
param(
    [switch]$LaunchOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }

$script:StateDir   = Join-Path $env:ProgramData 'Zoom1132DJ'
$script:LogDir     = Join-Path $script:StateDir 'logs'
$script:ProfilesDir= Join-Path $script:StateDir 'profiles'
$script:StateFile  = Join-Path $script:StateDir 'active_zoom_user.txt'
$script:LogFile    = Join-Path $script:LogDir ("engine_dj_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$script:ExitCode   = 0
$script:TranscriptStarted = $false

function Write-Step {
    param([string]$Level, [string]$Message)
    $line = "[{0}] {1}" -f $Level.ToUpperInvariant(), $Message
    Write-Host $line
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
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ("`"{0}`"" -f $self))
    if ($LaunchOnly) { $psArgs += '-LaunchOnly' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($psArgs -join ' ') -ErrorAction Stop
    } catch {
        throw ("Elevation failed or was declined by the user: {0}" -f $_.Exception.Message)
    }
    exit 0
}

function Ensure-Dirs {
    foreach ($dir in @($script:StateDir, $script:LogDir, $script:ProfilesDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Start-Logging {
    Ensure-Dirs
    try {
        Start-Transcript -Path $script:LogFile -Append | Out-Null
        $script:TranscriptStarted = $true
    } catch {
        Write-Step WARN ("Could not start transcript at {0}: {1}. Continuing without a log file." -f $script:LogFile, $_.Exception.Message)
    }
    Write-Step START 'InstallZoomie-DJ-v1.2.0.ps1'
    Write-Step INFO ("User={0} Computer={1}" -f $env:USERNAME, $env:COMPUTERNAME)
    Write-Step INFO ("LaunchOnlyMode={0}" -f $LaunchOnly)
}

function Stop-Logging {
    if (-not $script:TranscriptStarted) { return }
    try { Stop-Transcript | Out-Null }
    catch { Write-Step WARN ("Failed to stop transcript: {0}" -f $_.Exception.Message) }
}

function Get-ZoomExePath {
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe')) {
        try {
            $regValue = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
            if ($regValue) { [void]$candidates.Add($regValue) }
        } catch {
            Write-Verbose ("No Zoom App Paths entry at {0}: {1}" -f $key, $_.Exception.Message)
        }
    }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { [void]$candidates.Add((Join-Path $base 'Zoom\bin\Zoom.exe')) }
    }

    foreach ($userDir in (Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue)) {
        foreach ($relative in @('AppData\Roaming\Zoom\bin\Zoom.exe', 'AppData\Local\Programs\Zoom\bin\Zoom.exe', 'AppData\Zoom\bin\Zoom.exe')) {
            [void]$candidates.Add((Join-Path $userDir.FullName $relative))
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Remove-AccountAndProfile {
    param([string]$UserName)
    if (-not $UserName -or $UserName -notmatch '^Zoomie_') { return $true }

    Write-Step INFO ("Cleaning up old sandbox user & profile: {0}" -f $UserName)
    $succeeded = $true

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($user) {
        try { Remove-LocalUser -Name $UserName -ErrorAction Stop; Write-Step OK ("Removed local user {0}" -f $UserName) }
        catch {
            $succeeded = $false
            Write-Step WARN ("Failed removing user {0}: {1}" -f $UserName, $_.Exception.Message)
        }
    }

    $profilePath = Join-Path $env:SystemDrive ("Users\{0}" -f $UserName)
    try {
        $escaped = $profilePath.Replace('\', '\\')
        $userProfile = Get-CimInstance Win32_UserProfile -Filter ("LocalPath='{0}'" -f $escaped) -ErrorAction SilentlyContinue
        if ($userProfile) { $userProfile | Remove-CimInstance -ErrorAction Stop; Write-Step OK ("Purged WMI profile for {0}" -f $UserName) }
        if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop }
    } catch {
        $succeeded = $false
        Write-Step WARN ("Profile cleanup failed: {0}" -f $_.Exception.Message)
    }

    return $succeeded
}

function Ensure-AdminSandboxAccount {
    param([string]$UserName, [securestring]$Password)
    
    # DJ EDITION: Description kept safely under the 48-character limit
    New-LocalUser -Name $UserName -Password $Password -FullName "Zoom DJ Sandbox" -Description 'Zoom Sandbox Admin' -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Write-Step OK ("Created local Administrator user {0} (DJ/Webcam Edition)" -f $UserName)
    
    try {
        Add-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction Stop
        Write-Step OK ("Successfully added {0} to the Administrators group." -f $UserName)
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        Write-Step INFO ("{0} is already a member of Administrators." -f $UserName)
    } catch {
        throw ("Failed adding {0} to the Administrators group, which this edition requires: {1}" -f $UserName, $_.Exception.Message)
    }
}

function Ensure-PathAclForUser {
    param([string]$Path, [string]$UserName)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $qualifiedUser = "{0}\{1}" -f $env:COMPUTERNAME, $UserName
    $icaclsOutput = & { $ErrorActionPreference = 'Continue'; & icacls $Path /inheritance:e /grant:r ("{0}:(OI)(CI)M" -f $qualifiedUser) "Administrators:(OI)(CI)F" 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        throw ("icacls failed (exit {0}) while restricting {1} to {2}: {3}" -f $LASTEXITCODE, $Path, $qualifiedUser, ($icaclsOutput -join ' '))
    }
    Write-Step INFO ("Granted strict sandbox access to {0}: {1}" -f $qualifiedUser, $Path)
}

function Ensure-DesktopShortcut {
    $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
    $linkPath = Join-Path $publicDesktop 'Zoomie DJ.lnk'
    if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath -Force }
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($linkPath)
        $shortcut.TargetPath = "$ScriptDir\InstallZoomie-DJ-v1.2.0.exe"
        $shortcut.Arguments = "-LaunchOnly"
        $shortcut.IconLocation = Join-Path $ScriptDir 'Zoomies.ico'
        $shortcut.WindowStyle = 1
        $shortcut.Save()
        Write-Step OK "Created desktop shortcut: Zoomie DJ.lnk"
    } catch {
        Write-Step WARN ("Failed to create shortcut {0}: {1}" -f $linkPath, $_.Exception.Message)
    }
}

# ----------------- MAIN EXECUTION -----------------
try {
    Ensure-Elevated
    Start-Logging

    if (-not $LaunchOnly) {
        Ensure-DesktopShortcut

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

        $MsiPath       = Join-Path $ScriptDir "ZoomInstallerFull.msi"
        $CleanZoomPath = Join-Path $ScriptDir "CleanZoom.exe"
        $MsiMetaFile   = Join-Path $script:StateDir "zoom_msi.meta"
        $CleanMetaFile = Join-Path $script:StateDir "cleanzoom.meta"

        function Test-FileIntegrity {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [string]$ExpectedHash
            )
            if (-not (Test-Path -LiteralPath $Path)) {
                Write-Step WARN "Expected download is missing: $Path"
                return $false
            }
            if ((Get-Item -LiteralPath $Path).Length -eq 0) {
                Write-Step WARN "Download is empty (0 bytes): $Path"
                return $false
            }
            $fileHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            Write-Step INFO "File: $(Split-Path $Path -Leaf)"
            Write-Step INFO "Computed SHA-256: $fileHash"
            if ($ExpectedHash) {
                if ($fileHash -ne $ExpectedHash.Trim().ToUpperInvariant()) {
                    Write-Step WARN "SHA-256 mismatch. Expected: $ExpectedHash"
                    return $false
                }
                Write-Step OK "SHA-256 matches the expected value."
            } else {
                Write-Step INFO "No expected SHA-256 supplied; hash recorded for auditing only."
            }
            return $true
        }

        function Invoke-Download {
            param([string]$Url, [string]$OutFile)
            try {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            } catch {
                if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
                throw ("Download failed for {0}: {1}" -f $Url, $_.Exception.Message)
            }
        }

        function Save-RemoteMetadataStamp {
            param([string]$Url, [string]$MetaFile)
            try {
                $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
                if ($head.Headers['Last-Modified']) {
                    Set-Content -LiteralPath $MetaFile -Value $head.Headers['Last-Modified'] -Force
                }
            } catch {
                Write-Step WARN ("Could not record CDN metadata in {0}: {1}. The file will be re-downloaded next run." -f $MetaFile, $_.Exception.Message)
            }
        }

        function Test-NeedsUpdate {
            param([string]$Url, [string]$LocalPath, [string]$MetaFile)
            if (-not (Test-Path -LiteralPath $LocalPath)) { return $true }
            
            try {
                $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
                $remoteModified = $head.Headers['Last-Modified']
                
                if (Test-Path -LiteralPath $MetaFile) {
                    $localModified = Get-Content -LiteralPath $MetaFile -Raw
                    if ($remoteModified -and ($remoteModified.Trim() -ne $localModified.Trim())) {
                        Write-Step INFO "Newer version detected on CDN for $(Split-Path $LocalPath -Leaf)."
                        return $true
                    }
                } else {
                    return $true
                }
            } catch {
                Write-Step WARN ("Could not check CDN headers for updates ({0}). Using local file." -f $_.Exception.Message)
            }
            return $false
        }

        $MsiUrl = "https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64"
        $CleanZoomUrl = "https://assets.zoom.us/docs/msi-templates/CleanZoom.zip"

        if (Test-NeedsUpdate -Url $MsiUrl -LocalPath $MsiPath -MetaFile $MsiMetaFile) {
            Write-Step INFO "Downloading latest Zoom Workplace 64-bit MSI from official CDN..."
            Invoke-Download -Url $MsiUrl -OutFile $MsiPath
            if (-not (Test-FileIntegrity -Path $MsiPath)) { throw "MSI integrity validation failed." }

            Save-RemoteMetadataStamp -Url $MsiUrl -MetaFile $MsiMetaFile
            Write-Step OK "Zoom 64-bit MSI updated and verified."
        } else {
            Write-Step INFO "Zoom 64-bit MSI is up to date."
        }

        if (Test-NeedsUpdate -Url $CleanZoomUrl -LocalPath $CleanZoomPath -MetaFile $CleanMetaFile) {
            Write-Step INFO "Downloading latest CleanZoom utility..."
            $ZipPath = Join-Path $env:TEMP "CleanZoom.zip"
            Invoke-Download -Url $CleanZoomUrl -OutFile $ZipPath
            if (-not (Test-FileIntegrity -Path $ZipPath)) { throw "CleanZoom archive integrity validation failed." }

            $extractedExe = Join-Path $env:TEMP 'CleanZoom.exe'
            try {
                Expand-Archive -LiteralPath $ZipPath -DestinationPath $env:TEMP -Force -ErrorAction Stop
            } catch {
                throw ("Could not extract {0}: {1}" -f $ZipPath, $_.Exception.Message)
            }
            if (-not (Test-Path -LiteralPath $extractedExe)) {
                throw ("CleanZoom.exe was not found in the downloaded archive {0}." -f $ZipPath)
            }
            Move-Item -LiteralPath $extractedExe -Destination $CleanZoomPath -Force
            Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue

            Save-RemoteMetadataStamp -Url $CleanZoomUrl -MetaFile $CleanMetaFile
            Write-Step OK "CleanZoom updated and verified."
        } else {
            Write-Step INFO "CleanZoom utility is up to date."
        }

        Write-Step ACTION "Executing CleanZoom.exe..."
        $clean = Start-Process -FilePath $CleanZoomPath -Wait -PassThru
        if (-not $clean) { throw 'Failed to start CleanZoom.exe.' }
        if ($clean.ExitCode -ne 0) {
            Write-Step WARN ("CleanZoom exited with code {0}; continuing with the installation." -f $clean.ExitCode)
        }

        Write-Step INFO "Waiting 15 seconds for cleanup to settle..."
        Start-Sleep -Seconds 15

        Write-Step ACTION "Installing Zoom via MSI..."
        $msi = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$MsiPath`" /quiet /norestart" -Wait -PassThru
        if (-not $msi) { throw 'Failed to start msiexec.exe.' }
        if ($msi.ExitCode -notin @(0, 1641, 3010)) {
            throw ("Zoom MSI installation failed with msiexec exit code {0}." -f $msi.ExitCode)
        }
        if ($msi.ExitCode -in @(1641, 3010)) {
            Write-Step WARN ("Zoom installed but requested a reboot (msiexec exit code {0})." -f $msi.ExitCode)
        }
        Write-Step OK "Zoom clean installation finished successfully."
    } else {
        Write-Step INFO "LaunchOnly mode active. Skipping installation sequence."
    }

    $zoom = Get-ZoomExePath
    if (-not $zoom) { throw 'Zoom.exe was not found on system.' }
    Write-Step OK ("Using Zoom path: {0}" -f $zoom)

    if (Test-Path -LiteralPath $script:StateFile) {
        $lastUser = (Get-Content -LiteralPath $script:StateFile -Raw).Trim()
        if (-not (Remove-AccountAndProfile -UserName $lastUser)) {
            Write-Step WARN ("Sandbox user {0} could not be fully removed and is now orphaned. Run Uninstall-Zoomie to purge leftovers." -f $lastUser)
        }
    }

    $randNum = Get-Random -Minimum 10000 -Maximum 99999
    $activeName = "Zoomie_$randNum"
    
    $charSet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$-_='
    $PlainPassword = -join ((1..24) | ForEach-Object { $charSet[(Get-Random -Maximum $charSet.Length)] })
    $SecurePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force

    Write-Step INFO ("Rotation: Spawning new isolated Admin user {0}" -f $activeName)

    Ensure-AdminSandboxAccount -UserName $activeName -Password $SecurePassword

    $profileRoot = Join-Path $script:ProfilesDir $activeName
    $profileA = Join-Path $profileRoot 'dataA'
    Ensure-PathAclForUser -Path $profileRoot -UserName $activeName
    Ensure-PathAclForUser -Path $profileA -UserName $activeName

    Set-Content -LiteralPath $script:StateFile -Value $activeName -Encoding ascii -Force

    $zoomArgs1 = @('--multipt=TRUE', "--data=$profileA")
    $qualifiedUser = "{0}\{1}" -f $env:COMPUTERNAME, $activeName
    $cred = [pscredential]::new($qualifiedUser, $SecurePassword)

    Write-Step ACTION ("Starting Zoom instance as elevated sandbox user: {0}" -f $qualifiedUser)
    try {
        $p1 = Start-Process -FilePath $zoom -ArgumentList $zoomArgs1 -WorkingDirectory 'C:\ProgramData' -Credential $cred -PassThru -WindowStyle Normal -ErrorAction Stop
    } catch {
        throw ("Could not start Zoom as {0}: {1}" -f $qualifiedUser, $_.Exception.Message)
    }
    if (-not $p1) { throw 'Zoom Start-Process failed.' }
    Write-Step OK ("Zoom instance PID={0}" -f $p1.Id)

    if ($p1.Id -and (Get-Process -Id $p1.Id -ErrorAction SilentlyContinue)) {
        Wait-Process -Id $p1.Id -ErrorAction SilentlyContinue
    }

    Write-Step DONE 'Completed successfully.'
}
catch {
    $script:ExitCode = 1
    Write-Step FATAL (Format-ErrorRecord $_)
    Write-Step FATAL ("See log: {0}" -f $script:LogFile)
}
finally {
    Stop-Logging
    Write-Host "`n====================================================" -ForegroundColor Cyan
    if ($script:ExitCode -eq 0) {
        Write-Host "Process finished. Press any key to close this window..." -ForegroundColor Green
    } else {
        Write-Host "Process FAILED (exit code $script:ExitCode). Press any key to close this window..." -ForegroundColor Red
    }
    Write-Host "====================================================" -ForegroundColor Cyan
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Write-Host "(Non-interactive host; skipping keypress.)" -ForegroundColor DarkGray
    }
    exit $script:ExitCode
}