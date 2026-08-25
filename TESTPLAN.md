# Test plan — dfir-vm

**How v5 was actually verified, and how to verify the next one.**
Rewritten 2026-08-25. The previous version described a container-based acceptance gate that
no longer exists and a "run it on l3e7" instruction that was no longer true.

---

## 1. The gate that matters

`tools/validate_lab.sh` runs inside the guest, extracts every module README's ` ```bash ` blocks,
executes them against the baked evidence and reports per-module PASS/FAIL plus a single verdict
line:

```
=== RESULT: 26 pass / 0 fail / 0 unvalidated / 0 conceptual (allow-listed) ===
    missing tools: 0
LAB_VALIDATION: PASS
```

**The packer build now runs this and refuses to package unless it says PASS.** That is the whole
point: v2 shipped content with no tools, and v4 was packaged with two provisioning steps having
exited 1, because nothing ever failed the build.

Two design rules the harness enforces, both learned the hard way:

- **Unknown ⇒ FAIL.** A module the harness cannot validate counts as a failure, not a pass. It
  previously printed `SKIP` for any module whose fences were not tagged ` ```bash `, which is how
  module 04 stayed broken and invisible for six weeks.
- **Tool preflight.** It reports every lab tool that does not resolve on `PATH` before running
  anything, so "everything failed" becomes "these tools are missing".

Run it by hand any time:

```bash
bash /c/dfir/validate_lab.sh /c/dfir/lab
```

## 2. v5 verification record (2026-08-25)

| Step | Result |
|---|---|
| Lab synced to `dfir-lab@52b9d4a` in the image | 26 modules |
| Full harness in the guest | **26 pass / 0 fail / 0 unvalidated / 0 tools missing** |
| Export → `dfir-lab-vm-v5.ova` | 29.06 GB, SHA-256 `dd00d5c44fcd24c3498e15b034b0cb7377d2236779654348197ecd043a99da45` |
| OVA structure | `tar -tvf` shows `.ovf`, `.mf`, `.vmdk` in that order; `ovf:size` matches the VMDK byte-for-byte |
| Release | 15 parts + `dfir-lab-vm-v5.ova.sha256` + `parts.sha256` |
| Puller round-trip | `pull-vm.ps1` fetched from `main`, reassembled the OVA and verified the published SHA-256 |

**Provenance, stated plainly:** the v5 image was produced by exporting the *validated* VM
(Proxmox zvol → streamOptimized VMDK → OVA), not by a clean `packer build`. There is no VMware
Workstation host in the fleet, and Broadcom now gates that download behind an account. Every fix
is committed as `scripts/45-v5-fixes.ps1` so a clean bake reproduces the same content.

## 3. Verifying a release without downloading 29 GB twice

```powershell
# the whole user path, end to end
iwr -useb https://raw.githubusercontent.com/project-dfir/dfir-vm/main/pull-vm.ps1 | iex
```

It downloads every part, reassembles, and **verifies against the release's own
`.sha256`**. If a part is corrupt:

```powershell
iwr -useb https://raw.githubusercontent.com/project-dfir/dfir-vm/main/repair-vm.ps1 | iex
```

`repair-vm.ps1` re-checks each part against `parts.sha256` **published in the release**,
re-downloads only the bad ones, and reassembles. Neither script hardcodes a part count any more —
that bug made the v4 repairer mathematically unable to succeed.

## 4. In-VM smoke checks

- Desktop shows **START-HERE** and the **DFIR Lab Shell** shortcut.
- Login `Analyst` / `DFIRlab2026!` — the password **does not expire** (it did in v4, which locked
  every user out 40 days after the build).
- `C:\dfir\lab` contains `module-01` … `module-27` (26 dirs; there is no module-13).
- In Git-Bash: `PECmd`, `EvtxECmd`, `chainsaw`, `hayabusa`, `vol`, `rip`, `acp`, `velociraptor`
  all resolve by bare name.
- `C:\dfir\BUILD-INFO.txt` records the lab commit and the validation result.

### Module 20 needs elevation — by design

It queries the **live OS**, so `velociraptor.exe` declares `requireAdministrator`. Right-click
*DFIR Lab Shell* → **Run as administrator**. Unelevated it fails with `Permission denied`, which
is Git-Bash's rendering of *"The requested operation requires elevation."*

## 5. Offline use

The VM needs **no internet**. All evidence is baked in at build time and every tool is native —
there is no container and no runtime download. Disconnect the NIC and the modules still run.

> **Windows Defender must be excluded from `C:\dfir`.** The lab ships real attack telemetry, and
> Defender quarantines both the samples and anything derived from them — it deleted
> `module-06/data/high.csv`, the file that module's own Step 5 tells the student to create, and
> behaviour-blocked `bash.exe` so Git-Bash could not launch the forensic tools. `45-v5-fixes.ps1`
> adds the exclusions. Do not attempt to disable Defender instead: Tamper Protection re-asserts
> itself and the exclusion is sufficient.

## 6. Static checks (no VMware needed)

| Check | Tool |
|---|---|
| Packer template parses | `packer validate` (needs `packer init` for the vmware plugin) |
| Template formatting | `packer fmt -check` |
| `autounattend.xml` well-formed | `xmllint --noout` |
| PowerShell scripts parse | `pwsh -NoProfile -Command { ... }` / PSParser |
| Harness syntax | `bash -n tools/validate_lab.sh` |
