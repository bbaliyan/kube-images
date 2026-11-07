#!/usr/bin/env bash
# Wrapper for 'packer build'. Why a script: Packer cannot split the single
# PROXMOX_VE_API_TOKEN value into the token ID and secret that the template needs,
# and it cannot re-read the token file. The kube-node build does the same.
# Run it from this directory: the Ansible playbook path is relative.
set -euo pipefail

test -f "$HOME/.kube-compute/proxmox" && source "$HOME/.kube-compute/proxmox"
test -f "$HOME/.kube-compute/proxmox-endpoint" && source "$HOME/.kube-compute/proxmox-endpoint"

# A *.auto.pkrvars.hcl entry outranks these variables, so do not set the three
# Proxmox credentials in that file.
if [ -n "${PROXMOX_VE_ENDPOINT:-}" ]; then
  export PKR_VAR_proxmox_url="${PROXMOX_VE_ENDPOINT}/api2/json"
fi
if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
  export PKR_VAR_proxmox_api_token_id="${PROXMOX_VE_API_TOKEN%%=*}"
  export PKR_VAR_proxmox_api_token_secret="${PROXMOX_VE_API_TOKEN#*=}"
fi

packer init .
packer build "$@" .
