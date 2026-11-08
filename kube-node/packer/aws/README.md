# AWS Packer template

This template bakes an RKE2 node image as an AWS AMI. The base image is the AlmaLinux 10 AMI of the AlmaLinux OS Foundation. No seed step is needed.

The image has RKE2 and a minimal Cilium manifest. It does not have Argo CD. The RKE2 and Cilium versions come from `kube-node/versions/`. The Ansible role `rke2_bake_common` is the same role that the Proxmox build uses. The role `rke2_bake_aws` adds the AWS-only part.

## Prerequisites

- AWS credentials in the standard credential chain. If you use AWS SSO, run `aws sso login` first.
- The [Session Manager plugin for the AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on the build host.
- `aws`, `helm`, `packer`, `ansible` and `python3` with `PyYAML` on the build host.
- A build subnet that can reach the Systems Manager endpoints and the package repositories. The build instance has no public IP address by default.

The build connects to the instance over Session Manager. The instance needs no inbound security group rule. The connection is slower than plain SSH, because the build must open a new session after the reboot.

## Build an image

1. Run `cd kube-node/packer/aws`. Packer must run from this directory.
2. Run `cp aws.auto.pkrvars.hcl.example aws.auto.pkrvars.hcl`.
3. Edit `aws.auto.pkrvars.hcl`. Set `aws_region`. If the account has no default VPC, also set `vpc_id` and `subnet_id`.
4. Run `./build.sh .`.

`build.sh` does two things that `packer build` does not:

1. It reads the RKE2 version from `kube-node/versions/rke2-version.yaml`. To build with another version, run `PKR_VAR_k8s_version=v1.37.1+rke2r1 ./build.sh .`. Do not set `k8s_version` in `aws.auto.pkrvars.hcl`. That file outranks the environment.
2. It renders the Cilium manifest with `helm template` from `kube-node/versions/cilium-version.yaml` and `kube-node/helm-values/cilium-values.yaml`. The Proxmox build uses the same files.

The default build is for x86_64. For arm64, set both the architecture and the instance type as environment variables, because `build.sh` passes its arguments to `packer init`:

```bash
PKR_VAR_ami_architecture=arm64 PKR_VAR_instance_type=c7g.medium ./build.sh .
```

The instance type must be offered in `aws_region`. If it is not, set `instance_type` to a type of the same architecture that the region offers.

A real build needs an AWS account. The checks in this repository do not run it.

## The image name and tags

The name is `almalinux10-<architecture>-kube-image-<rke2 version>-<cilium version>-<date>-<suffix>`. The suffix is the `BUILD_ID` environment variable, or 8 random characters. The name is for people. Nothing checks it.

Every AMI has these tags: `kube-image`, `k8s-version`, `cilium-version`, `build-date`, `build-id`, `base-distro`, `architecture` and `source-ami-id`. All copies of one build share the same `build-id`. Use it to find the AMI in each region.

To use the image, set `os_image_ami_id` in the kube-compute AWS modules.

## Customizing the image

The defaults need no customization. If you need to customize the image, use the inputs below. Set them in `aws.auto.pkrvars.hcl`, or as `PKR_VAR_<name>` environment variables. Each example is a line in that file.

### Trust a private certificate authority

Use this if your nodes must trust a private certificate authority, for example because a registry or a proxy uses a certificate that it signed.

```hcl
trusted_ca_path = "/path/to/ca.pem"
```

The file must be a PEM certificate on the build host. The build installs it as `/etc/pki/ca-trust/source/anchors/trusted-ca.crt` and rebuilds the trust store. It does this before the first download, so it also covers a proxy that re-signs TLS. This is the same input as in the Proxmox build.

To use the image, set `trusted_ca_in_image = true` in the kube-compute node bootstrap module, together with `trusted_ca_pem`. The certificate then stays out of the cloud-init user data. The module still uses `trusted_ca_pem` for the TLS pin of containerd. The boot fails if the image does not have the file.

You can also leave the certificate out of the image. Set only `trusted_ca_pem` in kube-compute. Each node then receives the certificate in its user data when it boots. This option is easier to change. The image option keeps the certificate out of the user data.

### Choose the build network

```hcl
vpc_id                      = "vpc-0123456789abcdef0"
subnet_id                   = "subnet-0123456789abcdef0"
associate_public_ip_address = false
```

Set `vpc_id` and `subnet_id` together. Without them, the build uses the default VPC. The subnet must reach the Systems Manager endpoints and the package repositories, through a NAT gateway or VPC endpoints. If it cannot, set `associate_public_ip_address = true`.

### Use an instance profile

```hcl
iam_instance_profile = "my-build-profile"
```

By default, the build creates a temporary instance profile with only the Session Manager permissions. It deletes the profile at the end. If your account does not allow the build to create roles, give the name of an existing profile. The profile must allow Session Manager.

### Choose another base image

```hcl
base_ami_owners = ["123456789012"]
base_ami_name   = "my-almalinux-10-*"
```

The default is the newest AlmaLinux 10 AMI of the AlmaLinux OS Foundation (account `764336703387`). The base image must be AlmaLinux 10 or another RHEL 10 clone, because the Ansible role uses `dnf` and SELinux. To pin one image, set `base_ami_id = "ami-0123456789abcdef0"`. The ID replaces the name filter. The account in `base_ami_owners` must own the image.

### Use a proxy for the build

```hcl
build_proxy_url = "http://proxy.example.com:3128"
```

The build instance uses the proxy for its downloads. The setting is only in the build. It is not in the image. The URL shows in the build log, so do not put a password in it. If the proxy re-signs TLS, also set `trusted_ca_path`.

### Add tags, copy to other regions, encrypt and share

```hcl
extra_tags         = { Owner = "platform-team", CostCenter = "1234" }
region_replicas    = ["eu-west-1"]
encrypt_boot       = true
kms_key_id         = "alias/my-key"
region_kms_key_ids = { "eu-west-1" = "alias/my-key" }
ami_users          = ["123456789012"]
```

- `extra_tags` go on every resource of the build. They cannot replace the tags of the template.
- `region_replicas` copies the finished AMI, with its tags, to the listed regions. The build credentials need `ec2:CopyImage` and `ec2:CopySnapshot`.
- If the account enables EBS encryption by default, you do not need `encrypt_boot`. Use `encrypt_boot` and `kms_key_id` for a customer-managed key. A KMS key works in one region only. Give a key for each replica region in `region_kms_key_ids`.
- `ami_users` gives other accounts launch permission on the AMI and read access to its snapshot. If the AMI is encrypted, also share the KMS key with those accounts.

### Run your own playbook

Use this for anything the other inputs do not cover, for example extra packages or files.

```hcl
extra_playbook_path = "/path/to/extra.yml"
```

```yaml
- name: Extra packages
  hosts: all
  become: true
  tasks:
    - name: Install a tool
      ansible.builtin.dnf:
        name: htop
        state: present
```

The playbook runs after the base role and before the image cleanup. It can do what Ansible can do on the build instance: install packages, add files, change settings and run commands. It gets the same variables as the base role, for example `k8s_version`, `aws_region` and `build_proxy_url`.

The hook has limits:

- It runs on the build instance only. It cannot change the build template, the network or the AMI settings.
- It must set `become: true` itself.
- It must keep the Session Manager agent working and must not remove the build user. The build needs both until the cleanup.
- It must not change the RKE2 install or the Cilium manifest. Change the pin files instead.
- The cleanup runs after it. The cleanup removes the machine ID, the SSH host keys, the build SSH key and the cloud-init state. Changes to those do not reach the image.

## SELinux policy for node-exporter

The image loads a small SELinux module, so node-exporter can run confined on an SELinux-enforcing node. It adds the domain `node_exporter.process` and the file type `node_exporter.textfile_t`. A workload selects the domain with `seLinuxOptions.type: node_exporter.process`. Set this only after the image holds the module, or the pod does not start. The module is not compiled or loaded by the authors yet. For what it does and how to test it on one node first, see [the role README](../../ansible/roles/rke2_bake_common/README.md).


## Base image

The data source `amazon-ami.base` in `template.pkr.hcl` finds the newest AMI that matches `base_ami_owners`, `base_ami_name` and the architecture. The `source-ami-id` tag records the AMI that the build used. The role updates all packages, so the point release of the base image does not matter much.

## Profile a slow build

Run `../../scripts/build-profile.sh .` instead of `./build.sh .`. It adds Packer timestamps and Ansible task timings, and saves the full output in `build-logs/`. The script installs the `community.general` Ansible collection for the timings.

## Prune old images

Every build leaves an AMI and a snapshot. Packer does not remove them. `prune-images.sh` keeps the newest AMIs of one architecture in one region and deregisters the others with their snapshots. It only looks at AMIs that you own and that have the tag `kube-image=true`.

```bash
./prune-images.sh --region us-east-1 --architecture x86_64 --dry-run
./prune-images.sh --region us-east-1 --architecture x86_64 --keep 5 --yes
```

Run it once for each region and each architecture. A build can leave a temporary IAM role behind if its cleanup fails. Remove such roles by hand.

## Check without AWS

```bash
packer fmt -check .
packer init . && packer validate -var-file=../../tests/aws.pkrvars.hcl .
```
