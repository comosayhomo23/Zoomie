[CmdletBinding()]
param(
    [switch]$LaunchOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Robust path detection
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }

$script:StateDir   = Join-Path $env:ProgramData 'Zoom1132'
$script:LogDir     = Join-Path $script:StateDir 'logs'
$script:ProfilesDir= Join-Path $script:StateDir 'profiles'
$script:StateFile  = Join-Path $script:StateDir 'active_zoom_user.txt'
$script:LogFile    = Join-Path $script:LogDir ("engine_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$script:SandboxUserPattern = '^Zoomie_\d{5}$'
$script:TrustedPublisherPattern = 'Zoom Video Communications'

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
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ("`"{0}`"" -f $self))
    if ($LaunchOnly) { $args += '-LaunchOnly' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($args -join ' ')
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
    Start-Transcript -Path $script:LogFile -Append | Out-Null
    Write-Step START 'InstallZoomie-v1.2.0.ps1'
    Write-Step INFO ("User={0} Computer={1}" -f $env:USERNAME, $env:COMPUTERNAME)
    Write-Step INFO ("LaunchOnlyMode={0}" -f $LaunchOnly)
}

function Stop-Logging {
    try { Stop-Transcript | Out-Null } catch {}
}

function Get-ZoomExePath {
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe')) {
        try {
            $regValue = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
            if ($regValue) { [void]$candidates.Add($regValue) }
        } catch {}
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

function Get-SecureRandomInt {
    param([Parameter(Mandatory = $true)][int]$MaximumExclusive)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = [byte[]]::new(4)
        $limit = [uint32]([math]::Floor([uint32]::MaxValue / $MaximumExclusive) * $MaximumExclusive)
        do {
            $rng.GetBytes($buffer)
            $value = [System.BitConverter]::ToUInt32($buffer, 0)
        } while ($value -ge $limit)
        return [int]($value % $MaximumExclusive)
    } finally { $rng.Dispose() }
}

function New-SandboxUserName {
    return "Zoomie_{0}" -f (10000 + (Get-SecureRandomInt -MaximumExclusive 90000))
}

function New-SandboxPassword {
    [OutputType([securestring])]
    param([int]$Length = 24)

    $charSet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$-_='
    # Index ranges per Windows complexity class: lower, upper, digit, symbol.
    $classRanges = @(@(0, 25), @(26, 51), @(52, 61), @(62, 68))

    do {
        $indexes = @(1..$Length | ForEach-Object { Get-SecureRandomInt -MaximumExclusive $charSet.Length })
        $covered = $true
        foreach ($range in $classRanges) {
            if (-not ($indexes | Where-Object { $_ -ge $range[0] -and $_ -le $range[1] })) { $covered = $false }
        }
    } while (-not $covered)

    $secure = [System.Security.SecureString]::new()
    foreach ($index in $indexes) { $secure.AppendChar($charSet[$index]) }
    $secure.MakeReadOnly()
    return $secure
}

function Assert-TrustedPublisher {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("Cannot verify missing file: {0}" -f $Path)
    }
    $fileHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-Step INFO ("Verifying {0} (SHA-256: {1})" -f (Split-Path $Path -Leaf), $fileHash)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw ("Authenticode signature for {0} is not valid (status: {1})." -f (Split-Path $Path -Leaf), $signature.Status)
    }
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    if ($subject -notmatch $script:TrustedPublisherPattern) {
        throw ("{0} is signed by an untrusted publisher: {1}" -f (Split-Path $Path -Leaf), $subject)
    }
    Write-Step OK ("Signature verified for {0}: {1}" -f (Split-Path $Path -Leaf), $subject)
}

function Remove-AccountAndProfile {
    param([string]$UserName)
    if (-not $UserName -or $UserName -notmatch $script:SandboxUserPattern) {
        if ($UserName) { Write-Step WARN 'Ignoring unrecognized sandbox user name in state file.' }
        return
    }

    Write-Step INFO ("Cleaning up old sandbox user & profile: {0}" -f $UserName)
    
    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($user) {
        try { Remove-LocalUser -Name $UserName -ErrorAction Stop; Write-Step OK ("Removed local user {0}" -f $UserName) }
        catch { Write-Step WARN ("Failed removing user {0}: {1}" -f $UserName, $_.Exception.Message) }
    }

    $profilePath = Join-Path $env:SystemDrive ("Users\{0}" -f $UserName)
    try {
        $escaped = $profilePath.Replace('\', '\\')
        $profile = Get-CimInstance Win32_UserProfile -Filter ("LocalPath='{0}'" -f $escaped) -ErrorAction SilentlyContinue
        if ($profile) { $profile | Remove-CimInstance -ErrorAction Stop; Write-Step OK ("Purged WMI profile for {0}" -f $UserName) }
        if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop }
    } catch { Write-Step WARN ("Profile cleanup failed: {0}" -f $_.Exception.Message) }
}

function Ensure-RestrictedLocalAccount {
    param([string]$UserName, [securestring]$Password)
    
    # STANDARD EDITION: Creates a Least-Privilege Standard User (Users group)
    New-LocalUser -Name $UserName -Password $Password -FullName "Zoom Sandbox" -Description 'Restricted ephemeral Zoom instance' -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Write-Step OK ("Created standard local user {0} (Least Privilege)" -f $UserName)
    
    try {
        Add-LocalGroupMember -Group 'Users' -Member $UserName -ErrorAction Stop
    } catch {}
}

function Ensure-PathAclForUser {
    param([string]$Path, [string]$UserName)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $qualifiedUser = "{0}\{1}" -f $env:COMPUTERNAME, $UserName
    # /inheritance:r drops inherited ProgramData permissions so other local users cannot read sandbox data.
    & icacls $Path /inheritance:r /grant:r ("{0}:(OI)(CI)M" -f $qualifiedUser) 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("Failed to apply sandbox ACL to {0}" -f $Path) }
    Write-Step INFO ("Granted strict sandbox access to {0}: {1}" -f $qualifiedUser, $Path)
}

function Ensure-DesktopShortcut {
    $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
    $linkPath = Join-Path $publicDesktop 'Zoomie.lnk'
    if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath -Force }
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($linkPath)
        $shortcut.TargetPath = "$ScriptDir\InstallZoomie-v1.2.0.exe"
        $shortcut.Arguments = "-LaunchOnly"
        $shortcut.IconLocation = Join-Path $ScriptDir 'ZOOM.WTF_icon.ico'
        $shortcut.WindowStyle = 1
        $shortcut.Save()
        Write-Step OK "Created desktop shortcut: Zoomie.lnk"
    } catch { Write-Step WARN "Failed to create shortcut" }
}
# ----------------- MAIN EXECUTION -----------------
try {
    Ensure-Elevated
    Start-Logging

    # Only run the full clean install if NOT in LaunchOnly mode
    if (-not $LaunchOnly) {
        Ensure-DesktopShortcut

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

        $MsiPath       = Join-Path $ScriptDir "ZoomInstallerFull.msi"
        $CleanZoomPath = Join-Path $ScriptDir "CleanZoom.exe"
        $MsiMetaFile   = Join-Path $script:StateDir "zoom_msi.meta"
        $CleanMetaFile = Join-Path $script:StateDir "cleanzoom.meta"

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
                Write-Step WARN "Could not check CDN headers for updates. Using local file."
            }
            return $false
        }

        $MsiUrl = "https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64"
        $CleanZoomUrl = "https://assets.zoom.us/docs/msi-templates/CleanZoom.zip"

        # 1. Check and download Zoom 64-bit MSI if missing or updated
        if (Test-NeedsUpdate -Url $MsiUrl -LocalPath $MsiPath -MetaFile $MsiMetaFile) {
            Write-Step INFO "Downloading latest Zoom Workplace 64-bit MSI from official CDN..."
            Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing
            Assert-TrustedPublisher -Path $MsiPath
            
            try {
                $head = Invoke-WebRequest -Uri $MsiUrl -Method Head -UseBasicParsing
                if ($head.Headers['Last-Modified']) {
                    Set-Content -LiteralPath $MsiMetaFile -Value $head.Headers['Last-Modified'] -Force
                }
            } catch {}
            Write-Step OK "Zoom 64-bit MSI updated and verified."
        } else {
            Write-Step INFO "Zoom 64-bit MSI is up to date."
        }

        # 2. Check and download CleanZoom utility if missing or updated
        if (Test-NeedsUpdate -Url $CleanZoomUrl -LocalPath $CleanZoomPath -MetaFile $CleanMetaFile) {
            Write-Step INFO "Downloading latest CleanZoom utility..."
            # Download and extract into a private directory so the payload cannot be swapped before execution.
            $workDir = Join-Path $env:TEMP ("Zoomie_{0}" -f [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            try {
                $ZipPath = Join-Path $workDir 'CleanZoom.zip'
                Invoke-WebRequest -Uri $CleanZoomUrl -OutFile $ZipPath -UseBasicParsing
                Expand-Archive -LiteralPath $ZipPath -DestinationPath $workDir -Force
                $extracted = Join-Path $workDir 'CleanZoom.exe'
                Assert-TrustedPublisher -Path $extracted
                Move-Item -LiteralPath $extracted -Destination $CleanZoomPath -Force
            } finally {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            try {
                $head = Invoke-WebRequest -Uri $CleanZoomUrl -Method Head -UseBasicParsing
                if ($head.Headers['Last-Modified']) {
                    Set-Content -LiteralPath $CleanMetaFile -Value $head.Headers['Last-Modified'] -Force
                }
            } catch {}
            Write-Step OK "CleanZoom updated and verified."
        } else {
            Write-Step INFO "CleanZoom utility is up to date."
        }

        # Execute Cleanup & Installation
        Write-Step ACTION "Executing CleanZoom.exe..."
        Assert-TrustedPublisher -Path $CleanZoomPath
        Start-Process -FilePath $CleanZoomPath -Wait
        
        Write-Step INFO "Waiting 15 seconds for cleanup to settle..."
        Start-Sleep -Seconds 15
        
        Write-Step ACTION "Installing Zoom via MSI..."
        Assert-TrustedPublisher -Path $MsiPath
        Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$MsiPath`" /quiet /norestart" -Wait
        Write-Step OK "Zoom clean installation finished successfully."
    } else {
        Write-Step INFO "LaunchOnly mode active. Skipping installation sequence."
    }

    $zoom = Get-ZoomExePath
    if (-not $zoom) { throw 'Zoom.exe was not found on system.' }
    Write-Step OK ("Using Zoom path: {0}" -f $zoom)

    # 1. Clean up the previous temporary user (if exists)
    if (Test-Path -LiteralPath $script:StateFile) {
        $lastUser = (Get-Content -LiteralPath $script:StateFile -Raw).Trim()
        Remove-AccountAndProfile -UserName $lastUser
    }

    # 2. Generate new Randomized User and cryptographically random password
    $activeName = New-SandboxUserName
    $SecurePassword = New-SandboxPassword

    Write-Step INFO ("Rotation: Spawning new isolated standard user {0}" -f $activeName)

    # 3. Provision User and Sandbox folders
    Ensure-RestrictedLocalAccount -UserName $activeName -Password $SecurePassword

    $profileRoot = Join-Path $script:ProfilesDir $activeName
    $profileA = Join-Path $profileRoot 'dataA'
    Ensure-PathAclForUser -Path $profileRoot -UserName $activeName
    Ensure-PathAclForUser -Path $profileA -UserName $activeName

    Set-Content -LiteralPath $script:StateFile -Value $activeName -Encoding ascii -Force

    # 4. Launch Zoom as standard user restricted to sandbox
    $zoomArgs1 = @('--multipt=TRUE', "--data=$profileA")
    $qualifiedUser = "{0}\{1}" -f $env:COMPUTERNAME, $activeName
    $cred = [pscredential]::new($qualifiedUser, $SecurePassword)

    Write-Step ACTION ("Starting Zoom instance as restricted user: {0}" -f $qualifiedUser)
    $p1 = Start-Process -FilePath $zoom -ArgumentList $zoomArgs1 -WorkingDirectory 'C:\ProgramData' -Credential $cred -PassThru -WindowStyle Normal
    if (-not $p1) { throw 'Zoom Start-Process failed.' }
    Write-Step OK ("Zoom instance PID={0}" -f $p1.Id)

    if ($p1.Id -and (Get-Process -Id $p1.Id -ErrorAction SilentlyContinue)) {
        Wait-Process -Id $p1.Id -ErrorAction SilentlyContinue
    }

    Write-Step DONE 'Completed successfully.'
}
catch {
    Write-Step FATAL $_.Exception.Message
    Write-Step FATAL ("See log: {0}" -f $script:LogFile)
}
finally {
    Stop-Logging
    Write-Host "`n====================================================" -ForegroundColor Cyan
    Write-Host "Process finished. Press any key to close this window..." -ForegroundColor Green
    Write-Host "====================================================" -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}