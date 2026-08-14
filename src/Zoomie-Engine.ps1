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
    function Remove-OrphanSandboxAccounts {
        $currentName = [Environment]::UserName
        foreach ($user in @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match $sandboxPattern -and $_.Name -ne $currentName
        })) {
            Remove-AccountAndProfile $user.Name
        }
    }
    function New-SandboxAccount {
        param([string]$UserName, [securestring]$Password)
        New-LocalUser -Name $UserName -Password $Password -FullName $config.FullName `
            -Description $config.Description -PasswordNeverExpires -AccountNeverExpires | Out-Null
        Add-LocalGroupMember -Group $config.Group -Member $UserName -ErrorAction Stop
        Write-Step OK ("Created {0} sandbox user {1}" -f $Edition, $UserName)
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
            $password.AppendChar($class[[Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
        }
        $alphabet = $classes -join ''
        while ($password.Length -lt 24) {
            $password.AppendChar($alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)])
        }
        return $password
    }
    function Get-RandomSandboxName {
        return "Zoomie_{0:D5}" -f [Security.Cryptography.RandomNumberGenerator]::GetInt32(10000, 100000)
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
            $cleanHash = Assert-TrustedInstaller $cleanPath $allowedCn
            Assert-HashUnchanged $cleanPath $cleanHash
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
