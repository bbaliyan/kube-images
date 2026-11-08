#!/usr/bin/env bash
# Wrapper for 'packer build': reads the RKE2 version from the shared pin file
# and renders the boot-time Cilium manifest before every build.
set -euo pipefail

# ---- version pins ------------------------------------------------------------
kube_node_dir="$(dirname "${BASH_SOURCE[0]}")/../.."
versions_dir="${kube_node_dir}/versions"

pin() { # pin <file> <key>
  python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))[sys.argv[2]])' "${versions_dir}/$1" "$2"
}

# A PKR_VAR_* env var loses to a *.auto.pkrvars.hcl entry of the same name, so
# k8s_version must NOT be set in aws.auto.pkrvars.hcl - see README.md.
if [ -z "${PKR_VAR_k8s_version:-}" ]; then
  PKR_VAR_k8s_version="$(pin rke2-version.yaml rke2Version)"
  export PKR_VAR_k8s_version
fi

# ---- Cilium manifest render (build host, not the instance being baked) ----
cilium_version="$(pin cilium-version.yaml ciliumVersion)"
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

helm template cilium cilium \
  --repo https://helm.cilium.io/ \
  --version "${cilium_version}" \
  --namespace kube-system \
  --include-crds \
  -f "${kube_node_dir}/helm-values/cilium-values.yaml" \
  >"${render_dir}/cilium.yaml"

export PKR_VAR_rendered_manifests_dir="${render_dir}"

packer init "$@" # idempotent, so running it unconditionally removes a manual first-time step

build_args=("$@")
if [ "${PACKER_BUILD_TIMESTAMPS:-0}" = "1" ]; then
  build_args=("-timestamp-ui" "${build_args[@]}")
fi

# Not `exec`: the render_dir cleanup trap only runs on this shell's own exit.
packer build "${build_args[@]}"
