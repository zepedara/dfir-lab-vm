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

### In-VM acceptance checks
- [ ] Desktop shows `DFIR-LAB-README.html` + the three shortcuts.
- [ ] `wsl -l -v` lists **Ubuntu** as version **2**, Running.
- [ ] In Ubuntu: `docker version` works; `docker images` lists **dfir-aio** (once the container is published - see below).
- [ ] PowerShell: `PECmd --help`, `chainsaw --help`, `hayabusa --help` all resolve (on PATH).
- [ ] `C:\dfir\lab` contains modules `module-01..module-10` with `README.md` + `data/`.
- [ ] `dfir-lab` cd's into the lab; `dfir-aio` launches the container with the current folder as `/data`.
- [ ] Run module 01 both ways: native `PECmd -d .\data --csv .` AND `dfir-aio .\data PECmd -d /data --csv /data`.

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
