<powershell>
# Kasm autoscale startup script -- AD-joined Windows pool.
#
# Inlined into a VM Provider Config's `startup_script` field by
# ../create-provider.sh. Kasm substitutes all six placeholders before
# injecting into cloudbase-init user-data.
#
# -DnsServers is required: the golden image's cloudbase-init has
# NetworkConfigPlugin removed (crashes on ip=dhcp), so ipconfig from
# Kasm doesn't apply. Windows DHCPs onto the LAN and gets an
# AD-unaware resolver. Init-VM-Task.ps1 sets DNS on the primary NIC
# before the domain join.

$Version = "1.18.0"
$Zip     = "kasm-windows-startup.zip"
$Url     = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasm-autoscale-scripts/$Version/$Zip"
$Wd      = $Env:Temp
$ProgressPreference = "SilentlyContinue"

Write-Output "`nInitiating Kasm Startup Script (AD-joined)"

Invoke-WebRequest -URI $Url -OutFile "$Wd\$Zip" -UseBasicParsing
Expand-Archive -Path "$Wd\$Zip" -DestinationPath $Wd -Force

& "$Wd\Init-VM-Task.ps1" `
  -KasmHostname             "{upstream_auth_address}" `
  -RegistrationToken        "{checkin_jwt}" `
  -ServerId                 "{server_id}" `
  -ServerName               "{server_hostname}" `
  -DomainName               "{domain}" `
  -ActiveDirectoryCredential "{ad_join_credential}" `
  -DnsServers               "10.10.0.3"
</powershell>
