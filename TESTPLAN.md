# Test plan - dfir-lab-vm

## What was validated on rick (Linux, no VMware)

These are static checks that do **not** need VMware and were run during the build:

| Check | Tool | Result |
|---|---|---|
| Packer template parses + is internally valid | `packer validate` (1.11.2) | see commit notes |
| Packer template formatting | `packer fmt -check` | applied |
| Bash provisioner snippets / fallback shell | `shellcheck` | clean (the embedded WSL bash) |
| autounattend.xml is well-formed XML | `xmllint --noout` | clean |
| PowerShell scripts parse | PSParser / `pwsh -NoProfile -Command` (if available) | see commit notes |

> `packer validate` needs the `vmware` plugin; `packer init` downloads it. Validation
> uses placeholder ISO vars where a real eval URL/checksum isn't pinned.

## What CANNOT be tested on rick - must run on a Windows host with VMware Workstation Pro

The full **end-to-end VMware build is Windows-only** (needs VMware Workstation Pro +
hardware virtualization). Run this on the user's box or **l3e7**:

### End-to-end test (the real one)
1. On the Windows host with **VMware Workstation Pro** installed, open an **elevated PowerShell**.
2. Run the one-liner:
   ```powershell
   iwr https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/bootstrap.ps1 | iex
   ```
3. Expect: prereq checks pass -> Packer installs (if needed) -> ISO downloads ->
   a VMware window drives a hands-free Windows install -> provisioners run ->
   build reports the `.vmx` path. Total ~30-60 min.
4. **Open** the `.vmx` in Workstation Pro -> **Power On** -> log in `Analyst` / `dfir`.

### In-VM smoke checks
- [ ] Desktop shows `DFIR-LAB-README.html`, `DFIR-LAB-MODULES.html` + the shortcuts.
- [ ] `wsl -l -v` lists **Ubuntu** as version **2**, Running.
- [ ] In Ubuntu: `docker version` works; `docker images` lists **dfir-aio**.
- [ ] PowerShell: `PECmd --help`, `chainsaw --help`, `hayabusa --help` all resolve (on PATH).
- [ ] `C:\dfir\lab` contains modules `module-01..module-10` with `README.md` + `data/`.

### ⭐ OFFLINE ACCEPTANCE GATE (the non-negotiable requirement)

The finished VM must run the **entire** lab with **zero internet**. This is the
pass/fail gate for the build.

1. **Disconnect the VM's network adapter:** VMware *VM > Settings > Network Adapter*
   -> uncheck **Connected** (or `vmrun` equivalent). The VM is now air-gapped.
2. Run the baked acceptance test (elevated PowerShell in the VM):
   ```powershell
   C:\dfir\offline-selftest.ps1      # or the desktop "Offline acceptance self-test"
   ```
3. **Pass criteria:** the test walks **every** `C:\dfir\lab\module-XX`, picks a
   representative artifact, and runs the matching tool **both** ways with no network:
   - **native** (PECmd / AmcacheParser / AppCompatCacheParser / EvtxECmd / MFTECmd on PATH), and
   - **container** via `docker run --network none dfir-aio:v2 <tool>` (module 6 also runs `hayabusa`).
   It prints `[PASS]/[FAIL]` per module and a final line:
   `ACCEPTANCE (every module runnable with NIC off): YES|NO`.
   **The gate is YES** = every module passes with the NIC disconnected.
4. Spot-confirm manually too, e.g. module 1:
   - native: `cd C:\dfir\lab\module-01-prefetch-pecmd\data; PECmd -d . --csv .`
   - container: `dfir-aio . PECmd -d /data --csv /data` (with the NIC off).

> What makes this pass: the build **bakes in** the eval ISO -> Windows, the dfir-aio
> image (`docker load` into the VM's local store), all native tools + Sigma/Hayabusa
> rules + EZ maps, and the lab repo with every module's `get-data.sh` run at build so
> all EVTX/Prefetch/hive samples are on disk. Nothing is fetched at runtime.

### Content-growth paths (verify these too)
- [ ] **Online:** with internet, `dfir-update` pulls new lab modules/data + refreshes
      the container and tools, then re-indexes. (Optional convenience - NOT a runtime
      dependency; the baked lab is fully offline on its own.)
- [ ] **Offline:** drop a content-pack folder/zip in `C:\dfir\incoming`, run
      `dfir-import` (NIC disconnected) -> new module(s) appear in `C:\dfir\lab`, any
      bundled image tarball is `docker load`ed, the modules index refreshes. Then the
      offline self-test passes for the new module too.

## Known gates / wiring

1. **dfir-aio container publish** - `scripts/20-dfir-aio.ps1` has ONE WIRE-THIS block:
   - GHCR ref `ghcr.io/zepedara/dfir-aio:v2` (must be public for the bare pull), and
   - release fallback `zepedara/dfir-drop` tag `v2`, asset prefix `dfir-aio.part.`.
   Confirm both once the dfir-drop agent publishes. The VM builds fine before then;
   the container loads on first `dfir-aio` use after publish.
2. **Eval ISO URL** - Microsoft rotates the link. If the default 404s, pass a fresh
   one via `$env:DFIR_ISO_URL` + `$env:DFIR_ISO_SHA256` (or the vars file).
3. **Repo visibility** - the bare `iwr | iex` one-liner needs the repo **public**
   (the kit has zero proprietary content). For a private repo, use a token:
   ```powershell
   $h=@{Authorization="token <PAT>"}; (iwr -Headers $h https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/bootstrap.ps1).Content | iex
   ```
4. **Host hypervisor coexistence** - if the host runs Hyper-V/WSL2/Credential Guard,
   VMware may need recent builds to share VT-x, or disable Hyper-V on the host. The
   bootstrap warns about this; the VM ships its **own** WSL2 inside regardless.
5. **Windows 11 variant** - default is Win10 (no TPM/UEFI hassle). Win11 needs a
   Win11 eval ISO + UEFI + vTPM (encrypted VM); see the commented block in the template.
