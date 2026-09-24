#requires -version 3
<#
  ============================================================================
  DSH Web Launcher - installer
  ============================================================================

  Does exactly three things, and nothing else:

    1. copies dsh-launcher.ps1 + assets\icon.ico to
       %LOCALAPPDATA%\dsh-launcher\app\
    2. creates ONE Desktop shortcut (dsh.lnk) pointing at that copy
    3. runs the launcher's own -SelfTest so you can see the verdict

  IT DOES NOT
    * install, update, downgrade or remove DSH
    * touch %USERPROFILE%\.dsh (sessions, profiles, credentials)
    * change any browser setting
    * remove the folder you are installing from

  Run it from the extracted folder:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
  or right-click -> Run with PowerShell.

  ASCII-ONLY SOURCE ON PURPOSE (Windows PowerShell 5.1 reads .ps1 as ANSI
  unless the file has a UTF-8 BOM).
#>

[CmdletBinding()]
param(
    [string] $ShortcutName = 'dsh',
    [switch] $NoShortcut,
    [switch] $NoSelfTest
)

$ErrorActionPreference = 'Stop'

$here    = $PSScriptRoot
$srcPs1  = Join-Path $here 'dsh-launcher.ps1'
$srcIco  = Join-Path $here 'assets\icon.ico'
$destDir = Join-Path $env:LOCALAPPDATA 'dsh-launcher\app'
$destPs1 = Join-Path $destDir 'dsh-launcher.ps1'
$destIco = Join-Path $destDir 'assets\icon.ico'
$desktop = [Environment]::GetFolderPath('Desktop')

Write-Host ''
Write-Host '== DSH Web Launcher : install ==' -ForegroundColor Cyan

# ---------------------------------------------------------------- 0) sanity
if (-not (Test-Path -LiteralPath $srcPs1)) { throw "dsh-launcher.ps1 not found next to this script: $srcPs1" }
if (-not (Test-Path -LiteralPath $desktop)) { throw "Desktop folder not found: $desktop" }

# ------------------------------------------------------------- 1) copy files
if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
New-Item -ItemType Directory -Path (Join-Path $destDir 'assets') -Force | Out-Null

$sameFile = $false
try { $sameFile = ((Get-Item -LiteralPath $srcPs1).FullName -eq (Get-Item -LiteralPath $destPs1 -ErrorAction SilentlyContinue).FullName) } catch { }

if (-not $sameFile) {
    Copy-Item -LiteralPath $srcPs1 -Destination $destPs1 -Force
    Write-Host "  launcher copied -> $destPs1"
} else {
    Write-Host "  launcher already in place: $destPs1"
}

if (Test-Path -LiteralPath $srcIco) {
    Copy-Item -LiteralPath $srcIco -Destination $destIco -Force
    Write-Host "  icon copied     -> $destIco"
} else {
    Write-Host '  WARNING: assets\icon.ico not found - the shortcut will use a generic icon.' -ForegroundColor Yellow
    Write-Host '           (Windows ignores .png in IconLocation; it must be a .ico)' -ForegroundColor Yellow
}

# ------------------------------------------------------------ 2) shortcut
$psHost = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk    = Join-Path $desktop ($ShortcutName + '.lnk')

if (-not $NoShortcut) {
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath       = $psHost
    $s.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $destPs1 + '"'
    $s.WorkingDirectory = $destDir
    $s.Description      = 'Open DSH in a standalone app window (never installs or modifies DSH)'
    $s.WindowStyle      = 7
    if (Test-Path -LiteralPath $srcIco) { $s.IconLocation = "$destIco,0" }
    $s.Save()
    Write-Host "  desktop shortcut -> $lnk"

    # report anything that would end up as a second DSH icon on the desktop
    $stale = Get-ChildItem -LiteralPath $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne ($ShortcutName + '.lnk') -and $_.Name -match '(?i)dsh' }
    if ($stale) {
        Write-Host ''
        Write-Host '  NOTE: other DSH-looking shortcuts are on your Desktop. This installer' -ForegroundColor Yellow
        Write-Host '        does not delete them - remove them yourself if you only want one:' -ForegroundColor Yellow
        $stale | ForEach-Object { Write-Host "          $($_.FullName)" -ForegroundColor Yellow }
    }
} else {
    Write-Host '  shortcut creation skipped (-NoShortcut)'
}

# ------------------------------------------------------------ 3) self test
if (-not $NoSelfTest) {
    Write-Host ''
    & $destPs1 -SelfTest
}

Write-Host ''
Write-Host 'Done. What was written:' -ForegroundColor Green
Write-Host "  $destDir"
if (-not $NoShortcut) { Write-Host "  $lnk" }
Write-Host ''
Write-Host 'NOT touched: DSH itself, ~/.dsh (sessions, profiles, credentials), browser settings.'
Write-Host "Uninstall later with:  powershell -File `"$destPs1`" -Uninstall"
Write-Host ''
