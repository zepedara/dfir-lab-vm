# =============================================================================
# 55 - Make training content EASILY ADDABLE after build, WITHOUT rebuilding:
#       * dfir-update  : ONLINE refresh (git pull lab + get-data.sh + docker pull
#                        :latest + refresh native tools)
#       * dfir-import  : OFFLINE content-pack ingest (drop a folder/zip, no internet)
#       * dfir-reindex : regenerate the Desktop modules index from C:\dfir\lab
#       Lab content stays MODULAR: one self-contained folder per module-XX.
# Installs the three tools to C:\dfir\bin, wires profile commands + shortcuts.
# =============================================================================
$ErrorActionPreference = 'Stop'
$Bin = 'C:\dfir\bin'
New-Item -ItemType Directory -Force -Path $Bin, 'C:\dfir\incoming' | Out-Null

# --------------------------------------------------------------------------- #
# dfir-reindex.ps1 - regenerate the modules index (auto-lists modules present)
# --------------------------------------------------------------------------- #
@'
# Regenerate the Desktop modules index from whatever modules exist in C:\dfir\lab.
$lab = 'C:\dfir\lab'
$out = Join-Path (Join-Path $env:PUBLIC 'Desktop') 'DFIR-LAB-MODULES.html'
$mods = Get-ChildItem $lab -Directory -Filter 'module-*' -EA SilentlyContinue | Sort-Object Name
$rows = foreach ($m in $mods) {
    $title = $m.Name
    $rd = Join-Path $m.FullName 'README.md'
    if (Test-Path $rd) { $h1 = (Get-Content $rd | Where-Object { $_ -match '^#\s' } | Select-Object -First 1); if ($h1) { $title = ($h1 -replace '^#\s*','') } }
    $dataCount = (Get-ChildItem (Join-Path $m.FullName 'data') -Recurse -File -EA SilentlyContinue).Count
    "<tr><td><b>$($m.Name)</b></td><td>$([System.Web.HttpUtility]::HtmlEncode($title))</td><td>$dataCount data file(s)</td></tr>"
}
Add-Type -AssemblyName System.Web -EA SilentlyContinue
$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>DFIR Lab modules</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:820px;margin:30px auto;padding:0 20px}
h1{color:#6a1b9a}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:6px 8px;text-align:left}</style></head><body>
<h1>DFIR Lab - modules present</h1>
<p>Auto-generated $(Get-Date -Format 'u'). $($mods.Count) module(s) in C:\dfir\lab.
Re-run <code>dfir-reindex</code> after adding content.</p>
<table><tr><th>Folder</th><th>Title</th><th>Data</th></tr>
$($rows -join "`n")
</table></body></html>
"@
Set-Content -Path $out -Value $html -Encoding UTF8
Write-Host "Modules index written: $out ($($mods.Count) modules)"
'@ | Set-Content -Path (Join-Path $Bin 'dfir-reindex.ps1') -Encoding UTF8

# --------------------------------------------------------------------------- #
# dfir-update.ps1 - ONLINE refresh of everything from GitHub
# --------------------------------------------------------------------------- #
@'
# dfir-update - pull the latest lab content + tools (needs internet).
# Safe to run repeatedly. New Phase-2 modules land with this one command.
param([switch]$SkipTools)
$ErrorActionPreference = 'Continue'
Write-Host "== dfir-update : refreshing the DFIR lab from GitHub ==" -ForegroundColor Cyan
if (-not (Test-Connection 8.8.8.8 -Count 1 -Quiet -EA SilentlyContinue)) {
    Write-Warning "No internet. For an air-gapped VM use:  dfir-import <content-pack>"; return
}

# 1) Lab repo (new modules + data) -----------------------------------------
$lab = 'C:\dfir\lab'
if (Test-Path (Join-Path $lab '.git')) {
    Write-Host "[lab] git pull..."; git -C $lab pull --ff-only
} else {
    git clone --depth 1 https://github.com/zepedara/dfir-training-lab.git $lab
}
# Run any new/updated per-module data fetchers + LFS, inside WSL.
Write-Host "[lab] baking any new module data (get-data.sh / LFS)..."
wsl -d Ubuntu -u root -- bash -lic "cd /mnt/c/dfir/lab && git lfs pull 2>/dev/null; for s in \$(find . -iname get-data.sh | sort); do echo \"  run \$s\"; ( cd \$(dirname \$s) && bash ./get-data.sh ); done" 2>$null
# Mirror to WSL home for container mounts.
wsl -d Ubuntu -u analyst -- bash -lic "rm -rf ~/lab && cp -r /mnt/c/dfir/lab ~/lab" 2>$null

# 2) Container - pull latest toolset, retag :v2 + dfir-aio ------------------
Write-Host "[dfir-aio] docker pull ghcr.io/zepedara/dfir-aio:latest ..."
wsl -d Ubuntu -u root -- bash -lic "service docker start >/dev/null 2>&1; if docker pull ghcr.io/zepedara/dfir-aio:latest; then docker tag ghcr.io/zepedara/dfir-aio:latest dfir-aio:v2; docker tag ghcr.io/zepedara/dfir-aio:latest dfir-aio; echo '[dfir-aio] updated'; else echo '[dfir-aio] pull failed (using existing resident image)'; fi"

# 3) Windows-native tools refresh ------------------------------------------
if (-not $SkipTools) {
    Write-Host "[tools] refreshing EZ tools + Chainsaw/Hayabusa rules..."
    try {
        $gzt = "$env:TEMP\Get-ZimmermanTools.ps1"
        Invoke-WebRequest 'https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1' -OutFile $gzt -UseBasicParsing
        & powershell -NoProfile -ExecutionPolicy Bypass -File $gzt -Dest 'C:\dfir\tools\EZ' -NetVersion 9
        foreach ($t in 'EvtxECmd','RECmd','SQLECmd') { $e=Get-ChildItem 'C:\dfir\tools\EZ' -Recurse -Filter "$t.exe" -EA SilentlyContinue|Select -First 1; if($e){ & $e.FullName --sync 2>$null } }
    } catch { Write-Warning "[tools] EZ refresh: $($_.Exception.Message)" }
    $hb = Get-ChildItem 'C:\dfir\tools\hayabusa' -Recurse -Filter 'hayabusa.exe' -EA SilentlyContinue | Select -First 1
    if ($hb) { try { Push-Location $hb.Directory; & $hb.FullName update-rules 2>$null; Pop-Location } catch {} }
}

& C:\dfir\bin\dfir-reindex.ps1
Write-Host "== dfir-update complete ==" -ForegroundColor Green
'@ | Set-Content -Path (Join-Path $Bin 'dfir-update.ps1') -Encoding UTF8

# --------------------------------------------------------------------------- #
# dfir-import.ps1 - OFFLINE content-pack ingest (no internet)
# --------------------------------------------------------------------------- #
@'
# dfir-import <pack> - add training content to an AIR-GAPPED VM. No internet.
#
# Content-pack format (a folder OR a .zip), copied into the VM first:
#   <pack>/
#     modules/module-XX-name/...        -> copied into C:\dfir\lab\  (drop-in)
#     images/*.tar | *.tar.gz           -> docker load (e.g. updated dfir-aio)
#     images/dfir-aio.part.*            -> reassembled then docker load
#     (module data should be bundled in each module's data\ folder; any
#      get-data.sh present is run only if it works offline)
#     pack.json (optional: {"name","version","notes"})
#
# Usage:
#   dfir-import C:\dfir\incoming\phase2-pack        # a folder
#   dfir-import C:\dfir\incoming\phase2-pack.zip     # a zip
#   dfir-import                                       # scans C:\dfir\incoming\*
param([string]$Pack)
$ErrorActionPreference = 'Continue'
Write-Host "== dfir-import : add content (offline) ==" -ForegroundColor Cyan

function Import-One($root) {
    Write-Host "[import] ingesting $root"
    if (Test-Path (Join-Path $root 'pack.json')) { try { (Get-Content (Join-Path $root 'pack.json') -Raw | ConvertFrom-Json) | Format-List | Out-String | Write-Host } catch {} }
    # 1) Modules -> C:\dfir\lab (modular drop-in).
    $modSrc = Join-Path $root 'modules'
    if (Test-Path $modSrc) {
        foreach ($m in Get-ChildItem $modSrc -Directory) {
            $dest = Join-Path 'C:\dfir\lab' $m.Name
            Write-Host "[import]   module $($m.Name) -> $dest"
            Copy-Item $m.FullName $dest -Recurse -Force
        }
    } else {
        # Allow a pack that is itself one or more module-XX folders.
        foreach ($m in Get-ChildItem $root -Directory -Filter 'module-*') {
            Copy-Item $m.FullName (Join-Path 'C:\dfir\lab' $m.Name) -Recurse -Force
            Write-Host "[import]   module $($m.Name) added"
        }
    }
    # 2) Container images -> docker load (offline).
    $imgDir = Join-Path $root 'images'
    if (Test-Path $imgDir) {
        $wsl = (wsl -d Ubuntu -- wslpath "$imgDir").Trim()
        wsl -d Ubuntu -u root -- bash -lic "service docker start >/dev/null 2>&1
cd '$wsl' || exit 0
shopt -s nullglob
# reassemble split parts if present
if ls dfir-aio.part.* >/dev/null 2>&1; then cat dfir-aio.part.* > _img.tar.gz && docker load < _img.tar.gz && rm -f _img.tar.gz; fi
for f in *.tar *.tar.gz; do echo \"[import]   docker load \$f\"; docker load < \"\$f\"; done
# keep the friendly tags fresh if a new dfir-aio came in
LATEST=\$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i dfir-aio | head -1)
[ -n \"\$LATEST\" ] && docker tag \$LATEST dfir-aio:v2 && docker tag \$LATEST dfir-aio
docker images | grep -i dfir-aio || true"
    }
    # 3) Mirror lab into WSL home for container mounts.
    wsl -d Ubuntu -u analyst -- bash -lic "rm -rf ~/lab && cp -r /mnt/c/dfir/lab ~/lab" 2>$null
}

# Resolve the pack: explicit folder, explicit zip, or scan C:\dfir\incoming.
$targets = @()
if ($Pack) {
    if ($Pack -like '*.zip') {
        $ex = Join-Path $env:TEMP ("pack_" + [IO.Path]::GetFileNameWithoutExtension($Pack))
        Remove-Item $ex -Recurse -Force -EA SilentlyContinue
        Expand-Archive $Pack -DestinationPath $ex -Force
        # if the zip wraps a single folder, descend into it
        $inner = Get-ChildItem $ex -Directory
        $targets += $(if ($inner.Count -eq 1 -and -not (Get-ChildItem $ex -File)) { $inner[0].FullName } else { $ex })
    } else { $targets += (Resolve-Path $Pack).Path }
} else {
    Get-ChildItem 'C:\dfir\incoming' -Directory -EA SilentlyContinue | ForEach-Object { $targets += $_.FullName }
    Get-ChildItem 'C:\dfir\incoming' -Filter '*.zip' -EA SilentlyContinue | ForEach-Object {
        $ex = Join-Path $env:TEMP ("pack_" + $_.BaseName); Remove-Item $ex -Recurse -Force -EA SilentlyContinue
        Expand-Archive $_.FullName -DestinationPath $ex -Force; $targets += $ex
    }
}
if (-not $targets) { Write-Warning "No content packs found. Put a pack folder/zip in C:\dfir\incoming, or pass a path: dfir-import <pack>"; return }
foreach ($t in $targets) { Import-One $t }

& C:\dfir\bin\dfir-reindex.ps1
Write-Host "== dfir-import complete (offline) ==" -ForegroundColor Green
'@ | Set-Content -Path (Join-Path $Bin 'dfir-import.ps1') -Encoding UTF8

Write-Host "[content] Installed dfir-update / dfir-import / dfir-reindex to $Bin"

# --------------------------- Profile commands -------------------------------
$profilePath = $PROFILE.AllUsersAllHosts
New-Item -ItemType Directory -Force -Path (Split-Path $profilePath) | Out-Null
$append = @'

# ---- DFIR content management (auto-generated) ----
function dfir-update  { & 'C:\dfir\bin\dfir-update.ps1'  @args }   # ONLINE refresh from GitHub
function dfir-import  { & 'C:\dfir\bin\dfir-import.ps1'  @args }   # OFFLINE content-pack ingest
function dfir-reindex { & 'C:\dfir\bin\dfir-reindex.ps1' @args }   # rebuild the modules index
# ---- end DFIR content management ----
'@
Add-Content -Path $profilePath -Value $append -Encoding UTF8

# ------------------------------ Shortcuts -----------------------------------
$desktop = Join-Path $env:PUBLIC 'Desktop'
function New-Shortcut2($lnk, $target, $arguments, $workdir) {
    $ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $target; if ($arguments) { $s.Arguments = $arguments }; if ($workdir) { $s.WorkingDirectory = $workdir }; $s.Save()
}
$ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
try {
    New-Shortcut2 (Join-Path $desktop 'DFIR update (online).lnk') $ps "-NoExit -ExecutionPolicy Bypass -File `"$Bin\dfir-update.ps1`"" 'C:\dfir'
    New-Shortcut2 (Join-Path $desktop 'DFIR import content (offline).lnk') $ps "-NoExit -ExecutionPolicy Bypass -File `"$Bin\dfir-import.ps1`"" 'C:\dfir'
    New-Shortcut2 (Join-Path $desktop 'Drop content here (incoming).lnk') 'C:\dfir\incoming' $null 'C:\dfir\incoming'
} catch { Write-Warning "[content] shortcut issue: $($_.Exception.Message)" }

# Generate the initial modules index now.
& (Join-Path $Bin 'dfir-reindex.ps1')
Write-Host "[content] Update paths ready: dfir-update (online), dfir-import (offline)."
exit 0
