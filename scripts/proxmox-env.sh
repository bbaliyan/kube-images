#!/usr/bin/env bash
# Sourced by the Packer build wrappers of every image. Why a script: Packer cannot
# split the single PROXMOX_VE_API_TOKEN value into the token ID and secret, and
# it cannot re-read the token file after 'kube-proxmox-login' refreshes it.
# A *.auto.pkrvars.hcl entry outranks these variables, so do not set the three
# Proxmox credentials in that file.

test -f "$HOME/.kube-compute/proxmox" && source "$HOME/.kube-compute/proxmox"
test -f "$HOME/.kube-compute/proxmox-endpoint" && source "$HOME/.kube-compute/proxmox-endpoint"

if [ -n "${PROXMOX_VE_ENDPOINT:-}" ]; then
  export PKR_VAR_proxmox_url="${PROXMOX_VE_ENDPOINT}/api2/json"
fi
if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
  export PKR_VAR_proxmox_api_token_id="${PROXMOX_VE_API_TOKEN%%=*}"
  export PKR_VAR_proxmox_api_token_secret="${PROXMOX_VE_API_TOKEN#*=}"
fi
