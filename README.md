# dfir-lab-vm

**One PowerShell line on your Windows host builds a complete DFIR lab VM.**

```powershell
iwr https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/bootstrap.ps1 | iex
```

Run that in an **elevated PowerShell** on a Windows host that has **VMware Workstation
Pro**. It uses [HashiCorp Packer](https://www.packer.io/) to build a **Windows 10 +
WSL2** virtual machine that comes preloaded with the entire **zepedara DFIR lab**:

- the **[dfir-aio](https://github.com/zepedara/dfir-drop)** offline container (in WSL2 Docker),
- **Eric Zimmerman's tools** (PECmd, EvtxECmd, AppCompatCacheParser, AmcacheParser, MFTECmd, ...),
- **Chainsaw** + **Hayabusa** (Windows builds) + Sysinternals,
- the **[dfir-training-lab](https://github.com/zepedara/dfir-training-lab)** walkthrough at `C:\dfir\lab`.

Boot the VM and follow the lab natively - using **both** Windows-native tools **and**
the Linux `dfir-aio:v2` container.

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
Windows 10 Enterprise (Evaluation)  -  Analyst / dfir
 |- WSL2 + Ubuntu + Docker engine
 |     '- dfir-aio:v2 container loaded (offline DFIR toolbox)
 |- C:\dfir\tools   EZ Tools, Chainsaw, Hayabusa, Sysinternals  (on PATH)
 |- C:\dfir\lab     dfir-training-lab (modules 01-10 + data)
 '- Desktop\DFIR-LAB-README.html + shortcuts + a `dfir-aio` PowerShell helper
```

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
|   |- 30-windows-tools.ps1      # EZ Tools + Chainsaw + Hayabusa + Sysinternals
|   |- 40-clone-lab.ps1          # clone dfir-training-lab to C:\dfir\lab
|   '- 50-shortcuts-readme.ps1   # aliases, shortcuts, desktop README
|- docs/DFIR_VM_KIT.md           # full kit doc
|- TESTPLAN.md                   # how to validate + the end-to-end test plan
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
iwr https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/bootstrap.ps1 | iex
```

Default VM specs (override in the vars file): **4 vCPU / 8 GB RAM / 80 GB disk**.

---

## Status / what's left to wire

The **dfir-aio container reference** (`ghcr.io/zepedara/dfir-aio:v2` and the
split-parts release fallback) is the one thing pinned to the container's actual
publish. It lives in a single clearly-marked **WIRE-THIS** block at the top of
`scripts/20-dfir-aio.ps1`. Until the container is published the VM still builds
fully; the container just loads on first use once it's live. See `TESTPLAN.md`.
