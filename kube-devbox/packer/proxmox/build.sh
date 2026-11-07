#!/usr/bin/env bash
# Wrapper for 'packer build'. Run it from this directory: the Ansible playbook
# path is relative.
set -euo pipefail

# shellcheck source=../../../scripts/proxmox-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/proxmox-env.sh"

packer init .
packer build "$@" .
