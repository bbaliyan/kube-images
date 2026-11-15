#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for the two prune-images.sh scripts. Stand-in aws and curl commands
# return a fixed list of images and log what the script asks them to delete.
# No cloud access is needed. Run from the repository root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AWS_PRUNE="$ROOT/kube-node/packer/aws/prune-images.sh"
PVE_PRUNE="$ROOT/kube-node/packer/proxmox/prune-images.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
LOG="$WORK/calls.log"
mkdir -p "$BIN"

# --- stand-in aws: four AMIs, listed out of order, each with one snapshot
cat >"$BIN/aws" <<'AWS'
#!/usr/bin/env bash
echo "aws $*" >>"$CALL_LOG"
case "$*" in
  *"describe-images --region"*"--owners self"*)
    printf 'ami-b\tname-b\t2026-02-01T00:00:00.000Z\n'
    printf 'ami-d\tname-d\t2026-04-01T00:00:00.000Z\n'
    printf 'ami-a\tname-a\t2026-01-01T00:00:00.000Z\n'
    printf 'ami-c\tname-c\t2026-03-01T00:00:00.000Z\n'
    ;;
  *"--image-ids "*)
    all_args="$*"
    id="${all_args#*--image-ids }"
    printf 'snap-%s\n' "${id%% *}"
    ;;
esac
AWS

# --- stand-in curl: a Proxmox node with templates, a seed, a plain VM and a template of another kind
cat >"$BIN/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$CALL_LOG"
case "$*" in
  *"-X DELETE"*) echo '{"data":"UPID:ok"}' ;;
  *)
    cat <<'JSON'
{"data":[
 {"vmid":201,"name":"almalinux10-kube-image-v1.9.0-rke2r1-2026-01-02","tags":"kube-image;template"},
 {"vmid":202,"name":"almalinux10-kube-node-v1.10.0-rke2r1-2026-03-04-ab12cd34","tags":"kube-image;template"},
 {"vmid":203,"name":"almalinux10-kube-node-v1.10.0-rke2r1-2026-03-04-ef56ab78","tags":"kube-image;template"},
 {"vmid":204,"name":"almalinux10-kube-image-v1.10.0-rke2r1-2026-02-01","tags":"kube-image;template"},
 {"vmid":108,"name":"almalinux10-seed-2099-01-01","tags":"kube-image;template;seed-template"},
 {"vmid":300,"name":"some-vm-2099-01-01","tags":""},
 {"vmid":301,"name":"other-template-2099-01-01","tags":"template"}
]}
JSON
    ;;
esac
CURL
chmod +x "$BIN/aws" "$BIN/curl"

export PATH="$BIN:$PATH"
export CALL_LOG="$LOG"
export PROXMOX_VE_ENDPOINT="https://pve.example.com:8006"
export PROXMOX_VE_API_TOKEN="user@pam!token=secret"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# run NAME EXPECTED_EXIT SCRIPT ARGS...: runs a script, keeps its output in $out and its exit code in $code
run() {
  : >"$LOG"
  set +e
  out="$(bash "${@:3}" 2>&1 </dev/null)"
  code=$?
  set -e
}
expect() { # name, command...: passes when the command succeeds
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
called() { grep -qF -- "$1" "$LOG"; }
not_called() { ! grep -qF -- "$1" "$LOG"; }
mentions() { grep -qF -- "$1" <<<"$out"; }

# --- AWS
aws_args=(--region eu-west-1 --architecture x86_64)

run aws 0 "$AWS_PRUNE" "${aws_args[@]}" --keep 2 --yes
expect "aws: exits 0" test "$code" -eq 0
expect "aws: deregisters the oldest AMI" called "deregister-image --region eu-west-1 --image-id ami-a"
expect "aws: deregisters the second oldest AMI" called "deregister-image --region eu-west-1 --image-id ami-b"
expect "aws: keeps the newest AMI" not_called "--image-id ami-d"
expect "aws: keeps the second newest AMI" not_called "--image-id ami-c"
expect "aws: deletes the snapshot of a removed AMI" called "delete-snapshot --region eu-west-1 --snapshot-id snap-ami-a"

run aws 0 "$AWS_PRUNE" "${aws_args[@]}" --keep 2 --dry-run
expect "aws dry run: exits 0" test "$code" -eq 0
expect "aws dry run: changes nothing" not_called "deregister-image"
expect "aws dry run: says so" mentions "--dry-run: no changes made."

run aws 0 "$AWS_PRUNE" "${aws_args[@]}" --keep 4 --yes
expect "aws: nothing to prune when the keep count covers all AMIs" not_called "deregister-image"

run aws 0 "$AWS_PRUNE" "${aws_args[@]}" --keep 0 --yes
expect "aws: --keep 0 fails" test "$code" -ne 0
expect "aws: --keep 0 makes no call" test ! -s "$LOG"

run aws 0 "$AWS_PRUNE" "${aws_args[@]}" --keep many --yes
expect "aws: a --keep that is not a number fails" test "$code" -ne 0

run aws 0 "$AWS_PRUNE" --region
expect "aws: an option with no value fails" test "$code" -ne 0
expect "aws: an option with no value is named" mentions "--region needs a value"

run aws 0 "$AWS_PRUNE" --region eu-west-1
expect "aws: --architecture is required" test "$code" -ne 0

# --- Proxmox
run pve 0 "$PVE_PRUNE" --node pve1 --keep 2 --yes
expect "proxmox: exits 0" test "$code" -eq 0
expect "proxmox: keeps both builds of the newest day" not_called "qemu/202"
expect "proxmox: keeps both builds of the newest day (second)" not_called "qemu/203"
expect "proxmox: removes the older template with the newer RKE2 version" called "-X DELETE"
expect "proxmox: removes VM 204" called "qemu/204"
expect "proxmox: removes VM 201" called "qemu/201"
expect "proxmox: never touches the seed" not_called "qemu/108"
expect "proxmox: never touches a VM without the tags" not_called "qemu/300"
expect "proxmox: never touches a template of another kind" not_called "qemu/301"

# v1.9 sorts after v1.10 by name, but the date decides: with --keep 3, VM 201 (January) is the one that goes.
run pve 0 "$PVE_PRUNE" --node pve1 --keep 3 --yes
expect "proxmox: the date decides, not the RKE2 version" called "qemu/201"
expect "proxmox: --keep 3 keeps VM 204" not_called "qemu/204"

run pve 0 "$PVE_PRUNE" --node pve1 --keep 1 --dry-run
expect "proxmox dry run: changes nothing" not_called "-X DELETE"

run pve 0 "$PVE_PRUNE" --node pve1 --keep 0 --yes
expect "proxmox: --keep 0 fails" test "$code" -ne 0
expect "proxmox: --keep 0 makes no call" test ! -s "$LOG"

run pve 0 "$PVE_PRUNE" --node
expect "proxmox: an option with no value fails" test "$code" -ne 0

run pve 0 "$PVE_PRUNE" --keep 2
expect "proxmox: --node is required" test "$code" -ne 0

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
