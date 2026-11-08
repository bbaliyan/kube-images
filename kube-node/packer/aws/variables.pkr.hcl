# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  type        = string
  description = "AWS region to build the AMI in, e.g. us-east-1."
}

variable "instance_type" {
  type        = string
  default     = "c7a.medium"
  description = "EC2 instance type of the build instance. It must support ami_architecture. The type must be offered in aws_region. It does not limit the instance types that can launch the AMI."
}

variable "ami_architecture" {
  type        = string
  default     = "x86_64"
  description = "CPU architecture to build for, x86_64 or arm64. It must match the architecture of instance_type."

  validation {
    condition     = contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "The value of ami_architecture must be x86_64 or arm64."
  }
}

variable "k8s_version" {
  type        = string
  description = "RKE2 release to bake, e.g. v1.37.2+rke2r1. build.sh reads it from versions/rke2-version.yaml. To override it, export PKR_VAR_k8s_version. Do not set it in aws.auto.pkrvars.hcl, because that file outranks the environment."
}

variable "rendered_manifests_dir" {
  type        = string
  description = "Directory with the pre-rendered cilium.yaml to copy onto the AMI. build.sh always sets it. It has no default, so a bare 'packer build' fails instead of baking a stale manifest."
}

variable "ssh_username" {
  type        = string
  default     = "ec2-user"
  description = "User that Packer and Ansible connect as. The default is right for AlmaLinux AMIs."
}

variable "ami_name" {
  type        = string
  default     = null
  description = "Overrides the computed AMI name. Leave it unset in normal use."
}

variable "build_id_override" {
  type        = string
  default     = env("BUILD_ID")
  description = "Suffix that makes the AMI name and the build-id tag unique. It comes from the BUILD_ID environment variable. If it is empty, the build picks a random 8-character suffix."
}

variable "base_ami_owners" {
  type        = list(string)
  default     = ["764336703387"]
  description = "AWS account IDs that own the base image. The default is the AlmaLinux OS Foundation account."
}

variable "base_ami_name" {
  type        = string
  default     = "AlmaLinux OS 10*"
  description = "Name filter for the base image. The newest match is used. The base image must be AlmaLinux 10 or another RHEL 10 clone."
}

variable "base_ami_id" {
  type        = string
  default     = ""
  description = "Exact base AMI ID, e.g. ami-0123456789abcdef0. If set, it replaces the name filter. The account in base_ami_owners must own it."

  validation {
    condition     = var.base_ami_id == "" || startswith(var.base_ami_id, "ami-")
    error_message = "The value of base_ami_id must be empty or start with ami-."
  }
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "VPC of the build instance. Set it together with subnet_id. If both are null, the build uses the default VPC."
}

variable "subnet_id" {
  type        = string
  default     = null
  description = "Subnet of the build instance. The instance must reach the Systems Manager endpoints and the package repositories."
}

variable "associate_public_ip_address" {
  type        = bool
  default     = false
  description = "Give the build instance a public IP address. The default is false, because the build connects over Systems Manager. Set it to true only if the subnet has no NAT or VPC endpoints."
}

variable "iam_instance_profile" {
  type        = string
  default     = ""
  description = "Name of an existing instance profile for the build instance. It must allow Systems Manager Session Manager. If empty, the build creates a temporary profile and deletes it at the end."
}

variable "build_proxy_url" {
  type        = string
  default     = ""
  description = "HTTP(S) proxy URL for the downloads of the build instance, e.g. http://proxy.example.com:3128. It is not kept in the image. The URL shows in the build log, so do not put a password in it."
}

variable "trusted_ca_path" {
  type        = string
  default     = ""
  description = "Path on the build host to a CA certificate in PEM format. The build adds it to the trust store of the image at /etc/pki/ca-trust/source/anchors/trusted-ca.crt, before any download. Set trusted_ca_in_image = true in kube-compute for nodes that boot the image."
}

variable "extra_playbook_path" {
  type        = string
  default     = ""
  description = "Path on the build host to an Ansible playbook that runs after the base role and before the image cleanup. See README.md, 'Customizing the image'."
}

variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Tags added to every resource of the build. They cannot replace the tags that the template sets."
}

variable "region_replicas" {
  type        = list(string)
  default     = []
  description = "Regions to copy the finished AMI into. Do not list aws_region. The regions must be enabled for the account, and the build credentials need ec2:CopyImage and ec2:CopySnapshot."
}

variable "encrypt_boot" {
  type        = bool
  default     = false
  description = "Encrypt the AMI snapshot. If false, the image keeps the encryption setting of the base image. The account default for EBS encryption still applies. Set it to true to use kms_key_id."
}

variable "kms_key_id" {
  type        = string
  default     = null
  description = "KMS key ID, ARN or alias to encrypt the AMI snapshot in aws_region. It applies only if encrypt_boot is true. If null, the default EBS key is used."
}

variable "region_kms_key_ids" {
  type        = map(string)
  default     = {}
  description = "KMS key per replica region, as { region = key }. It applies only if encrypt_boot is true. A key works in one region only, so each region in region_replicas that uses a customer-managed key needs an entry."
}

variable "ami_users" {
  type        = list(string)
  default     = []
  description = "AWS account IDs that get launch permission on the AMI and read access to its snapshot. If the AMI is encrypted, also share the KMS key with these accounts."
}
