# DFIR VM verifier: checks tools, then sends the setup log + a report back to Rem.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tools = 'prefetch','vol','chainsaw','hayabusa','yara','fls','mmls','regripper','rip','capa','floss','olevba','python','git','bash','PECmd.exe','EvtxECmd.exe','MFTECmd.exe'
$rep = "DFIR VM VERIFY  " + (Get-Date -Format o) + "`r`n"
foreach ($t in $tools) {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if ($c) { $rep += "[OK]      $t  ->  $($c.Source)`r`n" } else { $rep += "[MISSING] $t`r`n" }
}
foreach ($p in 'C:\DFIR\dfir-training-lab','C:\dfir\dfir-training-lab','C:\Users\Analyst\dfir-training-lab') { if (Test-Path $p) { $rep += "[lab] found at $p`r`n" } }
$rep | Out-File "$env:USERPROFILE\dfir-verify.txt" -Encoding ascii
$log = "$env:USERPROFILE\dfir-setup.log"
$pub = 'https://ntfy.sh/rem-rafa-cd932571caca'
$T   = 'https://ricksanchez.tail33ae98.ts.net/rem-rafa-cd932571caca'
$K   = 'tk_oa9v85p645zgm7n50l0ytdpekuyyv'
# report (text) to public + rick
try { Invoke-RestMethod -Uri $pub -Method Post -Body $rep -Headers @{ Title='DFIR verify'; Tags='dfir_verify' } } catch {}
try { Invoke-RestMethod -Uri $T   -Method Post -Body $rep -Headers @{ Authorization="Bearer $K"; Title='DFIR verify'; Tags='dfir_verify' } } catch {}
# the setup log as attachment to public + rick
if (Test-Path $log) {
    try { Invoke-RestMethod -Uri $pub -Method Put -InFile $log -Headers @{ Filename='dfir-setup.log'; Title='DFIR setup log'; Tags='dfir_setup' } } catch {}
    try { Invoke-RestMethod -Uri $T   -Method Put -InFile $log -Headers @{ Authorization="Bearer $K"; Filename='dfir-setup.log'; Title='DFIR setup log'; Tags='dfir_setup' } } catch {}
}
Write-Host $rep
Write-Host '==== verify report sent to Rem ===='
