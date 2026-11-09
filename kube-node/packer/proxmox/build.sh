#!/usr/bin/env bash
# Wrapper for 'packer build': re-derives Proxmox credentials and requires
# the RKE2 version from the builder before every build. The credentials come
# from the shared scripts/proxmox-env.sh.
set -euo pipefail

# shellcheck source=../../../scripts/proxmox-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/proxmox-env.sh"

# ---- RKE2 version ------------------------------------------------------------
# The image keeps no version pin. The builder supplies the RKE2 release that the
# cluster's platform ref sets as k8sVersion.
if [ -z "${PKR_VAR_k8s_version:-}" ]; then
  echo "Set PKR_VAR_k8s_version to the k8sVersion of the platform ref, for example v1.37.1+rke2r1." >&2
  exit 1
fi
# A PKR_VAR_* env var loses to a *.auto.pkrvars.hcl entry of the same name, so
# k8s_version must NOT be set in the pkrvars file - see README.md.

packer init "$@" # idempotent, so running it unconditionally removes a manual first-time step

build_args=("$@")
if [ "${PACKER_BUILD_TIMESTAMPS:-0}" = "1" ]; then
  build_args=("-timestamp-ui" "${build_args[@]}")
fi

packer build "${build_args[@]}"
