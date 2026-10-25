# Gradal: starts the PC app and opens its window. The first run prepares everything it needs.
# Works in Windows PowerShell 5.1 and PowerShell 7. Double-click Gradal.cmd instead of running this by hand.
param([switch]$NoWindow, [switch]$Shortcut)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = $PSScriptRoot
$port = 7797
$url = "http://127.0.0.1:$port/"
$venv = Join-Path $env:LOCALAPPDATA 'Gradal\venv'
$py = Join-Path $venv 'Scripts\python.exe'
$pyw = Join-Path $venv 'Scripts\pythonw.exe'

function Test-Gradal {
  try { (Invoke-WebRequest "$($url)hello" -UseBasicParsing -TimeoutSec 2).Content -match 'gradal-public' } catch { $false }
}

function Find-Python {
  foreach ($cmd in @('py -3.13', 'py -3.12', 'python')) {
    $parts = $cmd.Split(' ')
    try {
      $v = & $parts[0] $parts[1..9] -c 'import sys; print(sys.version_info >= (3, 12))' 2>$null
      if ($v -eq 'True') { return $parts }
    } catch { }
  }
  return $null
}

if (-not (Test-Path $py)) {
  Write-Host 'Gradal: first run, preparing (a few minutes, once)...'
  $base = Find-Python
  if (-not $base) {
    Write-Host 'Python 3.12 or newer is needed. Installing it with winget...'
    winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements --silent
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $base = Find-Python
    if (-not $base) { throw 'Python could not be installed. Install Python 3.12 from python.org, then run Gradal again.' }
  }
  & $base[0] $base[1..9] -m venv $venv
  & $py -m pip install --quiet --upgrade pip
  & $py -m pip install --quiet -r (Join-Path $root 'requirements.txt')
}

if (-not (Test-Gradal)) {
  # started through WMI, so the server keeps running when this window (or any parent program) closes
  $server = Join-Path $root 'pc\server.py'
  $cmdLine = "`"$pyw`" `"$server`" --port $port"
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine; CurrentDirectory = $root }
  if ($r.ReturnValue -ne 0) { throw "Gradal could not start (code $($r.ReturnValue))." }
  for ($i = 0; $i -lt 40 -and -not (Test-Gradal); $i++) { Start-Sleep -Milliseconds 500 }
  if (-not (Test-Gradal)) { throw 'Gradal did not answer. See Documents\Gradal\gradal.log.' }
}

if ($Shortcut) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  $lnk = $ws.CreateShortcut((Join-Path $desktop 'Gradal.lnk'))
  $lnk.TargetPath = Join-Path $root 'Gradal.cmd'
  $lnk.WorkingDirectory = $root
  $lnk.IconLocation = (Join-Path $root 'pc\assets\gradal.ico')
  $lnk.WindowStyle = 7
  $lnk.Save()
}

if (-not $NoWindow) {
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($edge) { Start-Process $edge -ArgumentList "--app=$url" } else { Start-Process $url }
}
