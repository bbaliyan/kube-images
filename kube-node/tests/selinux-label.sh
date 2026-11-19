#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runs the file-context command of the rke2_bake_common role for /var/lib/ate
# in an AlmaLinux 10 container, then asserts that the context resolves to
# container_file_t at level s0. The container does not enforce SELinux, so
# this verifies the rule only, not access on a node.
# Needs a Docker daemon: make test-selinux-integration
set -euo pipefail

image="${SELINUX_TEST_IMAGE:-almalinux:10}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "FAIL: this test needs a Docker daemon" >&2
  exit 1
fi

name="selinux-label-test-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" "$image" sleep 600 >/dev/null

docker exec -i "$name" bash -s <<'INNER'
set -euo pipefail
dnf -y -q install container-selinux policycoreutils-python-utils libselinux-utils >/dev/null
semanage fcontext -a -t container_file_t -r s0 '/var/lib/ate(/.*)?'
want=system_u:object_r:container_file_t:s0
for path in /var/lib/ate /var/lib/ate/x; do
  got="$(selabel_lookup -b file -k "$path" | awk '{print $3}')"
  if [ "$got" != "$want" ]; then
    echo "FAIL: ${path}: got '${got}', want '${want}'" >&2
    exit 1
  fi
  echo "ok: ${path} resolves to ${want}"
done
INNER
