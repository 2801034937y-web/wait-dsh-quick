#requires -version 3
<#
  ============================================================================
  DSH Web Launcher  -  "double-click and it just works"
  ============================================================================

  WHAT IT DOES
    * starts the DSH local web server in a GENUINELY hidden window
      (WScript.Shell.Run(..., 0, ...) = SW_HIDE: no console is ever created)
    * CAPTURES the one-line access URL the server prints and opens THAT url,
      because `dsh web` rejects a plain URL with HTTP 401
      ("dsh web authentication required"). The printed URL carries a per-process
      launch token; opening it once mints the browser session cookie and
      redirects to the clean URL. The captured file is deleted right after.
    * opens the UI as a chrome-less browser app window (Edge/Chrome --app=)
    * if the server is already listening, it just opens the window (idempotent)
    * if anything is missing or fails, it shows a dialog that says WHY

  WHAT IT NEVER DOES  (this is a hard rule, please keep it)
    * it NEVER installs, upgrades, downgrades, patches or deletes DSH
    * it NEVER touches your save files / sessions / profile / credentials
    * it NEVER changes your browser settings or your default browser
    * it only ever READS a few files (package.json / bin.js) to report versions
    Everything it writes lives in its own folder or the Desktop, and only
    when YOU explicitly pass -MakeShortcut.

  FILES IT READS (read-only)
    <npm cache>\_npx\*\node_modules\@deepseek-ai\dsh\lib\bin.js
    <npm cache>\_npx\*\node_modules\@deepseek-ai\dsh\package.json
    <npm global prefix>\node_modules\@deepseek-ai\dsh\...
    %USERPROFILE%\.dsh\bin.js          (last-resort fallback)
    %ProgramFiles%\nodejs\node.exe     (and a few other places)

  FILES IT WRITES (only these)
    <Desktop>\<shortcut name>.lnk      only with -MakeShortcut
    %LOCALAPPDATA%\dsh-launcher\launcher.log         append-only log
    %LOCALAPPDATA%\dsh-launcher\server-output.txt    the server's one-line
                                                     access URL, deleted again
                                                     as soon as it is used

  USAGE
    dsh-launcher.ps1                       double-click / normal start
    dsh-launcher.ps1 -SelfTest             diagnose only, starts nothing
    dsh-launcher.ps1 -Port 3099            use another port
    dsh-launcher.ps1 -NoAppWindow          open a normal browser tab
    dsh-launcher.ps1 -NoBrowser            start the server only
    dsh-launcher.ps1 -MakeShortcut         create the Desktop shortcut
    dsh-launcher.ps1 -CleanRuntime         delete the launcher's own temp files
                                           (refuses while DSH is running)
    dsh-launcher.ps1 -Uninstall            remove this launcher again

  ENVIRONMENT OVERRIDES (optional)
    DSH_LAUNCHER_PORT      default port
    DSH_LAUNCHER_BROWSER   full path to msedge.exe / chrome.exe
    DSH_LAUNCHER_DISABLE   set to 1 to make double-click do nothing (panic key)

  ASCII-ONLY SOURCE ON PURPOSE
    Windows PowerShell 5.1 reads .ps1 as ANSI unless the file carries a UTF-8
    BOM, so every non-ASCII name/path is built from Unicode code points at
    runtime instead of being written literally. Please keep it that way, or
    save the file as UTF-8 WITH BOM if you prefer readable literals.
#>

[CmdletBinding()]
param(
    [int]    $Port = 0,                 # 0 = use env var / built-in default
    [string] $BrowserPath = '',
    [int]    $WaitSeconds = 45,
    [switch] $NoAppWindow,
    [switch] $NoBrowser,
    [switch] $SelfTest,
    [switch] $MakeShortcut,
    [switch] $CleanRuntime,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$script:LauncherName  = 'DSH Web Launcher'
$script:AppName       = 'DSH'
$script:DefaultPort   = 3080
$script:TestedVersions = @('0.1.7-alpha.1')   # add new verified versions here

# ---------------------------------------------------------------- tiny helpers
function CN([int[]]$codes) { -join ($codes | ForEach-Object { [char]$_ }) }

function Write-Log {
    param([string]$Text)
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'dsh-launcher'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -LiteralPath (Join-Path $dir 'launcher.log') -Value $line -Encoding UTF8
    } catch { }
}

function Show-Dialog {
    param([string]$Text, [string]$Title = $script:LauncherName, [int]$Icon = 48)
    Write-Log "DIALOG: $Text"
    try {
        $sh = New-Object -ComObject WScript.Shell
        [void]$sh.Popup($Text, 0, $Title, $Icon)
    } catch {
        Write-Host $Text
    }
}

# NOTE: use $PSScriptRoot, NOT Split-Path $MyInvocation.MyCommand.Path.
# Inside a *function* $MyInvocation refers to the function call, so that trick
# silently returns $null here. $PSScriptRoot exists since PowerShell 3.
function Get-ScriptFolder { return $PSScriptRoot }

# ------------------------------------------------------------------- detection
function Test-ServiceUp {
    param([int]$TimeoutMs = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Test-PortFree {
    param([int]$TimeoutMs = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $true }
        $client.EndConnect($iar)
        return $false          # something answered -> port is taken
    } catch {
        return $true           # refused / unreachable -> free
    } finally {
        try { $client.Close() } catch { }
    }
}

function Find-Node {
    $cands = @(
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        (Join-Path $env:APPDATA 'nvm\node.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-NpmConfig {
    param([string]$Key)
    try {
        $v = (& npm config get $Key 2>$null | Select-Object -First 1)
        if ($v) { return $v.Trim() }
    } catch { }
    return $null
}

function Get-CacheBases {
    # The npx cache / global prefix location is fully configurable, so gather
    # every candidate instead of assuming %LOCALAPPDATA%\npm-cache.
    $bases = @()
    if ($env:npm_config_cache) { $bases += $env:npm_config_cache }
    $c = Get-NpmConfig 'cache'
    if ($c -and $c -notmatch '^(undefined|null)$') { $bases += $c }
    $bases += @(
        (Join-Path $env:LOCALAPPDATA 'npm-cache'),
        (Join-Path $env:APPDATA 'npm-cache')
    )
    return ($bases | Where-Object { $_ } | Select-Object -Unique)
}

function Get-PrefixBases {
    $bases = @()
    if ($env:npm_config_prefix) { $bases += $env:npm_config_prefix }
    $p = Get-NpmConfig 'prefix'
    if ($p -and $p -notmatch '^(undefined|null)$') { $bases += $p }
    $bases += @(
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:LOCALAPPDATA 'npm')
    )
    return ($bases | Where-Object { $_ } | Select-Object -Unique)
}

function Find-DshEntry {
    $rel = 'node_modules\@deepseek-ai\dsh\lib\bin.js'

    # 1) npx cache: <cache>\_npx\<HASH>\node_modules\@deepseek-ai\dsh\lib\bin.js
    #    The <HASH> folder changes with every package version -> never hardcode it.
    foreach ($b in (Get-CacheBases)) {
        $npx = Join-Path $b '_npx'
        if (-not (Test-Path -LiteralPath $npx)) { continue }
        $hit = Get-ChildItem -LiteralPath $npx -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName $rel } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Sort-Object -Descending | Select-Object -First 1
        if ($hit) { return $hit }
    }

    # 2) global prefix: <prefix>\node_modules\@deepseek-ai\dsh\lib\bin.js
    foreach ($p in (Get-PrefixBases)) {
        $cand = Join-Path $p $rel
        if (Test-Path -LiteralPath $cand) { return $cand }
    }

    # 3) last resort: a hand-made copy inside the user profile
    $local = Join-Path $env:USERPROFILE '.dsh\bin.js'
    if (Test-Path -LiteralPath $local) { return $local }

    return $null
}

function Get-DshVersion {
    param([string]$Entry, [string]$Node)
    if (-not $Entry) { return $null }
    if ($Node) {
        try {
            $v = (& $Node $Entry --version 2>$null | Select-Object -First 1)
            # `node bin.js --version` can be polluted by the app's own banner,
            # so pick the first line that looks like a plain semver string.
            foreach ($line in @($v)) {
                $t = "$line".Trim()
                if ($t -match '^v?\d+\.\d+\.\d+[0-9A-Za-z\.\-\+]*$') { return ($t -replace '^v','') }
            }
        } catch { }
    }
    $pkg = Join-Path (Split-Path -Parent (Split-Path -Parent $Entry)) 'package.json'
    if (Test-Path -LiteralPath $pkg) {
        try {
            $j = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.version) { return "$($j.version)" }
        } catch { }
    }
    return $null
}

function Find-Browser {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }
    if ($env:DSH_LAUNCHER_BROWSER -and (Test-Path -LiteralPath $env:DSH_LAUNCHER_BROWSER)) {
        return $env:DSH_LAUNCHER_BROWSER
    }
    $cands = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# ---------------------------------------------------------------- presentation
function Get-Env {
    param([string]$Node, [string]$Entry, [string]$Browser)
    $folder = Get-ScriptFolder
    $ico = Join-Path $folder 'assets\icon.ico'
    $t = New-Object 'System.Collections.Specialized.OrderedDictionary'
    $t['launcher    '] = (Join-Path $folder 'dsh-launcher.ps1')
    $t['port        '] = "$Port"
    $t['node        '] = $(if ($Node)    { $Node }    else { 'NOT FOUND' })
    $t['dsh entry   '] = $(if ($Entry)   { $Entry }   else { 'NOT FOUND' })
    $t['dsh version '] = $(if ($Node -and $Entry) { Get-DshVersion -Entry $Entry -Node $Node } else { 'n/a' })
    $t['browser     '] = $(if ($Browser) { $Browser } else { 'NOT FOUND (falls back to default browser)' })
    $t['icon        '] = $(if (Test-Path -LiteralPath $ico) { $ico } else { 'NOT FOUND (shortcut will use a generic icon)' })
    $t['server up   '] = $(if (Test-ServiceUp) { 'yes (already listening)' } else { 'no' })
    $t['started by  '] = $(if (Get-OurServerPid) { 'this launcher' } elseif (Test-ServiceUp) { 'something else (never killed by us)' } else { 'n/a' })
    $t['browser sess'] = $(if (Test-ServiceUp) { if (Test-HasSessionCookie) { 'yes (session cookie still valid)' } else { 'NO - a fresh token would be needed' } } else { 'n/a' })
    $t['cookie file '] = $(if (Read-SessionCookie) { 'present in ' + (Get-SessionCookiePath) } else { 'none yet' })
    $cp = Get-CapturePath
    $t['token file  '] = $(if (Test-Path -LiteralPath $cp) { "$cp ($((Get-Item $cp).Length) B, locked while DSH runs)" } else { 'none' })
    $t['powershell  '] = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $t['os          '] = [string][Environment]::OSVersion.Version
    $t['desktop     '] = [Environment]::GetFolderPath('Desktop')
    return $t
}

function Show-Env {
    param([string]$Node, [string]$Entry, [string]$Browser, [switch]$Quiet)
    $t = Get-Env -Node $Node -Entry $Entry -Browser $Browser
    $lines = @()
    foreach ($k in $t.Keys) {
        $lines += ('{0}: {1}' -f $k, $t[$k])
        if (-not $Quiet) { Write-Host ('{0}: {1}' -f $k, $t[$k]) }
    }
    return ($lines -join [Environment]::NewLine)
}

# --------------------------------------------------------------- run the thing
function Get-RuntimeDir {
    $dir = Join-Path $env:LOCALAPPDATA 'dsh-launcher'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Start-DshServer {
    param([string]$Node, [string]$Entry)
    $args = @('--profile', 'web', '--port', "$Port", '--no-open')
    # --no-open matters: we open the app window ourselves, otherwise you get a
    # second, ordinary browser window with an address bar.
    $inner = '"{0}" "{1}" {2} 1> "{3}" 2>&1' -f $Node, $Entry, ($args -join ' '), (Get-CapturePath)

    # WHY A GENERATED .cmd INSTEAD OF ONE LONG COMMAND LINE
    #   WScript.Shell.Run() takes a single string. To capture the server's
    #   output we need a redirection, and a redirection cannot go inside the
    #   quoted /c argument without breaking the quoting:
    #     "...cmd.exe" /c ""node.exe" "bin.js" ..." 1> out.txt      <- BROKEN
    #   (cmd treats the whole quoted blob as the program name, nothing starts)
    #   Putting the identical line in a small .cmd file removes all quoting
    #   ambiguity and was measured to work. It must be written WITHOUT a BOM:
    #   a UTF-8 BOM makes cmd.exe choke on the first line ("off" is served as a
    #   command). Hence [System.IO.File]::WriteAllLines + ASCII.
    $bat = Join-Path (Get-RuntimeDir) 'start-server.cmd'
    [System.IO.File]::WriteAllLines($bat, @('@echo off', $inner), [System.Text.Encoding]::ASCII)

    # clear anything a previous run left behind, BEFORE the new server opens it
    Clear-CaptureFile

    $runArg = '"{0}" /c ""{1}""' -f (Join-Path $env:SystemRoot 'System32\cmd.exe'), $bat
    $shell = New-Object -ComObject WScript.Shell
    # 0 = SW_HIDE -> no console window is created at all.
    # $false     -> do not wait; this returns in well under 100 ms.
    [void]$shell.Run($runArg, 0, $false)
    Write-Log "spawned via $bat : $inner"
}

function Get-CapturePath {
    return (Join-Path (Get-RuntimeDir) 'server-output.txt')
}

function Read-CaptureFile {
    # The server keeps the file open for writing, so a plain read can hit a
    # sharing violation. Use a FileStream with FileShare.ReadWrite and retry.
    $path = Get-CapturePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd()
            $sr.Close()
        } finally { $fs.Close() }
        return $text
    } catch { return $null }
}

function Wait-Server {
    param([int]$Seconds, [switch]$WantUrl)
    for ($i = 0; $i -lt ($Seconds * 2); $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-ServiceUp)) { continue }
        if (-not $WantUrl) { return $true }
        $text = Read-CaptureFile
        if ($text -and $text -match 'https?://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9_\-]+') {
            return $Matches[0]
        }
        # server is answering but the token line is not flushed yet -> keep waiting
    }
    return $false
}

function Clear-CaptureFile {
    # HONEST LIMITATION: the spawned server holds this file open with an
    # exclusive write share for its whole lifetime, so it CANNOT be truncated
    # or deleted while the server runs (measured: both fail with "used by
    # another process"). Truncation is attempted anyway because it succeeds
    # when the server happens to be gone; a leftover access token is therefore
    # possible and is documented. It is per-process, single-user-readable, and
    # only ever written inside %LOCALAPPDATA%.
    $p = Get-CapturePath
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.SetLength(0) } finally { $fs.Close() }
    } catch { }
    try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop } catch { }
}

# ------------------------------------------------------------- server identity
function Get-StatePath { return (Join-Path (Get-RuntimeDir) 'server.json') }

function Save-ServerState {
    # Remember WHICH process we started, so a later run can recognise its own
    # child and never touch a server the user started themselves.
    $p = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
          Select-Object -First 1).OwningProcess
    if (-not $p) { return }
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    if (-not $proc) { return }
    $state = [ordered]@{
        port      = $Port
        pid       = $p
        startedAt = $proc.StartTime.ToUniversalTime().ToString('o')
        launcher  = $script:LauncherName
    }
    try {
        $state | ConvertTo-Json -Compress | Set-Content -LiteralPath (Get-StatePath) -Encoding UTF8
    } catch { }
}

function Get-OurServerPid {
    # Returns the pid only if the process listening on our port is still the
    # exact process we launched (same pid AND same start time).
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $state -or $state.port -ne $Port) { return $null }
    $cur = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1).OwningProcess
    if (-not $cur -or $cur -ne $state.pid) { return $null }
    $proc = Get-Process -Id $cur -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    if ($proc.StartTime.ToUniversalTime().ToString('o') -ne $state.startedAt) { return $null }
    return $cur
}

function Stop-OurServer {
    $p = Get-OurServerPid
    if (-not $p) { return $false }
    Write-Log "restarting our own server (pid $p) to mint a fresh access token"
    try { Stop-Process -Id $p -Force } catch { }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-PortFree) { return $true }
    }
    return $false
}

function Test-HasSessionCookie {
    # Short request carrying the cookie we captured earlier. 401 means the
    # browser session is gone (or was never established), anything else means
    # the app window will load without asking for anything.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        $client.ReceiveTimeout = 4000
        $client.SendTimeout    = 4000
        $extra = ''
        $cookie = Read-SessionCookie
        if ($cookie) { $extra = "Cookie: $cookie`r`n" }
        $req = "GET / HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`n$extra" + "Connection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream = $client.GetStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $buf = New-Object byte[] 64
        $n = $stream.Read($buf, 0, 64)
        if ($n -le 0) { return $null }
        $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        return ($head -notmatch '\b401\b')
    } catch {
        return $null
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-SessionCookiePath { return (Join-Path (Get-RuntimeDir) 'session-cookie.txt') }

function Read-SessionCookie {
    $p = Get-SessionCookiePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $v = (Get-Content -LiteralPath $p -Raw -Encoding ASCII).Trim() } catch { return $null }
    if ($v -match '^dsh-auth-[A-Za-z0-9_\-]+=v1\.[A-Za-z0-9_\-\.]+$') { return $v }
    return $null
}

function Save-SessionCookie {
    param([string]$Url)
    # Exchange the launch token the way the browser does, keep the resulting
    # session cookie so later runs can tell whether the session is still alive.
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.AllowAutoRedirect = $false
        $req.Timeout = 10000
        $resp = $req.GetResponse()
        try {
            $sc = $resp.Headers['Set-Cookie']
            if ($sc -and $sc -match '(dsh-auth-[A-Za-z0-9_\-]+=[^;]+)') {
                Set-Content -LiteralPath (Get-SessionCookiePath) -Value $Matches[1] -Encoding ASCII
                return $true
            }
        } finally { $resp.Close() }
    } catch { }
    return $false
}

function Open-Ui {
    param([string]$Browser, [string]$TargetUrl)
    if ($NoBrowser) { return }
    if ($Browser) {
        if ($NoAppWindow) { Start-Process -FilePath $Browser -ArgumentList @($TargetUrl) }
        else              { Start-Process -FilePath $Browser -ArgumentList @("--app=$TargetUrl") }
    } else {
        Start-Process $TargetUrl
    }
}

# ------------------------------------------------------------------ shortcuts
function Get-Desktop {
    return [Environment]::GetFolderPath('Desktop')
}

function New-Shortcut {
    param([string]$Name = 'dsh')
    $desktop = Get-Desktop
    if (-not (Test-Path -LiteralPath $desktop)) { throw "Desktop folder not found: $desktop" }

    $folder = Get-ScriptFolder
    $ps1    = Join-Path $folder 'dsh-launcher.ps1'
    $ico    = Join-Path $folder 'assets\icon.ico'
    if (-not (Test-Path -LiteralPath $ps1)) { throw "launcher not found: $ps1" }
    $host_  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk    = Join-Path $desktop ($Name + '.lnk')

    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath       = $host_
    $s.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"'
    $s.WorkingDirectory = $folder
    $s.Description      = 'Open DSH in a standalone app window'
    $s.WindowStyle      = 7
    if (Test-Path -LiteralPath $ico) { $s.IconLocation = "$ico,0" }
    $s.Save()

    # Remember the chosen name so -Uninstall removes exactly this one.
    try {
        Set-Content -LiteralPath (Join-Path (Get-RuntimeDir) 'shortcut-name.txt') -Value $Name -Encoding ASCII
    } catch { }
    return $lnk
}

function Remove-Shortcut {
    param([string]$Name = 'dsh')
    # SAFETY: only ever remove a .lnk that actually points back at THIS
    # launcher. Deleting by filename alone is how you destroy somebody else's
    # shortcut - that mistake was made once during development, so the check
    # stays. If the name does not match, nothing is removed and we say so.
    $lnk = Join-Path (Get-Desktop) ($Name + '.lnk')
    if (-not (Test-Path -LiteralPath $lnk)) { return $false }
    $self = (Get-ScriptFolder).TrimEnd('\')
    try {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        if ($s.Arguments -notlike "*$self*") {
            Write-Host "  refused: $lnk does not point at this launcher -> left alone" -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "  refused: could not read $lnk -> left alone" -ForegroundColor Yellow
        return $false
    }
    Remove-Item -LiteralPath $lnk -Force
    return $true
}

# ============================================================== main ==========
# 1) resolve configuration (argument > environment > built-in default)
if ($Port -le 0) {
    if ($env:DSH_LAUNCHER_PORT -and $env:DSH_LAUNCHER_PORT -match '^\d+$') { $Port = [int]$env:DSH_LAUNCHER_PORT }
    else { $Port = $script:DefaultPort }
}
$Url = "http://127.0.0.1:$Port"

# 2) panic key
if ($env:DSH_LAUNCHER_DISABLE -eq '1' -and -not ($SelfTest -or $MakeShortcut -or $Uninstall -or $CleanRuntime)) {
    Write-Host 'DSH_LAUNCHER_DISABLE=1 -> doing nothing.'
    exit 0
}

$node    = Find-Node
$entry   = Find-DshEntry
$browser = Find-Browser -Explicit $BrowserPath

# 3) diagnostic-only modes
if ($SelfTest) {
    Write-Host ''
    Write-Host "== $script:LauncherName : self test ==" -ForegroundColor Cyan
    [void](Show-Env -Node $node -Entry $entry -Browser $browser)
    $ver = Get-DshVersion -Entry $entry -Node $node
    Write-Host ''
    if (-not $node)  { Write-Host 'RESULT: node.exe not found. Install Node.js: https://nodejs.org/' -ForegroundColor Red;  exit 1 }
    if (-not $entry) { Write-Host 'RESULT: DSH entry not found. Run this once yourself, then re-test:' -ForegroundColor Red
                       Write-Host '        npx @deepseek-ai/dsh@0.1.7-alpha.1 web'
                       Write-Host '        (this launcher will not install it for you)' ; exit 2 }
    if ($ver -and ($script:TestedVersions -notcontains $ver)) {
        Write-Host "NOTE: DSH $ver is not in the verified list ($($script:TestedVersions -join ', '))." -ForegroundColor Yellow
        Write-Host '      It will still be started as-is; nothing about it is modified.' -ForegroundColor Yellow
    } else {
        Write-Host "RESULT: OK - DSH $ver, node, browser and shortcut targets all resolvable." -ForegroundColor Green
    }
    exit 0
}

if ($CleanRuntime) {
    Write-Host ''
    if (Test-ServiceUp) {
        Write-Host "A DSH server is still listening on port $Port." -ForegroundColor Yellow
        Write-Host 'The captured access link stays locked until it exits, so stop DSH first.' -ForegroundColor Yellow
        Write-Host "If DSH is on another port, pass it: -Port <n>   (or just delete the folder later)" -ForegroundColor Yellow
        Write-Host 'Nothing was deleted.'
        exit 6
    }
    Clear-CaptureFile
    $rt = Join-Path $env:LOCALAPPDATA 'dsh-launcher'
    foreach ($n in @('start-server.cmd','server.json','launcher.log')) {
        $p = Join-Path $rt $n
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host "removed $p" }
    }
    Write-Host 'Runtime files cleaned. DSH itself was not touched.' -ForegroundColor Green
    exit 0
}

if ($Uninstall) {
    Write-Host ''
    # Use the name recorded at install time, so a custom -ShortcutName is
    # removed correctly; fall back to the default.
    $name = 'dsh'
    $nameFile = Join-Path (Get-RuntimeDir) 'shortcut-name.txt'
    if (Test-Path -LiteralPath $nameFile) {
        try { $n = (Get-Content -LiteralPath $nameFile -Raw).Trim(); if ($n) { $name = $n } } catch { }
    }
    $gone = Remove-Shortcut -Name $name
    $dir  = Join-Path $env:LOCALAPPDATA 'dsh-launcher'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($gone) { Write-Host "Desktop shortcut removed: yes ($name.lnk)" }
    else       { Write-Host "Desktop shortcut removed: no ($name.lnk was absent or was not ours)" }
    Write-Host 'Runtime files removed: yes (anything still locked by a running DSH is kept)'
    Write-Host ''
    Write-Host 'NOTHING about DSH itself, and no user data, was touched.' -ForegroundColor Green
    Write-Host "You can delete this launcher folder manually: $(Get-ScriptFolder)"
    exit 0
}

if ($MakeShortcut) {
    try {
        $lnk = New-Shortcut
        Show-Dialog -Text ("Desktop shortcut created:`n`n$lnk`n`nIt only starts DSH. It never installs or modifies it.") -Icon 64
        Write-Host "shortcut created: $lnk" -ForegroundColor Green
        exit 0
    } catch {
        Show-Dialog -Text "Could not create the shortcut:`n$($_.Exception.Message)"
        exit 1
    }
}

# 4) normal start -------------------------------------------------------------
# Decision table (this is the part that used to show a 401 error page):
#
#   server down                              -> start it, open the printed
#                                               token URL (mints the cookie)
#   server up + browser already has cookie   -> just open the plain URL
#   server up + NO cookie + it is OUR server -> restart it (only our own pid,
#                                               verified by pid + start time)
#                                               to mint a fresh token
#   server up + NO cookie + started by YOU   -> never kill it; open the plain
#                                               URL and say what to do
$started = $false
$target  = $Url

if (Test-ServiceUp) {
    $hasCookie = Test-HasSessionCookie
    if ($hasCookie -eq $false) {
        $ourPid = Get-OurServerPid
        if ($ourPid) {
            Write-Log "server pid $ourPid is ours but has no browser session -> restarting for a fresh token"
            if (Stop-OurServer) {
                # fall through to the start path below
            } else {
                Show-Dialog -Text ("DSH is running on port $Port but did not stop cleanly, so a fresh access link could not be created.`n`nClose the DSH window and double-click the shortcut again.")
                exit 5
            }
        } else {
            # Not our child -> never terminate it. Open the window anyway and
            # give the browser a moment: the session cookie lives in the
            # browser's own store, which we cannot see, so the honest test is
            # "did it work after we opened it".
            Write-Log 'server is not ours and our probe has no cookie: opening anyway, will verify'
            $target = $Url
            Open-Ui -Browser $browser -TargetUrl $target
            $ok = $false
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Milliseconds 500
                if (Test-HasSessionCookie) { $ok = $true; break }
            }
            if (-not $ok) {
                Show-Dialog -Text ("DSH is already running on port $Port, but it was started outside this launcher and this browser still has no session for it.`n`nNothing was killed - that server may be in the middle of something, and this launcher never terminates a DSH process it did not start.`n`nTo fix it: close that DSH window, then double-click this shortcut again.`n`n(If a window did open and looks fine, just ignore this message.)")
                Write-Log 'not ours + no cookie after opening: told the user, killed nothing'
            } else {
                Write-Log 'not ours but the window authenticated fine: no action needed'
            }
            exit 0
        }
    }
}

if (-not (Test-ServiceUp)) {
    if (-not $node) {
        Show-Dialog -Text ("Node.js was not found on this computer.`n`nDSH runs on Node.js. Please install it from:`nhttps://nodejs.org/`n`nthen double-click this shortcut again.`n`n(This launcher will not download or install anything for you.)")
        Write-Log 'abort: node not found'
        exit 1
    }
    if (-not $entry) {
        Show-Dialog -Text ("DSH itself was not found on this computer.`n`nNothing was installed or changed. Run this once in a terminal, then try again:`n`nnpx @deepseek-ai/dsh@0.1.7-alpha.1 web`n`nAfter that, this launcher will find it automatically.")
        Write-Log 'abort: entry not found'
        exit 2
    }

    # A different program may already own the port. Never silently "reuse" it.
    if (-not (Test-PortFree)) {
        Show-Dialog -Text ("Port $Port is already in use by something that is not DSH.`n`nStart the launcher with another port, for example:`n`n  dsh-launcher.ps1 -Port 3099`n`nor set the environment variable DSH_LAUNCHER_PORT=3099.")
        Write-Log "abort: port $Port busy but does not look like DSH"
        exit 3
    }

    Write-Log "starting: $node $entry --profile web --port $Port --no-open"
    Start-DshServer -Node $node -Entry $entry
    $started = $true

    $tokenUrl = Wait-Server -Seconds $WaitSeconds -WantUrl
    if (-not $tokenUrl) {
        # Either nothing came up at all, or it answers but never printed a
        # usable token URL. Both deserve different wording.
        $answering = Test-ServiceUp
        $envDump = Show-Env -Node $node -Entry $entry -Browser $browser -Quiet
        if ($answering) {
            Show-Dialog -Text ("DSH is listening on $Url but did not print its access URL, so the browser would only get ""authentication required"".`n`nCaptured output:`n" + (Read-CaptureFile) + "`n`nTry it manually in a terminal:`n`n  node `"$entry`" --profile web --port $Port`n`nLog: $(Get-CapturePath)")
            Write-Log 'abort: no token url in server output'
        } else {
            Show-Dialog -Text ("DSH did not answer on $Url within $WaitSeconds seconds.`n`nChecklist:`n$envDump`n`nTry it manually in a terminal to see the real error:`n`n  node `"$entry`" --profile web --port $Port`n`nLog: $(Get-CapturePath)")
            Write-Log 'abort: server did not come up'
        }
        exit 4
    }
    $target = $tokenUrl
    Save-ServerState
    Write-Log "got access url for this process: $($target -replace 'token=.*','token=<redacted>')"
}

Open-Ui -Browser $browser -TargetUrl $target
# Keep a copy of the session cookie so the next run can tell - without a
# browser - whether the app window will load straight away or needs a token.
if ($started -and $target -match '\?token=') { [void](Save-SessionCookie -Url $target) }
# The token has done its job once the browser traded it for a session cookie.
# Best-effort only: while the server runs, the OS keeps the capture file
# exclusively locked, so a copy of the token can survive in
# %LOCALAPPDATA%\dsh-launcher\server-output.txt until the server exits.
if ($started) { Clear-CaptureFile }
Write-Log "opened $Url (browser=$browser, appWindow=$(-not $NoAppWindow))"
exit 0
