# =============================================================================
# 20 - Load the dfir-aio container into the WSL2 Docker engine.
#   Primary : docker pull ghcr.io/zepedara/dfir-aio:v2  (if GHCR pkg is public)
#   Fallback: download split-part assets from the dfir-drop GitHub release,
#             reassemble, and `docker load` (per the dfir-drop README).
# =============================================================================
$ErrorActionPreference = 'Stop'

# --------------------------- WIRE-THIS (single spot) -------------------------
# These are the only values to confirm once the container is actually published.
$Image       = 'ghcr.io/zepedara/dfir-aio:v2'
$ImageTagShort = 'dfir-aio:v2'
# Fallback release: where the split-part .tar.gz assets live. The dfir-drop
# README says "Download all dfir-aio.part.* files from the latest release".
$ReleaseOwnerRepo = 'zepedara/dfir-drop'
$ReleaseTag       = 'v2'          # <-- confirm the actual release tag once published
$PartGlob         = 'dfir-aio.part.'   # asset name prefix, per dfir-drop README
# ---------------------------------------------------------------------------

function Invoke-WSL([string]$cmd) {
    wsl.exe -d Ubuntu -u root -- bash -lic $cmd
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed ($LASTEXITCODE): $cmd" }
}
function TryWSL([string]$cmd) {
    wsl.exe -d Ubuntu -u root -- bash -lic $cmd
    return ($LASTEXITCODE -eq 0)
}

# Make sure dockerd is running in WSL.
Write-Host '[dfir-aio] Ensuring Docker daemon is up in WSL...'
Invoke-WSL "service docker start 2>/dev/null || (pgrep dockerd >/dev/null 2>&1 || (dockerd >/var/log/dockerd.log 2>&1 &)); for i in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 2; done; docker info >/dev/null 2>&1"

# 1) Try the simple GHCR pull first.
Write-Host "[dfir-aio] Attempting GHCR pull: $Image"
if (TryWSL "docker pull $Image") {
    Invoke-WSL "docker tag $Image $ImageTagShort 2>/dev/null || true"
    Write-Host '[dfir-aio] Pulled from GHCR.'
}
else {
    Write-Warning '[dfir-aio] GHCR pull failed (package may be private or not yet published). Using release split-parts fallback.'

    # 2) Fallback: pull split-part assets from the GitHub release and reassemble.
    #    Uses the public release download API - no auth needed for public assets.
    $fallback = @"
set -euo pipefail
mkdir -p /tmp/dfir-aio-dl && cd /tmp/dfir-aio-dl
echo '[dfir-aio] querying release $ReleaseOwnerRepo @ $ReleaseTag ...'
# List assets for the tag and grab every part file.
ASSETS=`$(curl -fsSL https://api.github.com/repos/$ReleaseOwnerRepo/releases/tags/$ReleaseTag | grep -oE '"browser_download_url": *"[^"]+"' | sed 's/.*"browser_download_url": *"//; s/"$//' | grep '$PartGlob' || true)
if [ -z "`$ASSETS" ]; then
  echo '[dfir-aio] No $PartGlob assets found on release $ReleaseTag - is the container published yet?' >&2
  exit 42
fi
for u in `$ASSETS; do echo "[dfir-aio]   downloading `$u"; curl -fsSL -O "`$u"; done
echo '[dfir-aio] reassembling + docker load ...'
cat ${PartGlob}* > dfir-aio.tar.gz
docker load < dfir-aio.tar.gz
rm -f dfir-aio.tar.gz ${PartGlob}*
"@
    if (-not (TryWSL $fallback)) {
        Write-Warning '[dfir-aio] Container not available yet (neither GHCR nor release).'
        Write-Warning '[dfir-aio] The VM is still fully built; once dfir-aio is published, run inside the VM:'
        Write-Warning "[dfir-aio]   wsl -d Ubuntu -- bash -lic 'docker pull $Image && docker tag $Image $ImageTagShort'"
        # Do NOT fail the whole build for a not-yet-published container.
        exit 0
    }
}

# Verify + a friendly tag the lab READMEs expect (dfir-aio:v2 and dfir-aio).
Invoke-WSL "docker tag $ImageTagShort dfir-aio 2>/dev/null || true"
Invoke-WSL "docker images | grep -i dfir-aio || true"
Write-Host '[dfir-aio] Container ready in WSL2 Docker.'
exit 0
