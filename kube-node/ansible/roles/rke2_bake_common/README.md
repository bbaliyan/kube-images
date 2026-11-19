# rke2_bake_common

Bake tasks that the Proxmox and AWS node images share: OS preparation, and RKE2.

## The node-exporter SELinux module

An SELinux-enforcing node runs node-exporter as `container_t` by default. That domain cannot read `/proc/1/mountinfo` (label `init_t`) or the textfile directory (label `var_lib_t`). The module `files/node_exporter.cil` adds a small confined domain that can. The pod then needs neither `spc_t` nor `privileged`.

The module adds two things and changes no existing domain:

| Name | What it is |
|---|---|
| `node_exporter.process` | A container domain built from the udica templates in container-selinux. It can read `init_t` files and directories, and read `node_exporter.textfile_t`. |
| `node_exporter.textfile_t` | The file type of `/var/lib/node_exporter/textfile_collector`. The role sets it with `semanage fcontext`, so `restorecon` keeps it. |

During the bake the role does these steps:

1. If SELinux is disabled on the build host, the role prints a message and skips the module.
2. The role copies the module to `/usr/local/share/node_exporter.cil`.
3. The role runs `semodule -i` with `base_container.cil`, `net_container.cil` and the modules of this role. It runs only when a module changed or is not loaded.
4. The role creates the textfile directory, labels it and runs `restorecon`.

If the module does not compile, step 3 fails and the bake stops. A bad module cannot reach a running node.

### Check that it works

On a node built from the image, run these commands:

1. Run `semodule -l | grep node_exporter` and verify that the module is listed.
2. Run `ls -dZ /var/lib/node_exporter/textfile_collector` and verify that the type is `node_exporter.textfile_t`.
3. After a pod uses the domain, run `ps -eZ | grep node_exporter` and verify that the label contains `node_exporter.process`.
4. Verify that the exporter log shows no `permission denied` and that `node_filesystem_size_bytes` exists.

If an SELinux denial appears for the domain, add one specific rule for it to `files/node_exporter.cil`. Do not add a broad rule.

### Select the domain in the cluster

The image only loads the domain. The workload chooses it. In the node-exporter chart values set:

```yaml
containerSecurityContext:
  seLinuxOptions:
    type: node_exporter.process
```

Warning: set this only after the node image holds the module. If the type is not loaded, the container runtime cannot start the pod.

## The Agent Substrate SELinux module

Agent Substrate runs its pods as `container_t` by default. That domain cannot write the state directory `/var/lib/ate`, and the worker cannot set up the gVisor sandbox. The module `files/agent_substrate.cil` adds two confined domains that can. The pods then need no `spc_t`.

| Name | What it is |
|---|---|
| `agent_substrate.state_t` | The file type of `/var/lib/ate`. The module holds the file context, so `restorecon` keeps it. If the kubelet creates the directory, it gets this type too. |
| `agent_substrate.atelet.process` | The domain of the atelet pod and its objectstore-plugin sidecar. |
| `agent_substrate.worker.process` | The domain of a worker pod: the worker, runsc and the gVisor sandbox. |

Each domain has the rules of `container_t` and the rules that an audit in permissive mode logged for its pod. The role loads the module in the same `semodule -i` call as the node-exporter module, then creates `/var/lib/ate` and runs `restorecon`.

`make test-selinux-integration` builds both modules in an AlmaLinux 10 container. It verifies that the types exist, that the domains are container domains, and that the file contexts resolve. The container does not enforce SELinux, so the test cannot find a missing rule. Only a test on an enforcing node can.

### Select the domains in the cluster

Set `seLinuxOptions.type` to `agent_substrate.atelet.process` on the atelet pod and to `agent_substrate.worker.process` on the worker pods.

Warning: set this only after the node image holds the module. If the type is not loaded, the container runtime cannot start the pod.

If an SELinux denial appears for a domain, add one specific rule for it to `files/agent_substrate.cil`. Do not add a broad rule.
