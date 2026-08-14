function Get-CryptoRandomInt32 {
    param([Parameter(Mandatory)][int]$ExclusiveMaximum)
    if ($ExclusiveMaximum -le 0) { throw 'Exclusive maximum must be positive.' }
    $provider = [Security.Cryptography.RNGCryptoServiceProvider]::new()
    try {
        $bytes = [byte[]]::new(4)
        $range = [uint64]1 -shl 32
        $limit = $range - ($range % [uint64]$ExclusiveMaximum)
        do {
            $provider.GetBytes($bytes)
            $value = [uint64][BitConverter]::ToUInt32($bytes, 0)
        } while ($value -ge $limit)
        return [int]($value % [uint64]$ExclusiveMaximum)
    } finally {
        $provider.Dispose()
    }
}

function Get-RandomSecurePassword {
    $classes = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#%^*_+=.'
    )
    $password = [Security.SecureString]::new()
    foreach ($class in $classes) {
        $password.AppendChar($class[(Get-CryptoRandomInt32 $class.Length)])
    }
    $alphabet = $classes -join ''
    while ($password.Length -lt 24) {
        $password.AppendChar($alphabet[(Get-CryptoRandomInt32 $alphabet.Length)])
    }
    return $password
}

function Get-RandomSandboxName {
    return "Zoomie_{0:D5}" -f ((Get-CryptoRandomInt32 90000) + 10000)
}

function Invoke-ZoomieEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Standard', 'DJ')]
        [string]$Edition,
        [switch]$LaunchOnly
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $config = @{
        Standard = @{
            State = 'Zoom1132'; Log = 'engine'; Shortcut = 'Zoomie.lnk'
            Icon = 'ZOOM.WTF_icon.ico'; Exe = 'InstallZoomie-v1.2.0.exe'
            Group = 'Users'; FullName = 'Zoom Sandbox'; Description = 'Restricted ephemeral Zoom instance'
        }
        DJ = @{
            State = 'Zoom1132DJ'; Log = 'engine_dj'; Shortcut = 'Zoomie DJ.lnk'
            Icon = 'Zoomies.ico'; Exe = 'InstallZoomie-DJ-v1.2.0.exe'
            Group = 'Administrators'; FullName = 'Zoom DJ Sandbox'; Description = 'Zoom Sandbox Admin'
        }
    }[$Edition]
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
    $stateDir = Join-Path $env:ProgramData $config.State
    $logDir = Join-Path $stateDir 'logs'
    $profilesDir = Join-Path $stateDir 'profiles'
    $stagingDir = Join-Path $stateDir 'installers'
    $stateFile = Join-Path $stateDir 'active_zoom_user.txt'
    $logFile = Join-Path $logDir ("{0}_{1}.log" -f $config.Log, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    $allowedCn = @('Zoom Video Communications, Inc.')
    $sandboxPattern = '^Zoomie_\d{5}$'

    function Write-Step {
        param([string]$Level, [string]$Message)
        Write-Host ("[{0}] {1}" -f $Level.ToUpperInvariant(), $Message)
    }
    function Test-IsAdmin {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return [Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    function Invoke-Elevation {
        if (Test-IsAdmin) { return }
        $self = $PSCommandPath
        if (-not $self) { throw 'Could not determine script path for elevation.' }
        $elevationArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ("`"{0}`"" -f $self))
        if ($LaunchOnly) { $elevationArguments += '-LaunchOnly' }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($elevationArguments -join ' ')
        exit 0
    }
    function Assert-RestrictedAcl {
        param([string]$Path, [string[]]$Users)
        $grant = @('SYSTEM:(OI)(CI)(F)', 'Administrators:(OI)(CI)(F)')
        $grant += @($Users | ForEach-Object { "{0}:(OI)(CI)(M)" -f $_ })
        $result = & icacls.exe $Path /inheritance:r /grant:r $grant 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not apply ACL to ${Path}: $($result -join ' ')" }
        $bad = @(Get-Acl -LiteralPath $Path).Access | Where-Object {
            $_.IdentityReference.Value -match '(^|\\)(Users|Everyone|Authenticated Users)$'
        }
        if ($bad.Count) { throw "Unsafe ACL remains on $Path." }
    }
    function Initialize-AdminOnlyDirectory {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -LiteralPath $Path -Force | Out-Null
        }
        Assert-RestrictedAcl $Path @()
    }
    function Set-PathAclForUser {
        param([string]$Path, [string]$UserName)
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -LiteralPath $Path -Force | Out-Null
        }
        $qualified = "{0}\{1}" -f $env:COMPUTERNAME, $UserName
        Assert-RestrictedAcl $Path @($qualified)
        Write-Step INFO ("Granted strict sandbox access to {0}: {1}" -f $qualified, $Path)
    }
    function Initialize-Directories {
        Initialize-AdminOnlyDirectory $stateDir
        foreach ($dir in @($logDir, $profilesDir, $stagingDir)) {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -LiteralPath $dir -Force | Out-Null
            }
            Assert-RestrictedAcl $dir @()
        }
    }
    function Start-Logging {
        Initialize-Directories
        Start-Transcript -Path $logFile -Append | Out-Null
        Write-Step START ("InstallZoomie-{0}.ps1" -f $Edition)
        Write-Step INFO ("User={0} Computer={1} Edition={2}" -f $env:USERNAME, $env:COMPUTERNAME, $Edition)
        Write-Step INFO ("LaunchOnlyMode={0}" -f $LaunchOnly)
    }
    function Stop-Logging { try { Stop-Transcript | Out-Null } catch {} }
    function Get-ZoomExePath {
        $paths = [Collections.Generic.List[string]]::new()
        foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe')) {
            try {
                $value = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
                if ($value) { [void]$paths.Add($value) }
            } catch {}
        }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($base) { [void]$paths.Add((Join-Path $base 'Zoom\bin\Zoom.exe')) }
        }
        foreach ($userDir in Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue) {
            foreach ($relative in @('AppData\Roaming\Zoom\bin\Zoom.exe', 'AppData\Local\Programs\Zoom\bin\Zoom.exe', 'AppData\Zoom\bin\Zoom.exe')) {
                [void]$paths.Add((Join-Path $userDir.FullName $relative))
            }
        }
        foreach ($path in ($paths | Select-Object -Unique)) {
            if ($path -and (Test-Path -LiteralPath $path)) { return $path }
        }
        return $null
    }
    function Get-ProfileRecord {
        param([string]$UserName)
        $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
        if (-not $user) { return $null }
        $sid = $user.SID.Value
        $root = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        foreach ($key in @((Join-Path $root $sid), (Join-Path $root "$sid.bak"))) {
            try {
                $path = (Get-ItemProperty -LiteralPath $key -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
                if ($path) {
                    return [pscustomobject]@{
                        Sid = $sid
                        RegistryKey = $key
                        Path = [Environment]::ExpandEnvironmentVariables($path)
                    }
                }
            } catch {}
        }
        return [pscustomobject]@{ Sid = $sid; RegistryKey = $null; Path = $null }
    }
    function Remove-AccountAndProfile {
        param([string]$UserName)
        if ($UserName -notmatch $sandboxPattern) { return }
        $record = Get-ProfileRecord $UserName
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($record -and $record.Sid -eq $currentSid) { return }
        if ($record) {
            $hive = "HKU\$($record.Sid)"
            & reg.exe query $hive 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & reg.exe unload $hive 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Could not unload registry hive for $UserName." }
            }
        }
        $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
        if ($user) {
            Remove-LocalUser -Name $UserName -ErrorAction Stop
            Write-Step OK ("Removed local user {0}" -f $UserName)
        }
        if ($record -and $record.RegistryKey) {
            Remove-Item -LiteralPath $record.RegistryKey -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($record -and $record.Path -and (Test-Path -LiteralPath $record.Path)) {
            Remove-Item -LiteralPath $record.Path -Recurse -Force -ErrorAction Stop
            Write-Step OK ("Removed profile {0}" -f $record.Path)
        }
        $sandboxPath = Join-Path $profilesDir $UserName
        if (Test-Path -LiteralPath $sandboxPath) {
            Remove-Item -LiteralPath $sandboxPath -Recurse -Force -ErrorAction Stop
            Write-Step OK ("Removed sandbox data {0}" -f $sandboxPath)
        }
    }
    function Test-SandboxUserLive {
        param([string]$UserName)
        $escapedName = [regex]::Escape($UserName)
        $processes = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object {
            $_.UserName -match "\\$escapedName$"
        })
        if ($processes.Count -gt 0) { return $true }
        $sessions = & quser.exe 2>$null
        if ($LASTEXITCODE -eq 0 -and ($sessions -match "(^|\s)$escapedName(\s|$)")) { return $true }
        return $false
    }
    function Initialize-SandboxProfile {
        param([string]$UserName, [securestring]$Password)
        try {
            $credential = [pscredential]::new(("{0}\{1}" -f $env:COMPUTERNAME, $UserName), $Password)
            $probe = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
                -ArgumentList '/c exit 0' -Credential $credential -LoadUserProfile -Wait -PassThru `
                -WindowStyle Hidden
            if (-not $probe) { throw 'Profile materialization process did not start.' }
            $record = Get-ProfileRecord $UserName
            if (-not $record -or -not $record.Path -or -not (Test-Path -LiteralPath (Join-Path $record.Path 'NTUSER.DAT'))) {
                throw 'Profile materialization did not produce NTUSER.DAT.'
            }
            Write-Step INFO ("Materialized profile for {0}: {1}" -f $UserName, $record.Path)
            return $record
        } catch {
            Write-Step WARN ("Could not materialize profile for {0}: {1}" -f $UserName, $_.Exception.Message)
            return $null
        }
    }
    function Get-ConsentValue {
        param([string]$Path)
        try {
            return (Get-ItemProperty -LiteralPath $Path -Name Value -ErrorAction Stop).Value
        } catch {
            return $null
        }
    }
    function Set-SandboxMediaConsent {
        param([string]$UserName, [string]$Sid, [string]$ProfilePath)
        $gpoPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
        $policy = @{
            webcam = 'LetAppsAccessCamera'
            microphone = 'LetAppsAccessMicrophone'
        }
        $hkuRoot = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
        $loadedHere = $false
        try {
            $cameraPolicy = $null
            $microphonePolicy = $null
            if (Test-Path -LiteralPath $gpoPath) {
                $cameraGpo = Get-ItemProperty -LiteralPath $gpoPath -Name $policy.webcam `
                    -ErrorAction SilentlyContinue
                $microphoneGpo = Get-ItemProperty -LiteralPath $gpoPath -Name $policy.microphone `
                    -ErrorAction SilentlyContinue
                if ($cameraGpo) { $cameraPolicy = $cameraGpo.($policy.webcam) }
                if ($microphoneGpo) { $microphonePolicy = $microphoneGpo.($policy.microphone) }
            }
            if ($cameraPolicy -eq 2) {
                Write-Step WARN 'Camera access is force-denied by Group Policy.'
            }
            if ($microphonePolicy -eq 2) {
                Write-Step WARN 'Microphone access is force-denied by Group Policy.'
            }

            foreach ($device in @('webcam', 'microphone')) {
                $machinePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$device"
                $machineValue = Get-ConsentValue $machinePath
                $machineChildValue = Get-ConsentValue (Join-Path $machinePath 'NonPackaged')
                if ($machineValue -eq 'Deny' -or $machineChildValue -eq 'Deny') {
                    Write-Step WARN ("{0} machine consent floor is Deny; HKLM was not modified." -f $device)
                }
            }

            & reg.exe query "HKU\$Sid" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $hivePath = Join-Path $ProfilePath 'NTUSER.DAT'
                if (-not (Test-Path -LiteralPath $hivePath)) {
                    Write-Step WARN ("Could not grant media consent for {0}: NTUSER.DAT is missing." -f $UserName)
                    return
                }
                $loadResult = & reg.exe load "HKU\$Sid" $hivePath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Step WARN ("Could not load profile hive for {0}: {1}" -f $UserName, ($loadResult -join ' ').Trim())
                    return
                }
                $loadedHere = $true
            }

            foreach ($device in @('webcam', 'microphone')) {
                $devicePolicy = if ($device -eq 'webcam') { $cameraPolicy } else { $microphonePolicy }
                if ($devicePolicy -eq 2) { continue }
                $userPath = Join-Path $hkuRoot $device
                $userChildPath = Join-Path $userPath 'NonPackaged'
                try {
                    New-Item -LiteralPath $userPath -Force -ErrorAction Stop | Out-Null
                    New-ItemProperty -LiteralPath $userPath -Name Value -PropertyType String -Value Allow -Force -ErrorAction Stop | Out-Null
                    New-Item -LiteralPath $userChildPath -Force -ErrorAction Stop | Out-Null
                    New-ItemProperty -LiteralPath $userChildPath -Name Value -PropertyType String -Value Allow -Force -ErrorAction Stop | Out-Null
                    $parentValue = Get-ConsentValue $userPath
                    $childValue = Get-ConsentValue $userChildPath
                    if ($parentValue -eq 'Allow' -and $childValue -eq 'Allow') {
                        Write-Step INFO ("{0} consent granted for {1} (device and NonPackaged)." -f $device, $UserName)
                    } else {
                        Write-Step WARN ("{0} consent could not be verified for {1}." -f $device, $UserName)
                    }
                } catch {
                    Write-Step WARN ("Could not grant {0} consent for {1}: {2}" -f $device, $UserName, $_.Exception.Message)
                }
            }
        } finally {
            if ($loadedHere) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                $unloadResult = & reg.exe unload "HKU\$Sid" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Step INFO ("Unloaded temporary profile hive for {0}." -f $UserName)
                } else {
                    Write-Step WARN ("Could not unload temporary profile hive for {0}: {1}" -f $UserName, ($unloadResult -join ' ').Trim())
                }
            }
        }
    }
    function Invoke-MediaPreflight {
        Write-Step INFO 'Media device preflight:'
        try {
            $gpoPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
            $camera = $null
            $microphone = $null
            $cameraGpo = Get-ItemProperty -LiteralPath $gpoPath -Name LetAppsAccessCamera `
                -ErrorAction SilentlyContinue
            $microphoneGpo = Get-ItemProperty -LiteralPath $gpoPath -Name LetAppsAccessMicrophone `
                -ErrorAction SilentlyContinue
            if ($cameraGpo) { $camera = $cameraGpo.LetAppsAccessCamera }
            if ($microphoneGpo) { $microphone = $microphoneGpo.LetAppsAccessMicrophone }
            $cameraState = if ($camera -eq 2) { 'ForceDeny' } elseif ($camera -eq 1) { 'ForceAllow' } else { 'UserControl/Unset' }
            $microphoneState = if ($microphone -eq 2) { 'ForceDeny' } elseif ($microphone -eq 1) { 'ForceAllow' } else { 'UserControl/Unset' }
            Write-Step INFO ("GPO camera={0}; microphone={1}" -f $cameraState, $microphoneState)
        } catch {
            Write-Step WARN ("GPO media policy probe failed: {0}" -f $_.Exception.Message)
        }
        try {
            $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='FrameServer'" -ErrorAction Stop
            if ($service) {
                Write-Step INFO ("FrameServer start type: {0}" -f $service.StartMode)
            } else {
                Write-Step WARN 'FrameServer service was not found.'
            }
        } catch {
            Write-Step WARN ("FrameServer probe failed: {0}" -f $_.Exception.Message)
        }
        try {
            $category = '{860BB310-5D01-11D0-BD3B-00A0C911CE86}'
            $roots = @(
                "HKLM:\SOFTWARE\Classes\CLSID\$category\Instance",
                "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\$category\Instance"
            )
            $devices = @()
            foreach ($root in $roots) {
                if (Test-Path -LiteralPath $root) {
                    foreach ($entry in Get-ChildItem -LiteralPath $root -ErrorAction Stop) {
                        $name = (Get-ItemProperty -LiteralPath $entry.PSPath -Name FriendlyName -ErrorAction SilentlyContinue).FriendlyName
                        if ($name) { $devices += $name }
                    }
                }
            }
            $devices = @($devices | Sort-Object -Unique)
            if ($devices.Count) {
                foreach ($device in $devices) { Write-Step INFO ("DirectShow camera: {0}" -f $device) }
            } else {
                Write-Step WARN 'No DirectShow video-input devices were registered.'
            }
        } catch {
            Write-Step WARN ("DirectShow camera probe failed: {0}" -f $_.Exception.Message)
        }
        try {
            foreach ($flow in @(
                @{ Label = 'render'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render' },
                @{ Label = 'capture'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture' }
            )) {
                $endpoints = @(Get-ChildItem -LiteralPath $flow.Path -ErrorAction Stop)
                if (-not $endpoints.Count) {
                    Write-Step WARN ("Audio {0} endpoints: none registered." -f $flow.Label)
                    continue
                }
                foreach ($endpoint in $endpoints) {
                    $propertyPath = Join-Path $endpoint.PSPath 'Properties'
                    $friendlyName = $null
                    if (Test-Path -LiteralPath $propertyPath) {
                        $property = Get-ItemProperty -LiteralPath $propertyPath `
                            -Name '{a45c254e-df1c-4efd-8020-67d146a850e0},14' `
                            -ErrorAction SilentlyContinue
                        if ($property) {
                            $bytes = $property.'{a45c254e-df1c-4efd-8020-67d146a850e0},14'
                            if ($bytes -is [byte[]] -and $bytes.Length -gt 12) {
                                $friendlyName = [Text.Encoding]::Unicode.GetString(
                                    $bytes, 12, $bytes.Length - 12).Trim([char]0)
                            }
                        }
                    }
                    if (-not $friendlyName) { $friendlyName = $endpoint.PSChildName }
                    Write-Step INFO ("Audio {0} endpoint: {1}" -f $flow.Label, $friendlyName)
                }
            }
        } catch {
            Write-Step WARN ("Audio endpoint probe failed: {0}" -f $_.Exception.Message)
        }
    }
    function Remove-OrphanSandboxAccounts {
        $currentName = [Environment]::UserName
        foreach ($user in @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match $sandboxPattern -and $_.Name -ne $currentName
        })) {
            if (Test-SandboxUserLive -UserName $user.Name) {
                Write-Step WARN ("Leaving live sandbox user in place: {0}" -f $user.Name)
                continue
            }
            try {
                Remove-AccountAndProfile $user.Name
            } catch {
                Write-Step WARN ("Failed cleaning sandbox user {0}: {1}" -f $user.Name, $_.Exception.Message)
            }
        }
    }
    function New-SandboxAccount {
        param([string]$UserName, [securestring]$Password)
        New-LocalUser -Name $UserName -Password $Password -FullName $config.FullName `
            -Description $config.Description -PasswordNeverExpires -AccountNeverExpires | Out-Null
        $qualifiedName = "{0}\{1}" -f $env:COMPUTERNAME, $UserName
        try {
            Add-LocalGroupMember -Group $config.Group -Member $UserName -ErrorAction Stop
        } catch {
            $member = Get-LocalGroupMember -Group $config.Group -ErrorAction Stop |
                Where-Object { $_.Name -eq $qualifiedName -or $_.SID.Value -eq (Get-LocalUser -Name $UserName).SID.Value }
            if (-not $member) { throw }
        }
        Write-Step OK ("Created {0} sandbox user {1}" -f $Edition, $UserName)
    }
    function Get-TrustedPublisherCn {
        param($Certificate)
        $cn = $Certificate.Subject -split ',' |
            Where-Object { $_.Trim().StartsWith('CN=') } |
            Select-Object -First 1
        if (-not $cn) { throw 'Signer certificate has no CN.' }
        return $cn.Trim().Substring(3).Trim('"')
    }
    function Assert-TrustedInstaller {
        param([string]$Path, [string[]]$AllowedCn)
        if (-not (Test-Path -LiteralPath $Path)) { throw "Installer missing: $Path" }
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if ($signature.Status -ne 'Valid') { throw "Signature status: $($signature.Status)" }
        $cn = Get-TrustedPublisherCn $signature.SignerCertificate
        if ($AllowedCn -notcontains $cn) { throw "Untrusted publisher: $cn" }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    function Assert-HashUnchanged {
        param([string]$Path, [string]$ExpectedHash)
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $ExpectedHash) {
            throw "File changed after verification: $(Split-Path $Path -Leaf)"
        }
    }
    function Test-NeedsUpdate {
        param([string]$Url, [string]$LocalPath, [string]$MetaFile)
        if (-not (Test-Path -LiteralPath $LocalPath)) { return $true }
        try {
            $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
            $remote = $head.Headers['Last-Modified']
            if (-not (Test-Path -LiteralPath $MetaFile)) { return $true }
            $local = Get-Content -LiteralPath $MetaFile -Raw
            return [bool]($remote -and $remote.Trim() -ne $local.Trim())
        } catch {
            Write-Step WARN 'Could not check CDN headers. Retaining staged file for signature verification.'
            return $false
        }
    }
    function Set-DownloadMetadata {
        param([string]$Url, [string]$MetaFile)
        try {
            $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
            if ($head.Headers['Last-Modified']) {
                Set-Content -LiteralPath $MetaFile -Value $head.Headers['Last-Modified'] -Force
            }
        } catch {}
    }
    function New-DesktopShortcut {
        $linkPath = Join-Path (Join-Path $env:PUBLIC 'Desktop') $config.Shortcut
        if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath -Force }
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $shortcut = $wsh.CreateShortcut($linkPath)
            $shortcut.TargetPath = Join-Path $scriptDir $config.Exe
            $shortcut.Arguments = '-LaunchOnly'
            $shortcut.IconLocation = Join-Path $scriptDir $config.Icon
            $shortcut.WindowStyle = 1
            $shortcut.Save()
            Write-Step OK ("Created desktop shortcut: {0}" -f $config.Shortcut)
        } catch { Write-Step WARN 'Failed to create shortcut.' }
    }

    $activeUser = $null
    try {
        Invoke-Elevation
        Start-Logging
        Remove-OrphanSandboxAccounts
        if (-not $LaunchOnly) {
            New-DesktopShortcut
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            $msiUrl = 'https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64'
            $cleanUrl = 'https://assets.zoom.us/docs/msi-templates/CleanZoom.zip'
            $msiPath = Join-Path $stagingDir 'ZoomInstallerFull.msi'
            $cleanPath = Join-Path $stagingDir 'CleanZoom.exe'
            $msiMeta = Join-Path $stateDir 'zoom_msi.meta'
            $cleanMeta = Join-Path $stateDir 'cleanzoom.meta'
            if (Test-NeedsUpdate -Url $msiUrl -LocalPath $msiPath -MetaFile $msiMeta) {
                Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
                Set-DownloadMetadata $msiUrl $msiMeta
            }
            $msiHash = Assert-TrustedInstaller $msiPath $allowedCn
            if (Test-NeedsUpdate -Url $cleanUrl -LocalPath $cleanPath -MetaFile $cleanMeta) {
                $zipPath = Join-Path $stagingDir 'CleanZoom.zip'
                Invoke-WebRequest -Uri $cleanUrl -OutFile $zipPath -UseBasicParsing
                Expand-Archive -LiteralPath $zipPath -DestinationPath $stagingDir -Force
                Move-Item -LiteralPath (Join-Path $stagingDir 'CleanZoom.exe') -Destination $cleanPath -Force
                Remove-Item -LiteralPath $zipPath -Force
                Set-DownloadMetadata $cleanUrl $cleanMeta
            }
            Assert-TrustedInstaller $cleanPath $allowedCn | Out-Null
            Start-Process -FilePath $cleanPath -Wait
            Start-Sleep -Seconds 15
            Assert-HashUnchanged $msiPath $msiHash
            Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait
        }
        $zoom = Get-ZoomExePath
        if (-not $zoom) { throw 'Zoom.exe was not found on system.' }
        $activeUser = Get-RandomSandboxName
        Set-Content -LiteralPath $stateFile -Value $activeUser -Encoding ascii -Force
        $securePassword = Get-RandomSecurePassword
        New-SandboxAccount $activeUser $securePassword
        $profileRoot = Join-Path $profilesDir $activeUser
        $profileA = Join-Path $profileRoot 'dataA'
        Set-PathAclForUser $profileRoot $activeUser
        Set-PathAclForUser $profileA $activeUser
        $profileRecord = Initialize-SandboxProfile -UserName $activeUser -Password $securePassword
        if ($profileRecord) {
            Set-SandboxMediaConsent -UserName $activeUser -Sid $profileRecord.Sid -ProfilePath $profileRecord.Path
        }
        Invoke-MediaPreflight
        $credential = [pscredential]::new(("{0}\{1}" -f $env:COMPUTERNAME, $activeUser), $securePassword)
        $process = Start-Process -FilePath $zoom -ArgumentList @('--multipt=TRUE', "--data=$profileA") `
            -WorkingDirectory 'C:\ProgramData' -Credential $credential -PassThru -WindowStyle Normal
        if (-not $process) { throw 'Zoom Start-Process failed.' }
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
        Write-Step DONE 'Completed successfully.'
    } catch {
        Write-Step FATAL $_.Exception.Message
        Write-Step FATAL ("See log: {0}" -f $logFile)
    } finally {
        if ($activeUser) {
            try { Remove-AccountAndProfile $activeUser } catch { Write-Step WARN $_.Exception.Message }
            try { if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force } } catch {}
        }
        Stop-Logging
        Write-Host "`n====================================================" -ForegroundColor Cyan
        Write-Host 'Process finished. Press any key to close the window...' -ForegroundColor Green
        Write-Host "====================================================" -ForegroundColor Cyan
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}
