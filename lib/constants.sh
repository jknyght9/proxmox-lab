#!/usr/bin/env bash

# =============================================================================
# constants.sh - Shared constants used across setup.sh library modules
# =============================================================================

# VM/LXC user accounts
VM_USER="labadmin"
LXC_USER="root"

# GlusterFS paths
GLUSTER_BRICK="/data/gluster"
GLUSTER_VOLUME="nomad-data"
NOMAD_DATA_DIR="/srv/gluster/nomad-data"

# Nomad job directories (on GlusterFS)
TRAEFIK_DIR="$NOMAD_DATA_DIR/traefik"
VAULT_DIR="$NOMAD_DATA_DIR/vault"
AUTHENTIK_DIR="$NOMAD_DATA_DIR/authentik"

# VM ID ranges - LXC containers
VMID_STEP_CA=902
VMID_NOMAD_START=905
VMID_NOMAD_END=907
VMID_DNS_START=910
VMID_DNS_END=912
VMID_LABNET_DNS_START=920
VMID_LABNET_DNS_END=922
VMID_KASM=930

# VM ID ranges - Packer templates
VMID_DOCKER_TEMPLATE=9001
VMID_NOMAD_TEMPLATE=9002
VMID_BASE_TEMPLATE=9999
