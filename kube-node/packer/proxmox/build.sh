#!/usr/bin/env bash
# Wrapper for 'packer build': re-derives Proxmox credentials, resolves the
# k8s version, and renders the boot-time Cilium manifest before every build. The credentials come
# from the shared scripts/proxmox-env.sh.
set -euo pipefail

# shellcheck source=../../../scripts/proxmox-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/proxmox-env.sh"

# ---- k8s version resolution -------------------------------------------------
: "${KUBE_PLATFORM_REPO_URL:=https://github.com/bbaliyan/kube-platform.git}"
: "${KUBE_PLATFORM_REVISION:=main}"

# A PKR_VAR_* env var loses to a *.auto.pkrvars.hcl entry of the same name, so
# k8s_version must NOT be set in proxmox.auto.pkrvars.hcl - see README.md.
if [ -z "${PKR_VAR_k8s_version:-}" ]; then
  platform_versions_url="$(printf '%s' "${KUBE_PLATFORM_REPO_URL}" | sed -E 's#^https://github\.com/#https://raw.githubusercontent.com/#; s#\.git$##')/${KUBE_PLATFORM_REVISION}/platform/platform-versions/values.yaml"
  PKR_VAR_k8s_version="$(curl -fsSL "${platform_versions_url}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["k8sVersion"])')"
  export PKR_VAR_k8s_version
fi

# ---- Cilium manifest render (build host, not the VM being baked) ----------
cilium_version="$(python3 -c 'import yaml; print(yaml.safe_load(open("cilium-version.yaml"))["ciliumVersion"])')"
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

helm template cilium cilium \
  --repo https://helm.cilium.io/ \
  --version "${cilium_version}" \
  --namespace kube-system \
  --include-crds \
  -f helm-values/cilium-values.yaml \
  >"${render_dir}/cilium.yaml"

export PKR_VAR_rendered_manifests_dir="${render_dir}"

packer init "$@" # idempotent, so running it unconditionally removes a manual first-time step

build_args=("$@")
if [ "${PACKER_BUILD_TIMESTAMPS:-0}" = "1" ]; then
  build_args=("-timestamp-ui" "${build_args[@]}")
fi

# Not `exec`: the render_dir cleanup trap only runs on this shell's own exit.
packer build "${build_args[@]}"
