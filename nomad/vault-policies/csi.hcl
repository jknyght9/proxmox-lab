# Vault policy for the CSI plugin (csi-driver-nfs).
#
# Today the plugin reads no secrets — NFS export hosts + paths come in via
# each volume's mount_options, and there's no per-mount credential (we use
# IP allow-lists, not Kerberos). Policy is kept narrow and empty-ish so that
# future hardening (NFSv4+Kerberos, iSCSI+CHAP) can grant precisely what's
# needed without retrofitting the WIF wiring.

# Reserved: NAS credentials path. Empty grant for now; democratic-csi would
# need this if we swap in dynamic provisioning later.
path "secret/data/nas/*" {
  capabilities = []
}
