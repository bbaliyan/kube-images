#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail when a bake task gives a module an argument the module does not accept.

Why a script: ansible-lint checks module arguments only for modules whose
argument spec it can load, and it skips dnf. --syntax-check reads no module
spec. Running the playbook in check mode takes minutes. This reads each task's
arguments and compares them with the options that `ansible-doc` lists for the
module, aliases included. Free-form modules (command, shell, raw) are skipped.
What a shell string does stays with a real bake.

Usage: ansible-args.py DIR...   (each DIR holds playbooks and roles)
"""
import json
import subprocess
import sys
from pathlib import Path

import yaml

FREE_FORM = {"command", "shell", "raw", "script", "meta", "include_tasks",
             "import_tasks", "include_role", "import_role", "import_playbook",
             "set_fact", "debug", "assert", "fail", "include_vars", "add_host",
             "group_by", "pause", "wait_for_connection", "gather_facts"}
TASK_KEYWORDS = {
    "name", "when", "tags", "register", "become", "become_user", "become_method",
    "environment", "vars", "loop", "loop_control", "with_items", "with_dict",
    "with_fileglob", "with_first_found", "retries", "delay", "until", "notify",
    "ignore_errors", "ignore_unreachable", "changed_when", "failed_when",
    "no_log", "delegate_to", "run_once", "check_mode", "diff", "args", "block",
    "rescue", "always", "listen", "any_errors_fatal", "throttle", "timeout",
    "connection", "module_defaults", "collections", "no_log", "async", "poll",
    "port", "remote_user", "debugger", "action", "local_action", "max_fail_percentage",
}
TASK_LISTS = ("tasks", "pre_tasks", "post_tasks", "handlers", "block", "rescue", "always")


def walk(items):
    """Yield every task dict, descending into blocks."""
    for item in items or []:
        if not isinstance(item, dict):
            continue
        if any(key in item for key in ("block", "rescue", "always")):
            for key in ("block", "rescue", "always"):
                yield from walk(item.get(key))
        else:
            yield item


def tasks_of(path):
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, list):
        return
    for entry in data:
        if not isinstance(entry, dict):
            continue
        if "hosts" in entry:  # a play
            for key in TASK_LISTS:
                yield from walk(entry.get(key))
        else:
            yield from walk([entry])


def module_of(task):
    for key in task:
        if key not in TASK_KEYWORDS:
            return key
    return None


def main(dirs):
    found = []  # (file, task name, module, args)
    for directory in dirs:
        root = Path(directory)
        files = [*root.glob("*.yml"), *root.glob("roles/*/tasks/**/*.yml"),
                 *root.glob("roles/*/handlers/**/*.yml")]
        for path in files:
            for task in tasks_of(path):
                module = module_of(task)
                if module is None or module.split(".")[-1] in FREE_FORM:
                    continue
                args = task[module] if isinstance(task[module], dict) else None
                if args is None:
                    continue
                found.append((path, task.get("name", "?"), module, set(args) | set(task.get("args") or {})))

    modules = sorted({m for _, _, m, _ in found})
    docs = json.loads(subprocess.run(["ansible-doc", "-j", *modules], check=True,
                                     capture_output=True, text=True).stdout)
    failed = 0
    for path, name, module, args in found:
        options = docs[module]["doc"]["options"]
        accepted = set(options)
        for spec in options.values():
            accepted.update(spec.get("aliases", []))
        unknown = sorted(args - accepted)
        if unknown:
            failed += 1
            print(f"FAIL {path}: task '{name}': {module} does not accept {', '.join(unknown)}")
    print(f"{len(found)} tasks in {len(modules)} modules checked, {failed} with a bad argument")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["."]))
