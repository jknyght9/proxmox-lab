# Allow PowerShell execution
Set-ExecutionPolicy Bypass -Force

# Enable WinRM
winrm quickconfig -q
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
winrm set winrm/config '@{MaxTimeoutms="1800000"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# Optional updates
Install-WindowsUpdate -AcceptAll -AutoReboot

# Optional Docker install (if required)
# Install-Module -Name DockerMsftProvider -Repository PSGallery -Force
# Install-Package -Name docker -ProviderName DockerMsftProvider -Force

# Generalize image for cloning
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /shutdown
