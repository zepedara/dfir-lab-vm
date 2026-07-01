# repair-vm.ps1 - Verify a downloaded DFIR VM and re-download ONLY the corrupted/missing parts,
# then reassemble + verify. Run it from the folder that has your dfir-lab-vm.ova.part* files.
#   iwr -useb https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/repair-vm.ps1 | iex
$ErrorActionPreference = "Stop"
$base     = "https://github.com/zepedara/dfir-lab-vm/releases/download/vm-v1"
$rawsha   = "https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/parts.sha256"
$finalsha = "7E6F834D16373A2BA37798DAE67BEDAB6D5850822E264D21E53CEE17FF84EEFD"
$parts    = 0..9 | ForEach-Object { "dfir-lab-vm.ova.part{0:D3}" -f $_ }

Write-Host "== fetching per-part checksums ==" -ForegroundColor Cyan
$want = @{}
((Invoke-WebRequest -UseBasicParsing $rawsha).Content -split "`n") | ForEach-Object {
  if ($_ -match '^([0-9A-Fa-f]{64})\s+(\S+)') { $want[$matches[2].Trim()] = $matches[1].ToUpper() }
}

$fixed = 0
foreach ($p in $parts) {
  $need = $false
  if (Test-Path $p) {
    $h = (Get-FileHash $p -Algorithm SHA256).Hash.ToUpper()
    if ($want[$p] -and $h -eq $want[$p]) { Write-Host ("OK   {0}" -f $p) -ForegroundColor Green }
    else { Write-Host ("BAD  {0} (will re-download)" -f $p) -ForegroundColor Yellow; $need = $true }
  } else { Write-Host ("MISS {0} (will download)" -f $p) -ForegroundColor Yellow; $need = $true }

  if ($need) {
    for ($t = 1; $t -le 4; $t++) {
      try {
        Invoke-WebRequest "$base/$p" -OutFile $p -UseBasicParsing
        $h = (Get-FileHash $p -Algorithm SHA256).Hash.ToUpper()
        if ($h -eq $want[$p]) { Write-Host ("  fixed {0}" -f $p) -ForegroundColor Green; $fixed++; break }
        else { Write-Host ("  attempt {0} still bad, retrying" -f $t) -ForegroundColor Yellow }
      } catch { Write-Host ("  download error (attempt {0}): {1}" -f $t, $_.Exception.Message) -ForegroundColor Red }
      if ($t -eq 4) { Write-Host ("  GAVE UP on {0} - re-run the script" -f $p) -ForegroundColor Red }
    }
  }
}

Write-Host "== reassembling dfir-lab-vm.ova (streaming, no OOM) ==" -ForegroundColor Cyan
$out = "dfir-lab-vm.ova"
if (Test-Path $out) { Remove-Item $out -Force }
$fs = [System.IO.File]::Create((Join-Path (Get-Location) $out))
try {
  foreach ($p in $parts) {
    $in = [System.IO.File]::OpenRead((Join-Path (Get-Location) $p))
    $in.CopyTo($fs); $in.Close()
  }
} finally { $fs.Close() }

Write-Host "== verifying final OVA ==" -ForegroundColor Cyan
$fh = (Get-FileHash $out -Algorithm SHA256).Hash.ToUpper()
if ($fh -eq $finalsha) {
  Write-Host "SUCCESS - dfir-lab-vm.ova verified. Import it into VMware Workstation Pro (File > Open)." -ForegroundColor Green
} else {
  Write-Host ("FINAL MISMATCH: got {0}, expected {1}. Re-run repair-vm.ps1 (a part is still bad)." -f $fh, $finalsha) -ForegroundColor Red
}
