# dfir-vm

**A prebuilt Windows DFIR lab VM — every tool native, no container, no internet needed.**

## Just want the VM? Pull the prebuilt one (recommended)

```powershell
iwr -useb https://raw.githubusercontent.com/project-dfir/dfir-vm/main/pull-vm.ps1 | iex
```

Downloads the split release parts, reassembles `dfir-lab-vm-v5.ova`, verifies the SHA-256,
then you **File > Open** it in VMware Workstation Pro. Login **`Analyst` / `DFIRlab2026!`**.

### v5 — 2026-08-25

The first release where the **shipped VM and the lab walkthrough demonstrably match**.
Validation in the image: **26 modules pass, 0 fail, 0 unvalidated, 0 tools missing.**

| Fixed in v5 | Was |
|---|---|
| All **26** modules present, lab synced to `dfir-lab@main` | 25 modules, 3 commits behind |
| **Windows Defender exclusions** for `C:\dfir` | Defender quarantined the lab's own samples *and* student output — it deleted `module-06/data/high.csv`, the file Step 5 tells you to create |
| **`acp` resolves on PATH** (module 04 runs) | the shim was written to `C:\dfir\Git\usr\bin`, which is not on PATH |
| **Analyst password never expires** | the documented credentials stopped working 40 days after the v4 build |
| **module 20 passes** | needs an elevated shell; now documented in the module |
| Answer key matches the shipped evidence | 6 answer-key claims contradicted the data — see `dfir-lab/TRAINING_VALUE_AUDIT.md` |

Module 20 (live triage with Velociraptor) still requires an **elevated** shell by design —
right-click the *DFIR Lab Shell* shortcut and *Run as administrator*.

## Or build it yourself from source

```powershell
iwr https://raw.githubusercontent.com/project-dfir/dfir-vm/main/bootstrap.ps1 | iex
```

Run that in an **elevated PowerShell** on a Windows host that has **VMware Workstation
Pro**. It uses [HashiCorp Packer](https://www.packer.io/) to build a Windows VM preloaded with:

- **Eric Zimmerman's tools** (PECmd, EvtxECmd, AppCompatCacheParser, AmcacheParser, MFTECmd, ...),
- **Chainsaw** + **Hayabusa** (Windows builds) + Sysinternals,
- Git-Bash, Python 3 + Volatility 3, oletools, the Didier Stevens suite, RegRipper, Sleuth Kit,
  Zircolite, Velociraptor, tshark, hindsight — all native, all on `PATH`,
- the **[dfir-lab](https://github.com/project-dfir/dfir-lab)** walkthrough at `C:\dfir\lab`.

**The build now gates on the lab actually working.** After provisioning it runs
`tools/validate_lab.sh` in the guest and **refuses to package** unless every module is
demonstrably runnable (`LAB_VALIDATION: PASS`). The v4 build had no such gate and shipped
with two provisioning steps having exited non-zero.

> The `dfir-aio` container path is **retired**. `ghcr.io/zepedara/dfir-aio` no longer exists
> and the lab is native-first; the container scripts remain in `scripts/` for reference only
> and are not part of the default build.

> **Legal:** This kit **never redistributes Windows**. The build downloads a free
> *Microsoft "Windows 10 Enterprise EVALUATION"* ISO straight from Microsoft (or a URL
> you supply) and you accept Microsoft's evaluation licence at build time. Educational use.

---

## What you need (the bootstrap checks all of this)

| Requirement | Why |
|---|---|
| **VMware Workstation Pro** (Windows) | the `vmware-iso` Packer builder drives it |
| **~30 GB free disk** | eval ISO (~5 GB) + the VM (~25 GB) |
| **Hardware virtualization** (VT-x/AMD-V) | to run the guest |
| **Internet** | download the ISO, tools, container |
| **Elevated PowerShell** | Packer needs admin to control VMware |

Packer itself is installed automatically if missing (winget -> choco -> direct zip).

---

## What the one-liner does

1. **Checks prerequisites** - VMware Workstation Pro path (via `vmware.exe`/`vmrun.exe`),
   free disk, virtualization, internet. Clear message if anything's missing.
2. **Installs Packer** if it isn't already present.
3. **Downloads this kit** (git clone, or zip fallback) to `%USERPROFILE%\dfir-lab-vm`.
4. **Runs `packer init` + `packer validate` + `packer build`.**
5. **Prints next steps** - where the `.vmx` landed and how to open it.

The build is **idempotent**: re-run the one-liner to resume after a failure.

---

## What gets built (the VM)

```
Windows 10 Enterprise (Evaluation)  -  Analyst / dfir   <- a FRESH BUILD.
(The prebuilt v5 OVA from pull-vm.ps1 uses Analyst / DFIRlab2026! instead, and its
password does not expire.)
 |- WSL2 + Ubuntu + Docker engine
 |     '- dfir-aio:v2 container docker-loaded (resident, offline DFIR toolbox)
 |- C:\dfir\tools   EZ Tools(+maps), Chainsaw(+Sigma), Hayabusa(+rules), Sysinternals  (PATH)
 |- C:\dfir\lab     dfir-training-lab (modules 01-10 + ALL data baked in)
 |- C:\dfir\bin     dfir-update / dfir-import / dfir-reindex  (grow content later)
 |- C:\dfir\offline-selftest.ps1   (air-gap acceptance test)
 '- Desktop  README + modules index + shortcuts + `dfir-aio` PowerShell helper
```

**Offline by design:** internet is used **only during the build**. The finished VM runs
the **entire** lab with the **network disconnected** - the container is `docker load`ed
in, all tool rules/maps are synced in, and every module's data is fetched at build. Prove
it with `C:\dfir\offline-selftest.ps1` (NIC off) - it checks every module native **and**
`docker run --network none`. See `TESTPLAN.md` for the acceptance gate.

Output is a **VMware Workstation Pro importable VM** (`.vmx` + `.vmdk`) under
`packer/output-dfir-lab-vm/`. Open it in Workstation Pro (**File -> Open**) and **Power On**.

---

## Layout

```
dfir-lab-vm/
|- bootstrap.ps1                 # the one-liner target
|- packer/
|   |- dfir-win.pkr.hcl          # Packer template (vmware-iso, Workstation Pro)
|   |- config.pkrvars.hcl.example# copy -> config.pkrvars.hcl to tune specs/ISO
|   '- http/autounattend.xml     # hands-free Windows install + WinRM enable
|- scripts/                      # provisioners (run INSIDE the building VM)
|   |- 00-wsl2.ps1               # enable WSL2 features
|   |- 10-docker.ps1             # Ubuntu + Docker engine in WSL2
|   |- 20-dfir-aio.ps1           # load dfir-aio:v2 (GHCR pull / release fallback)
|   |- 30-windows-tools.ps1      # EZ Tools(+maps) + Chainsaw(+Sigma) + Hayabusa(+rules) + Sysinternals
|   |- 40-clone-lab.ps1          # clone dfir-training-lab + run every get-data.sh (bake data)
|   |- 50-shortcuts-readme.ps1   # aliases, shortcuts, desktop README + modules index
|   |- 55-content-update.ps1     # install dfir-update (online) / dfir-import (offline pack)
|   '- 60-verify-offline.ps1     # air-gap check + comprehensive offline self-test
|- docs/DFIR_VM_KIT.md           # full kit doc
|- TESTPLAN.md                   # validation + the OFFLINE ACCEPTANCE GATE
'- README.md
```

---

## Tuning the build

Set environment variables **before** the one-liner, or copy
`packer/config.pkrvars.hcl.example` to `packer/config.pkrvars.hcl` and edit it:

```powershell
$env:DFIR_ISO_URL    = '<fresh Win10 Enterprise eval ISO url>'
$env:DFIR_ISO_SHA256 = '<sha256 of that ISO>'
$env:DFIR_VM_DIR     = 'D:\dfir-lab-vm'   # build on a roomier drive
$env:DFIR_SKIP_BUILD = '1'                # set up + validate, but don't build yet
iwr https://raw.githubusercontent.com/project-dfir/dfir-vm/main/bootstrap.ps1 | iex
```

Default VM specs (override in the vars file): **4 vCPU / 8 GB RAM / 80 GB disk**.

---

## Status / what's left to wire

The **dfir-aio container reference** (`ghcr.io/zepedara/dfir-aio:v2` and the
split-parts release fallback) is the one thing pinned to the container's actual
publish. It lives in a single clearly-marked **WIRE-THIS** block at the top of
`scripts/20-dfir-aio.ps1`. Until the container is published the VM still builds
fully; the container just loads on first use once it's live. See `TESTPLAN.md`.
