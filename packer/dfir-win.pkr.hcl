# =============================================================================
# DFIR Lab VM - Packer template (VMware Workstation Pro, vmware-iso builder)
# Builds a Windows 10 Enterprise EVALUATION VM, unattended, then provisions it
# into the full zepedara DFIR lab (WSL2 + dfir-aio container + EZ Tools +
# Chainsaw/Hayabusa + dfir-training-lab).
#
# Output: an importable VMware Workstation Pro VM (.vmx + .vmdk) under
#         packer/output-dfir-lab-vm/
#
# LEGAL: we download a FREE Microsoft Windows 10 Enterprise EVALUATION ISO.
#        We never redistribute Windows. You accept MS's eval licence at build.
# =============================================================================

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = "1.0.11"
    }
  }
}

# ----------------------------- Variables ------------------------------------

variable "iso_url" {
  type = string
  # ---------------------------------------------------------------------------
  # The one-liner (bootstrap.ps1) ALWAYS passes this via -var: it auto-resolves a
  # FRESH, currently-valid Windows 10 link from Microsoft at build time using the
  # vendored Fido helper (tools/Fido.ps1) - so you set nothing. The default below
  # is only a fallback for running `packer build` by hand WITHOUT -var; Microsoft
  # rotates these links so it WILL eventually 404. To run standalone, pass a fresh
  # link:  packer build -var iso_url=... -var iso_checksum=none .  (or set
  # $env:DFIR_ISO_URL before the one-liner to use your own / a local file:/// ISO).
  # NB: a RETAIL multi-edition Win10 x64 ISO is expected; autounattend.xml selects
  # the "Windows 10 Pro" edition. LEGAL: we never host Windows; it comes from MS.
  # ---------------------------------------------------------------------------
  default = "https://software.download.prss.microsoft.com/dbazure/Win10_22H2_English_x64v1.iso"
}

variable "iso_checksum" {
  type = string
  # If you change iso_url you MUST update this. "none" disables verification
  # (NOT recommended). Format: "sha256:<hex>".
  default = "none"
}

variable "vm_name" {
  type    = string
  default = "dfir-lab-vm"
}
variable "cpus" {
  type    = number
  default = 4
}
variable "memory" {
  type    = number
  default = 8192 # MB
}
variable "disk_size" {
  type    = number
  default = 81920 # MB (80 GB, thin)
}
variable "winrm_username" {
  type    = string
  default = "Analyst"
}
variable "winrm_password" {
  type      = string
  default   = "dfir"
  sensitive = true
}

# ----------------------------- Source ---------------------------------------

source "vmware-iso" "dfir" {
  vm_name          = var.vm_name
  output_directory = "output-${var.vm_name}"

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # Windows 10 64-bit. Workstation Pro guest id.
  guest_os_type = "windows9-64"
  version       = "19" # vmx hardware version; safe for recent Workstation Pro

  cpus                 = var.cpus
  memory               = var.memory
  disk_size            = var.disk_size
  disk_adapter_type    = "lsisas1068"
  disk_type_id         = "0" # single growable vmdk for easy import
  network_adapter_type = "e1000e"
  sound                = false
  usb                  = true

  # autounattend.xml is delivered as a secondary CD (label must be readable by
  # Windows Setup, which scans removable media for autounattend.xml at the root).
  cd_files = ["./http/autounattend.xml"]
  cd_label = "UNATTEND"

  # Communicator: WinRM (the unattend + first-logon script enable it).
  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "4h" # generous: covers full Windows install + first boot
  winrm_use_ssl  = false
  winrm_insecure = true

  # Boot: Win Setup shows "Press any key to boot from CD" - send a key.
  boot_wait    = "3s"
  boot_command = ["<spacebar>"]

  # Clean shutdown via the same admin creds.
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "30m"

  # Extra vmx knobs for a smooth headless Windows install on Workstation Pro.
  vmx_data = {
    "tools.syncTime"            = "TRUE"
    "time.synchronize.continue" = "TRUE"
    "RemoteDisplay.vnc.enabled" = "FALSE"
    "firmware"                  = "bios" # Win10 eval: legacy BIOS = no TPM/secureboot hassle
  }

  # -------------------------------------------------------------------------
  # Windows 11 note: to build Win11 instead, supply a Win11 Enterprise eval ISO
  # and switch to UEFI + vTPM by setting firmware="efi" and adding:
  #   "managedVM.autoAddVTPM" = "software"
  #   "vhv.enable"            = "TRUE"
  # plus an encrypted VM (Workstation requires encryption for vTPM). Win10 is the
  # default here precisely because it avoids that complexity.
  # -------------------------------------------------------------------------
}

# --------------------------- Build / provisioners ---------------------------
#
# 2026-08-25 AUDIT FIX (ISSUE-01 / ISSUE-02).
#
# What was wrong: this list ran 00/10/20/30/40/50/55/60 and NOTHING else, so the
# entire V3 native-first toolchain (Git-Bash, Python3+volatility3, oletools, the
# Didier Stevens suite, RegRipper + Parse::Win32Registry, Sleuth Kit, every bash
# shim, and all module 17-22 tooling) was never installed by any build. A fresh
# build therefore shipped lab CONTENT with no TOOLS - exactly the v2 failure
# V3_LESSONS.md was written to prevent. The shipped v4 image only worked because
# a separate A:\provision.ps1 ran the numbered scripts by hand; its transcript
# (recovered from C:\dfir-provision.log) is the sequence reproduced below.
#
# There is also now a real GATE: the build runs tools/validate_lab.sh in the
# guest and FAILS if any module is not demonstrably runnable. V3_LESSONS §8 asked
# for this and it was never wired up; the v4 build packaged with TWO provisioning
# steps having exited 1.
#
# The container path (00-wsl2 / 10-docker / 20-dfir-aio) is deliberately NOT in
# the default build: ghcr.io/zepedara/dfir-aio is 404 and the lab is native-first.

build {
  name    = "dfir-lab-vm"
  sources = ["source.vmware-iso.dfir"]

  # 1. Windows-native DFIR tools: EZ Tools, Chainsaw, Hayabusa, Sysinternals.
  provisioner "powershell" {
    script = "../scripts/30-windows-tools.ps1"
  }

  # 2. Native environment: Git-for-Windows (bash + coreutils + perl), Python 3.
  provisioner "powershell" {
    script = "../scripts/32-native-env.ps1"
  }

  # 3. The former-container tool set, installed natively (volatility3, oletools,
  #    Didier Stevens, Sleuth Kit, RegRipper, YARA, prefetch shim).
  provisioner "powershell" {
    script = "../scripts/34-native-tools.ps1"
  }

  # 4. The remaining native forensic tools + the canonical /opt/chainsaw path.
  provisioner "powershell" {
    script = "../scripts/35-native-forensic-tools.ps1"
  }

  # 5. Bash shims so every tool resolves by bare name in Git-Bash.
  provisioner "powershell" {
    script = "../scripts/36-shim.ps1"
  }

  # 6. Addon-module tooling (modules 17-22): Velociraptor, Zircolite, WxTCmd,
  #    hindsight, tshark, evtx_dump.
  provisioner "powershell" {
    script = "../scripts/36-addon-tools.ps1"
  }

  # 7. Clone the lab and bake in every module's data.
  provisioner "powershell" {
    script = "../scripts/40-clone-lab.ps1"
  }

  # 8. Aliases, shortcuts, desktop README.
  provisioner "powershell" {
    script = "../scripts/50-shortcuts-readme.ps1"
  }

  # 9. Content growth paths: dfir-update (online) + dfir-import (offline pack).
  provisioner "powershell" {
    script = "../scripts/55-content-update.ps1"
  }

  # 10. v5 fixes: Defender exclusions for the lab tree, the acp shim on PATH,
  #     non-expiring Analyst credentials, lab synced to main. Elevated.
  provisioner "powershell" {
    script            = "../scripts/45-v5-fixes.ps1"
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
  }

  # 11. THE GATE. Upload the harness and refuse to package unless every module is
  #     demonstrably runnable. `validate_lab.sh` exits non-zero on any FAIL and on
  #     any module it cannot validate, so a silently-skipped module fails the build.
  provisioner "file" {
    source      = "../tools/validate_lab.sh"
    destination = "C:/dfir/validate_lab.sh"
  }
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [
      "Write-Host '[gate] running the lab validation harness...'",
      "& 'C:\\dfir\\tools\\git\\bin\\bash.exe' -lc 'bash /c/dfir/validate_lab.sh /c/dfir/lab' | Tee-Object -FilePath C:\\dfir\\validation.log",
      "$verdict = Select-String -Path C:\\dfir\\validation.log -Pattern '^LAB_VALIDATION:' | Select-Object -Last 1",
      "Write-Host \"[gate] $verdict\"",
      "if ($verdict -notmatch 'LAB_VALIDATION: PASS') { throw '[gate] REFUSING TO PACKAGE - the lab is not demonstrably runnable. See C:\\dfir\\validation.log' }",
      "Write-Host '[gate] PASS - packaging allowed.'"
    ]
  }

  # 12. Final tidy + build manifest.
  provisioner "powershell" {
    inline = [
      "Write-Host '[final] DFIR lab provisioning complete.'",
      "$null = New-Item -ItemType Directory -Force -Path C:\\dfir",
      "Set-Content -Path C:\\dfir\\BUILD-INFO.txt -Value \"DFIR Lab VM built $(Get-Date -Format o) by Packer (project-dfir/dfir-vm)\""
    ]
  }
}
