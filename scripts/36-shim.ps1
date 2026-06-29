# =============================================================================
# 36 - docker shim + hardcoded container paths + Git Bash profile + START-HERE.
# =============================================================================
$ErrorActionPreference = 'Continue'
function Hdr($m){ Write-Host "==== $m ====" -ForegroundColor Cyan }
$GitDir='C:\DFIR\Git'; $Opt="$GitDir\opt"; $Bin="$GitDir\usr\bin"
$U8 = New-Object Text.UTF8Encoding($false)

# ---- chainsaw hardcoded container paths (sigma rules + mapping) ----
Hdr 'Wiring chainsaw hardcoded container paths'
$csRoot='C:\dfir\tools\chainsaw'
$sigmaSrc = (Get-ChildItem $csRoot -Recurse -Directory -Filter 'sigma' -ErrorAction SilentlyContinue | Select-Object -First 1)
$mapSrc   = (Get-ChildItem $csRoot -Recurse -Filter 'sigma-event-logs-all.yml' -ErrorAction SilentlyContinue | Select-Object -First 1)
New-Item -ItemType Directory -Force "$Opt\chainsaw","$Opt\chainsaw\repo\mappings","$GitDir\chainsaw\mappings" | Out-Null
if ($sigmaSrc) {
    cmd /c "rmdir `"$Opt\chainsaw\sigma`" 2>nul"
    cmd /c "mklink /J `"$Opt\chainsaw\sigma`" `"$($sigmaSrc.FullName)`"" | Out-Null
    cmd /c "rmdir `"$GitDir\sigma`" 2>nul"
    cmd /c "mklink /J `"$GitDir\sigma`" `"$($sigmaSrc.FullName)`"" | Out-Null
    Write-Host "[shim] sigma -> $($sigmaSrc.FullName)"
} else { Write-Warning '[shim] chainsaw sigma dir not found' }
if ($mapSrc) {
    Copy-Item $mapSrc.FullName "$Opt\chainsaw\repo\mappings\sigma-event-logs-all.yml" -Force
    Copy-Item $mapSrc.FullName "$GitDir\chainsaw\mappings\sigma-event-logs-all.yml" -Force
    Write-Host '[shim] chainsaw mapping baked'
} else { Write-Warning '[shim] chainsaw mapping yml not found' }

# ---- Git Bash profile: tool dirs on MSYS PATH ----
Hdr 'Installing Git Bash profile (dfir.sh)'
New-Item -ItemType Directory -Force "$GitDir\etc\profile.d" | Out-Null
$prof = @'
# DFIR lab environment (native)
export PATH="/usr/bin:$PATH:/c/DFIR/Python:/c/DFIR/Python/Scripts"
for d in /c/dfir/tools/EZ /c/dfir/tools/EZ/* /c/dfir/tools/chainsaw /c/dfir/tools/hayabusa /c/dfir/tools/sysinternals /c/DFIR/tools/sleuthkit /c/DFIR/tools/yara; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d";; esac
done
export PATH
alias ll='ls -la'
'@
[IO.File]::WriteAllText("$GitDir\etc\profile.d\dfir.sh", ($prof -replace "`r",''), $U8)

# ---- docker shim (embedded) ----
Hdr 'Installing docker shim'
$shim = @'
#!/usr/bin/env bash
# dfir-aio:v2 native shim: emulate `docker run -it --rm [--network none] -v "$PWD":/data dfir-aio:v2`
set -u
GITROOT="C:/DFIR/Git"
sub="${1:-}"
case "$sub" in
  run) shift ;;
  ""|--version|version) echo "dfir-aio native shim (no real Docker)"; exit 0 ;;
  images|ps|pull|info) echo "[dfir-shim] '$sub' is a no-op in the native lab."; exit 0 ;;
  *) echo "[dfir-shim] only 'docker run ... dfir-aio:v2' is emulated." >&2; exit 0 ;;
esac
mount_src=""; cmd=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v|--volume) v="$2"; mount_src="${v%%:/data*}"; mount_src="${mount_src%:}"; shift 2 ;;
    -v*) v="${1#-v}"; mount_src="${v%%:/data*}"; mount_src="${mount_src%:}"; shift ;;
    --volume=*) v="${1#--volume=}"; mount_src="${v%%:/data*}"; mount_src="${mount_src%:}"; shift ;;
    -it|-i|-t|--rm|-d|--detach|--interactive|--tty|--privileged) shift ;;
    --network|--name|-e|-w|--user|-u|--hostname|-h) shift 2 ;;
    --network=*|--name=*|-e*) shift ;;
    dfir-aio:v2|dfir-aio|dfir-aio:latest) shift; cmd=("$@"); break ;;
    ghcr.io/zepedara/dfir-aio*) shift; cmd=("$@"); break ;;
    *) shift ;;
  esac
done
[ -z "$mount_src" ] && mount_src="$PWD"
win_src="$(cygpath -w "$mount_src" 2>/dev/null)"
[ -z "$win_src" ] && win_src="$(cd "$mount_src" 2>/dev/null && pwd -W 2>/dev/null)"
cmd //c "if exist \"C:\\DFIR\\Git\\data\" rmdir \"C:\\DFIR\\Git\\data\"" >/dev/null 2>&1
cmd //c mklink /J "C:\\DFIR\\Git\\data" "$win_src" >/dev/null 2>&1
export DFIR_DATA_WIN="$win_src"
cd "$GITROOT/data" 2>/dev/null || cd "$mount_src"
if [ "${#cmd[@]}" -gt 0 ]; then
  exec "${cmd[@]}"
else
  echo ""
  echo "  dfir-aio (native) - DFIR toolbox, no container needed."
  echo "  Evidence is at /data (this folder). Type 'exit' to leave."
  echo "  Tools: EvtxECmd AppCompatCacheParser AmcacheParser MFTECmd PECmd prefetch"
  echo "    chainsaw hayabusa vol capa floss yara pdfid pdf-parser oledump zipdump"
  echo "    oleid olevba rtfobj regripper fls mmls icat istat mactime + awk/sed/grep..."
  echo ""
  exec bash -i
fi
'@
[IO.File]::WriteAllText("$Bin\docker", ($shim -replace "`r",''), $U8)
Write-Host "[shim] docker shim installed at $Bin\docker"

# ---- Desktop START-HERE + Git Bash shortcut ----
Hdr 'Desktop START-HERE + shortcut'
$desk = 'C:\Users\Public\Desktop'
New-Item -ItemType Directory -Force $desk | Out-Null
$startHere = @'
DFIR TRAINING LAB - NATIVE WINDOWS EDITION
==========================================
This VM runs the entire lab with tools installed NATIVELY on Windows.
NO Docker / NO WSL2 / NO container (your host blocks the nested virtualization
those need - this native build runs anywhere).

HOW TO RUN THE LAB
------------------
1. Double-click "DFIR Lab Shell" on the Desktop (opens Git Bash).
2. cd into a module data folder, e.g.:
      cd /c/dfir/lab/module-01-prefetch-pecmd/data
3. Follow the module README commands exactly as written.

THE "docker run ... dfir-aio:v2" LINES STILL WORK
-------------------------------------------------
A docker shim intercepts:
      docker run -it --rm --network none -v "$PWD":/data dfir-aio:v2
and drops you into the same native toolbox with /data = your current folder.
All container tools are on PATH by the same names: EvtxECmd, AppCompatCacheParser,
AmcacheParser, MFTECmd, PECmd, prefetch, chainsaw, hayabusa, vol (Volatility3),
capa, floss, yara, pdfid, pdf-parser, oledump, zipdump, oleid, olevba, rtfobj,
regripper, fls, mmls, icat, istat, mactime - plus grep/awk/sed/sort/cut/uniq.

Lab text: C:\dfir\lab (modules 01-11 + COURSE/GLOSSARY/ANSWER-KEY + research).
Tools: C:\dfir\tools and C:\DFIR.   Login: Analyst / dfir.
'@
[IO.File]::WriteAllText("$desk\START-HERE.txt", (($startHere -replace "`r",'') -replace "`n","`r`n"), $U8)

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$desk\DFIR Lab Shell.lnk")
$sc.TargetPath = "$GitDir\git-bash.exe"
$sc.Arguments = '--cd=C:\dfir\lab'
$sc.WorkingDirectory = 'C:\dfir\lab'
$sc.IconLocation = "$GitDir\git-bash.exe,0"
$sc.Save()
Write-Host '[shim] START-HERE + shortcut created.'
exit 0
