build {
  name = "win10-gold"
  sources = ["source.proxmox.win10"]

  provisioner "powershell" {
    inline = [
      "Set-ExecutionPolicy Bypass -Force",
      "Invoke-WebRequest -Uri 'https://aka.ms/wslinstall' -OutFile 'C:\\Windows\\Temp\\setup.ps1'"
    ]
  }

  provisioner "powershell" {
    script = "scripts/win10_setup.ps1"
  }
}
