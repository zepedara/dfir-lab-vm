#!/usr/bin/env bash
# Native lab validation harness — runs every module's README bash blocks in
# Git-Bash on the VM with the native tools on PATH, captures per-module pass/fail.
# Usage: bash validate_lab.sh [LABDIR]   (default C:\dfir\lab -> /c/dfir/lab)
#
# DESIGN RULE (added 2026-08-24 audit, PATTERN-C): **unknown ⇒ FAIL.**
# A module that cannot be validated is NOT a pass. Previously a module with no
# ```bash-tagged fence printed SKIP and vanished from the tally, so the harness
# could report a clean run having never executed that module (module-04 was
# invisible this way for the entire life of the harness). The only way a module
# is allowed to go unexecuted now is by being named explicitly in CONCEPTUAL
# below — a deliberate, reviewable act.
#
# Authoring convention this harness relies on (verified across all 26 modules):
# each README's bash blocks contain exactly ONE `cd <module>/...` at the top and
# are relative to the LAB ROOT, so concatenating a module's blocks into a single
# script is correct and intended.
set -u
export PATH="/c/dfir/tools/git/usr/bin:/c/dfir/tools/git/bin:/c/dfir/tools/native-shim:/c/dfir/tools/EZ/net9:/c/dfir/tools/chainsaw:/c/dfir/tools/hayabusa:/c/dfir/tools/addons:$PATH"
LAB="${1:-/c/dfir/lab}"
cd "$LAB" || { echo "no lab dir $LAB"; exit 2; }

# Modules that legitimately have nothing to execute. Add a name here ONLY with a
# stated reason; anything not listed must produce runnable commands.
CONCEPTUAL=""

# extract ```bash ... ``` blocks from a README into a runnable script
extract_blocks() {
  awk '
    /^```bash/ {inb=1; next}
    /^```/     {inb=0; next}
    inb        {print}
  ' "$1"
}

is_conceptual() {
  case " $CONCEPTUAL " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Pre-flight: report which tools the lab invokes are actually resolvable. This
# turns "everything failed" into "these 6 tools are missing", which is the
# difference between a useful and a useless failure report.
# ---------------------------------------------------------------------------
echo "=== TOOL PREFLIGHT ==="
missing_tools=0
for t in PECmd EvtxECmd AmcacheParser AppCompatCacheParser MFTECmd SrumECmd \
         JLECmd LECmd RBCmd SBECmd chainsaw hayabusa vol rip mactime fls icat \
         mmls blkls istat olevba oledump pdf-parser tshark zircolite hindsight \
         velociraptor python3 acp; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  ok      %s\n' "$t"
  else
    printf '  MISSING %s\n' "$t"; missing_tools=$((missing_tools+1))
  fi
done
echo "  -> $missing_tools tool(s) missing"
echo

pass=0; fail=0; unvalidated=0; conceptual=0
failed_names=""; unvalidated_names=""
echo "=== NATIVE LAB VALIDATION $(date) ==="
for d in module-*/; do
  m="${d%/}"
  readme="$d/README.md"
  [ -f "$readme" ] || continue
  # neutralize interactive pagers / prompts
  blocks="$(extract_blocks "$readme" | sed -E 's/\| *less( +-[A-Za-z]+)*/| cat/g; s/\| *more\b/| cat/g')"
  nblocks="$(printf '%s\n' "$blocks" | grep -c . )"
  if [ "$nblocks" -eq 0 ]; then
    if is_conceptual "$m"; then
      echo "CONCEPT   $m  (allow-listed: no executable content by design)"
      conceptual=$((conceptual+1))
    else
      # NOT a pass. Either the module has no commands, or its fences are not
      # tagged ```bash and the harness is blind to them.
      echo "UNVALIDATED $m  (no \`\`\`bash-tagged command blocks — untagged fences? -> counts as FAILURE)"
      unvalidated=$((unvalidated+1)); unvalidated_names="$unvalidated_names $m"
    fi
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
    fail=$((fail+1)); failed_names="$failed_names $m"
  fi
done

echo
echo "=== RESULT: $pass pass / $fail fail / $unvalidated unvalidated / $conceptual conceptual (allow-listed) ==="
[ -n "$failed_names" ]      && echo "    failed:     $failed_names"
[ -n "$unvalidated_names" ] && echo "    unvalidated:$unvalidated_names"
echo "    missing tools: $missing_tools"

# Single machine-readable verdict line. UNVALIDATED counts against the gate.
bad=$((fail + unvalidated))
if [ "$bad" -eq 0 ]; then
  echo "LAB_VALIDATION: PASS"
  exit 0
else
  echo "LAB_VALIDATION: FAIL ($bad module(s) not demonstrably runnable)"
  exit 1
fi
