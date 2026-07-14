#!/usr/bin/env bash
# Native lab validation harness — runs every module's README bash blocks in
# Git-Bash on the VM with the native tools on PATH, captures per-module pass/fail.
# Usage: bash validate_lab.sh [LABDIR]   (default C:\dfir\lab -> /c/dfir/lab)
set -u
export PATH="/c/dfir/tools/git/usr/bin:/c/dfir/tools/git/bin:/c/dfir/tools/native-shim:/c/dfir/tools/EZ/net9:/c/dfir/tools/chainsaw:/c/dfir/tools/hayabusa:$PATH"
LAB="${1:-/c/dfir/lab}"
cd "$LAB" || { echo "no lab dir $LAB"; exit 2; }

# extract ```bash ... ``` blocks from a README into a runnable script
extract_blocks() {
  awk '
    /^```bash/ {inb=1; next}
    /^```/     {inb=0; next}
    inb        {print}
  ' "$1"
}

pass=0; fail=0
echo "=== NATIVE LAB VALIDATION $(date) ==="
for d in module-*/; do
  m="${d%/}"
  readme="$d/README.md"
  [ -f "$readme" ] || continue
  # neutralize interactive pagers / prompts
  blocks="$(extract_blocks "$readme" | sed -E 's/\| *less( +-[A-Za-z]+)*/| cat/g; s/\| *more\b/| cat/g')"
  nblocks="$(printf '%s\n' "$blocks" | grep -c . )"
  if [ "$nblocks" -eq 0 ]; then
    echo "SKIP  $m  (no command blocks — stub/overview)"
    continue
  fi
  # write blocks to a temp script and run it from the lab root (bash reads the
  # SCRIPT from the file; </dev/null only satisfies interactive stdin reads).
  log="/c/dfir/valout_${m}.log"
  tmp="/c/dfir/_run_${m}.sh"
  printf '%s\n' "$blocks" > "$tmp"
  ( cd "$LAB" && timeout 150 bash "$tmp" > "$log" 2>&1 </dev/null )
  rc=$?
  outlines="$(grep -c . "$log" 2>/dev/null)"
  # count REAL errors only: filter out benign lines (EvtxECmd non-fatal map warnings,
  # 'ERROR' inside filenames/paths) THEN match unambiguous failure signatures.
  errs="$(grep -vE 'Error loading map file|Records included|\\VOLUME\{|-ERROR|ERROR\.|ERRORDETAILS|DNSERROR|INETCACHE' "$log" 2>/dev/null \
          | grep -ciE 'command not found|not recognized as|No such file or directory|Traceback \(most recent|Segmentation fault|Permission denied|FATAL' )"
  if [ "$rc" -eq 0 ] && [ "${errs:-0}" -eq 0 ] && [ "${outlines:-0}" -gt 0 ]; then
    echo "PASS  $m  ($nblocks cmd-lines, $outlines out-lines)"
    pass=$((pass+1))
  else
    echo "FAIL  $m  (rc=$rc errs=$errs out-lines=${outlines:-0})  detail:"
    if [ "${outlines:-0}" -eq 0 ]; then
      echo "        (no output produced — commands may not have run)"
    fi
    grep -iE 'command not found|No such file|not recognized|error|cannot|Traceback|fatal|unable to' "$log" 2>/dev/null | head -4 | sed 's/^/        /'
    fail=$((fail+1))
  fi
done
echo "=== RESULT: $pass pass / $fail fail ==="
