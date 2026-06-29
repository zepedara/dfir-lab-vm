# =============================================================================
# 34 - Native installs of the former-container DFIR tools (no Docker).
# =============================================================================
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Hdr($m){ Write-Host "==== $m ====" -ForegroundColor Cyan }

$GitDir = 'C:\DFIR\Git'
$Py     = 'C:\DFIR\Python\python.exe'
$Bin    = "$GitDir\usr\bin"
$Tools  = 'C:\DFIR\tools'
$Opt    = "$GitDir\opt"
New-Item -ItemType Directory -Force "$Tools","$Opt","$Opt\didierstevens","$Opt\regripper",'C:\DFIR\opt','C:\DFIR\dl' | Out-Null

function New-Wrapper($name,$body){
    $path = Join-Path $Bin $name
    $text = "#!/usr/bin/env bash`n" + $body + "`n"
    [IO.File]::WriteAllText($path, ($text -replace "`r",''), (New-Object Text.UTF8Encoding($false)))
}

# ------------------------------ pip tools -----------------------------------
Hdr 'pip: volatility3, capa, floss, oletools, windowsprefetch'
& $Py -m pip install --no-input volatility3 flare-capa flare-floss oletools windowsprefetch pefile 2>&1 | Select-Object -Last 3
foreach($t in 'vol','capa','floss','oleid','olevba','rtfobj','oleobj','olemeta','mraptor'){
    New-Wrapper $t "exec `"C:/DFIR/Python/Scripts/$t.exe`" `"`$@`""
}

# ---------------------- Didier Stevens suite (.py) --------------------------
Hdr 'Didier Stevens (pdfid, pdf-parser, oledump, zipdump)'
$dsBase = 'https://raw.githubusercontent.com/DidierStevens/DidierStevensSuite/master'
$dsMap = @{ 'pdfid'='pdfid.py'; 'pdf-parser'='pdf-parser.py'; 'oledump'='oledump.py'; 'zipdump'='zipdump.py' }
foreach($k in $dsMap.Keys){
    $f = $dsMap[$k]
    try {
        & curl.exe -L --fail --retry 3 -o (Join-Path "$Opt\didierstevens" $f) "$dsBase/$f"
        New-Wrapper $k "exec `"C:/DFIR/Python/python.exe`" `"C:/DFIR/Git/opt/didierstevens/$f`" `"`$@`""
    } catch { Write-Warning ("didier " + $f + ": " + $_.Exception.Message) }
}

# -------------------------------- YARA --------------------------------------
Hdr 'YARA (win64)'
try {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/VirusTotal/yara/releases/latest' -Headers @{'User-Agent'='dfir'}
    $url = ($rel.assets | Where-Object { $_.name -match 'win64\.zip$' } | Select-Object -First 1).browser_download_url
    if ($url){
        $zip='C:\DFIR\dl\yara.zip'; & curl.exe -L --fail --retry 3 -o $zip $url
        Expand-Archive $zip "$Tools\yara" -Force
        $y = Get-ChildItem "$Tools\yara" -Recurse -Filter 'yara*.exe'
        $yexe = ($y | Where-Object { $_.Name -match '^yara(64)?\.exe$' } | Select-Object -First 1)
        $ycexe= ($y | Where-Object { $_.Name -match '^yarac(64)?\.exe$' } | Select-Object -First 1)
        if($yexe){ New-Wrapper 'yara' ("exec `"" + ($yexe.FullName -replace '\\','/') + "`" `"`$@`"") }
        if($ycexe){ New-Wrapper 'yarac' ("exec `"" + ($ycexe.FullName -replace '\\','/') + "`" `"`$@`"") }
    }
} catch { Write-Warning "yara: $($_.Exception.Message)" }

# ---------------------------- The Sleuth Kit --------------------------------
Hdr 'The Sleuth Kit (win)'
try {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/sleuthkit/sleuthkit/releases/latest' -Headers @{'User-Agent'='dfir'}
    $url = ($rel.assets | Where-Object { $_.name -match 'win32\.zip$' } | Select-Object -First 1).browser_download_url
    if ($url){
        $zip='C:\DFIR\dl\tsk.zip'; & curl.exe -L --fail --retry 3 -o $zip $url
        Expand-Archive $zip "$Tools\sleuthkit" -Force
        $tskbin = (Get-ChildItem "$Tools\sleuthkit" -Recurse -Filter 'fls.exe' | Select-Object -First 1).DirectoryName
        if($tskbin){
            $cur=[Environment]::GetEnvironmentVariable('PATH','Machine'); if($cur -notlike "*$tskbin*"){[Environment]::SetEnvironmentVariable('PATH',"$cur;$tskbin",'Machine')}
            $mac = Get-ChildItem "$Tools\sleuthkit" -Recurse -Filter 'mactime*' | Select-Object -First 1
            if($mac){ New-Wrapper 'mactime' ("exec perl `"" + ($mac.FullName -replace '\\','/') + "`" `"`$@`"") }
        }
    }
} catch { Write-Warning "sleuthkit: $($_.Exception.Message)" }

# ------------------------------- RegRipper ----------------------------------
Hdr 'RegRipper 3.0 (perl)'
try {
    $zip='C:\DFIR\dl\rr.zip'
    & curl.exe -L --fail --retry 3 -o $zip 'https://github.com/keydet89/RegRipper3.0/archive/refs/heads/master.zip'
    Expand-Archive $zip 'C:\DFIR\dl\rr' -Force
    $src = Get-ChildItem 'C:\DFIR\dl\rr' -Directory | Select-Object -First 1
    Copy-Item "$($src.FullName)\*" "$Opt\regripper" -Recurse -Force
    if (Test-Path "$Opt\regripper\rip.pl") {
        New-Wrapper 'regripper' "exec perl `"C:/DFIR/Git/opt/regripper/rip.pl`" `"`$@`""
        New-Wrapper 'rip.pl' "exec perl `"C:/DFIR/Git/opt/regripper/rip.pl`" `"`$@`""
    }
} catch { Write-Warning "regripper: $($_.Exception.Message)" }

# ----------------------- prefetch (libscca-style) ---------------------------
Hdr 'prefetch (libscca-style emulator)'
$fmtPy = @'
#!/usr/bin/env python3
# Emulates dfir-aio's libscca `prefetch`: prints PF info with the exact labels
# the lab greps/awk's (Executable filename / Run count / Last run time: N /
# Number of filenames / Filename: N). Uses windowsprefetch (handles Win10 MAM).
import sys
try:
    from windowsprefetch import Prefetch
except Exception as e:
    sys.stderr.write("prefetch: windowsprefetch not available: %s\n" % e); sys.exit(2)
def main(argv):
    if not argv:
        sys.stderr.write("Usage: prefetch <file.pf> [more.pf ...]\n"); return 1
    rc = 0
    for path in argv:
        try:
            pf = Prefetch(path)
        except Exception as e:
            sys.stderr.write("prefetch: %s: libscca read error: %s\n" % (path, e)); rc = 1; continue
        exe = getattr(pf, 'executableName', '') or ''
        runcount = getattr(pf, 'runCount', 0) or 0
        ts = list(getattr(pf, 'timestamps', []) or [])
        names = [n for n in (getattr(pf, 'resources', []) or []) if n]
        h = getattr(pf, 'hash', '') or ''
        print("Windows Prefetch File (PF) information:")
        print("\tExecutable filename\t\t: %s" % exe)
        if h:
            print("\tPrefetch hash\t\t\t: %s" % h)
        print("\tRun count\t\t\t: %s" % runcount)
        i = 1
        for t in ts:
            print("\tLast run time: %d\t\t: %s" % (i, t)); i += 1
        print("\tNumber of filenames\t\t: %d" % len(names))
        j = 1
        for n in names:
            print("\tFilename: %d\t\t: %s" % (j, n)); j += 1
        print("")
    return rc
if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
'@
[IO.File]::WriteAllText('C:\DFIR\opt\prefetch_fmt.py', ($fmtPy -replace "`r",''), (New-Object Text.UTF8Encoding($false)))
New-Wrapper 'prefetch' "exec `"C:/DFIR/Python/python.exe`" `"C:/DFIR/opt/prefetch_fmt.py`" `"`$@`""

Write-Host '[34] native DFIR tools installed (best-effort).'
exit 0
