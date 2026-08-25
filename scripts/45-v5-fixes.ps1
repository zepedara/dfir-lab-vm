# =============================================================================
# 45 - v5 fixes. Everything the 2026-08-25 audit found wrong with the v4 image.
#      Idempotent; safe to re-run. Run ELEVATED (Defender + local-account steps).
#
# Findings this closes (see dfir-lab/MODULE_REVIEW.md + TRAINING_VALUE_AUDIT.md):
#   1. Defender quarantines the lab's own samples AND student output (it deleted
#      module-06/data/high.csv, the file Step 5 tells you to create) and
#      behaviour-blocks bash.exe so Git-Bash cannot launch the forensic tools.
#   2. `acp` was written to C:\dfir\Git\usr\bin (NOT on PATH) by 42-module04-acp,
#      so module 04 could not run. Two Git trees exist; only tools\git is wired.
#   3. The Analyst password expired 40 days after the v4 build, so the documented
#      credentials no longer log in.
#   4. The baked lab was 3 commits behind main and shipped 25 of 26 modules.
# =============================================================================
$ErrorActionPreference = 'Continue'
function Say($m) { Write-Host ("==== " + $m + " ====") }

# --- 1. Defender: exclude the lab tree ---------------------------------------
# The lab ships real attack telemetry; Defender treats the samples AND anything
# derived from them (CSV timelines full of malicious command lines) as threats.
Say 'Defender exclusions for C:\dfir'
foreach ($p in 'C:\dfir', 'C:\Python27') {
    try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; Write-Host "  excluded $p" }
    catch { Write-Host "  Add-MpPreference failed for $p ($($_.Exception.Message))" }
}
foreach ($proc in 'bash.exe', 'EvtxECmd.exe', 'chainsaw.exe', 'hayabusa.exe', 'python.exe', 'perl.exe') {
    try { Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop; Write-Host "  excluded process $proc" } catch {}
}
# Policy-backed fallback (survives even when Set-MpPreference is unavailable).
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions'
New-Item -Path "$pol\Paths" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $pol -Name 'Exclusions_Paths' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "$pol\Paths" -Name 'C:\dfir' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
Write-Host '  policy exclusion written'

# --- 2. acp shim on the PATH -------------------------------------------------
Say 'acp shim -> Python 2.7 (module 04)'
$shimDir = 'C:\dfir\tools\native-shim'
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
$py2 = 'C:\Python27\python.exe'
$acpPy = 'C:\dfir\tools\appcompatprocessor\AppCompatProcessor.py'
if ((Test-Path $py2) -and (Test-Path $acpPy)) {
    # extensionless bash shim, LF endings - Git-Bash ignores .cmd for bare names
    $shim = "#!/usr/bin/env bash`nexec /c/Python27/python.exe /c/dfir/tools/appcompatprocessor/AppCompatProcessor.py `"`$@`"`n"
    [IO.File]::WriteAllText("$shimDir\acp", $shim.Replace("`r`n", "`n"))
    Write-Host "  wrote $shimDir\acp"
} else {
    Write-Host "  SKIP: python2=$(Test-Path $py2) acp=$(Test-Path $acpPy)"
}

# --- 3. Analyst credentials must keep working --------------------------------
Say 'Analyst password never expires'
try {
    Set-LocalUser -Name Analyst -PasswordNeverExpires $true -ErrorAction Stop
    Write-Host '  PasswordNeverExpires = true'
} catch { Write-Host "  failed: $($_.Exception.Message)" }
try { net accounts /maxpwage:unlimited | Out-Null; Write-Host '  maxpwage = unlimited' } catch {}

# --- 4. Bring the baked lab up to main ---------------------------------------
Say 'sync C:\dfir\lab to origin/main'
$git = 'C:\dfir\tools\git\bin\git.exe'
if (-not (Test-Path $git)) { $git = 'C:\dfir\Git\cmd\git.exe' }
if ((Test-Path $git) -and (Test-Path 'C:\dfir\lab\.git')) {
    & $git -C C:\dfir\lab remote set-url origin https://github.com/project-dfir/dfir-lab.git
    & $git -C C:\dfir\lab fetch --depth 1 origin main 2>&1 | Select-Object -Last 2
    & $git -C C:\dfir\lab reset --hard FETCH_HEAD 2>&1 | Select-Object -Last 1
    Write-Host ('  lab now at: ' + (& $git -C C:\dfir\lab log --oneline -1))
    Write-Host ('  modules: ' + (Get-ChildItem 'C:\dfir\lab' -Directory -Filter 'module-*').Count)
} else { Write-Host '  git or lab repo missing' }

# --- 5. Materialise any compressed evidence ----------------------------------
Say 'decompress shipped .gz evidence'
$bash = 'C:\dfir\tools\git\bin\bash.exe'
if (Test-Path $bash) {
    & $bash -lc 'for f in $(find /c/dfir/lab -name "*.gz" 2>/dev/null); do t="${f%.gz}"; if [ ! -f "$t" ]; then gunzip -kf "$f" && echo "  gunzipped $f"; fi; done' 2>&1 | Select-Object -Last 10
}

Say 'v5 fixes complete'
