#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Loads the SELinux modules of rke2_bake_common into the policy store of an
# AlmaLinux 10 container, the same way the role does, then asserts that the
# types exist, that the domains are container domains, and that the file
# contexts resolve. The container has SELinux disabled, so the policy is built
# but not enforced: denials on a real node are covered only by a node test.
#
# This needs a Docker daemon. Inside the kube-devenv image there is none, so the
# script skips there; run it on a host with Docker: make test-selinux-integration
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
files_dir="${here}/../ansible/roles/rke2_bake_common/files"
image="${SELINUX_TEST_IMAGE:-almalinux:10}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  if [ "${SELINUX_REQUIRE_DOCKER:-0}" = "1" ]; then
    echo "FAIL: this test needs a Docker daemon" >&2
    exit 1
  fi
  echo "skip: no Docker daemon here. Run this on a host with Docker: make test-selinux-integration"
  exit 0
fi

# Mounting from a Docker-in-Docker path would not work, so copy the files in with a pipe.
name="selinux-modules-test-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" "$image" sleep 3600 >/dev/null
tar -C "$files_dir" -c node_exporter.cil agent_substrate.cil |
  docker exec -i "$name" bash -c 'mkdir -p /usr/local/share && tar -C /usr/local/share -x'

docker exec -i "$name" bash -s <<'INNER'
set -euo pipefail
dnf -y -q install container-selinux policycoreutils libselinux-utils setools-console >/dev/null

# The same command as the role task "load the policy modules with the udica templates".
semodule -i \
  /usr/share/udica/templates/base_container.cil \
  /usr/share/udica/templates/net_container.cil \
  /usr/local/share/node_exporter.cil \
  /usr/local/share/agent_substrate.cil

policy="$(ls /etc/selinux/targeted/policy/policy.*)"
fail=0
expect() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: got '$2', want '$3'" >&2
    fail=1
  fi
}

modules="$(semodule -l)"
for module in node_exporter agent_substrate; do
  expect "module ${module} is loaded" "$(grep -cx "${module}" <<<"${modules}")" 1
done

for type in node_exporter.textfile_t agent_substrate.state_t; do
  expect "file type ${type} exists" "$(seinfo "$policy" -t "$type" | grep -c "^   ${type}$")" 1
done

# The container runtime can start a pod with seLinuxOptions.type only in a
# container domain that the system_r role may enter.
for domain in node_exporter.process agent_substrate.atelet.process agent_substrate.worker.process; do
  attrs="$(seinfo "$policy" -t "$domain" -x)"
  for attr in container_domain mcs_constrained_type; do
    expect "${domain} has ${attr}" "$(grep -c "[ ,]${attr}[,;]" <<<"${attrs}")" 1
  done
  expect "system_r may enter ${domain}" "$(seinfo "$policy" -r system_r -x | grep -cw "$domain")" 1
done

for path in /var/lib/ate /var/lib/ate/actors/example/rootfs; do
  expect "file context of ${path}" "$(selabel_lookup -b file -k "$path" | awk '{print $3}')" system_u:object_r:agent_substrate.state_t:s0
done

expect "the kubelet labels a new /var/lib/ate as agent_substrate.state_t" \
  "$(sesearch "$policy" -T -s container_runtime_t -t var_lib_t -c dir | grep -c 'dir agent_substrate.state_t ate;')" 1

exit "$fail"
INNER
