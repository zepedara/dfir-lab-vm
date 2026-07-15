# =============================================================================
# 36 - Addon-module tools (PROVEN, lab validated 20/0 on 2026-07-15)
#   Installs the open-source tooling the addon modules (17-22) need, plus the
#   bash shims that make each resolve by bare name in Git-Bash. Run AFTER 35.
#   All open-source, license-verified. Native-Windows. NO container / WSL.
# =============================================================================
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Say($m) { Write-Host "[addon-tools] $m" }

$tools = 'C:\dfir\tools'
$add   = Join-Path $tools 'addons'
$shim  = Join-Path $tools 'native-shim'
$git   = Join-Path $tools 'git'
$py    = 'C:\dfir\Python\python.exe'
$ez    = 'C:\dfir\tools\EZ\net9'
New-Item -ItemType Directory -Force -Path $add, $shim | Out-Null
function New-Shim($name, $body) { [IO.File]::WriteAllText((Join-Path $shim $name), "#!/usr/bin/env bash`n$body`n") }

# ---------------------------------------------------------------------------
# 1) Python packages (module 19 browser, 21 network, 22 detection)
# ---------------------------------------------------------------------------
& $py -m pip install --quiet --disable-pip-version-check pyhindsight sigma-cli yara-python scapy
# Hindsight needs ccl_chromium_reader, which is GitHub-only (NOT on PyPI):
& $git\bin\git.exe --version *> $null
& $py -m pip install --quiet --disable-pip-version-check "git+https://github.com/cclgroupltd/ccl_chromium_reader.git"
# sigma-cli sqlite/Zircolite backend
if (Test-Path 'C:\dfir\Python\Scripts\sigma.exe') { & 'C:\dfir\Python\Scripts\sigma.exe' plugin install sqlite 2>$null }
New-Shim 'hindsight' "exec '$py' '/c/dfir/Python/Scripts/hindsight.py' `"`$@`""
New-Shim 'sigma'     "exec '/c/dfir/Python/Scripts/sigma.exe' `"`$@`""

# ---------------------------------------------------------------------------
# 2) Velociraptor (module 20 triage) - single AGPL .exe
# ---------------------------------------------------------------------------
$vr = (Invoke-RestMethod 'https://api.github.com/repos/Velocidex/velociraptor/releases/latest' -Headers @{'User-Agent'='ps'}).assets |
      Where-Object { $_.name -match 'windows-amd64\.exe$' } | Select-Object -First 1
if ($vr) { & curl.exe -L --fail -s -o "$add\velociraptor.exe" $vr.browser_download_url
           New-Shim 'velociraptor' "exec '/c/dfir/tools/addons/velociraptor.exe' `"`$@`"" ; Say 'velociraptor' }

# ---------------------------------------------------------------------------
# 3) WxTCmd (EZ, Windows Timeline) - completes the user-activity triad (module 17)
# ---------------------------------------------------------------------------
& curl.exe -L --fail -s -o "$env:TEMP\WxTCmd.zip" 'https://download.ericzimmerman.dev/net9/WxTCmd.zip'
if (Test-Path "$env:TEMP\WxTCmd.zip") { Expand-Archive "$env:TEMP\WxTCmd.zip" -DestinationPath $ez -Force }

# ---------------------------------------------------------------------------
# 4) Zircolite + evtx_dump (module 22 detection-engineering)
# ---------------------------------------------------------------------------
if (-not (Test-Path "$add\Zircolite\zircolite.py")) {
    & $git\bin\git.exe clone --depth 1 -q https://github.com/wagga40/Zircolite.git "$add\Zircolite"
}
& $py -m pip install --quiet --disable-pip-version-check -r "$add\Zircolite\requirements.txt"
New-Item -ItemType Directory -Force -Path "$add\Zircolite\bin" | Out-Null
# evtx_dump (omerbenamram) - the Rust evtx parser Zircolite shells out to
& curl.exe -L --fail -s -o "$add\Zircolite\bin\evtx_dump.exe" 'https://github.com/omerbenamram/evtx/releases/download/v0.12.2/evtx_dump-v0.12.2.exe'
# shim forces UTF-8 so Zircolite's emoji/checkmark console output doesn't crash cp1252
New-Shim 'zircolite' "export PYTHONUTF8=1`nexport PYTHONIOENCODING=utf-8`nexec '$py' '/c/dfir/tools/addons/Zircolite/zircolite.py' `"`$@`""

# ---------------------------------------------------------------------------
# 5) tshark (module 21 network) - Wireshark silent install (offline pcap analysis;
#    Npcap NOT needed - captures are crafted with Scapy, not sniffed live)
# ---------------------------------------------------------------------------
if (-not (Test-Path 'C:\Program Files\Wireshark\tshark.exe')) {
    & curl.exe -L --fail -s -o "$env:TEMP\wireshark.exe" 'https://1.na.dl.wireshark.org/win64/Wireshark-latest-x64.exe'
    Start-Process "$env:TEMP\wireshark.exe" -ArgumentList '/S','/desktopicon=no' -Wait -NoNewWindow
}
[IO.File]::WriteAllText((Join-Path $shim 'tshark'),  "#!/usr/bin/env bash`nexec `"/c/Program Files/Wireshark/tshark.exe`" `"`$@`"`n")
[IO.File]::WriteAllText((Join-Path $shim 'dumpcap'), "#!/usr/bin/env bash`nexec `"/c/Program Files/Wireshark/dumpcap.exe`" `"`$@`"`n")

# ---------------------------------------------------------------------------
# 6) MemProcFS (memory-expansion) - installs, but the filesystem MOUNT needs the
#    Dokany driver (install separately: choco install dokany2 / the Dokany MSI).
#    Without Dokany, MemProcFS can't mount M: - so the memory-expansion module is
#    GATED on Dokany being present in the V3 image. Binary staged here regardless.
# ---------------------------------------------------------------------------
$mp = (Invoke-RestMethod 'https://api.github.com/repos/ufrisk/MemProcFS/releases/latest' -Headers @{'User-Agent'='ps'}).assets |
      Where-Object { $_.name -match 'win_x64.*\.zip$' } | Select-Object -First 1
if ($mp) { & curl.exe -L --fail -s -o "$env:TEMP\memprocfs.zip" $mp.browser_download_url
           New-Item -ItemType Directory -Force -Path "$add\MemProcFS" | Out-Null
           Expand-Archive "$env:TEMP\memprocfs.zip" -DestinationPath "$add\MemProcFS" -Force }

Say 'addon tools done: pyhindsight+ccl, sigma-cli+sqlite, scapy, yara, Velociraptor, WxTCmd, Zircolite+evtx_dump, tshark/dumpcap, MemProcFS (+ shims). Dokany still needed for MemProcFS mount.'
