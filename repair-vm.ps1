# repair-vm.ps1 - Verify a downloaded DFIR VM and re-download ONLY the corrupted/missing parts,
# then reassemble + verify. Run it from the folder that has your dfir-lab-vm*.part* files.
#   iwr -useb https://raw.githubusercontent.com/project-dfir/dfir-vm/main/repair-vm.ps1 | iex
#
# 2026-08-25 AUDIT FIX (ISSUE-04): this script used to hardcode `$parts = 0..9` and read a
# checked-in parts.sha256 that predated the release it pointed at. vm-v4 shipped FIFTEEN parts,
# so every part hashed as BAD, the repair loop never converged, and a "successful" run
# concatenated 10 of 15 parts into a corrupt OVA. Nothing about the release is hardcoded now:
# the part list, sizes, download URLs and expected final hash are all read from the GitHub
# release at runtime, so a new release needs no edit here beyond -Tag.
[CmdletBinding()]
param(
  [string]$Repo = "project-dfir/dfir-vm",
  [string]$Tag  = "vm-v5"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = @{ 'User-Agent' = 'dfir-repair' }

# Release assets come back as application/octet-stream, so -UseBasicParsing gives
# us .Content as a byte[]. Decode before parsing or a hash compares against "100"
# (the decimal value of the first byte).
function Get-TextContent($resp) {
  if ($resp.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($resp.Content) }
  return [string]$resp.Content
}


Write-Host "== reading release $Repo @ $Tag ==" -ForegroundColor Cyan
$rel   = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $UA
$parts = @($rel.assets | Where-Object { $_.name -match '\.part\d{3}$' } | Sort-Object name)
if (-not $parts -or $parts.Count -eq 0) { throw "No .partNNN assets found in release $Tag of $Repo." }
$totalGB = [math]::Round((($parts | Measure-Object size -Sum).Sum)/1GB, 2)
Write-Host ("   {0} parts, {1} GB total" -f $parts.Count, $totalGB)

# The assembled filename is derived from the parts, so v4/v5 naming both work.
$ovaName = ($parts[0].name -replace '\.part\d{3}$', '')
Write-Host "   target: $ovaName"

# Expected final hash: from the release's own manifest asset (never hardcoded).
$finalsha = $null
$manifest = $rel.assets | Where-Object { $_.name -eq "$ovaName.sha256" } | Select-Object -First 1
if ($manifest) {
  $finalsha = ((Get-TextContent (Invoke-WebRequest -Uri $manifest.browser_download_url -Headers $UA -UseBasicParsing)) -split '\s+')[0].Trim().ToUpper()
  Write-Host "   expected sha256: $finalsha"
} else {
  Write-Host "   WARNING: no $ovaName.sha256 in the release; final verification will be skipped." -ForegroundColor Yellow
}

# Per-part checksums: prefer a parts.sha256 published IN THE RELEASE (always in step with the
# parts). Fall back to exact-size validation, which still catches a truncated download.
$want = @{}
$pm = $rel.assets | Where-Object { $_.name -eq 'parts.sha256' } | Select-Object -First 1
if ($pm) {
  ((Get-TextContent (Invoke-WebRequest -Uri $pm.browser_download_url -Headers $UA -UseBasicParsing)) -split "`n") | ForEach-Object {
    if ($_ -match '^([0-9A-Fa-f]{64})\s+\*?(\S+)') { $want[$matches[2].Trim()] = $matches[1].ToUpper() }
  }
  Write-Host ("   per-part checksums: {0} entries from the release" -f $want.Count)
} else {
  Write-Host "   no per-part manifest in the release - falling back to exact-size validation." -ForegroundColor Yellow
}

$fixed = 0; $bad = 0
foreach ($a in $parts) {
  $p = $a.name
  $need = $false
  if (Test-Path $p) {
    if ($want.ContainsKey($p)) {
      $h = (Get-FileHash $p -Algorithm SHA256).Hash.ToUpper()
      if ($h -eq $want[$p]) { Write-Host ("OK   {0}" -f $p) -ForegroundColor Green }
      else { Write-Host ("BAD  {0} (checksum mismatch - re-downloading)" -f $p) -ForegroundColor Yellow; $need = $true }
    } else {
      $len = (Get-Item $p).Length
      if ($len -eq $a.size) { Write-Host ("OK   {0} (size matches release)" -f $p) -ForegroundColor Green }
      else { Write-Host ("BAD  {0} ({1} bytes, release says {2})" -f $p, $len, $a.size) -ForegroundColor Yellow; $need = $true }
    }
  } else { Write-Host ("MISS {0}" -f $p) -ForegroundColor Yellow; $need = $true }

  if ($need) {
    $ok = $false
    for ($t = 1; $t -le 4 -and -not $ok; $t++) {
      try {
        # curl.exe with range-resume where available: a dropped connection on a ~1.9 GB part
        # continues instead of restarting from zero.
        $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
        if ($curl) {
          & $curl -L --fail --retry 8 --retry-all-errors --retry-delay 3 -C - -A 'dfir-repair' -o $p $a.browser_download_url
          if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
        } else {
          Invoke-WebRequest $a.browser_download_url -OutFile $p -Headers $UA -UseBasicParsing
        }
        if ($want.ContainsKey($p)) { $ok = ((Get-FileHash $p -Algorithm SHA256).Hash.ToUpper() -eq $want[$p]) }
        else                       { $ok = ((Get-Item $p).Length -eq $a.size) }
        if ($ok) { Write-Host ("  fixed {0}" -f $p) -ForegroundColor Green; $fixed++ }
        else     { Write-Host ("  attempt {0} still bad, retrying" -f $t) -ForegroundColor Yellow }
      } catch { Write-Host ("  download error (attempt {0}): {1}" -f $t, $_.Exception.Message) -ForegroundColor Red }
    }
    if (-not $ok) { Write-Host ("  GAVE UP on {0}" -f $p) -ForegroundColor Red; $bad++ }
  }
}
if ($bad -gt 0) { throw "$bad part(s) could not be repaired. Re-run repair-vm.ps1 (it resumes)." }

Write-Host "== reassembling $ovaName (streamed, no OOM) ==" -ForegroundColor Cyan
if (Test-Path $ovaName) { Remove-Item $ovaName -Force }
$fs = [System.IO.File]::Create((Join-Path (Get-Location) $ovaName))
try {
  foreach ($a in $parts) {
    $in = [System.IO.File]::OpenRead((Join-Path (Get-Location) $a.name))
    try { $in.CopyTo($fs, 16MB) } finally { $in.Close() }
  }
} finally { $fs.Close() }

Write-Host "== verifying ==" -ForegroundColor Cyan
$fh = (Get-FileHash $ovaName -Algorithm SHA256).Hash.ToUpper()
if (-not $finalsha) {
  Write-Host ("Assembled {0} ({1} GB). No manifest to verify against." -f $ovaName, [math]::Round((Get-Item $ovaName).Length/1GB,2)) -ForegroundColor Yellow
} elseif ($fh -eq $finalsha) {
  Write-Host "SUCCESS - $ovaName verified. Import it into VMware Workstation Pro (File > Open)." -ForegroundColor Green
} else {
  Write-Host ("FINAL MISMATCH: got {0}, expected {1}. Re-run repair-vm.ps1." -f $fh, $finalsha) -ForegroundColor Red
  exit 1
}
