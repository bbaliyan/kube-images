# SPDX-License-Identifier: Apache-2.0
packer {
  required_plugins {
    amazon = {
      # Version 1.4.0 and later run a DryRun RunInstances without a subnet
      # when they check the instance profile. That always fails in an account
      # with no default VPC.
      version = ">= 1.3.3, < 1.4.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  build_date       = formatdate("YYYY-MM-DD", timestamp())
  distro_slug      = "almalinux10" # bump alongside the default base_ami_name
  k8s_version_safe = replace(var.k8s_version, "+", "-")
  cilium_version   = yamldecode(file("${path.root}/../../versions/cilium-version.yaml")).ciliumVersion
  # A random suffix keeps two builds on the same day apart.
  build_suffix = var.build_id_override != "" ? var.build_id_override : substr(uuidv4(), 0, 8)
  # Identifies one build in every region it is copied to.
  build_id = "${local.build_date}-${local.build_suffix}"
  # The architecture is in the name so an x86_64 and an arm64 build of the same
  # day do not collide. AMI names are unique per account and region.
  image_name = coalesce(var.ami_name, "${local.distro_slug}-${var.ami_architecture}-kube-image-${local.k8s_version_safe}-${local.cilium_version}-${local.build_date}-${local.build_suffix}")

  # extra_tags comes last in merge(), so the fixed tags win.
  common_tags = merge(var.extra_tags, {
    Name           = local.image_name
    kube-image     = "true"
    k8s-version    = local.k8s_version_safe
    cilium-version = local.cilium_version
    build-date     = local.build_date
    build-id       = local.build_id
    base-distro    = local.distro_slug
    architecture   = var.ami_architecture
    source-ami-id  = data.amazon-ami.base.id
  })
  snapshot_tags = merge(var.extra_tags, {
    Name         = local.image_name
    kube-image   = "true"
    build-id     = local.build_id
    architecture = var.ami_architecture
  })

  # Ansible resolves relative paths against the playbook directory, so both
  # paths are made absolute here.
  extra_playbook  = var.extra_playbook_path != "" ? abspath(var.extra_playbook_path) : ""
  trusted_ca_path = var.trusted_ca_path != "" ? abspath(var.trusted_ca_path) : ""
}

# A data source, not an inline filter, so the ID is known for the source-ami-id tag.
data "amazon-ami" "base" {
  region      = var.aws_region
  owners      = var.base_ami_owners
  most_recent = true
  filters = merge(
    {
      architecture        = var.ami_architecture
      virtualization-type = "hvm"
      state               = "available"
    },
    var.base_ami_id != "" ? { image-id = var.base_ami_id } : { name = var.base_ami_name },
  )
}

source "amazon-ebs" "rke2" {
  region                      = var.aws_region
  instance_type               = var.instance_type
  source_ami                  = data.amazon-ami.base.id
  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip_address

  # gp3 has its full baseline speed at once. The gp2 default needs time to
  # build up burst credit, and the package update writes a lot.
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    delete_on_termination = true
  }

  ami_name        = local.image_name
  ami_description = "RKE2 ${var.k8s_version} / Cilium ${local.cilium_version}, baked ${local.build_date} from ${data.amazon-ami.base.id}"
  tags            = local.common_tags
  snapshot_tags   = local.snapshot_tags
  # The copies carry the tags of the AMI.
  ami_regions = var.region_replicas
  # Tags on the build instance and its volumes, for cost reports.
  run_tags        = local.common_tags
  run_volume_tags = local.common_tags

  # null keeps the encryption setting of the base image. false would force an
  # unencrypted AMI.
  encrypt_boot       = var.encrypt_boot ? true : null
  kms_key_id         = var.encrypt_boot ? var.kms_key_id : null
  region_kms_key_ids = var.encrypt_boot ? var.region_kms_key_ids : null
  ami_users          = var.ami_users
  snapshot_users     = var.ami_users

  ssh_username = var.ssh_username
  # Session Manager needs no inbound security group rule and no network path
  # from the build host to the instance. The build host needs the
  # session-manager-plugin binary. A reconnect after the reboot is slower
  # than over plain SSH.
  ssh_interface = "session_manager"
  # The default RSA key of Packer uses a SHA-1 signature, which the default
  # crypto policy of AlmaLinux 10 rejects.
  temporary_key_pair_type = "ed25519"

  iam_instance_profile = var.iam_instance_profile != "" ? var.iam_instance_profile : null
  # Without an instance profile of your own, the build creates one with only
  # the Session Manager permissions and deletes it at the end.
  dynamic "temporary_iam_instance_profile_policy_document" {
    for_each = var.iam_instance_profile == "" ? [1] : []
    content {
      Version = "2012-10-17"
      Statement {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ssm:UpdateInstanceInformation",
          "ec2messages:GetMessages",
          "ec2messages:AcknowledgeMessage",
        ]
        Resource = ["*"]
      }
    }
  }
}

build {
  name    = "rke2-aws"
  sources = ["source.amazon-ebs.rke2"]

  provisioner "ansible" {
    playbook_file = "../../ansible/playbook-aws.yml"
    user          = var.ssh_username
    # use_proxy stays true. There is no direct IP path to the instance, so
    # Packer's own proxy must reopen the Session Manager tunnel after the reboot.
    ansible_env_vars = ["ANSIBLE_PIPELINING=True"]
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_manifests_dir=${var.rendered_manifests_dir}",
      "--extra-vars", "aws_region=${var.aws_region}",
      "--extra-vars", "trusted_ca_path=${local.trusted_ca_path}",
      "--extra-vars", "build_proxy_url=${var.build_proxy_url}",
      "--extra-vars", "extra_playbook_path=${local.extra_playbook}",
    ]
  }
}
