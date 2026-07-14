# DFIR Lab VM — V3 Lessons Learned (2026-07-14)

Distilled from bringing the shipped **v2** VM to a **14 pass / 0 fail** native validation.
The one-line takeaway: **v2 shipped the correct lab CONTENT but almost none of the native TOOLS the content needs.** Nothing catches that except actually running every command in the guest — so V3 must gate on exactly that.

---

## 1. Architecture decision: native-first, not container

The v2 lab was authored around `docker run dfir-aio:v3`, which needs WSL2 → **nested virtualization**. That fails on any host with Hyper-V / WSL2 / VBS enabled (VBS is on-by-default on much of Win11, and our own l3e7 host runs Hyper-V). Result: the container lab is unrunnable for a large fraction of end users, not just us.

**V3 primary path = native Windows tools in Git-Bash** (no container, no nested virt). Git-for-Windows supplies bash + GNU awk/grep/sort/sed/cut/uniq, so the lab's Linux pipelines run almost unchanged. Keep the container only as an *optional* bonus for nested-virt-capable hosts, behind a preflight check.

## 2. The tools v2 forgot to install

v2's provisioning installed only EZ tools + chainsaw + hayabusa. The full set the 16 modules actually invoke:

| Need | Tool | Notes |
|---|---|---|
| bash + coreutils | Git-for-Windows (portable) | provides awk/grep/sort/sed/cut/uniq/head/tail |
| memory | Python 3.12 + `pip install volatility3` | v2 guest had **only Python 2.7** |
| office docs | `pip install oletools` (olevba/oleid/mraptor) | oletools ≠ the whole Didier Stevens suite |
| office/pdf docs | Didier Stevens: `oledump.py`, `zipdump.py`, `pdfid.py`, `pdf-parser.py` + `plugin_http_heuristics.py` | download individually; oledump `-p` plugins live next to oledump.py |
| registry | RegRipper3.0 + **Perl `Parse::Win32Registry`** | Git's Perl does NOT ship this module — install from CPAN |
| filesystem timeline | Sleuth Kit (mactime/fls/mmls) | |
| CSV | Miller (mlr), csvkit | |
| evtx/sigma | chainsaw + sigma rules + mappings, hayabusa | see §4 for the path pitfall |
| exec artifacts | EZ tools (PECmd/EvtxECmd/AmcacheParser/AppCompatCacheParser) | already in v2 |

**Do NOT depend on libyal Windows binaries** (`sccainfo`/libscca as the `prefetch` engine). libyal ships source only — no prebuilt Win binary. Use **PECmd** and a `prefetch`→PECmd shim instead.

## 3. Shims (extensionless bash in `C:\dfir\tools\native-shim`, on PATH)

Git-Bash ignores `.cmd`/`.exe` when you type a bare name and doesn't read PowerShell shims. Every tool the lab calls by a bare name needs an extensionless bash shim:

```
prefetch  -> PECmd (emits sccainfo-compatible fields)
vol       -> C:\dfir\Python\Scripts\vol.exe
chainsaw  -> chainsaw.exe
olevba oleid mraptor -> oletools entry points
oledump   -> python oledump.py
rip       -> perl -I<perllib> rip.pl
mactime   -> perl mactime
zipdump pdfid pdf-parser -> python <tool>.py
```

## 4. Chainsaw rules/mappings path must be canonical

Modules 06/07/08/09/11 point chainsaw at placeholder paths — and **inconsistently**: most use `-s /opt/chainsaw/sigma --mapping /opt/chainsaw/repo/mappings/sigma-event-logs-all.yml`, but the capstone used a different `-s /sigma --mapping /chainsaw/mappings/`. Chainsaw fails hard ("Specified event log path is invalid") on a missing path.

**Fix:** one canonical rules location, referenced identically everywhere. We materialize it at `C:\dfir\tools\git\opt\chainsaw\` (= git-bash `/opt/chainsaw/`) by copying the real chainsaw `sigma/` and `mappings/` there, so every as-written command resolves. V3 should either bake `/opt/chainsaw/{sigma,repo/mappings}` at build time OR rewrite all module commands to one native path — but never leave placeholder paths.

## 5. Bundle EVERY data file the commands reference

module-16 shipped NTUSER/SAM/SYSTEM/UsrClass but **not the SOFTWARE hive** that the `run`/`uninstall`/`networklist` plugins parse. A module is only "done" if every hive/image/log its commands touch is actually in `data/`. (We backfilled SOFTWARE via `reg save HKLM\SOFTWARE`; V3 should carry the real evidence hive.)

## 6. Commands must be self-contained (setup steps in the block, not the prose)

module-12's `vol -o dump ... --dump` needs `dump/` to exist. The README mentioned `mkdir -p dump` only in prose, so a copy-paste run fails. Any directory/prereq a command needs must be an actual line in the ```bash block.

## 7. Build/packaging discipline

- **Store-less Windows** (build 26100 Enterprise/eval, no Microsoft Store): inbox `wsl --install` is a dead stub. If the container path is kept, install the standalone WSL MSI from github.com/microsoft/WSL/releases, and set `vhv.enable="TRUE"` in the packer vmx.
- **Finalize before capture**: v2 was packaged mid-provision (OOBE not complete, sshd not up). Packer must reach the SSH-connected/provisioned milestone and a stable powered-off desktop before the artifact is captured.
- **Detached processes**: Windows kills SSH-session child processes on disconnect; `nohup` AND `Start-Process` both die. Use scheduled tasks (`schtasks`) for anything that must outlive the SSH session.

## 8. The gate that would have caught all of this

Add an **auto-validation gate** to the build: after provisioning, run `validate_lab.sh` (extracts every module's ```bash blocks, runs them in Git-Bash against the bundled data, per-module PASS/FAIL with benign-error filtering) inside the guest over SSH. **Refuse to package unless 14/14 pass AND SSH is reachable at first boot.** This single gate turns "we hope it works" into "it demonstrably ran end-to-end."

Validation harness lives at `C:\dfir\validate_lab.sh` in the guest (copy in repo `tools/`).
