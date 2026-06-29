# DFIR VM Kit - build a full DFIR lab VM with one PowerShell line

> Headline deliverable of the zepedara DFIR lab. Repo: **github.com/zepedara/dfir-lab-vm**

## The one-liner

Run in an **elevated PowerShell** on a Windows host with **VMware Workstation Pro**:

```powershell
iwr https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/bootstrap.ps1 | iex
```

That's it. ~30-60 minutes later you have a ready-to-use DFIR lab VM.

---

## Prerequisites (auto-checked by the bootstrap)

- **VMware Workstation Pro** on Windows (detected via `vmware.exe` / `vmrun.exe`; clear error if absent).
- **~30 GB free disk** (eval ISO ~5 GB + VM ~25 GB).
- **Hardware virtualization** (Intel VT-x / AMD-V) enabled.
- **Internet** access.
- **Admin / elevated** PowerShell.
- Packer is installed automatically if missing (winget -> choco -> direct zip).

---

## What the kit builds

A **Windows 10 Enterprise (Evaluation)** VMware Workstation Pro VM, fully provisioned:

| Layer | Contents |
|---|---|
| **OS** | Windows 10 Enterprise eval, user `Analyst` / `dfir`, OOBE skipped |
| **WSL2** | Ubuntu + Docker engine (no Docker Desktop / GUI login needed) |
| **Container** | `dfir-aio:v2` loaded into WSL Docker - the offline Linux DFIR toolbox |
| **Native tools** | Eric Zimmerman suite, Chainsaw, Hayabusa, Sysinternals - all on PATH |
| **Lab** | `dfir-training-lab` cloned to `C:\dfir\lab` (modules 01-10 + data) |
| **UX** | Desktop README (HTML) + shortcuts + a `dfir-aio` PowerShell helper |

Output: an importable **`.vmx` + `.vmdk`** under `packer/output-dfir-lab-vm/`.
Open it in Workstation Pro (**File -> Open**) and **Power On**.

---

## How it maps to the lab

The dfir-training-lab walkthrough is done **two ways from the same files** - the VM lets you do either per step:

| | Windows-native | Linux container |
|---|---|---|
| **How** | tools on PATH | `dfir-aio` helper -> `dfir-aio:v2` in WSL2 |
| **Module 1 (Prefetch)** | `PECmd -d .\data --csv .` | `dfir-aio .\data PECmd -d /data --csv /data` |
| **Module 6 (Sigma)** | `chainsaw` / `hayabusa` on PATH | `chainsaw hunt /data ...` inside the container |
| **Output** | CSVs - open in Timeline Explorer / Excel | same CSVs land in the mounted `/data` |

Helpers baked into the PowerShell profile: `dfir-lab` (go to the lab), `dfir-aio`
(launch the container mounting the current folder as `/data`), `dfir-wsl` (Ubuntu shell).

---

## Architecture

```
bootstrap.ps1  --(checks, installs Packer, clones kit)-->  packer build
       |
       v
 packer/dfir-win.pkr.hcl  (vmware-iso, Workstation Pro)
       |  downloads free Win10 Enterprise EVAL ISO
       |  http/autounattend.xml -> hands-free install + WinRM
       v  provisioners (inside the building VM):
   00-wsl2 -> [reboot] -> 10-docker -> 20-dfir-aio -> 30-windows-tools -> 40-clone-lab -> 50-shortcuts
       v
 output-dfir-lab-vm/dfir-lab-vm.vmx  (+ .vmdk)
```

---

## Legal & safety

- **No Windows redistribution.** The build downloads Microsoft's free *evaluation*
  ISO; you accept the eval licence at build time. The kit ships only scripts/config.
- **Educational / personal** use. The VM is a throwaway lab - change the default
  `Analyst/dfir` password if you keep it.
- **Reversible.** Everything lives under `%USERPROFILE%\dfir-lab-vm` and the VM's
  output folder; delete them to fully undo. Packer is the only host install.

---

## What's left to wire / test

- **dfir-aio container publish:** one WIRE-THIS block in `scripts/20-dfir-aio.ps1`
  (`ghcr.io/zepedara/dfir-aio:v2` + the `zepedara/dfir-drop` release split-parts
  fallback, tag `v2`, prefix `dfir-aio.part.`). The VM builds fully before publish;
  the container loads on first use afterward.
- **Eval ISO URL** may rotate - override via `$env:DFIR_ISO_URL` / `$env:DFIR_ISO_SHA256`.
- **End-to-end VMware build is Windows-only** - cannot run on rick. Final test must
  run on the user's box or l3e7 with VMware Workstation Pro. See `TESTPLAN.md`.
