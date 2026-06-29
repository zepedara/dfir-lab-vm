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
      version = ">= 1.0.0"
    }
  }
}

# ----------------------------- Variables ------------------------------------

variable "iso_url" {
  type = string
  # ---------------------------------------------------------------------------
  # WIRE-THIS (optional): Microsoft rotates eval ISO download links periodically.
  # Default points at the Win10 Enterprise eval. If MS changes it, grab a fresh
  # link from https://www.microsoft.com/evalcenter/evaluate-windows-10-enterprise
  # and pass it:  packer build -var iso_url=... -var iso_checksum=sha256:...
  # or set $env:DFIR_ISO_URL / $env:DFIR_ISO_SHA256 before the one-liner.
  # ---------------------------------------------------------------------------
  default = "https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
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

build {
  name    = "dfir-lab-vm"
  sources = ["source.vmware-iso.dfir"]

  # 1. Enable WSL2 features (needs a reboot afterwards).
  provisioner "powershell" {
    script = "../scripts/00-wsl2.ps1"
  }
  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  # 2. Install Docker (docker engine inside the WSL2 Ubuntu distro).
  provisioner "powershell" {
    script = "../scripts/10-docker.ps1"
  }

  # 3. Load the dfir-aio container (GHCR pull, with split-parts release fallback).
  provisioner "powershell" {
    script            = "../scripts/20-dfir-aio.ps1"
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
  }

  # 4. Install Windows-native DFIR tools (EZ Tools, Chainsaw, Hayabusa).
  provisioner "powershell" {
    script = "../scripts/30-windows-tools.ps1"
  }

  # 5. Clone the dfir-training-lab to C:\dfir\lab.
  provisioner "powershell" {
    script = "../scripts/40-clone-lab.ps1"
  }

  # 6. Aliases, shortcuts, desktop README - make the walkthrough "just work".
  provisioner "powershell" {
    script = "../scripts/50-shortcuts-readme.ps1"
  }

  # 6a. Content growth paths: dfir-update (online) + dfir-import (offline pack).
  provisioner "powershell" {
    script = "../scripts/55-content-update.ps1"
  }

  # 6b. AIR-GAP verification + install the runtime offline self-test in the VM.
  provisioner "powershell" {
    script            = "../scripts/60-verify-offline.ps1"
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
  }

  # 7. Final tidy: clear temp, leave a build manifest.
  provisioner "powershell" {
    inline = [
      "Write-Host '[final] DFIR lab provisioning complete.'",
      "$null = New-Item -ItemType Directory -Force -Path C:\\dfir",
      "Set-Content -Path C:\\dfir\\BUILD-INFO.txt -Value \"DFIR Lab VM built $(Get-Date -Format o) by Packer (zepedara/dfir-lab-vm)\""
    ]
  }
}
