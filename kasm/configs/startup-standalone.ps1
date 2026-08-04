<powershell>
# Kasm autoscale startup script -- non-domain-joined Windows pool.
#
# Inlined into a VM Provider Config's `startup_script` field by
# ../create-provider.sh. Kasm substitutes {upstream_auth_address},
# {checkin_jwt}, {server_id}, {server_hostname} before injection into
# cloudbase-init user-data.

$Version = "1.18.0"  # match Kasm deployment; verify what's in the S3 bucket
$Zip     = "kasm-windows-startup.zip"
$Url     = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasm-autoscale-scripts/$Version/$Zip"
$Wd      = $Env:Temp
$ProgressPreference = "SilentlyContinue"

Write-Output "`nInitiating Kasm Startup Script (standalone)"

Invoke-WebRequest -URI $Url -OutFile "$Wd\$Zip" -UseBasicParsing
Expand-Archive -Path "$Wd\$Zip" -DestinationPath $Wd -Force

& "$Wd\Init-VM-Task.ps1" `
  -KasmHostname      "{upstream_auth_address}" `
  -RegistrationToken "{checkin_jwt}" `
  -ServerId          "{server_id}" `
  -ServerName        "{server_hostname}" `
  -RenameComputer
</powershell>
