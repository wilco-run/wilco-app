# Installer for the Wilco desktop app on Windows (x64; Windows PowerShell 5.1 and PowerShell 7+).
#
#   irm https://wilco.run/download/app/install.ps1 | iex
#
# Options (the same as the macOS install.sh where they apply):
#   & ([scriptblock]::Create((irm https://wilco.run/download/app/install.ps1))) -Uninstall
#   & ([scriptblock]::Create((irm https://wilco.run/download/app/install.ps1))) -Version v0.1.1-test.20261010.1
#   ... -NoLaunch | -AllowAdmin | -Help
#
# What it does: reads SHA256SUMS from https://wilco.run/download/app/, which names the one Windows installer
# (Wilco-<version>-<build id>-win-x64.exe) and its SHA-256; downloads the installer, checks the checksum and that it
# is a Windows program, and runs it silently. The installer installs Wilco for this Windows account only
# (%LOCALAPPDATA%\Programs, no administrator rights), over an installed copy if there is one (a running Wilco is
# asked to close first; sessions and settings are kept), adds Start menu and desktop shortcuts, and opens Wilco
# (not with -NoLaunch).
#
# Test builds are not signed with a code signing certificate. Windows shows "Windows protected your PC" for an
# installer a web browser downloaded; this script downloads it itself, which Windows does not mark as coming from
# the internet, so it runs without that screen. On a PC with Smart App Control on, Windows refuses unsigned apps.
#
# -Version TAG installs an earlier build from the release archive on GitHub
# (https://github.com/wilco-run/wilco-app/releases/download/TAG/), which holds the same files under the same names.
# -Uninstall runs Wilco's own uninstaller silently; %APPDATA%\Wilco and %USERPROFILE%\.wilco are kept.
#
# Environment (mirrors and tests): WILCO_APP_DOWNLOAD_BASE replaces https://wilco.run/download/app (any folder with
# SHA256SUMS and the installer, such as one GitHub archive release); WILCO_APP_ARCHIVE_BASE replaces
# https://github.com/wilco-run/wilco-app/releases/download (for -Version).
#
# Rules for this file (as client/wilco-install.ps1): pure ASCII (Windows PowerShell 5.1 reads BOM-less files with
# the ANSI code page); never `exit` (`irm | iex` runs in the caller's session); everything in one script block, so
# no variable, function or preference leaks to the caller; downloads and SHA-256 through .NET (a Windows
# PowerShell 5.1 started from PowerShell 7 may fail to load Get-FileHash).

& {
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Version = '',
    [switch]$Uninstall,
    [switch]$NoLaunch,
    [switch]$AllowAdmin,
    [Alias('h')][switch]$Help,
    [switch]$ThrowOnError,
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# All state in one hashtable (no $script: scope under irm | iex).
$A = @{}
$A.Repo = 'wilco-run/wilco-app'
# wilco.run serves the current build here (the download tool that publishes this script checks this line).
$A.DefaultBase = 'https://wilco.run/download/app'
$A.ArchiveDefault = 'https://github.com/wilco-run/wilco-app/releases/download'
$A.OptCmd = '& ([scriptblock]::Create((irm https://wilco.run/download/app/install.ps1)))'
$A.InstallerRe = '^Wilco-(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})-[0-9]{8}T[0-9]{6}Z-win-x64\.exe$'
$A.TagRe = '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
$A.MaxSums = 65536
$A.MaxInstaller = [long]1073741824
$A.UserAgent = 'wilco-app-installer/1 (windows)'
$A.Uninstaller = 'Uninstall Wilco.exe'
$A.Tmp = ''
$A.OldProtocol = $null

function Say([string]$Text) { Write-Host $Text }
function Fail([string]$Text) { throw [System.InvalidOperationException]::new($Text) }

function Show-WaHelp {
    Say 'Wilco desktop app installer for Windows (x64)'
    Say ''
    Say 'Install or update:  irm https://wilco.run/download/app/install.ps1 | iex'
    Say ('Options:            ' + $A.OptCmd + ' <option>')
    Say '  -Version TAG   install this build (for example v0.1.1-test.20261010.1) from the release archive'
    Say '  -NoLaunch      do not open Wilco after installing'
    Say '  -Uninstall     remove Wilco; your sessions and settings are kept'
    Say '  -AllowAdmin    run from an administrator PowerShell anyway (not recommended)'
    Say '  -Help          show this help'
}

# The uninstall entry Wilco's installer writes for this user (HKCU), found by its uninstaller's name.
function Get-WaEntry {
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $v -or -not $v.PSObject.Properties['UninstallString']) { continue }
        if ([string]$v.UninstallString -like ('*\' + $A.Uninstaller + '"*')) { return $v }
    }
    return $null
}

function Split-WaCommand([string]$Line) {
    $m = [regex]::Match($Line, '^\s*"([^"]+)"\s*(.*)$')
    if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[2].Value) }
    $m = [regex]::Match($Line, '^\s*(\S+)\s*(.*)$')
    return @($m.Groups[1].Value, $m.Groups[2].Value)
}

# Runs a program and waits for it (no window); returns its exit code. Throws when it does not finish in time.
function Invoke-WaProgram([string]$File, [string]$Arguments, [int]$Seconds) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Not PowerShell 7's module path: the installer runs Windows PowerShell 5.1, which cannot load its modules from there.
    if ($psi.EnvironmentVariables.ContainsKey('PSModulePath')) { $psi.EnvironmentVariables.Remove('PSModulePath') }
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($Seconds * 1000)) { Fail ('"' + [IO.Path]::GetFileName($File) + '" did not finish within ' + $Seconds + ' seconds.') }
    $p.WaitForExit()
    return $p.ExitCode
}

# GET over https into a file, at most $Max bytes; returns the number of bytes. GitHub's archive answers with a
# redirect to its download host, which is followed as long as it stays https.
function Save-WaUrl([string]$Url, [string]$Path, [long]$Max) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = $A.UserAgent
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 60000
    $req.AllowAutoRedirect = $true
    $resp = $null
    try {
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) { Fail ('Downloading ' + $Url + ' failed: HTTP ' + [int]$r.StatusCode + '.') }
            Fail ('Downloading ' + $Url + ' failed: ' + $_.Exception.Message)
        }
        if ($resp.ResponseUri.Scheme -ne 'https' -and -not ($resp.ResponseUri.IsLoopback)) { Fail ('Refusing a download that is not https: ' + $resp.ResponseUri) }
        if ($resp.ContentLength -gt $Max) { Fail ('The file at ' + $Url + ' is larger than expected.') }
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
        try {
            $buf = New-Object byte[] 65536
            [long]$total = 0
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $total += $n
                if ($total -gt $Max) { Fail ('The file at ' + $Url + ' is larger than expected.') }
                $out.Write($buf, 0, $n)
            }
            return $total
        } finally {
            $out.Dispose()
            $in.Dispose()
        }
    } finally {
        if ($resp) { $resp.Dispose() }
    }
}

function Get-WaSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() } finally { $fs.Dispose(); $sha.Dispose() }
}

# An MZ header whose PE header ("PE\0\0") is where it says.
function Test-WaProgram([string]$Path) {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        $head = New-Object byte[] 4096
        $n = $fs.Read($head, 0, $head.Length)
        if ($n -lt 64 -or $head[0] -ne 0x4D -or $head[1] -ne 0x5A) { return $false }
        $pe = [BitConverter]::ToInt32($head, 0x3C)
        if ($pe -lt 0 -or $pe + 4 -gt $n) { return $false }
        return ([BitConverter]::ToUInt32($head, $pe) -eq 0x00004550)
    } finally { $fs.Dispose() }
}

function Test-WaAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WaUninstall {
    $entry = Get-WaEntry
    if (-not $entry) { Say 'Wilco is not installed for this Windows account. Nothing to remove.'; return }
    $line = if ($entry.PSObject.Properties['QuietUninstallString'] -and $entry.QuietUninstallString) { [string]$entry.QuietUninstallString } else { [string]$entry.UninstallString + ' /S' }
    $parts = Split-WaCommand $line
    Say 'Removing Wilco (a running Wilco is closed first)...'
    $code = Invoke-WaProgram $parts[0] $parts[1] 600
    if ($code -ne 0) { Fail ('The uninstaller ended with code ' + $code + '.') }
    # The uninstaller copies itself to %TEMP% and finishes from there.
    for ($i = 0; $i -lt 120 -and (Get-WaEntry); $i++) { Start-Sleep -Milliseconds 500 }
    if (Get-WaEntry) { Fail 'Wilco is still listed as installed after the uninstaller finished.' }
    Say 'Wilco was removed. Your sessions and settings in %APPDATA%\Wilco and %USERPROFILE%\.wilco are kept.'
}

function Invoke-WaInstall {
    $base = $A.DefaultBase
    if ($env:WILCO_APP_DOWNLOAD_BASE) { $base = [string]$env:WILCO_APP_DOWNLOAD_BASE }
    if ($Version) {
        if ($Version -notmatch $A.TagRe) { Fail ('-Version must be a release tag such as v0.1.1-test.20261010.1 (got "' + $Version + '").') }
        $archive = $A.ArchiveDefault
        if ($env:WILCO_APP_ARCHIVE_BASE) { $archive = [string]$env:WILCO_APP_ARCHIVE_BASE }
        $base = $archive.TrimEnd('/') + '/' + $Version
    }
    $base = $base.TrimEnd('/')
    $u = [Uri]$base
    if ($u.Scheme -ne 'https' -and -not $u.IsLoopback) { Fail ('The download address must use https: ' + $base) }

    $A.Tmp = Join-Path ([IO.Path]::GetTempPath()) ('wilco-app-install-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    [void](New-Item -ItemType Directory -Path $A.Tmp)
    $sumsPath = Join-Path $A.Tmp 'SHA256SUMS'
    [void](Save-WaUrl ($base + '/SHA256SUMS') $sumsPath $A.MaxSums)
    $found = @()
    foreach ($line in [IO.File]::ReadAllLines($sumsPath)) {
        $m = [regex]::Match($line, '^([0-9a-f]{64})  (\S+)$')
        if ($m.Success -and $m.Groups[2].Value -match $A.InstallerRe) { $found += , @($m.Groups[1].Value, $m.Groups[2].Value) }
    }
    if ($found.Count -eq 0) { Fail ('There is no Windows build at ' + $base + ' yet.') }
    if ($found.Count -gt 1) { Fail ('SHA256SUMS at ' + $base + ' names more than one Windows installer.') }
    $want = $found[0][0]
    $name = $found[0][1]
    $exe = Join-Path $A.Tmp $name
    Say ('Downloading ' + $name + '...')
    $bytes = Save-WaUrl ($base + '/' + $name) $exe $A.MaxInstaller
    $got = Get-WaSha256 $exe
    if ($got -ne $want) { Fail ('The download does not match its published checksum (' + $got + ' instead of ' + $want + '). Nothing was installed; try again.') }
    if (-not (Test-WaProgram $exe)) { Fail 'The download is not a Windows program. Nothing was installed.' }
    Say ('Checksum OK (' + [Math]::Round($bytes / 1MB, 1) + ' MB). Installing Wilco for this Windows account (an open Wilco is closed first)...')
    $installArgs = '/S'
    if (-not $NoLaunch) { $installArgs += ' --force-run' }
    $code = Invoke-WaProgram $exe $installArgs 900
    if ($code -ne 0) { Fail ('The installer ended with code ' + $code + '. Close Wilco if it is open, then run this command again.') }
    $entry = $null
    for ($i = 0; $i -lt 60 -and -not $entry; $i++) { $entry = Get-WaEntry; if (-not $entry) { Start-Sleep -Milliseconds 500 } }
    if (-not $entry) { Fail 'The installer finished, but Wilco is not listed as installed.' }
    # electron-builder's per-user entry has no InstallLocation; the folder is the uninstaller's.
    $where = ''
    if ($entry.PSObject.Properties['InstallLocation'] -and $entry.InstallLocation) { $where = [string]$entry.InstallLocation }
    else { $exeParts = Split-WaCommand ([string]$entry.UninstallString); if ($exeParts[0]) { $where = [IO.Path]::GetDirectoryName($exeParts[0]) } }
    if ($where -and -not (Test-Path -LiteralPath (Join-Path $where 'Wilco.exe'))) { Fail ('The installer finished, but ' + (Join-Path $where 'Wilco.exe') + ' is missing.') }
    $ver = ([regex]::Match($name, '^Wilco-([0-9.]+)-')).Groups[1].Value
    Say ('Wilco ' + $ver + ' is installed' + $(if ($where) { ' in ' + $where } else { '' }) + '.')
    if ($NoLaunch) { Say 'Open it from the Start menu or the desktop shortcut.' } else { Say 'Wilco is opening. Next time, open it from the Start menu or the desktop shortcut.' }
    Say 'Wilco checks for updates itself. To remove it, use Settings > Apps > Installed apps.'
}

try {
    if ($Help) { Show-WaHelp; return }
    if ($Rest -and @($Rest).Count -gt 0) { Fail ('Unknown option: ' + (@($Rest) -join ' ') + '. Run with -Help for the options.') }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Fail 'This installer is for Windows. On a Mac: curl -fsSL https://wilco.run/download/app/install.sh | bash' }
    if (-not [Environment]::Is64BitOperatingSystem) { Fail 'Wilco needs 64-bit Windows.' }
    if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Wilco needs Windows 10 or later.' }
    if ((Test-WaAdmin) -and -not $AllowAdmin) {
        Fail ('This PowerShell runs as administrator. Wilco installs for your own Windows account and should not run as administrator: open PowerShell normally and run the command again (or add -AllowAdmin: ' + $A.OptCmd + ' -AllowAdmin).')
    }
    # Windows PowerShell 5.1 may not offer TLS 1.2 by default; restored afterwards.
    $A.OldProtocol = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = $A.OldProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($Uninstall) { Invoke-WaUninstall } else { Invoke-WaInstall }
} catch {
    $msg = $_.Exception.Message
    if ($ThrowOnError) { throw }
    Write-Host ('Error: ' + $msg) -ForegroundColor Red
} finally {
    if ($null -ne $A.OldProtocol) { [Net.ServicePointManager]::SecurityProtocol = $A.OldProtocol }
    if ($A.Tmp -and (Test-Path -LiteralPath $A.Tmp)) { Remove-Item -LiteralPath $A.Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
} @args
