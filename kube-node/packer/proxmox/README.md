# Proxmox Packer template

Bakes an RKE2 node image as a Proxmox VM template, cloned from a one-time seed
AlmaLinux 10 template.

## One-time setup: create the seed template

kube-images clones from an existing AlmaLinux 10 Proxmox template rather than
installing from ISO. Create it once per Proxmox cluster with the automated
`seed/` OpenTofu config (`kube-node/packer/proxmox/seed/`) — no manual Proxmox UI or
`qm` commands. Every subsequent `packer build` clones from the same seed.

Proxmox API credentials come from `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN`
(see the root README's "Proxmox credentials"). Uploading the vendor-data
snippet that installs `qemu-guest-agent` on the seed needs a separate SSH
connection to the Proxmox host itself:

**With an SSH key** (default: the dedicated `tofu` PAM user +
`~/.ssh/id_ed25519_tofu` — the same PVE-ops account this project's
`kube-examples` consumer repo already provisions; see its
`live/proxmox/README.md`, "One-time: user and token setup"):

```bash
cd seed
tofu init
tofu apply \
  -var proxmox_node=t630 \
  -var disk_datastore_id=nvme-pool \
  -var iso_datastore_id=local \
  -var proxmox_ssh_address=pve.lan
```

**No SSH key set up?** Pass a password instead — override `proxmox_ssh_user`
to whatever account you have a password for:

```bash
cd seed
tofu init
tofu apply \
  -var proxmox_node=t630 \
  -var disk_datastore_id=nvme-pool \
  -var iso_datastore_id=local \
  -var proxmox_ssh_address=pve.lan \
  -var proxmox_ssh_user=root \
  -var proxmox_ssh_password="$(read -srp 'PVE SSH password: ' p && echo "$p")"
```

(the subshell keeps the password out of shell history and `ps`;
`TF_VAR_proxmox_ssh_password` as an env var works too — never put it in a
committed `.tfvars` file.)

A few things to know before running either command:

- `iso_datastore_id` must support both the `import` and `snippets` content
  types. PVE directory-backed storage typically supports both, but
  `snippets` may need enabling separately (Datacenter → Storage → your
  datastore → Content).
- `os_image_url` defaults to the current AlmaLinux 10 GenericCloud image —
  override only for a different mirror or build.
- Note the `seed_template_vm_id` output — that's what
  `proxmox.auto.pkrvars.hcl` needs, below.

## Building

Run `packer` from inside this directory — the Ansible provisioner's
playbook path in `template.pkr.hcl` is relative to the current working
directory, not the repo root.

```bash
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit proxmox.auto.pkrvars.hcl: proxmox_node, seed_template_vm_id,
# disk_datastore_id
packer init .
./build.sh .
```

`build.sh` is a thin wrapper around `packer build`, not optional boilerplate
— it does three things a plain `packer build` can't:

1. Re-derives `proxmox_url`/`proxmox_api_token_id`/`proxmox_api_token_secret`
   from the current `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` right before
   building, so a token refreshed with `kube-proxmox-login` in the same
   terminal is always picked up (the devcontainer's own export only runs
   once, at shell start).
2. Reads `k8s_version` from `kube-node/versions/rke2-version.yaml`.
   **Do not** set it in `proxmox.auto.pkrvars.hcl`: a var-file entry
   outranks the `PKR_VAR_k8s_version` that `build.sh` exports and would
   silently defeat the pin.
3. Renders the boot-time Cilium manifest (`helm template`) into a temp
   dir, for the Ansible provisioner to copy onto the template. The chart
   version comes from `kube-node/versions/cilium-version.yaml`.

Building outside the devcontainer or without `build.sh`? Set `k8s_version`
in `proxmox.auto.pkrvars.hcl`, render the Cilium manifest yourself the way
`build.sh` does, and pass `-var rendered_manifests_dir=...` on the command
line. There is no default, so a bare `packer build` fails at once instead of
baking a stale or empty manifest.

## What the image holds

The image does not hold Argo CD. It holds a minimal Cilium manifest at
`/opt/kube-compute/manifests/cilium.yaml`. The node needs a CNI when RKE2
starts. kube-compute's `bootstrap.sh` copies the manifest into RKE2's
manifests directory. It deletes the copy when the `cilium` DaemonSet in
`kube-system` is Ready. At first boot, `bootstrap.sh` also downloads Argo CD
from kube-platform's published `argocd-bootstrap.yaml`.

The Cilium chart version is pinned in `kube-node/versions/cilium-version.yaml`.
Renovate updates it with a longer `minimumReleaseAge` than kube-platform's
Cilium rule, so the platform takes each release first. The values are in
`helm-values/cilium-values.yaml`. They give a working CNI and nothing more.
The platform manages Cilium after boot.

## Version pins

The image pins its own Cilium and RKE2. It does not read any other
repository. Both pins are in `kube-node/versions/`, shared by every
provider:

- `rke2-version.yaml` holds the RKE2 release.
- `cilium-version.yaml` holds the Cilium chart version.

To build one image with another RKE2 release, export it before the build:

```bash
export PKR_VAR_k8s_version=v1.37.1+rke2r1
./build.sh .
```

Renovate opens a pull request for each RKE2 patch release, 3 days after
the release. It does not open RKE2 minor or major updates by itself. They
wait on the Renovate dependency dashboard until the owner approves them.

To move to a new RKE2 minor release:

1. Upgrade the cluster to the new minor with the platform's upgrade plan.
2. Approve the update on the dependency dashboard, or edit
   `rke2-version.yaml`, and merge it.
3. Build the new image.

A new node from an image that is one patch release older than the cluster
works. A node from an image with a newer minor release than the cluster is
not supported. Do not build such an image before step 1 is done.

## Upgrade order

Rebuild the images first, then upgrade the kube-compute module. An image
built from this change works only with a kube-compute module that downloads
Argo CD itself. An older image with the new module, or a new image with the
old module, fails at first boot.

## Profiling a slow build

`./build-profile.sh .` runs the same build as `./build.sh .` with Packer/
Ansible timing instrumentation turned on, and tees the full output to
`build-logs/<timestamp>.log` for later review:

- `PACKER_BUILD_TIMESTAMPS=1` timestamps every Packer console line, so you
  can diff timestamps between phases (clone, SSH wait, provisioning,
  template conversion).
- `ANSIBLE_CALLBACKS_ENABLED=community.general.profile_tasks,community.general.timer`
  prints each Ansible task's duration as it finishes, plus a slowest-first
  summary and total playbook runtime at the end. `community.general` isn't
  part of `kube-devenv`'s bare `ansible-core` install (see its Dockerfile);
  the script installs it via `ansible-galaxy` before every run.

Both env vars can be overridden before calling the script if you want
different values; otherwise these are the defaults. Note that `shell`/
`command` module output (e.g. `dnf update -y`) is only visible once a task
finishes — Ansible doesn't stream it live regardless of verbosity. For
genuine real-time visibility into a single long-running task, SSH into the
build VM directly with the same `ssh_username`/keypair Packer uses (its IP
is printed early in the build log), or open its console from the Proxmox
UI, and tail e.g. `journalctl -f` or `/var/log/dnf.log` there.

## VM template naming

Self-descriptive:
`almalinux10-kube-image-<k8s_version>-<cilium_version>-<build-date>`.
Point `kube-compute`'s `proxmox-control-plane`/`proxmox-node-pool` modules
at the resulting template's numeric Proxmox VM ID via
`proxmox_template_vm_id`. The name is documentation only — kube-compute
performs no compatibility check against it.

Each template is also tagged `kube-image`, `template`, the sanitized
`k8s_version`, `almalinux10`, and `seed-vm-<seed_template_vm_id>` (the seed
this build cloned from — Proxmox has no queryable "resolved source", so the
seed VM ID is the closest fact worth recording).

## Pruning old builds

Every `packer build` leaves the previous template around — Packer has no
build history or artifact retention of its own. `prune-images.sh` finds
every VM tagged `kube-image;template` on a node, keeps the N most recent (by
the build date embedded in the name), and destroys the rest. It never
touches the seed (tagged `seed-template`, not `template`).

```bash
./prune-images.sh --node t630 --dry-run   # see what would be destroyed
./prune-images.sh --node t630             # keeps 3 by default, asks to confirm
./prune-images.sh --node t630 --keep 5 --yes   # non-interactive
```

Talks to the Proxmox API directly (no SSH needed), using the same
`PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` as the rest of this repo.

## Validating without a live Proxmox connection

```bash
packer fmt -check .
packer validate .
```
