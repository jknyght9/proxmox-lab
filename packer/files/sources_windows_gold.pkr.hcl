packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
  }
}

variable "win_iso"     { type = string, default = "/var/lib/vz/template/iso/Win10_22H2_English_x64.iso" }
variable "virtio_iso"  { type = string, default = "/var/lib/vz/template/iso/virtio-win.iso" }
variable "admin_pass"  { type = string, sensitive = true, default = "ChangeMe123!" }

source "qemu" "win10" {
  accelerator        = "kvm"
  iso_url            = var.win_iso
  iso_checksum       = "none" # set a real sha256 if you want verification
  shutdown_command   = "a:/sysprep-shutdown.cmd" # we’ll map a floppy later with sysprep script

  cpus               = 2
  memory             = 4096
  disk_size          = "40G"
  format             = "qcow2"
  headless           = true
  machine_type       = "q35"

  # Attach the VirtIO drivers & our answer file
  cd_files           = [
    "${path.root}/http/autounattend.xml"
  ]
  cd_label           = "cidata" # makes it show up as a secondary CD (optional)

  # Second CD for VirtIO drivers
  boot_wait          = "5s"
  qemuargs = [
    ["-device", "virtio-net,netdev=user.0"],
    ["-netdev", "user,id=user.0"],
    ["-drive", "file=${var.virtio_iso},media=cdrom,index=3"]
  ]

  # Serve autounattend over HTTP as well (some setups prefer this)
  http_directory     = "${path.root}/http"

  communicator       = "winrm"
  winrm_username     = "Administrator"
  winrm_password     = var.admin_pass
  winrm_timeout      = "2h"

  # VirtIO disk + NIC
  disk_interface     = "virtio"
  net_device         = "virtio-net"
}

build {
  name    = "win10-golden"
  sources = ["source.qemu.win10"]

  provisioner "powershell" {
    script = "files/scripts/enable-winrm.ps1"
  }
  provisioner "powershell" {
    script = "files/scripts/enable-rdp.ps1"
  }

  # Generalize and shut down via unattend
  provisioner "powershell" {
    script = "files/scripts/sysprep-shutdown.ps1"
    pause_before = "10s"
  }

  post-processor "manifest" {
    output = "manifest.json"
  }
}