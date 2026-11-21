<#
    LSB Server Installer & Control Panel
    ------------------------------------
    One program that does two jobs:
      * First run: installs the LandSandBoat server from the latest release of
        your GitHub fork (server + portable Python, MariaDB and Git).
      * After that: a control panel with Start/Stop, status lights, folder
        buttons, backups, database updates and server updates.

    Written for Windows PowerShell 5.1 so ps2exe can turn it into an .exe:
        Invoke-ps2exe LSB-Installer.ps1 LSB-Installer.exe -noConsole -STA

    Folder layout it creates (example: C:\LSB):
        C:\LSB\server\            the LSB server (from lsb-windows.zip)
        C:\LSB\runtime\           portable Python, MariaDB, Git (from the zip)
        C:\LSB\database\          the MariaDB data - never touched by updates
        C:\LSB\old\               previous versions kept after "Update server"
        C:\LSB\lsb-panel.json     this program's settings (DB port & password)
        C:\LSB\panel.log          everything shown in the log box
        C:\LSB\LSB Control Panel.exe
#>

# ===================== Settings you may want to change =====================
$GitHubRepo        = 'Infinityshift/server'   # where the releases come from
$ZipAssetName      = 'lsb-windows.zip'
$PanelAssetName    = 'LSB-Installer.exe'          # the control panel, in the same releases
$MyModuleFolders   = @('infinityshift')       # always kept as-is when updating the server
$DefaultInstallDir = 'C:\LSB'
$DefaultDbPort     = 3307                     # 3306 is left free for any other MariaDB/MySQL
$DbName            = 'xidb'
$AppTitle          = 'LSB Server'
# ==========================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Windows.Forms.Application]::EnableVisualStyles()

# Small helper written in C#: sends Ctrl+C to a server window so it shuts down cleanly
# (the same as clicking in its window and pressing Ctrl+C).
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LsbConsole {
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll")] static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint groupId);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    public static bool HasOwnConsole() { return GetConsoleWindow() != IntPtr.Zero; }
    public static bool SendCtrlC(uint pid) {
        if (!AttachConsole(pid)) return false;
        SetConsoleCtrlHandler(IntPtr.Zero, true);       // don't let the Ctrl+C close us too
        bool ok = GenerateConsoleCtrlEvent(0, 0);         // 0 = CTRL_C_EVENT
        System.Threading.Thread.Sleep(300);
        FreeConsole();
        SetConsoleCtrlHandler(IntPtr.Zero, false);
        return ok;
    }
}

// Dark title bar (Windows 10 2004+ and Windows 11). Older Windows ignores it.
public static class LsbWindow {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void SetDarkTitleBar(IntPtr hwnd, bool dark) {
        int value = dark ? 1 : 0;
        try {
            if (DwmSetWindowAttribute(hwnd, 20, ref value, 4) != 0) {   // DWMWA_USE_IMMERSIVE_DARK_MODE
                DwmSetWindowAttribute(hwnd, 19, ref value, 4);          // same, on early Windows 10 builds
            }
        } catch { }
    }
}
'@

# ----------------------------------------------------------------------------
# Paths and saved settings
# ----------------------------------------------------------------------------
$SelfPath    = if ($PSCommandPath) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$SelfIsExe   = $SelfPath -like '*.exe'
$PointerFile = Join-Path $env:APPDATA 'LSB-Panel\location.txt'
$script:P    = $null      # paths of the current install
$script:Cfg  = $null      # contents of lsb-panel.json
$script:Busy = $false

function Get-Paths([string]$root) {
    $rt = Join-Path $root 'runtime'
    [pscustomobject]@{
        Root      = $root
        Server    = Join-Path $root 'server'
        Runtime   = $rt
        Python    = Join-Path $rt 'python\python.exe'
        MariaBin  = Join-Path $rt 'mariadb\bin'
        GitCmd    = Join-Path $rt 'git\cmd'
        DbData    = Join-Path $root 'database'
        Old       = Join-Path $root 'old'
        Downloads = Join-Path $root 'downloads'
        Config    = Join-Path $root 'lsb-panel.json'
        LogFile   = Join-Path $root 'panel.log'
    }
}

function Find-Install {
    # 1) next to this program   2) the folder remembered from the last install
    $here = Split-Path $SelfPath -Parent
    if (Test-Path (Join-Path $here 'lsb-panel.json')) { return $here }
    if (Test-Path $PointerFile) {
        $dir = (Get-Content $PointerFile -Raw).Trim()
        if ($dir -and (Test-Path (Join-Path $dir 'lsb-panel.json'))) { return $dir }
    }
    return $null
}

function Save-Config {
    $script:Cfg | ConvertTo-Json | Set-Content -Path $script:P.Config -Encoding UTF8
}

function Load-Config([string]$root) {
    $script:P   = Get-Paths $root
    $script:Cfg = Get-Content $script:P.Config -Raw | ConvertFrom-Json
    Set-ToolEnvironment
}

# Make the bundled Python / MariaDB / Git usable by dbtool.py and anything we start
function Set-ToolEnvironment {
    $extra = @($script:P.GitCmd, $script:P.MariaBin, (Split-Path $script:P.Python -Parent)) -join ';'
    if ($env:PATH -notlike "$extra*") { $env:PATH = "$extra;$env:PATH" }
    $env:PYTHONUNBUFFERED  = '1'           # show dbtool output as it happens
    $env:PYTHONIOENCODING  = 'utf-8'
    $env:PROMPT            = '$P$G'        # stops dbtool waiting for "Press ENTER" if it errors
    # Let git work even if Windows says the folder belongs to another user account
    $env:GIT_CONFIG_COUNT  = '1'
    $env:GIT_CONFIG_KEY_0  = 'safe.directory'
    $env:GIT_CONFIG_VALUE_0 = '*'
}

# ----------------------------------------------------------------------------
# Little UI helpers
# ----------------------------------------------------------------------------
function Pump { [System.Windows.Forms.Application]::DoEvents() }

function Wait-Ms([int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { Pump; Start-Sleep -Milliseconds 50 }
}

function Log([string]$msg) {
    $msg = $msg -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''     # remove colour codes from dbtool output
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    $script:LogBox.AppendText($line + "`r`n")
    if ($script:P -and (Test-Path $script:P.Root)) {
        try { Add-Content -Path $script:P.LogFile -Value $line -Encoding UTF8 } catch { }
    }
    Pump
}

function Set-Progress([int]$percent, [string]$text) {
    $script:Progress.Value = [Math]::Max(0, [Math]::Min(100, $percent))
    if ($text) { $script:StatusText.Text = $text }
    Pump
}

function Show-Info([string]$text)  { [void][System.Windows.Forms.MessageBox]::Show($text, $AppTitle, 'OK', 'Information') }
function Show-Error([string]$text) { [void][System.Windows.Forms.MessageBox]::Show($text, $AppTitle, 'OK', 'Error') }
function Ask-YesNo([string]$text)  { return ([System.Windows.Forms.MessageBox]::Show($text, $AppTitle, 'YesNo', 'Question') -eq 'Yes') }

# Runs a button's work: blocks other buttons, catches errors, refreshes the lights
function Run-Action([string]$name, [scriptblock]$work) {
    if ($script:Busy) { return }
    $script:Busy = $true
    Set-ButtonsEnabled $false
    Log "=== $name ==="
    try {
        & $work
    } catch {
        Log "ERROR: $($_.Exception.Message)"
        Show-Error "$name failed:`n`n$($_.Exception.Message)`n`nSee the log at the bottom for details."
    } finally {
        $script:Busy = $false
        Set-ButtonsEnabled $true
        Set-Progress 0 'Ready'
        if ($script:P) { Update-Status }
    }
}

# ----------------------------------------------------------------------------
# Downloading and unzipping (with a progress bar)
# ----------------------------------------------------------------------------
function Get-LatestRelease {
    Log "Checking GitHub for the latest release of $GitHubRepo..."
    $rel = Invoke-RestMethod "https://api.github.com/repos/$GitHubRepo/releases/latest" -Headers @{ 'User-Agent' = 'LSB-Installer' }
    $asset = $rel.assets | Where-Object { $_.name -eq $ZipAssetName } | Select-Object -First 1
    if (-not $asset) { throw "The latest release ($($rel.tag_name)) has no $ZipAssetName." }
    Log ("Latest release: {0} ({1:N0} MB)" -f $rel.tag_name, ($asset.size / 1MB))
    [pscustomobject]@{ Tag = $rel.tag_name; Url = $asset.browser_download_url; Size = $asset.size }
}

function Download-File([string]$url, [string]$dest) {
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
    Log "Downloading $url"
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = 'LSB-Installer'
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($dest)
    try {
        $buf = New-Object byte[] 1048576
        $done = 0L
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($sw.ElapsedMilliseconds -gt 250) {
                $sw.Restart()
                $pct = if ($total -gt 0) { [int](100 * $done / $total) } else { 0 }
                Set-Progress $pct ("Downloading... {0:N0} of {1:N0} MB" -f ($done / 1MB), ($total / 1MB))
            }
        }
    } finally {
        $out.Close(); $in.Close(); $resp.Close()
    }
    Log "Download finished."
}

function Expand-ZipWithProgress([string]$zip, [string]$dest) {
    Log "Unpacking $(Split-Path $zip -Leaf) into $dest (this can take a few minutes)..."
    New-Item -ItemType Directory -Force $dest | Out-Null
    $destFull = [IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'
    $za = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $count = $za.Entries.Count
        $i = 0
        foreach ($e in $za.Entries) {
            $i++
            $target = [IO.Path]::GetFullPath((Join-Path $dest $e.FullName))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path in zip: $($e.FullName)" }
            if ($e.Name -eq '') {
                [void][IO.Directory]::CreateDirectory($target)
            } else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            }
            if ($i % 250 -eq 0) { Set-Progress ([int](100 * $i / $count)) ("Unpacking... {0:N0} of {1:N0} files" -f $i, $count) }
        }
    } finally {
        $za.Dispose()
    }
    Log "Unpacked $count files."
}

# ----------------------------------------------------------------------------
# Running programs (output goes to the log box)
# ----------------------------------------------------------------------------
function Invoke-Logged([string]$exe, [string]$arguments, [string]$workDir) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = $arguments
    $psi.WorkingDirectory       = $workDir
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $p = [Diagnostics.Process]::Start($psi)
    # Answer "no" to any question a tool might ask, then close its input so it can't wait forever
    1..5 | ForEach-Object { $p.StandardInput.WriteLine('n') }
    $p.StandardInput.Close()

    $oT = $p.StandardOutput.ReadLineAsync()
    $eT = $p.StandardError.ReadLineAsync()
    while ($oT -or $eT) {
        $got = $false
        if ($oT -and $oT.IsCompleted) {
            $got = $true
            if ($null -eq $oT.Result) { $oT = $null } else { Log $oT.Result; $oT = $p.StandardOutput.ReadLineAsync() }
        }
        if ($eT -and $eT.IsCompleted) {
            $got = $true
            if ($null -eq $eT.Result) { $eT = $null } else {
                if ($eT.Result -notmatch 'Using a password on the command line') { Log $eT.Result }
                $eT = $p.StandardError.ReadLineAsync()
            }
        }
        if (-not $got) { Pump; Start-Sleep -Milliseconds 50 }
    }
    $p.WaitForExit()
    return $p.ExitCode
}

# dbtool.py stores where MariaDB is in tools\config.yaml. Point it at our copy every time,
# so it never stops to ask (and still works if the install folder is moved).
function Set-DbtoolConfig {
    $cfgFile = Join-Path $script:P.Server 'tools\config.yaml'
    $bin = ($script:P.MariaBin -replace '\\', '/').TrimEnd('/') + '/'
    $line = "- mysql_bin: '" + ($bin -replace "'", "''") + "'"
    if (Test-Path $cfgFile) {
        $text = Get-Content $cfgFile -Raw
        if ($text -match '(?m)^- mysql_bin:.*$') { $text = $text -replace '(?m)^- mysql_bin:.*$', $line }
        else { $text = $line + "`n" + $text }
        Set-Content $cfgFile $text -NoNewline -Encoding ASCII
    } else {
        Set-Content $cfgFile ($line + "`n- auto_backup: 0`n- auto_update_client: true`n- db_ver: ''`n") -NoNewline -Encoding ASCII
    }
}

function Invoke-Dbtool([string]$arguments) {
    Set-DbtoolConfig
    Log "Running: dbtool.py $arguments"
    $code = Invoke-Logged $script:P.Python "tools\dbtool.py $arguments" $script:P.Server
    if ($code -ne 0) { throw "dbtool.py $arguments exited with code $code" }
}

# ----------------------------------------------------------------------------
# MariaDB
# ----------------------------------------------------------------------------
function Get-MariaExe([string[]]$names) {
    foreach ($n in $names) { $f = Join-Path $script:P.MariaBin $n; if (Test-Path $f) { return $f } }
    throw "Could not find $($names -join ' / ') in $($script:P.MariaBin)"
}

function Test-PortFree([int]$port) {
    try {
        $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $port)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

function Test-PortOpen([int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(300) -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

function Write-MariaIni {
    $data = $script:P.DbData -replace '\\', '/'
    $plugins = (Join-Path $script:P.Runtime 'mariadb\lib\plugin') -replace '\\', '/'
    @"
# Written by the LSB installer
[mysqld]
datadir=$data
port=$($script:Cfg.DbPort)
bind-address=127.0.0.1
character-set-server=utf8mb4
collation-server=utf8mb4_general_ci
max_allowed_packet=64M

[client]
port=$($script:Cfg.DbPort)
plugin-dir=$plugins
"@ | Set-Content (Join-Path $script:P.DbData 'my.ini') -Encoding ASCII
}

function Initialize-Database {
    if (Test-Path (Join-Path $script:P.DbData 'mysql')) { Log "Database folder already exists - skipping setup."; return }
    Log "Creating the MariaDB data folder..."
    $tool = Get-MariaExe @('mariadb-install-db.exe', 'mysql_install_db.exe')
    $code = Invoke-Logged $tool ("--datadir=`"{0}`" --port={1} --password={2}" -f $script:P.DbData, $script:Cfg.DbPort, $script:Cfg.DbPassword) $script:P.Root
    if ($code -ne 0) { throw "MariaDB setup failed (code $code)" }
    Write-MariaIni
}

function Start-Database {
    if (Get-Running 'db') { return $false }
    if (-not (Test-PortFree $script:Cfg.DbPort)) { throw "Port $($script:Cfg.DbPort) is already used by another program. Close it, or change DbPort in lsb-panel.json and settings\network.lua." }
    Write-MariaIni
    $exe = Get-MariaExe @('mariadbd.exe', 'mysqld.exe')
    Log "Starting MariaDB on port $($script:Cfg.DbPort)..."
    $ini = Join-Path $script:P.DbData 'my.ini'
    $argLine = "--defaults-file=`"$ini`" --datadir=`"$($script:P.DbData)`" --port=$($script:Cfg.DbPort) --console"
    $style = if ($script:ShowWindows.Checked) { 'Minimized' } else { 'Hidden' }
    Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $script:P.Root -WindowStyle $style | Out-Null
    for ($i = 0; $i -lt 120; $i++) {
        if (Test-PortOpen $script:Cfg.DbPort) { Log "MariaDB is ready."; return $true }
        if ($i -gt 6 -and -not (Get-Running 'db')) { throw "MariaDB stopped right after starting. Check $($script:P.DbData)\*.err for the reason." }
        Wait-Ms 500
    }
    throw "MariaDB did not start within 60 seconds."
}

function Stop-Database {
    $procs = Get-Running 'db'
    if (-not $procs) { return }
    Log "Stopping MariaDB..."
    $admin = Get-MariaExe @('mariadb-admin.exe', 'mysqladmin.exe')
    [void](Invoke-Logged $admin ("-h127.0.0.1 -P{0} -uroot -p{1} shutdown" -f $script:Cfg.DbPort, $script:Cfg.DbPassword) $script:P.Root)
    if (-not (Wait-ProcessesExit $procs 60)) {
        Log "MariaDB did not stop by itself - forcing it to close."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Log "MariaDB stopped."
}

# ----------------------------------------------------------------------------
# Server processes
# ----------------------------------------------------------------------------
# Start order. Stop happens in the reverse order.
# LogName = the server's log file (log\<LogName>-server.log), which is where it
#           announces "The <LogName>-server is ready to work" once it has loaded.
# ReadySeconds = how long to wait for that before giving up and moving on.
$script:Components = @(
    [pscustomobject]@{ Key = 'db';      Label = 'Database (MariaDB)'; Names = @('mariadbd', 'mysqld'); Exe = $null;            LogName = $null;      ReadySeconds = 0 },
    [pscustomobject]@{ Key = 'connect'; Label = 'Connect (login)';    Names = @('xi_connect');         Exe = 'xi_connect.exe'; LogName = 'connect';  ReadySeconds = 60 },
    [pscustomobject]@{ Key = 'search';  Label = 'Search';             Names = @('xi_search');          Exe = 'xi_search.exe';  LogName = 'search';   ReadySeconds = 60 },
    [pscustomobject]@{ Key = 'world';   Label = 'World';              Names = @('xi_world');           Exe = 'xi_world.exe';   LogName = 'world';    ReadySeconds = 120 },
    [pscustomobject]@{ Key = 'profile'; Label = 'Profile';            Names = @('xi_profile');         Exe = 'xi_profile.exe'; LogName = 'profile';  ReadySeconds = 60 },
    [pscustomobject]@{ Key = 'map';     Label = 'Map (game world)';   Names = @('xi_map');             Exe = 'xi_map.exe';     LogName = 'map';      ReadySeconds = 600 }
)

# Servers that are running but haven't finished loading yet (shown in yellow)
$script:Starting = @{}

function Get-Running([string]$key) {
    $c = $script:Components | Where-Object { $_.Key -eq $key }
    $root = $script:P.Root
    foreach ($n in $c.Names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
        }
    }
}

function Test-AnyGameRunning {
    foreach ($c in $script:Components) { if ($c.Key -ne 'db' -and (Get-Running $c.Key)) { return $true } }
    return $false
}

function Wait-ProcessesExit($procs, [int]$seconds) {
    $procs = @($procs)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $seconds) {
        $alive = @($procs | Where-Object { -not $_.HasExited })
        if ($alive.Count -eq 0) { return $true }
        Wait-Ms 250
        $procs | ForEach-Object { $_.Refresh() }
    }
    return $false
}

function Get-LogPath($c) {
    return Join-Path $script:P.Server ("log\{0}-server.log" -f $c.LogName)
}

function Get-FileLength([string]$path) {
    if (Test-Path $path) { return (Get-Item $path).Length }
    return 0
}

# Reads whatever was added to a log file after position $offset.
# The server keeps the file open, so it's opened in "share" mode.
function Read-LogFrom([string]$path, [long]$offset) {
    if (-not (Test-Path $path)) { return '' }
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if ($offset -gt $fs.Length) { $offset = 0 }   # the file was cleared or replaced
        [void]$fs.Seek($offset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($fs)
        return $reader.ReadToEnd()
    } finally {
        $fs.Close()
    }
}

# Waits until the server writes "...-server is ready to work" in its log.
# Returns 'ready', 'stopped' (it closed) or 'timeout'.
function Wait-ServerReady($c, [long]$logOffset) {
    $path = Get-LogPath $c
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastNote = 0
    while ($sw.Elapsed.TotalSeconds -lt $c.ReadySeconds) {
        Wait-Ms 1000
        Update-Status
        $text = ''
        try { $text = Read-LogFrom $path $logOffset } catch { }
        if ($text -match 'ready to work') { return 'ready' }
        if (-not (Get-Running $c.Key)) { return 'stopped' }
        $secs = [int]$sw.Elapsed.TotalSeconds
        if ($secs - $lastNote -ge 15) {
            $lastNote = $secs
            Log ("  ...{0} is still loading ({1} seconds so far)" -f $c.Label, $secs)
        }
        Set-Progress 0 ("Waiting for {0} to finish loading... {1}s" -f $c.Label, $secs)
    }
    return 'timeout'
}

# Starts everything that isn't running yet, one at a time, waiting for each
# to finish loading. -QuietIfRunning skips the "already running" lines.
function Start-Server([switch]$QuietIfRunning) {
    [void](Start-Database)
    $style = if ($script:ShowWindows.Checked) { 'Minimized' } else { 'Hidden' }
    $allReady = $true
    foreach ($c in $script:Components | Where-Object { $_.Exe }) {
        $exe = Join-Path $script:P.Server $c.Exe
        if (-not (Test-Path $exe)) { continue }          # e.g. older builds have no xi_profile
        if (Get-Running $c.Key) {
            if (-not $QuietIfRunning) { Log "$($c.Label) is already running." }
            continue
        }

        # Remember where the log ends now, so only NEW lines are checked for "ready"
        $logOffset = Get-FileLength (Get-LogPath $c)

        Log "Starting $($c.Label)..."
        Start-Process -FilePath $exe -WorkingDirectory $script:P.Server -WindowStyle $style | Out-Null
        $script:Starting[$c.Key] = $true
        $sw = [Diagnostics.Stopwatch]::StartNew()

        try {
            $result = Wait-ServerReady $c $logOffset
        } finally {
            $script:Starting.Remove($c.Key)
        }

        switch ($result) {
            'ready'   { Log ("{0} is ready ({1:N0} seconds)." -f $c.Label, $sw.Elapsed.TotalSeconds) }
            'stopped' { $allReady = $false; Log "WARNING: $($c.Label) closed while starting. Click Logs and open $($c.LogName)-server.log to see why." }
            'timeout' { $allReady = $false; Log "WARNING: $($c.Label) didn't say it was ready within $($c.ReadySeconds) seconds. It may still be loading - check $($c.LogName)-server.log." }
        }
    }
    Update-Status
    if ($allReady) {
        Log "Server is ready - you can log in now."
    } else {
        Log "Server started, but something above needs a look before logging in."
    }
}

# Stops one server program cleanly (Ctrl+C), forcing it only if it hangs
function Stop-Component($c) {
    $procs = @(Get-Running $c.Key)
    if ($procs.Count -eq 0) { return }
    $canCtrlC = -not [LsbConsole]::HasOwnConsole()
    Log "Stopping $($c.Label)..."
    foreach ($p in $procs) {
        $sent = $false
        if ($canCtrlC) { $sent = [LsbConsole]::SendCtrlC([uint32]$p.Id) }
        if (-not $sent) { Log "  (could not send Ctrl+C, closing it directly)"; $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Wait-ProcessesExit $procs 30)) {
        Log "  $($c.Label) did not close within 30 seconds - forcing it to close."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Stop-GameServers {
    $ordered = @($script:Components | Where-Object { $_.Exe })
    [array]::Reverse($ordered)
    foreach ($c in $ordered) { Stop-Component $c }
}

# Restarts only the map server, which runs all the Lua scripts and modules.
# The database and the login/world/search servers keep running. Anything
# else that happens to be stopped is started too.
function Restart-MapServer {
    $map = $script:Components | Where-Object { $_.Key -eq 'map' }
    if (-not (Test-Path (Join-Path $script:P.Server $map.Exe))) { throw "xi_map.exe was not found in the server folder." }

    if (Get-Running 'map') {
        if (-not (Ask-YesNo "Restart the map server?`n`nAnyone logged in will be disconnected. Log out first, then log back in once it says it's ready.")) { return }
        Stop-Component $map
    }

    Start-Server -QuietIfRunning
}

function Stop-Server {
    Stop-GameServers
    Stop-Database
    Log "Server stopped."
}

# Makes sure the game servers are off. Returns $false if the user said no.
function Confirm-GameStopped([string]$why) {
    if (-not (Test-AnyGameRunning)) { return $true }
    if (-not (Ask-YesNo "The server must be stopped to $why.`n`nStop it now?")) { return $false }
    Stop-GameServers
    return $true
}

# ----------------------------------------------------------------------------
# Settings files
# ----------------------------------------------------------------------------
function Write-NetworkSettings {
    $file = Join-Path $script:P.Server 'settings\network.lua'
    if (Test-Path $file) { Log "settings\network.lua already exists - leaving it alone."; return }
    @"
-- Written by the LSB installer.
-- Only the settings listed here replace the ones in settings\default\network.lua;
-- everything else keeps its default value. Add more lines inside the { } if you need to.
xi = xi or {}
xi.settings = xi.settings or {}

xi.settings.network =
{
    SQL_HOST     = '127.0.0.1',
    SQL_PORT     = $($script:Cfg.DbPort),
    SQL_LOGIN    = 'root',
    SQL_PASSWORD = '$($script:Cfg.DbPassword)',
    SQL_DATABASE = '$DbName',
}
"@ | Set-Content $file -Encoding ASCII
    Log "Wrote settings\network.lua (database port $($script:Cfg.DbPort))."
}

function New-Password {
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 20
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# ----------------------------------------------------------------------------
# Visual C++ runtime
# ----------------------------------------------------------------------------
function Test-VCRedist {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64') {
        try {
            $v = Get-ItemProperty $k -ErrorAction Stop
            # The server is built with Visual Studio 2022, which needs runtime 14.40 or newer
            if ($v.Installed -eq 1 -and ($v.Major -gt 14 -or $v.Minor -ge 40)) { return $true }
        } catch { }
    }
    return $false
}

function Install-VCRedist {
    if (Test-VCRedist) { Log "Visual C++ runtime is already installed."; return }
    $file = Join-Path $script:P.Downloads 'vc_redist.x64.exe'
    Download-File 'https://aka.ms/vs/17/release/vc_redist.x64.exe' $file
    Log "Installing the Visual C++ runtime (Windows will ask for permission)..."
    try {
        $p = Start-Process $file -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
    } catch {
        throw "The Visual C++ runtime was not installed (permission was refused). The server cannot run without it."
    }
    if ($p.ExitCode -notin 0, 1638, 3010) { throw "Visual C++ runtime installer failed with code $($p.ExitCode)." }
    if ($p.ExitCode -eq 3010) { Log "Visual C++ runtime installed - Windows wants a restart at some point." }
    else { Log "Visual C++ runtime installed." }
    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------
function Install-Server([string]$root, [int]$port) {
    $root = [IO.Path]::GetFullPath($root)
    if (Test-Path (Join-Path $root 'server')) { throw "There is already a server in $root. Pick an empty folder." }
    if (-not (Test-PortFree $port)) { throw "Port $port is already in use. Pick another database port." }

    New-Item -ItemType Directory -Force $root | Out-Null
    $script:P = Get-Paths $root
    $script:Cfg = [pscustomobject]@{ DbPort = $port; DbPassword = (New-Password); Release = '' }
    Set-ToolEnvironment
    Log "Installing to $root"

    Install-VCRedist

    $rel = Get-LatestRelease
    $zip = Join-Path $script:P.Downloads $ZipAssetName
    Download-File $rel.Url $zip
    Expand-ZipWithProgress $zip $root
    Remove-Item $zip -Force
    if (-not (Test-Path (Join-Path $script:P.Server 'xi_map.exe'))) { throw "The download did not contain server\xi_map.exe - the release zip looks wrong." }
    if (-not (Test-Path $script:P.Python)) { throw "The download did not contain runtime\python - rebuild the release with the new workflow." }

    Write-NetworkSettings
    foreach ($m in $MyModuleFolders) { New-Item -ItemType Directory -Force (Join-Path $script:P.Server "modules\$m") | Out-Null }

    Set-Progress 0 'Setting up the database...'
    Initialize-Database
    $script:Cfg.Release = $rel.Tag
    Save-Config                                   # saved now so the password is never lost
    [void](Start-Database)
    Log "Filling the database (dbtool.py setup $DbName) - this takes a few minutes..."
    Invoke-Dbtool "setup $DbName"
    Stop-Database

    # Remember where we installed, and put the control panel in the install folder
    New-Item -ItemType Directory -Force (Split-Path $PointerFile -Parent) | Out-Null
    Set-Content $PointerFile $root
    if ($SelfIsExe) {
        $panelExe = Join-Path $root 'LSB Control Panel.exe'
        Copy-Item $SelfPath $panelExe -Force
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'LSB Control Panel.lnk'))
        $sc.TargetPath = $panelExe
        $sc.WorkingDirectory = $root
        $sc.Save()
        Log "Added 'LSB Control Panel' to your desktop."
    }
    Log "Install complete!"
    Show-Info "The server is installed.`n`nPress Start to run it."
    Show-Panel
}

# ----------------------------------------------------------------------------
# Maintenance
# ----------------------------------------------------------------------------
function Backup-Database {
    $started = Start-Database
    try { Invoke-Dbtool 'backup' }
    finally { if ($started) { Stop-Database } }
    Log "Backup saved in server\sql\backups."
}

function Update-Database {
    if (-not (Confirm-GameStopped 'apply database updates')) { return }
    $started = Start-Database
    try {
        Log "Making a backup first..."
        Invoke-Dbtool 'backup'
        # Always "full": the zip has no git history, so dbtool can't work out which files changed.
        # Player data (characters, accounts, etc.) is protected and is not replaced.
        Invoke-Dbtool 'update full'
    } finally { if ($started) { Stop-Database } }
    Log "Database updates applied."
}

function Copy-IfExists([string]$from, [string]$to) {
    if (Test-Path $from) {
        $dir = if ($to.EndsWith('\')) { $to } else { Split-Path $to -Parent }
        New-Item -ItemType Directory -Force $dir | Out-Null
        Copy-Item $from $to -Recurse -Force
    }
}

# ----------------------------------------------------------------------------
# Update the control panel itself
# ----------------------------------------------------------------------------
# The build number is stamped into the .exe (ps2exe -version 1.0.<build>) and
# into each release's tag (windows-build-<build>), so the two can be compared.
function Get-MyBuildNumber {
    # 1.0.<build> -> the third number ("build part"); 0 for a home-made build
    try { return [int][Diagnostics.FileVersionInfo]::GetVersionInfo($SelfPath).FileBuildPart } catch { }
    return 0
}

function Update-ControlPanel {
    if (-not $SelfIsExe) { throw "This only works in the .exe version of the control panel." }

    Log "Checking GitHub for a newer control panel..."
    $rel = Invoke-RestMethod "https://api.github.com/repos/$GitHubRepo/releases/latest" -Headers @{ 'User-Agent' = 'LSB-Installer' }
    $asset = $rel.assets | Where-Object { $_.name -eq $PanelAssetName } | Select-Object -First 1
    if (-not $asset) { throw "The latest release ($($rel.tag_name)) has no $PanelAssetName." }

    $latest  = if ($rel.tag_name -match '(\d+)$') { [int]$Matches[1] } else { 0 }
    $current = Get-MyBuildNumber
    Log "This control panel: build $current. Latest release: build $latest."

    if ($current -ge $latest -and $current -gt 0) {
        if (-not (Ask-YesNo "You already have the newest control panel (build $current).`n`nDownload it again anyway?")) { return }
    } elseif (-not (Ask-YesNo "Update the control panel to build $latest?`n`nIt will close and reopen by itself. The server keeps running.")) {
        return
    }

    $newFile = "$SelfPath.new"
    $oldFile = $SelfPath -replace '\.exe$', '.old.exe'
    if (Test-Path $newFile) { Remove-Item $newFile -Force }
    Download-File $asset.browser_download_url $newFile

    # Make sure what came down is a real Windows program, not an error page
    $bytes = [IO.File]::ReadAllBytes($newFile)
    if ($bytes.Length -lt 100KB -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        Remove-Item $newFile -Force -ErrorAction SilentlyContinue
        throw "The download doesn't look like a program file. Nothing was changed."
    }

    # Windows won't let a running program be overwritten, but it can be renamed.
    if (Test-Path $oldFile) { Remove-Item $oldFile -Force -ErrorAction SilentlyContinue }
    Move-Item $SelfPath $oldFile -Force
    try {
        Move-Item $newFile $SelfPath -Force
    } catch {
        Move-Item $oldFile $SelfPath -Force   # put the old one back
        throw "Could not put the new control panel in place: $($_.Exception.Message)"
    }

    Log "Control panel updated - reopening..."
    Start-Process -FilePath $SelfPath -WorkingDirectory (Split-Path $SelfPath -Parent) | Out-Null
    $script:Restarting = $true
    $form.Close()
}

# Deletes the previous version left behind by an update (it may still be
# closing when the new one starts, so this is retried by the status timer).
$script:OldPanelCleaned = -not $SelfIsExe
function Remove-OldPanel {
    if ($script:OldPanelCleaned) { return }
    $oldFile = $SelfPath -replace '\.exe$', '.old.exe'
    if (-not (Test-Path $oldFile)) { $script:OldPanelCleaned = $true; return }
    try {
        Remove-Item $oldFile -Force -ErrorAction Stop
        $script:OldPanelCleaned = $true
    } catch { }
}

function Update-Server {
    $rel = Get-LatestRelease
    if ($rel.Tag -eq $script:Cfg.Release) {
        if (-not (Ask-YesNo "You already have the latest build ($($rel.Tag)).`n`nInstall it again anyway?")) { return }
    } elseif (-not (Ask-YesNo "Update from $($script:Cfg.Release) to $($rel.Tag)?`n`nYour database, settings, modules\init.txt and your own modules are kept. The current version is moved to the 'old' folder.")) { return }
    if (-not (Confirm-GameStopped 'update it')) { return }

    Log "Making a database backup first..."
    Backup-Database
    Stop-Database

    $zip = Join-Path $script:P.Downloads $ZipAssetName
    $new = Join-Path $script:P.Root '_new'
    if (Test-Path $new) { Remove-Item $new -Recurse -Force }
    Download-File $rel.Url $zip
    Expand-ZipWithProgress $zip $new
    Remove-Item $zip -Force
    if (-not (Test-Path "$new\server\xi_map.exe")) { throw "The new download looks wrong (no server\xi_map.exe). Nothing was changed." }

    # Move the current version out of the way (kept in old\ in case you need anything from it)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $oldServer  = Join-Path $script:P.Old "server-$stamp"
    $oldRuntime = Join-Path $script:P.Old "runtime-$stamp"
    New-Item -ItemType Directory -Force $script:P.Old | Out-Null
    Log "Moving the current version to old\..."
    try {
        Move-Item $script:P.Server $oldServer
    } catch {
        throw "Could not move the server folder - is a file in it open in another program (Notepad, Explorer)? Nothing was changed."
    }
    try {
        Move-Item $script:P.Runtime $oldRuntime
    } catch {
        Move-Item $oldServer $script:P.Server            # put it back
        throw "Could not move the runtime folder - is a program from it still running? Nothing was changed."
    }
    Move-Item "$new\server"  $script:P.Server
    Move-Item "$new\runtime" $script:P.Runtime
    Remove-Item $new -Recurse -Force -ErrorAction SilentlyContinue

    Log "Bringing back your settings, modules and backups..."
    # settings\*.lua (but take the new settings\default)
    Get-ChildItem (Join-Path $oldServer 'settings') -Force | Where-Object { $_.Name -ne 'default' } | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $script:P.Server 'settings') -Recurse -Force
    }
    # modules: your init.txt, your own module folders, and any folder the new version doesn't have
    $oldMods = Join-Path $oldServer 'modules'
    $newMods = Join-Path $script:P.Server 'modules'
    Copy-IfExists (Join-Path $oldMods 'init.txt') (Join-Path $newMods 'init.txt')
    Get-ChildItem $oldMods -Directory | ForEach-Object {
        $dest = Join-Path $newMods $_.Name
        if ($MyModuleFolders -contains $_.Name) {
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Copy-Item $_.FullName $dest -Recurse -Force
        } elseif (-not (Test-Path $dest)) {
            Copy-Item $_.FullName $dest -Recurse -Force
        }
    }
    # database backups, logs, and the login server's TLS key/certificate
    Copy-IfExists (Join-Path $oldServer 'sql\backups\*') (Join-Path $script:P.Server 'sql\backups\')
    Copy-IfExists (Join-Path $oldServer 'log\*')         (Join-Path $script:P.Server 'log\')
    foreach ($f in 'login.key', 'login.cert') { Copy-IfExists (Join-Path $oldServer $f) (Join-Path $script:P.Server $f) }

    $script:Cfg.Release = $rel.Tag
    Save-Config

    Log "Applying database updates for the new version..."
    [void](Start-Database)
    try { Invoke-Dbtool 'update full' } finally { Stop-Database }

    Log "Update complete. The previous version is in $($script:P.Old) - delete it once you're happy."
    Show-Info "Update complete!`n`nYour previous version was kept in:`n$($script:P.Old)`n`nPress Start to run the server."
}

function Open-Folder([string]$path) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force $path | Out-Null }
    Start-Process explorer.exe $path | Out-Null
}

# ----------------------------------------------------------------------------
# The window
# ----------------------------------------------------------------------------
$font = New-Object Drawing.Font('Segoe UI', 9)
$form = New-Object Windows.Forms.Form
$form.Text = $AppTitle
$form.Size = New-Object Drawing.Size(780, 640)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $font

function New-Button([string]$text, [int]$x, [int]$y, [int]$w = 150) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 32)
    return $b
}
function New-Label([string]$text, [int]$x, [int]$y, [int]$w = 300) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, 22)
    return $l
}

# --- shared bottom area: progress + log ---
$script:StatusText = New-Label 'Ready' 12 392 620
$form.Controls.Add($script:StatusText)
$script:DarkModeBox = New-Object Windows.Forms.CheckBox
$script:DarkModeBox.Text = 'Dark mode'; $script:DarkModeBox.Location = New-Object Drawing.Point(652, 390); $script:DarkModeBox.Size = New-Object Drawing.Size(100, 22)
$form.Controls.Add($script:DarkModeBox)
$script:Progress = New-Object Windows.Forms.ProgressBar
$script:Progress.Location = New-Object Drawing.Point(12, 416); $script:Progress.Size = New-Object Drawing.Size(740, 18)
$form.Controls.Add($script:Progress)
$script:LogBox = New-Object Windows.Forms.TextBox
$script:LogBox.Multiline = $true; $script:LogBox.ReadOnly = $true; $script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Location = New-Object Drawing.Point(12, 440); $script:LogBox.Size = New-Object Drawing.Size(740, 150)
$script:LogBox.Font = New-Object Drawing.Font('Consolas', 8.5)
$form.Controls.Add($script:LogBox)

# --- install screen ---
$installPanel = New-Object Windows.Forms.Panel
$installPanel.Location = New-Object Drawing.Point(0, 0); $installPanel.Size = New-Object Drawing.Size(770, 385)
$title = New-Label 'Install the LSB server' 20 20 500
$title.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold); $title.Height = 32
$installPanel.Controls.Add($title)
$intro = New-Label "This downloads the latest server build from github.com/$GitHubRepo and sets everything up, including its own database. It needs about 5 GB of free space." 20 60 720
$intro.Height = 40
$installPanel.Controls.Add($intro)
$installPanel.Controls.Add((New-Label 'Install folder:' 20 115 120))
$folderBox = New-Object Windows.Forms.TextBox
$folderBox.Location = New-Object Drawing.Point(140, 112); $folderBox.Size = New-Object Drawing.Size(470, 24); $folderBox.Text = $DefaultInstallDir
$installPanel.Controls.Add($folderBox)
$browseBtn = New-Button 'Browse...' 620 108 110
$installPanel.Controls.Add($browseBtn)
$installPanel.Controls.Add((New-Label 'Database port:' 20 155 120))
$portBox = New-Object Windows.Forms.NumericUpDown
$portBox.Location = New-Object Drawing.Point(140, 152); $portBox.Size = New-Object Drawing.Size(90, 24)
$portBox.Minimum = 1024; $portBox.Maximum = 65535; $portBox.Value = $DefaultDbPort
$installPanel.Controls.Add($portBox)
$installPanel.Controls.Add((New-Label '(leave as is unless something else already uses it)' 240 155 400))
$installBtn = New-Button 'Install' 20 200 200
$installBtn.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold); $installBtn.Height = 40
$installBtn.Tag = 'start'
$installPanel.Controls.Add($installBtn)
$form.Controls.Add($installPanel)

# --- control panel screen ---
$panel = New-Object Windows.Forms.Panel
$panel.Location = New-Object Drawing.Point(0, 0); $panel.Size = New-Object Drawing.Size(770, 385); $panel.Visible = $false

$statusGroup = New-Object Windows.Forms.GroupBox
$statusGroup.Text = 'Status'; $statusGroup.Location = New-Object Drawing.Point(12, 10); $statusGroup.Size = New-Object Drawing.Size(270, 230)
$script:Lights = @{}
$y = 25
foreach ($c in $script:Components) {
    $dot = New-Label ([string][char]0x25CF) 15 ($y - 4) 24
    $dot.Font = New-Object Drawing.Font('Segoe UI', 14); $dot.Height = 28; $dot.ForeColor = [Drawing.Color]::Gray
    $dot.Tag = 'light'   # status light: its color is set by Update-Status, not the theme
    $statusGroup.Controls.Add($dot)
    $statusGroup.Controls.Add((New-Label $c.Label 42 $y 200))
    $script:Lights[$c.Key] = $dot
    $y += 32
}
$panel.Controls.Add($statusGroup)

$startBtn = New-Button 'Start' 300 20 140
$startBtn.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold); $startBtn.Height = 44
$startBtn.Tag = 'start'
$stopBtn = New-Button 'Stop' 450 20 140
$stopBtn.Font = $startBtn.Font; $stopBtn.Height = 44
# Restarts only xi_map - enough after changing Lua modules or scripts
$restartMapBtn = New-Button 'Restart map' 600 20 140
$restartMapBtn.Font = $startBtn.Font; $restartMapBtn.Height = 44
$stopBtn.Tag = 'stop'
$restartMapBtn.Tag = 'restart'
$script:ShowWindows = New-Object Windows.Forms.CheckBox
$script:ShowWindows.Text = 'Show server windows (minimized)'; $script:ShowWindows.Location = New-Object Drawing.Point(300, 72); $script:ShowWindows.Size = New-Object Drawing.Size(300, 22)
$panel.Controls.AddRange(@($startBtn, $stopBtn, $restartMapBtn, $script:ShowWindows))

$folderGroup = New-Object Windows.Forms.GroupBox
$folderGroup.Text = 'Open folder'; $folderGroup.Location = New-Object Drawing.Point(300, 105); $folderGroup.Size = New-Object Drawing.Size(450, 65)
$openServerBtn   = New-Button 'Server'   10 22 100
$openModulesBtn  = New-Button 'Modules'  118 22 100
$openSettingsBtn = New-Button 'Settings' 226 22 100
$openLogsBtn     = New-Button 'Logs'     334 22 100
$folderGroup.Controls.AddRange(@($openServerBtn, $openModulesBtn, $openSettingsBtn, $openLogsBtn))
$panel.Controls.Add($folderGroup)

$maintGroup = New-Object Windows.Forms.GroupBox
$maintGroup.Text = 'Maintenance'; $maintGroup.Location = New-Object Drawing.Point(300, 175); $maintGroup.Size = New-Object Drawing.Size(450, 102)
$backupBtn   = New-Button 'Back up database' 10 22 135
$dbUpdateBtn = New-Button 'Apply DB updates' 154 22 135
$updateBtn   = New-Button 'Update server'    298 22 135
$updatePanelBtn = New-Button 'Update control panel' 10 60 180
$maintGroup.Controls.AddRange(@($backupBtn, $dbUpdateBtn, $updateBtn, $updatePanelBtn))
$panel.Controls.Add($maintGroup)

$script:InfoLabel = New-Label '' 12 290 740
$script:InfoLabel.Height = 60
$panel.Controls.Add($script:InfoLabel)
$form.Controls.Add($panel)

$script:AllButtons = @($installBtn, $browseBtn, $startBtn, $stopBtn, $restartMapBtn, $backupBtn, $dbUpdateBtn, $updateBtn, $updatePanelBtn)
function Set-ButtonsEnabled([bool]$on) { foreach ($b in $script:AllButtons) { $b.Enabled = $on } }

function Update-Status {
    if (-not $script:P -or -not $script:panel.Visible) { return }
    foreach ($c in $script:Components) {
        $dot = $script:Lights[$c.Key]
        if ($c.Exe -and -not (Test-Path (Join-Path $script:P.Server $c.Exe))) { $dot.ForeColor = [Drawing.Color]::LightGray; continue }
        if (Get-Running $c.Key) {
            # Yellow = running but still loading; green = ready
            $dot.ForeColor = if ($script:Starting[$c.Key]) { [Drawing.Color]::Gold } else { [Drawing.Color]::LimeGreen }
        } else {
            $dot.ForeColor = [Drawing.Color]::Firebrick
        }
    }
}

function Show-Panel {
    $script:installPanel.Visible = $false
    $script:panel.Visible = $true
    $build = ''
    $bi = Join-Path $script:P.Server 'BUILD-INFO.txt'
    if (Test-Path $bi) { $build = (Get-Content $bi -Raw).Trim() }
    $script:InfoLabel.Text = "Installed in: $($script:P.Root)`r`nRelease: $($script:Cfg.Release)   $build`r`nDatabase: MariaDB on 127.0.0.1:$($script:Cfg.DbPort), database '$DbName'"
    Update-Status
}

# --- button actions ---
$browseBtn.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where to install the server (a new, empty folder is best)'
    if ($dlg.ShowDialog() -eq 'OK') { $folderBox.Text = Join-Path $dlg.SelectedPath 'LSB' }
})
$installBtn.Add_Click({ Run-Action 'Install' { Install-Server $folderBox.Text ([int]$portBox.Value) } })
$startBtn.Add_Click({ Run-Action 'Start server' { Start-Server } })
$stopBtn.Add_Click({ Run-Action 'Stop server' { Stop-Server } })
$restartMapBtn.Add_Click({ Run-Action 'Restart map server' { Restart-MapServer } })
$updatePanelBtn.Add_Click({ Run-Action 'Update control panel' { Update-ControlPanel } })
$backupBtn.Add_Click({ Run-Action 'Back up database' { Backup-Database } })
$dbUpdateBtn.Add_Click({ Run-Action 'Apply database updates' { Update-Database } })
$updateBtn.Add_Click({ Run-Action 'Update server' { Update-Server } })
$openServerBtn.Add_Click({   Open-Folder $script:P.Server })
$openModulesBtn.Add_Click({  Open-Folder (Join-Path $script:P.Server 'modules') })
$openSettingsBtn.Add_Click({ Open-Folder (Join-Path $script:P.Server 'settings') })
$openLogsBtn.Add_Click({     Open-Folder (Join-Path $script:P.Server 'log') })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    if (-not $script:Busy) { Update-Status }
    Remove-OldPanel
})
$timer.Start()

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:Restarting) { return }   # the control panel is updating itself; the server keeps running
    if ($script:Busy) {
        Show-Info 'Please wait for the current task to finish.'
        $e.Cancel = $true; return
    }
    if ($script:P -and $script:panel.Visible -and ((Test-AnyGameRunning) -or (Get-Running 'db'))) {
        $answer = [Windows.Forms.MessageBox]::Show("The server is still running.`n`nYes = stop it, then close`nNo = leave it running and close`nCancel = don't close", $AppTitle, 'YesNoCancel', 'Question')
        if ($answer -eq 'Cancel') { $e.Cancel = $true; return }
        if ($answer -eq 'Yes') {
            $script:Busy = $true
            try { Stop-Server } catch { Show-Error $_.Exception.Message }
            $script:Busy = $false
        }
    }
})

# ----------------------------------------------------------------------------
# Look: dark / light theme and the window icon
# ----------------------------------------------------------------------------
$UiSettingsFile = Join-Path $env:APPDATA 'LSB-Panel\ui.json'

function Get-DarkModeSetting {
    try {
        if (Test-Path $UiSettingsFile) {
            $ui = Get-Content $UiSettingsFile -Raw | ConvertFrom-Json
            if ($null -ne $ui.DarkMode) { return [bool]$ui.DarkMode }
        }
    } catch { }
    return $true   # dark by default
}

function Save-DarkModeSetting([bool]$dark) {
    try {
        New-Item -ItemType Directory -Force (Split-Path $UiSettingsFile -Parent) | Out-Null
        @{ DarkMode = $dark } | ConvertTo-Json | Set-Content $UiSettingsFile -Encoding UTF8
    } catch { }
}

function New-Rgb([int]$r, [int]$g, [int]$b) { return [Drawing.Color]::FromArgb($r, $g, $b) }

$script:Themes = @{
    Dark = @{
        Back = New-Rgb 30 31 34;    Surface = New-Rgb 43 45 49;  Hover = New-Rgb 55 58 64
        Input = New-Rgb 22 23 26;   Text = New-Rgb 227 229 232;  Muted = New-Rgb 160 165 172
        Border = New-Rgb 70 74 80
        Accent = @{
            start   = @{ Back = New-Rgb 31 77 54;  Border = New-Rgb 46 125 85;  Hover = New-Rgb 39 96 67 }
            stop    = @{ Back = New-Rgb 90 38 38;  Border = New-Rgb 140 58 58;  Hover = New-Rgb 110 47 47 }
            restart = @{ Back = New-Rgb 34 64 94;  Border = New-Rgb 53 103 154; Hover = New-Rgb 42 79 115 }
        }
    }
    Light = @{
        Back = [Drawing.SystemColors]::Control; Surface = [Drawing.SystemColors]::Control; Hover = [Drawing.SystemColors]::ControlLight
        Input = [Drawing.SystemColors]::Window; Text = [Drawing.SystemColors]::ControlText; Muted = [Drawing.SystemColors]::ControlText
        Border = [Drawing.SystemColors]::ControlDark
        Accent = @{
            start   = @{ Back = New-Rgb 220 245 220 }
            stop    = @{ Back = New-Rgb 250 225 225 }
            restart = @{ Back = New-Rgb 225 235 250 }
        }
    }
}

function Set-ControlTheme($parent, $t, [bool]$dark) {
    foreach ($c in $parent.Controls) {
        if ($c -is [Windows.Forms.Button]) {
            $accent = if ($c.Tag) { $t.Accent[[string]$c.Tag] } else { $null }
            $c.ForeColor = $t.Text
            if ($dark) {
                $c.FlatStyle = 'Flat'
                $c.UseVisualStyleBackColor = $false
                $c.BackColor = if ($accent) { $accent.Back } else { $t.Surface }
                $c.FlatAppearance.BorderColor = if ($accent) { $accent.Border } else { $t.Border }
                $c.FlatAppearance.MouseOverBackColor = if ($accent) { $accent.Hover } else { $t.Hover }
                $c.FlatAppearance.MouseDownBackColor = $t.Border
            } else {
                $c.FlatStyle = 'Standard'
                if ($accent) { $c.UseVisualStyleBackColor = $false; $c.BackColor = $accent.Back }
                else { $c.BackColor = [Drawing.SystemColors]::Control; $c.UseVisualStyleBackColor = $true }
            }
        } elseif ($c -is [Windows.Forms.TextBox] -or $c -is [Windows.Forms.NumericUpDown]) {
            $c.BackColor = $t.Input
            $c.ForeColor = $t.Text
            $c.BorderStyle = if ($dark) { 'FixedSingle' } else { 'Fixed3D' }
        } elseif ($c -is [Windows.Forms.CheckBox]) {
            $c.ForeColor = $t.Text
            $c.FlatStyle = if ($dark) { 'Flat' } else { 'Standard' }
        } elseif ($c -is [Windows.Forms.GroupBox]) {
            $c.ForeColor = $t.Muted
        } elseif ($c -is [Windows.Forms.Label]) {
            if ($c.Tag -ne 'light') { $c.ForeColor = $t.Text }
        } elseif ($c -is [Windows.Forms.Panel]) {
            $c.BackColor = $t.Back
        }

        if ($c.Controls.Count -gt 0 -and -not ($c -is [Windows.Forms.NumericUpDown])) {
            Set-ControlTheme $c $t $dark
        }
    }
}

function Set-Theme([bool]$dark) {
    $t = if ($dark) { $script:Themes.Dark } else { $script:Themes.Light }
    $form.BackColor = $t.Back
    $form.ForeColor = $t.Text
    Set-ControlTheme $form $t $dark
    $script:InfoLabel.ForeColor = $t.Muted
    if ($form.IsHandleCreated) {
        [LsbWindow]::SetDarkTitleBar($form.Handle, $dark)
        # nudge Windows into redrawing the title bar straight away
        $form.Width += 1; $form.Width -= 1
    }
}

# The title bar can only be changed once the window exists
$form.Add_HandleCreated({ [LsbWindow]::SetDarkTitleBar($form.Handle, $script:DarkModeBox.Checked) })

$script:DarkModeBox.Checked = Get-DarkModeSetting
Set-Theme $script:DarkModeBox.Checked
$script:DarkModeBox.Add_CheckedChanged({
    Set-Theme $script:DarkModeBox.Checked
    Save-DarkModeSetting $script:DarkModeBox.Checked
})

# Window icon (taskbar and title bar). The .exe carries the icon that ps2exe
# built into it; when running the .ps1 itself, lsb-icon.ico next to it is used.
try {
    if ($SelfIsExe) {
        $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($SelfPath)
    } else {
        $iconFile = Join-Path (Split-Path $SelfPath -Parent) 'lsb-icon.ico'
        if (Test-Path $iconFile) { $form.Icon = New-Object Drawing.Icon($iconFile) }
    }
} catch { }

# --- start up: control panel if installed, otherwise the install screen ---
$existing = Find-Install
if ($existing) {
    Load-Config $existing
    Show-Panel
    Log "Ready. Server folder: $($script:P.Server)"
} else {
    Log 'Choose a folder and press Install.'
}

[void]$form.ShowDialog()
$timer.Stop()
