#!/usr/bin/env bash
# Runs ./build.sh of the current directory with Packer and Ansible timings on,
# and saves the full output in build-logs/. Run it from a build directory:
#   cd kube-node/packer/<aws|proxmox> && ../../scripts/build-profile.sh .
set -euo pipefail

build_dir="$PWD"
[ -x "${build_dir}/build.sh" ] || {
  echo "Run this script from a directory that has build.sh." >&2
  exit 1
}
log_dir="${build_dir}/build-logs"
mkdir -p "${log_dir}"
log_file="${log_dir}/$(date -u +%Y%m%dT%H%M%SZ).log"

export PACKER_BUILD_TIMESTAMPS="${PACKER_BUILD_TIMESTAMPS:-1}"
# The timing callbacks are in community.general, which kube-devenv does not
# ship. Install it into a local directory and point Ansible at it.
collections_dir="${build_dir}/.ansible-collections"
mkdir -p "${collections_dir}"
ansible-galaxy collection install community.general -p "${collections_dir}" >/dev/null
export ANSIBLE_COLLECTIONS_PATH="${collections_dir}"
export ANSIBLE_CALLBACKS_ENABLED="${ANSIBLE_CALLBACKS_ENABLED:-community.general.profile_tasks,community.general.timer}"

# build.sh forwards $@ straight to 'packer init', which requires a TEMPLATE
# argument — default to the current directory, the usual `./build.sh .` call.
if [ "$#" -eq 0 ]; then
  set -- "."
fi

echo "Profiling build — full output also saved to ${log_file}" >&2

# Redirect through tee here, not with a pipe. With a pipe, Ctrl-C returns before
# Packer finishes its cleanup and leaves build resources behind.
exec > >(tee "${log_file}") 2>&1
"${build_dir}/build.sh" "$@"
