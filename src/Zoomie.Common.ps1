# Shared helpers for the Zoomie script suite.
#
# Scripts consume this file by dot-sourcing it with a trailing "# zoomie:inline"
# marker. Build-Zoomie.ps1 replaces those marker lines with the contents of this
# file before calling ps2exe, so compiled executables stay self-contained.

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level.ToUpperInvariant(), $Message)
}

function Write-Banner {
    param([string[]]$Message, [string]$Color = 'Cyan')
    $rule = '===================================================='
    Write-Host $rule -ForegroundColor $Color
    foreach ($line in $Message) { Write-Host " $line" -ForegroundColor $Color }
    Write-Host $rule -ForegroundColor $Color
}

function Wait-ForKeyPress {
    param([string]$Message = 'Process finished. Press any key to close this window...')
    Write-Host ''
    Write-Banner -Message $Message -Color Green
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Confirm-Elevation {
    param([string]$ScriptPath, [string[]]$ExtraArguments = @())
    if (Test-IsAdmin) { return }
    if (-not $ScriptPath) { throw 'Could not determine script path for elevation.' }
    Write-Step INFO 'Not elevated. Relaunching with Administrator rights...'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath)) + $ExtraArguments
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($arguments -join ' ')
    exit 0
}

function New-ZoomieDirectory {
    param([string[]]$Path)
    foreach ($dir in $Path) {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Get-ZoomiePath {
    param([Parameter(Mandatory = $true)][string]$StateDirName, [string]$LogPrefix = 'engine')
    $stateDir = Join-Path $env:ProgramData $StateDirName
    $logDir = Join-Path $stateDir 'logs'
    return [pscustomobject]@{
        StateDir    = $stateDir
        LogDir      = $logDir
        ProfilesDir = Join-Path $stateDir 'profiles'
        StateFile   = Join-Path $stateDir 'active_zoom_user.txt'
        LogFile     = Join-Path $logDir ("{0}_{1}.log" -f $LogPrefix, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    }
}

function Start-ZoomieLog {
    param([Parameter(Mandatory = $true)]$Paths, [string]$ScriptName, [hashtable]$Context = @{})
    New-ZoomieDirectory -Path @($Paths.StateDir, $Paths.LogDir, $Paths.ProfilesDir)
    Start-Transcript -Path $Paths.LogFile -Append | Out-Null
    Write-Step START $ScriptName
    Write-Step INFO ("User={0} Computer={1}" -f $env:USERNAME, $env:COMPUTERNAME)
    foreach ($key in $Context.Keys) {
        Write-Step INFO ("{0}={1}" -f $key, $Context[$key])
    }
}

function Stop-ZoomieLog {
    try { Stop-Transcript | Out-Null } catch { }
}

function Get-ZoomExePath {
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe')) {
        try {
            $regValue = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
            if ($regValue) { [void]$candidates.Add($regValue) }
        } catch { }
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

function Remove-ZoomieSandboxUser {
    param([string]$UserName)
    if (-not $UserName -or $UserName -notmatch '^Zoomie_') { return }

    Write-Step INFO ("Cleaning up old sandbox user & profile: {0}" -f $UserName)

    if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
        try {
            Remove-LocalUser -Name $UserName -ErrorAction Stop
            Write-Step OK ("Removed local user {0}" -f $UserName)
        } catch {
            Write-Step WARN ("Failed removing user {0}: {1}" -f $UserName, $_.Exception.Message)
        }
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
        Write-Step WARN ("Profile cleanup failed for {0}: {1}" -f $UserName, $_.Exception.Message)
    }
}

function New-ZoomieSandboxCredential {
    param([int]$PasswordLength = 24)
    $userName = "Zoomie_{0}" -f (Get-Random -Minimum 10000 -Maximum 99999)
    $charSet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$-_='
    $securePassword = [System.Security.SecureString]::new()
    for ($i = 0; $i -lt $PasswordLength; $i++) {
        $securePassword.AppendChar($charSet[(Get-Random -Maximum $charSet.Length)])
    }
    $securePassword.MakeReadOnly()
    $qualifiedName = "{0}\{1}" -f $env:COMPUTERNAME, $userName
    return [pscustomobject]@{
        UserName      = $userName
        QualifiedName = $qualifiedName
        Password      = $securePassword
        Credential    = [pscredential]::new($qualifiedName, $securePassword)
    }
}

function New-ZoomieSandboxUser {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][securestring]$Password,
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$Description,
        # 'Users' for least-privilege sandboxing, 'Administrators' for the DJ/Webcam edition.
        [ValidateSet('Users', 'Administrators')][string]$Group = 'Users'
    )
    New-LocalUser -Name $UserName -Password $Password -FullName $FullName -Description $Description -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Write-Step OK ("Created local user {0} (group: {1})" -f $UserName, $Group)

    try {
        Add-LocalGroupMember -Group $Group -Member $UserName -ErrorAction Stop
        Write-Step OK ("Added {0} to the {1} group." -f $UserName, $Group)
    } catch {
        Write-Step WARN ("Failed adding {0} to the {1} group: {2}" -f $UserName, $Group, $_.Exception.Message)
    }
}

function Grant-ZoomiePathAccess {
    param([string]$Path, [string]$UserName)
    New-ZoomieDirectory -Path $Path
    $qualifiedUser = "{0}\{1}" -f $env:COMPUTERNAME, $UserName
    & icacls $Path /inheritance:e /grant:r ("{0}:(OI)(CI)M" -f $qualifiedUser) "Administrators:(OI)(CI)F" | Out-Null
    Write-Step INFO ("Granted strict sandbox access to {0}: {1}" -f $qualifiedUser, $Path)
}

function New-ZoomieDesktopShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$IconPath,
        [string]$Arguments = '-LaunchOnly'
    )
    $linkPath = Join-Path (Join-Path $env:PUBLIC 'Desktop') $Name
    if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath -Force }
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($linkPath)
        $shortcut.TargetPath = $TargetPath
        $shortcut.Arguments = $Arguments
        if ($IconPath) { $shortcut.IconLocation = $IconPath }
        $shortcut.WindowStyle = 1
        $shortcut.Save()
        Write-Step OK ("Created desktop shortcut: {0}" -f $Name)
    } catch {
        Write-Step WARN ("Failed to create shortcut {0}" -f $Name)
    }
}

function Test-FileIntegrity {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Write-Step INFO ("File: {0}" -f (Split-Path $Path -Leaf))
    Write-Step INFO ("Computed SHA-256: {0}" -f (Get-FileHash -Path $Path -Algorithm SHA256).Hash)
    return $true
}

function Get-RemoteLastModified {
    param([string]$Url)
    try {
        $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
        return $head.Headers['Last-Modified']
    } catch {
        return $null
    }
}

function Test-ZoomieDownloadNeeded {
    param([string]$Url, [string]$LocalPath, [string]$MetaFile)
    if (-not (Test-Path -LiteralPath $LocalPath)) { return $true }
    if (-not (Test-Path -LiteralPath $MetaFile)) { return $true }

    $remoteModified = Get-RemoteLastModified -Url $Url
    if (-not $remoteModified) {
        Write-Step WARN 'Could not check CDN headers for updates. Using local file.'
        return $false
    }

    $localModified = Get-Content -LiteralPath $MetaFile -Raw
    if ($remoteModified.Trim() -ne $localModified.Trim()) {
        Write-Step INFO ("Newer version detected on CDN for {0}." -f (Split-Path $LocalPath -Leaf))
        return $true
    }
    return $false
}

function Save-ZoomieDownloadMeta {
    param([string]$Url, [string]$MetaFile)
    $remoteModified = Get-RemoteLastModified -Url $Url
    if ($remoteModified) {
        Set-Content -LiteralPath $MetaFile -Value $remoteModified -Force
    }
}

function Install-ZoomieRuntime {
    <#
        Downloads (when stale) and runs CleanZoom plus the Zoom Workplace MSI.
        Shared by the Standard and DJ editions.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [Parameter(Mandatory = $true)][string]$StateDir,
        [int]$CleanupSettleSeconds = 15
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    $msiUrl = 'https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64'
    $cleanZoomUrl = 'https://assets.zoom.us/docs/msi-templates/CleanZoom.zip'
    $msiPath = Join-Path $ScriptDir 'ZoomInstallerFull.msi'
    $cleanZoomPath = Join-Path $ScriptDir 'CleanZoom.exe'
    $msiMetaFile = Join-Path $StateDir 'zoom_msi.meta'
    $cleanMetaFile = Join-Path $StateDir 'cleanzoom.meta'

    if (Test-ZoomieDownloadNeeded -Url $msiUrl -LocalPath $msiPath -MetaFile $msiMetaFile) {
        Write-Step INFO 'Downloading latest Zoom Workplace 64-bit MSI from official CDN...'
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
        if (-not (Test-FileIntegrity -Path $msiPath)) { throw 'MSI integrity validation failed.' }
        Save-ZoomieDownloadMeta -Url $msiUrl -MetaFile $msiMetaFile
        Write-Step OK 'Zoom 64-bit MSI updated and verified.'
    } else {
        Write-Step INFO 'Zoom 64-bit MSI is up to date.'
    }

    if (Test-ZoomieDownloadNeeded -Url $cleanZoomUrl -LocalPath $cleanZoomPath -MetaFile $cleanMetaFile) {
        Write-Step INFO 'Downloading latest CleanZoom utility...'
        $zipPath = Join-Path $env:TEMP 'CleanZoom.zip'
        Invoke-WebRequest -Uri $cleanZoomUrl -OutFile $zipPath -UseBasicParsing
        if (-not (Test-FileIntegrity -Path $zipPath)) { throw 'CleanZoom archive integrity validation failed.' }

        Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force
        Move-Item -Path (Join-Path $env:TEMP 'CleanZoom.exe') -Destination $cleanZoomPath -Force
        Remove-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue

        Save-ZoomieDownloadMeta -Url $cleanZoomUrl -MetaFile $cleanMetaFile
        Write-Step OK 'CleanZoom updated and verified.'
    } else {
        Write-Step INFO 'CleanZoom utility is up to date.'
    }

    Write-Step ACTION 'Executing CleanZoom.exe...'
    Start-Process -FilePath $cleanZoomPath -Wait

    Write-Step INFO ("Waiting {0} seconds for cleanup to settle..." -f $CleanupSettleSeconds)
    Start-Sleep -Seconds $CleanupSettleSeconds

    Write-Step ACTION 'Installing Zoom via MSI...'
    Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /quiet /norestart' -f $msiPath) -Wait
    Write-Step OK 'Zoom clean installation finished successfully.'
}

function Start-ZoomieInstance {
    <#
        Rotates the sandbox account, provisions its profile folders and launches
        Zoom as that account, blocking until Zoom exits.
    #>
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$Description,
        [ValidateSet('Users', 'Administrators')][string]$Group = 'Users'
    )

    $zoom = Get-ZoomExePath
    if (-not $zoom) { throw 'Zoom.exe was not found on system.' }
    Write-Step OK ("Using Zoom path: {0}" -f $zoom)

    if (Test-Path -LiteralPath $Paths.StateFile) {
        Remove-ZoomieSandboxUser -UserName (Get-Content -LiteralPath $Paths.StateFile -Raw).Trim()
    }

    $sandbox = New-ZoomieSandboxCredential
    Write-Step INFO ("Rotation: Spawning new isolated {0} user {1}" -f $Group, $sandbox.UserName)
    New-ZoomieSandboxUser -UserName $sandbox.UserName -Password $sandbox.Password -FullName $FullName -Description $Description -Group $Group

    $profileRoot = Join-Path $Paths.ProfilesDir $sandbox.UserName
    $profileData = Join-Path $profileRoot 'dataA'
    Grant-ZoomiePathAccess -Path $profileRoot -UserName $sandbox.UserName
    Grant-ZoomiePathAccess -Path $profileData -UserName $sandbox.UserName

    Set-Content -LiteralPath $Paths.StateFile -Value $sandbox.UserName -Encoding ascii -Force

    Write-Step ACTION ("Starting Zoom instance as sandbox user: {0}" -f $sandbox.QualifiedName)
    $process = Start-Process -FilePath $zoom -ArgumentList @('--multipt=TRUE', "--data=$profileData") -WorkingDirectory 'C:\ProgramData' -Credential $sandbox.Credential -PassThru -WindowStyle Normal
    if (-not $process) { throw 'Zoom Start-Process failed.' }
    Write-Step OK ("Zoom instance PID={0}" -f $process.Id)

    if ($process.Id -and (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
}
