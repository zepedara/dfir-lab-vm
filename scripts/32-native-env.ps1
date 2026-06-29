# =============================================================================
# 32 - Native environment for the DFIR lab (replaces WSL2/Docker).
#   Installs Git for Windows (-> C:\DFIR\Git) which provides Git Bash + the Unix
#   text utilities (bash/grep/awk/sed/sort/uniq/cut/tr/wc/head/less/comm/tee/perl)
#   the lab pipelines need, AND whose MSYS root (C:\DFIR\Git) hosts /data, /opt,
#   /sigma, /chainsaw used by the (former container) lab commands.
#   Also installs Python 3 (+pip) for the Python DFIR tools.
# PowerShell 5.1-safe. Everything baked so the finished VM runs OFFLINE.
# =============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Hdr($m){ Write-Host "==== $m ====" -ForegroundColor Cyan }

$GitDir = 'C:\DFIR\Git'
$PyDir  = 'C:\DFIR\Python'
New-Item -ItemType Directory -Force 'C:\DFIR','C:\DFIR\dl' | Out-Null

# --------------------------- Git for Windows --------------------------------
Hdr 'Installing Git for Windows (bash + coreutils + perl) to C:\DFIR\Git'
if (-not (Test-Path "$GitDir\usr\bin\bash.exe")) {
    $asset = $null
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{'User-Agent'='dfir'}
        $asset = ($rel.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } | Select-Object -First 1).browser_download_url
    } catch { Write-Warning "git api: $($_.Exception.Message)" }
    if (-not $asset) { $asset = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' }
    $exe = 'C:\DFIR\dl\GitSetup.exe'
    & curl.exe -L --fail --retry 4 -o $exe $asset
    if (-not (Test-Path $exe)) { throw 'Git installer download failed' }
    # Inno Setup silent install to a custom dir. NoAutoCrlf keeps lab data byte-faithful.
    $p = Start-Process $exe -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- /DIR=`"$GitDir`" /NOICONS /COMPONENTS=`"gitlfs,assoc_sh`"" -Wait -PassThru
    "git_installer_exit=$($p.ExitCode)"
}
if (-not (Test-Path "$GitDir\usr\bin\bash.exe")) { throw "Git Bash not found at $GitDir after install" }
Write-Host "[git] bash at $GitDir\usr\bin\bash.exe"

# ------------------------------- Python 3 -----------------------------------
Hdr 'Installing Python 3 (+pip) to C:\DFIR\Python'
if (-not (Test-Path "$PyDir\python.exe")) {
    $pyUrl = 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe'
    $exe = 'C:\DFIR\dl\python.exe'
    & curl.exe -L --fail --retry 4 -o $exe $pyUrl
    if (-not (Test-Path $exe)) { throw 'Python installer download failed' }
    # Per-machine, all users, no PATH munge (we set PATH ourselves), include pip.
    $p = Start-Process $exe -ArgumentList "/quiet InstallAllUsers=1 TargetDir=`"$PyDir`" Include_pip=1 Include_test=0 Include_doc=0 PrependPath=0 AssociateFiles=0 Shortcuts=0" -Wait -PassThru
    "python_installer_exit=$($p.ExitCode)"
}
if (-not (Test-Path "$PyDir\python.exe")) { throw "python.exe not found at $PyDir after install" }
& "$PyDir\python.exe" -m pip install --upgrade pip 2>&1 | Select-Object -Last 1

# ------------------------- Machine PATH additions ---------------------------
Hdr 'Adding Git + Python to machine PATH'
$add = @("$GitDir\cmd", "$GitDir\usr\bin", "$GitDir\mingw64\bin", $PyDir, "$PyDir\Scripts")
$cur = [Environment]::GetEnvironmentVariable('PATH','Machine')
foreach ($p in $add) { if ($cur -notlike "*$p*") { $cur = "$cur;$p" } }
[Environment]::SetEnvironmentVariable('PATH', $cur, 'Machine')
$env:PATH = "$cur;$env:PATH"
Write-Host '[env] Git Bash, coreutils, perl, Python now on PATH.'
exit 0
