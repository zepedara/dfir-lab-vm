<#
  pull-vm.ps1  --  One-liner puller for the prebuilt DFIR training-lab VM.

  Run on the WORK box (PowerShell), then open the resulting .ova in VMware Workstation Pro:

      iwr -useb https://raw.githubusercontent.com/project-dfir/dfir-vm/main/pull-vm.ps1 | iex

  It downloads every split part of the VM from the GitHub Release, reassembles them into a
  single .ova, and verifies the SHA-256. Resumable: re-run it and it skips parts
  you already have. No GitHub account/token needed (public release).
#>
[CmdletBinding()]
param(
  [string]$Repo = "project-dfir/dfir-vm",
  [string]$Tag  = "vm-v5",
  [string]$Dest = "$env:USERPROFILE\Downloads\dfir-lab-vm",
  [string]$StatusTopic = "dfir-rafa-vmpull"   # public ntfy.sh topic for a best-effort status ping
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = @{ 'User-Agent' = 'dfir-pull' }

New-Item -ItemType Directory -Force $Dest | Out-Null
$logPath = Join-Path $Dest 'pull-vm.log'
function Log($m){
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue
}
function Ping($m){  # best-effort status to a public ntfy.sh topic (no token); never fatal
  try { Invoke-RestMethod -Uri "https://ntfy.sh/$StatusTopic" -Method Post -Body $m -Headers @{ Title='dfir-vm-pull' } -TimeoutSec 15 | Out-Null } catch {}
}

try {
  Log "DFIR lab VM puller -> $Dest"
  Log "Fetching release $Repo @ $Tag ..."
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $UA
  $parts    = @($rel.assets | Where-Object { $_.name -match '\.part\d{3}$' } | Sort-Object name)
  if (-not $parts -or $parts.Count -eq 0) { throw "No VM parts found in release $Tag of $Repo." }
  # Derive the assembled filename from the parts so the script is release-agnostic.
  $ovaName  = ($parts[0].name -replace '\.part\d{3}$', '')
  $manifest =   $rel.assets | Where-Object { $_.name -eq "$ovaName.sha256" } | Select-Object -First 1
  if (-not $parts -or $parts.Count -eq 0) { throw "No VM parts found in release $Tag of $Repo." }
  $totalGB = [math]::Round((($parts | Measure-Object size -Sum).Sum)/1GB, 2)
  Log ("Found {0} parts, {1} GB total." -f $parts.Count, $totalGB)
  Ping ("starting: $($parts.Count) parts / $totalGB GB")

  # Download (resumable: skip parts already fully present)
  $i = 0
  foreach ($a in $parts) {
    $i++
    $out = Join-Path $Dest $a.name
    if ((Test-Path $out) -and ((Get-Item $out).Length -eq $a.size)) { Log "[$i/$($parts.Count)] have $($a.name), skipping"; continue }
    Log ("[{0}/{1}] downloading {2} ({3} MB)..." -f $i, $parts.Count, $a.name, [math]::Round($a.size/1MB))
    $tmp = "$out.partial"
    # Robust download: curl.exe with byte-range resume (-C -) + auto-retry, so a
    # dropped connection CONTINUES instead of restarting the ~1.9 GB part. Falls
    # back to Invoke-WebRequest (with its own retry loop) if curl is unavailable.
    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if ($curl) {
      & $curl -L --fail --retry 12 --retry-all-errors --retry-delay 3 -C - -A 'dfir-pull' -o $tmp $a.browser_download_url
      if ($LASTEXITCODE -ne 0) { throw "curl download failed for $($a.name) (exit $LASTEXITCODE)" }
    } else {
      $ok = $false
      for ($r = 1; $r -le 6 -and -not $ok; $r++) {
        try { Invoke-WebRequest -Uri $a.browser_download_url -OutFile $tmp -Headers $UA -UseBasicParsing; $ok = $true }
        catch { Log ("    retry {0}/6 for {1}: {2}" -f $r, $a.name, $_.Exception.Message); Start-Sleep -Seconds ($r*3) }
      }
      if (-not $ok) { throw "download failed for $($a.name) after retries" }
    }
    Move-Item $tmp $out -Force
  }

  # Reassemble (streamed, low memory)
  $ova = Join-Path $Dest $ovaName
  Log "Reassembling -> $ova"
  if (Test-Path $ova) { Remove-Item $ova -Force }
  $outFs = [IO.File]::Open($ova, [IO.FileMode]::Create, [IO.FileAccess]::Write)
  try {
    foreach ($a in $parts) {
      $inFs = [IO.File]::OpenRead((Join-Path $Dest $a.name))
      try { $inFs.CopyTo($outFs, 16MB) } finally { $inFs.Close() }
    }
  } finally { $outFs.Close() }

  # Verify
  if ($manifest) {
    Log "Verifying SHA-256..."
    $expected = ((Invoke-WebRequest -Uri $manifest.browser_download_url -Headers $UA -UseBasicParsing).Content -split '\s+')[0].Trim()
    $actual   = (Get-FileHash $ova -Algorithm SHA256).Hash
    if ($actual -ieq $expected) { Log "SHA-256 OK ($actual)" }
    else { throw "SHA-256 MISMATCH`n expected: $expected`n actual:   $actual`n Re-run to repair the bad part(s)." }
  } else {
    Log "WARNING: no checksum manifest in release; skipping verification."
  }

  $sizeGB = [math]::Round((Get-Item $ova).Length/1GB, 2)
  Log "DONE. $ovaName ready ($sizeGB GB)."
  Log "Next: open VMware Workstation Pro -> File > Open -> select '$ova' -> Import. Then power it on."
  Log "Lab login: Analyst / dfir.  In the lab repo run e.g.:  cd module-04-scaling-appcompatprocessor ; acp acp.db load data/fleet ; acp acp.db stack FileName"
  Ping "DONE: $ovaName reassembled ($sizeGB GB), checksum OK. Import in Workstation Pro."
  Write-Host ""
  Write-Host "==================================================================" -ForegroundColor Green
  Write-Host " VM ready: $ova" -ForegroundColor Green
  Write-Host " Open it in VMware Workstation Pro (File > Open) and import." -ForegroundColor Green
  Write-Host "==================================================================" -ForegroundColor Green
}
catch {
  Log "ERROR: $($_.Exception.Message)"
  Ping "ERROR: $($_.Exception.Message)"
  Write-Host "`nPull failed -- see $logPath . Re-running resumes where it left off." -ForegroundColor Red
  throw
}
