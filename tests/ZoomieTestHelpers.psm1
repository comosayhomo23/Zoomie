Set-StrictMode -Version Latest

<#
The Zoomie scripts are single-file executables: every function lives next to a
top-level "MAIN EXECUTION" block that elevates the process, installs Zoom and
waits for a key press. Dot-sourcing them would run that block, so the tests
extract only the function definitions from the parsed AST and evaluate those.
#>

function Get-ZoomieRepoRoot {
    [CmdletBinding()]
    param()
    Split-Path -Parent $PSScriptRoot
}

function Get-ZoomieScriptPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Get-ZoomieRepoRoot) $Name
}

function Get-ScriptFunctionDefinition {
    <#
    .SYNOPSIS
    Returns a scriptblock defining every function found in a .ps1 file.
    .DESCRIPTION
    Functions declared inside the main try/catch block (Test-NeedsUpdate,
    Test-FileIntegrity) are included as well, so nested definitions are covered.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Name
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Failed to parse {0}: {1}" -f $Path, ($errors[0].Message))
    }

    $functions = $ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true)

    if ($Name) {
        $functions = @($functions | Where-Object { $Name -contains $_.Name })
        $missing = @($Name | Where-Object { $found = $_; -not ($functions | Where-Object { $_.Name -eq $found }) })
        if ($missing) {
            throw ("Functions not found in {0}: {1}" -f $Path, ($missing -join ', '))
        }
    }

    [scriptblock]::Create((($functions | ForEach-Object { $_.Extent.Text }) -join "`n`n"))
}

function Get-ScriptVariableValue {
    <#
    .SYNOPSIS
    Evaluates a top-level `$script:<Name> = ...` assignment from a .ps1 file.
    .DESCRIPTION
    Used to assert on the state/log directory layout without executing the
    script's main block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Failed to parse {0}: {1}" -f $Path, ($errors[0].Message))
    }

    $assignments = @($ast.FindAll(
        {
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left.Extent.Text -like '$script:*'
        },
        $true))

    $index = -1
    for ($i = 0; $i -lt $assignments.Count; $i++) {
        if ($assignments[$i].Left.Extent.Text -eq ('$script:' + $Name)) { $index = $i; break }
    }
    if ($index -lt 0) {
        throw ("No assignment to `$script:{0} in {1}" -f $Name, $Path)
    }

    # Later assignments build on earlier ones ($script:LogDir uses $script:StateDir),
    # so replay everything up to the requested variable.
    $statements = ($assignments[0..$index] | ForEach-Object { $_.Extent.Text }) -join "`n"
    & ([scriptblock]::Create(($statements + "`n" + ('$script:' + $Name))))
}

$script:CommandStubs = @{
    'Get-LocalUser' = {
        [CmdletBinding()] param([Parameter(Position = 0)][string]$Name)
        throw 'Get-LocalUser stub was called without being mocked.'
    }
    'New-LocalUser' = {
        [CmdletBinding()] param(
            [Parameter(Position = 0)][string]$Name,
            [securestring]$Password,
            [string]$FullName,
            [string]$Description,
            [switch]$PasswordNeverExpires,
            [switch]$AccountNeverExpires,
            [switch]$NoPassword)
        throw 'New-LocalUser stub was called without being mocked.'
    }
    'Remove-LocalUser' = {
        [CmdletBinding()] param([Parameter(Position = 0)][string]$Name)
        throw 'Remove-LocalUser stub was called without being mocked.'
    }
    'Add-LocalGroupMember' = {
        [CmdletBinding()] param(
            [Parameter(Position = 0)][string]$Group,
            [Parameter(Position = 1)][string[]]$Member)
        throw 'Add-LocalGroupMember stub was called without being mocked.'
    }
    'Get-CimInstance' = {
        [CmdletBinding()] param(
            [Parameter(Position = 0)][string]$ClassName,
            [string]$Filter,
            [string]$Namespace,
            [string]$Query)
        throw 'Get-CimInstance stub was called without being mocked.'
    }
    'Remove-CimInstance' = {
        [CmdletBinding()] param(
            [Parameter(Position = 0, ValueFromPipeline = $true)][object]$InputObject)
        process { throw 'Remove-CimInstance stub was called without being mocked.' }
    }
    'icacls' = {
        param()
        throw 'icacls stub was called without being mocked.'
    }
    'Invoke-ps2exe' = {
        [CmdletBinding()] param(
            [string]$InputFile,
            [string]$OutputFile,
            [string]$IconFile,
            [switch]$RequireAdmin,
            [string]$Title,
            [string]$Company,
            [string]$Product,
            [string]$Version)
        throw 'Invoke-ps2exe stub was called without being mocked.'
    }
}

function Register-WindowsCommandStub {
    <#
    .SYNOPSIS
    Defines global stubs for commands that only exist on Windows.
    .DESCRIPTION
    Pester derives a mock's parameters from the command it replaces, so the
    Windows-only account/CIM cmdlets (plus the icacls executable and the ps2exe
    module) need a stub with a matching signature on platforms where they are
    missing. Real commands are never shadowed, and every stub throws so an
    unmocked call is loud rather than silently passing.
    #>
    [CmdletBinding()]
    param([string[]]$Name = @($script:CommandStubs.Keys))

    foreach ($command in $Name) {
        if (Get-Command -Name $command -ErrorAction SilentlyContinue) { continue }
        Set-Item -Path ("function:global:{0}" -f $command) -Value $script:CommandStubs[$command]
    }

    # New-Object only exposes -ComObject on Windows; wrap it elsewhere so the
    # shortcut code can be mocked, delegating anything non-COM to the cmdlet.
    if (-not (Get-Command New-Object).Parameters.ContainsKey('ComObject')) {
        Set-Item -Path 'function:global:New-Object' -Value {
            [CmdletBinding()] param(
                [Parameter(Position = 0)][string]$TypeName,
                [Parameter(Position = 1)][object[]]$ArgumentList,
                [string]$ComObject,
                [switch]$Strict)
            if ($ComObject) {
                throw ("Cannot create COM object '{0}' on this platform." -f $ComObject)
            }
            Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
        }
    }
}

function Register-FakeSystemDrive {
    <#
    .SYNOPSIS
    Maps a C: PowerShell drive on non-Windows hosts.
    .DESCRIPTION
    Get-ZoomExePath scans the hard-coded 'C:\Users' path with the -Directory
    dynamic parameter, which cannot even bind (let alone be mocked) while the
    C: drive does not resolve.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    if ($IsWindows) { return }
    if (Get-PSDrive -Name C -ErrorAction SilentlyContinue) { return }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    New-PSDrive -Name C -PSProvider FileSystem -Root $Root -Scope Global | Out-Null
}

function Set-ZoomieFakeEnvironment {
    <#
    .SYNOPSIS
    Points the Windows environment variables the scripts read at a sandbox root.
    .DESCRIPTION
    The scripts build paths with Join-Path, which cannot resolve a 'C:' drive
    qualifier on Linux, so tests use real directories under the sandbox instead
    of hard-coded Windows paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ComputerName = 'TESTPC'
    )

    $paths = [pscustomobject]@{
        SystemDrive     = Join-Path $Root 'drive'
        ProgramData     = Join-Path $Root 'ProgramData'
        ProgramFiles    = Join-Path $Root 'ProgramFiles'
        ProgramFilesX86 = Join-Path $Root 'ProgramFilesX86'
        Public          = Join-Path $Root 'Public'
        Temp            = Join-Path $Root 'Temp'
        ComputerName    = $ComputerName
    }

    $env:SystemDrive             = $paths.SystemDrive
    $env:ProgramData             = $paths.ProgramData
    $env:ProgramFiles            = $paths.ProgramFiles
    ${env:ProgramFiles(x86)}     = $paths.ProgramFilesX86
    $env:PUBLIC                  = $paths.Public
    $env:TEMP                    = $paths.Temp
    $env:COMPUTERNAME            = $ComputerName

    $paths
}

function New-ZoomieSandbox {
    <#
    .SYNOPSIS
    Creates an isolated copy of a repository script under a temporary root.
    .DESCRIPTION
    The build/scaffolding scripts operate on $PSScriptRoot, so running a copy
    keeps their side effects (Set-Location, New-Item, Remove-Item) inside the
    sandbox instead of the working tree.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ScriptName)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("zoomie-tests-{0}" -f [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    $copied = [ordered]@{}
    foreach ($name in $ScriptName) {
        $destination = Join-Path $root (Split-Path $name -Leaf)
        Copy-Item -LiteralPath (Get-ZoomieScriptPath $name) -Destination $destination -Force
        $copied[(Split-Path $name -Leaf)] = $destination
    }

    [pscustomobject]@{
        Root    = $root
        Scripts = $copied
    }
}

function Remove-ZoomieSandbox {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-FakeShortcutShell {
    <#
    .SYNOPSIS
    Returns a stand-in for the WScript.Shell COM object plus the shortcut it hands out.
    #>
    [CmdletBinding()]
    param()

    $shortcut = [pscustomobject]@{
        FullName     = $null
        TargetPath   = $null
        Arguments    = $null
        IconLocation = $null
        WindowStyle  = $null
        Saved        = $false
    }
    $shortcut | Add-Member -MemberType ScriptMethod -Name Save -Value { $this.Saved = $true }

    $shell = [pscustomobject]@{ Shortcut = $shortcut; RequestedPath = $null }
    $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
        param([string]$Path)
        $this.RequestedPath = $Path
        $this.Shortcut.FullName = $Path
        $this.Shortcut
    }

    $shell
}

Export-ModuleMember -Function @(
    'Get-ZoomieRepoRoot'
    'Get-ZoomieScriptPath'
    'Get-ScriptFunctionDefinition'
    'Get-ScriptVariableValue'
    'Register-WindowsCommandStub'
    'Set-ZoomieFakeEnvironment'
    'Register-FakeSystemDrive'
    'New-ZoomieSandbox'
    'Remove-ZoomieSandbox'
    'New-FakeShortcutShell'
)
