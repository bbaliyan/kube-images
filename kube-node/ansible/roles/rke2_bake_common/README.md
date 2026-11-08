# rke2_bake_common

Bake tasks that the Proxmox and AWS node images share: OS preparation, RKE2 and the bootstrap program.

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
3. The role runs `semodule -i` with `base_container.cil`, `net_container.cil` and the module. It runs only when the module changed or is not loaded.
4. The role creates the textfile directory, labels it and runs `restorecon`.

If the module does not compile, step 3 fails and the bake stops. A bad module cannot reach a running node.

The authors did not compile or load this module. `secilc` is not in the dev box or in the kube-devenv image, so no check compiles it. Test it on one node first.

### Test the module on one node

Run these steps as an operator on one node that you can rebuild. They are reversible.

1. Copy `files/node_exporter.cil` to the node.
2. Run `semodule -i /usr/share/udica/templates/base_container.cil /usr/share/udica/templates/net_container.cil node_exporter.cil`.
3. If `semodule` reports an error, stop. Run `semodule -r node_exporter base_container net_container` to undo, and report the error.
4. Run `semodule -l | grep node_exporter` and verify that the module is listed.
5. Run `semanage fcontext -a -t node_exporter.textfile_t '/var/lib/node_exporter/textfile_collector(/.*)?'`.
6. Run `mkdir -p /var/lib/node_exporter/textfile_collector && restorecon -Rv /var/lib/node_exporter`.
7. Run `ls -dZ /var/lib/node_exporter/textfile_collector` and verify that the type is `node_exporter.textfile_t`.
8. Set `seLinuxOptions.type: node_exporter.process` on the node-exporter pod (see the next section) and run `ps -eZ | grep node_exporter`.
9. Verify that the exporter log shows no `permission denied` and that `node_filesystem_size_bytes` exists.
10. If an AVC denial appears, add one specific rule for it. Do not add a broad rule.
11. To undo, run `semanage fcontext -d '/var/lib/node_exporter/textfile_collector(/.*)?'` and `semodule -r node_exporter base_container net_container`.

### Select the domain in the cluster

The image only loads the domain. The workload chooses it. In the node-exporter chart values set:

```yaml
containerSecurityContext:
  seLinuxOptions:
    type: node_exporter.process
```

Warning: set this only after the node image holds the module. If the type is not loaded, the container runtime cannot start the pod.
