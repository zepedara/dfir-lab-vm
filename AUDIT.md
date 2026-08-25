# DFIR Lab + VM — End-to-End Readiness Audit (WORKING DOCUMENT)

**Status:** LIVE — updated as the audit and the end-to-end test proceed.
**Opened:** 2026-08-24 · **Scope:** `project-dfir/dfir-lab` (26 modules) + `project-dfir/dfir-vm` (build/ship kit)
**Test host:** `cthuwu-win` (192.168.1.145, Proxmox VE 9.2.10) — the box formerly called l3e7.

> How to use this doc: §1 is the current verdict. §2 is the issue register (every issue
> annotated with evidence + fix). §3 is the pattern analysis — the *why* behind the issues,
> which is what stops us repeating them. §4 is the end-to-end test plan and its live log.

---

## 1. Verdict

**Not ready to ship a fresh build. The shipped v4 OVA is testable and is what we are testing.**

Two different things must not be confused:

| Thing | State |
|---|---|
| **The shipped artifact** (`vm-v4` OVA, 27.9 GB, 15 parts, 2026-07-16) | Exists, downloadable. Being tested now. Content = **24 modules**. |
| **A fresh `packer build` from this repo today** | **Would reproduce the v2 failure.** The entire V3 native-first toolchain is orphaned — see ISSUE-01. |

The single most important finding: **the repo's automated build does not build the VM that
was shipped.** The v4 OVA was brought to a working state by *manual, in-guest* script runs.
That state is not reproducible from `packer build`. If we rebuild for the 26-module content,
we rebuild the broken v2 architecture unless ISSUE-01 is fixed first.

---

## 2. Issue register

Severity: **P0** blocks end-to-end · **P1** breaks a user-visible path · **P2** correctness/debt.

### P0 — blocking

**ISSUE-01 · The V3 native-first toolchain is orphaned; packer still builds v2.**
`packer/dfir-win.pkr.hcl` provisions only `00-wsl2, 10-docker, 20-dfir-aio, 30-windows-tools,
40-clone-lab, 50-shortcuts-readme, 55-content-update, 60-verify-offline`.
Scripts `32-native-env`, `34-native-tools`, `35-native-forensic-tools`, `36-addon-tools`,
`36-shim` — i.e. Git-Bash, Python3+volatility3, oletools, Didier Stevens suite, RegRipper +
Perl `Parse::Win32Registry`, Sleuth Kit, Miller/csvkit, **every bash shim**, and all addon
tooling for modules 17–22 — are **never invoked by any build**.
*Evidence:* provisioner list, `packer/dfir-win.pkr.hcl` lines 136–195; `grep` finds no
reference to 32/34/35/36 outside `guest-setup.ps1` and their own file headers.
*Impact:* a fresh build ships content with no tools — the exact v2 failure that
`V3_LESSONS.md` §2 was written to prevent.
*Fix:* add the missing provisioners in dependency order (30 → 32 → 34 → 35 → 36-shim →
36-addon) before `40-clone-lab`.

**ISSUE-02 · No build-time validation gate — the one V3 called non-negotiable.**
`tools/validate_lab.sh` exists but **nothing runs it**. V3_LESSONS §8: *"Refuse to package
unless 14/14 pass."* The packer build packages unconditionally.
*Impact:* "we hope it works" instead of "it demonstrably ran". This is precisely why v2 shipped broken.
*Fix:* add a provisioner that uploads and runs `validate_lab.sh` in Git-Bash and **fails the
build** on any FAIL — and on any SKIP (see ISSUE-03).

**ISSUE-03 · Both verification harnesses are structurally incapable of failing.**
Two independent instances of the same bug:
- `tools/validate_lab.sh` extracts only ` ```bash ` fences. **module-04 has zero
  language-tagged fences** (all bare ` ``` `) → prints `SKIP … (no command blocks)` and is
  never validated at all.
- `scripts/60-verify-offline.ps1` `Plan()` recognizes only 5 artifact types (`*.pf`,
  `Amcache.hve`, `SYSTEM`, `*.evtx`, `$MFT`). Everything else falls through to *"no recognized
  artifact (concept module) — nothing to execute"* and is skipped. That silently excludes
  modules **12 (memory .raw), 14 (docs), 17, 19 (browser), 20, 21 (pcap), 22, 26 (carving),
  27 (SRUDB.dat)**.
- **Skips are not counted as failures in either harness**, so the gate can print
  `ACCEPTANCE …: YES` having never executed ~10 of the 26 modules.
*Fix:* treat SKIP as FAIL unless a module is explicitly allow-listed as conceptual; extend
`Plan()` to cover `.raw/.dd`, `.pcap`, `SRUDB.dat`, `.docm/.doc/.pdf`, browser SQLite and
`collection.zip`; tag module-04's fences `bash`.

### P1 — user-visible breakage

**ISSUE-04 · `repair-vm.ps1` is hard-broken against the release it points at.**
It hardcodes `$parts = 0..9` (10 parts); **vm-v4 has 15** (`part000`–`part014`).
`parts.sha256` was committed **2026-07-01**, two weeks *before* the v4 build (2026-07-16),
and lists only 10 hashes.
*Impact:* every part hashes as BAD → a re-download loop that never converges; even on
"success" it concatenates 10 of 15 parts → a corrupt OVA. `$finalsha` is likewise pre-v4.
*Fix:* derive the part list and hashes from the release API at runtime instead of hardcoding.
True hashes for all 15 parts are being computed during the current pull and will be committed.

**ISSUE-05 · The container path is dead but still wired into the build.**
`ghcr.io/zepedara/dfir-aio` → the `zepedara/dfir-aio` repo is **404**. `20-dfir-aio.ps1`,
`36-shim.ps1`, `55-content-update.ps1`, `60-verify-offline.ps1` and `docs/` all still
reference **`dfir-aio:v2`**; the only published image is `dfir-aio-v4` in `project-dfir/dfir-drop`.
*Impact:* the `20-dfir-aio` provisioner burns build time and fails; the offline gate reports
container failures forever. V3 demoted the container to optional — the code never followed.
*Fix:* drop the container provisioner from the default build, or repoint it to `dfir-aio-v4`
behind an explicit opt-in flag.

**ISSUE-06 · Content/artifact version drift.** Shipped OVA = **24 modules**; repo lab =
**26 modules** (module-24, -26, -27 landed after the v4 build). `pull-vm.ps1` advertises the
lab but delivers a two-module-old snapshot.
*Fix:* re-bake once the P0s are fixed, or state the delta explicitly in the README.

**ISSUE-07 · `guest-setup.ps1` — the *manual* path — is also incomplete.**
It runs `30, 32, 34, 36-shim, 40` and **omits `35-native-forensic-tools` and `36-addon-tools`**,
i.e. the Didier Stevens suite, RegRipper's Perl module, Sleuth Kit, and all module 17–22
tooling. A third install recipe that disagrees with the other two (see PATTERN-B).

**ISSUE-08 · Instructor material is 16 modules behind.** `ANSWER-KEY.md` covers
**Modules 1–10 only**; the lab ships 26. `COURSE.md` and `README.md` correctly index all 26.

### P2 — correctness / debt

**ISSUE-09 · module-20 has no `data/` directory at all** (and no `get-data.sh`), yet its
commands reference `collection.zip`. It can never pass a data-driven check.

**ISSUE-10 · Data-less-by-design modules depend on live internet at build time.**
`get-data.sh` fetchers reach GitHub, **Google Drive** (`drive.usercontent.google.com` — the
classic fragile confirm-token path) and third-party blogs. Modules 12, 14, 17, 19, 22 ship
empty `data/` dirs. If a fetch 404s at build the module is silently empty — and
`40-clone-lab.ps1` explicitly swallows the failure: `|| echo "WARN: … (continuing)"`.

**ISSUE-11 · `40-clone-lab.ps1` bakes module data *through WSL*** (`wsl.exe -d Ubuntu -u root`).
On a native-first build with no WSL present, the whole data-baking step no-ops → empty modules.

**ISSUE-12 · Dangling prerequisite:** `35-native-forensic-tools.ps1` states it *"Assumes
05-native-toolbox.ps1"* — **no such script exists** (that work lives in `32-native-env.ps1`).

**ISSUE-13 · `validate_lab.sh` concatenates all of a module's blocks into one script**, so
relative `cd`s compound across blocks and one early failure fails the entire module.

**ISSUE-14 · Legacy `zepedara/*` URLs persist repo-wide.** They currently work via GitHub 301
redirects (verified: `dfir-training-lab`, `dfir-lab-vm`, `dfir-drop` → 301; raw → 200), so this
is not breaking *yet* — but it is one un-owned redirect away from breaking every path.

**ISSUE-15 · `Native()` in the offline gate returns true if a tool merely *executes***, and
resolves it with a wildcard `Get-Command "$exe*"` — it can match the wrong binary, and it
never checks output correctness.

---

## 3. Patterns — the actual root causes

The issues above are not independent. They are four recurring failure modes:

**PATTERN-A · Content outruns provisioning.** Every time the lab grows, the install/build side
lags. v2: 16 modules of content, ~4 tools installed. Today: 26 modules of content, a build that
installs the v2 tool set, an answer key covering 10, and a shipped OVA covering 24.
*Countermeasure:* module count is a **build input**. Adding a module must fail CI until its
tools are in an installer, its data is bundled, and its answer key exists.

**PATTERN-B · Multiple parallel install recipes that silently diverge.** Three lists exist —
the packer provisioners, `guest-setup.ps1`, and the manual `run.ps1`/`fix*.ps1` lineage — and
**no two agree**. ISSUE-01, -07 and -12 are all this same bug.
*Countermeasure:* ONE ordered manifest of steps, consumed by both packer and the manual path.
Nothing may hardcode its own copy of the list.

**PATTERN-C · Verification that cannot fail.** Both harnesses convert "I don't know how to
check this" into "skip", and skips into "pass" (ISSUE-03, -15). The build then packages
regardless (ISSUE-02). A green result currently carries almost no information.
*Countermeasure:* **unknown ⇒ FAIL.** Allow-list conceptual modules explicitly and by name;
never let a pattern-match miss produce a silent pass.

**PATTERN-D · Stale hardcoded constants outliving the thing they describe.** `0..9` parts vs 15;
`parts.sha256` predating its release; `dfir-aio:v2` vs v4; `zepedara/*` vs `project-dfir/*`;
`05-native-toolbox.ps1`. Each was correct once.
*Countermeasure:* derive at runtime from the release API, or keep one constants file. If a
number describes an external artifact, never type it twice.

### The meta-lesson — the one we keep re-learning

`V3_LESSONS.md` already diagnosed PATTERN-A and PATTERN-C correctly on 2026-07-14, and
prescribed the exact fix: a build-time validation gate. **The lessons were written down and
then never wired into the build.** A lesson that is not enforced by an executable gate is a
lesson that will be re-learned. Every countermeasure above must land as *code that fails* —
not as a paragraph in a markdown file. This document is subject to its own rule: it is only
worth something once §4/T6 turns it into gates.

---

## 4. End-to-end test plan (live)

Constraint discovered: **the TESTPLAN's premise is void.** It directs the VMware build to run
on "the user's box or l3e7" — but l3e7 was rebuilt as **Proxmox VE** on 2026-08-14. There is no
Windows + VMware Workstation host left in the fleet, and a nested VMware-inside-KVM build is
not a sensible test target.

**Chosen approach — test the artifact users actually receive, rather than a build we cannot run:**

| Step | What | Status |
|---|---|---|
| T1 | Pull all 15 vm-v4 parts on `cthuwu-win`, hash each, reassemble, verify vs published manifest | **RUNNING** (`dfir-ova-pull.service`) |
| T2 | Capture true per-part SHA-256 → replaces the stale `parts.sha256` (fixes ISSUE-04) | pending T1 |
| T3 | `qm importovf` the OVA into Proxmox and boot it (no VMware needed) | pending T1 |
| T4 | Run `tools/validate_lab.sh` in-guest across all modules → real per-module PASS/FAIL | pending T3 |
| T5 | Run the offline acceptance gate with the NIC detached; compare its verdict against T4 | pending T4 |
| T6 | Fix P0/P1 issues, re-bake, re-run T4/T5 | pending |

T5 is deliberately designed to **prove or disprove ISSUE-03**: if the gate reports
`ACCEPTANCE: YES` while T4 shows real failures, the gate is confirmed non-functional as written.

### Live log

- `2026-08-24 23:54` — pull started on cthuwu-win, `/var/lib/vz/template/dfir-vm`, 780 GB free.
- `2026-08-25 00:00` — 2.8 GB / 27.9 GB downloaded, healthy.
