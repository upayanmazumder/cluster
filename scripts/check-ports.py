#!/usr/bin/env python3
"""Validate inventory/ports.yaml against itself, against k8s/ manifests, and against the firewall.

Fails (exit 1) if:
  1. An entry carries a `status` that is not one of the documented values.
  2. Two registry entries share the same (port, proto, scope) with status in {live, open, target}
     (a duplicate claim on the same reachable surface).
  3. A Kubernetes Service of type NodePort or LoadBalancer, or a container `hostPort`, appears
     under k8s/ with a port that has no matching entry in the registry at all (any status).
  4. The registry and `terraform/firewall.tf` disagree about what the internet can reach, in
     either direction.

Check 4 is the one this file was missing, and it is where the registry had actually drifted. The
registry calls itself "source of truth for every port that is (or was, or will be) reachable from
outside the pod network", but nothing compared it to the object that decides that — the Hetzner
Cloud Firewall. So on 2026-09-30 the registry said of tcp/15432 and tcp/15433, the two public
Postgres ports, "**NO such rule exists today**", while `firewall.tf` had carried
`source_ips = ["0.0.0.0/0", "::/0"]` for both since 2026-09-29. Two files, opposite claims, both
green. A gate that checks the registry against the least consequential half of its surface is the
kind of check this repository's own `.gitleaks.toml` warns about.

The Hetzner Cloud Firewall is an allow-list: once attached, inbound traffic with no matching rule
is dropped. So "a rule exists" and "the internet can reach it" are the same statement, which is
what makes this comparison meaningful rather than advisory.

This intentionally does not require every registry entry to have a live manifest (host-level ports
like sshd/etcd/kubelet/tailscaled have no k8s Service) and does not require every status to be
unique per port (a port legitimately has both a `live`/`remove` row for the current path and a
`target` row for the future one).

Usage: python3 scripts/check-ports.py [--repo-root PATH]
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
from collections import defaultdict

# The `status` values the registry's own header documents, plus the two it had grown in practice
# (`open`/`closed`, used by the N7 Postgres rows) and `removed` (a path that is gone, not merely
# scheduled to go). Validating the set matters because the checks below branch on it: a typo such
# as `opened` previously made an entry silently invisible to every check rather than failing.
#
#   live    — reachable today
#   open    — reachable today, deliberately and recently opened (N7's Postgres edge)
#   remove  — reachable today, scheduled for removal
#   target  — NOT reachable; the intended future state
#   closed  — NOT reachable; the path exists but nothing can get to it
#   removed — NOT reachable; the path itself is gone
VALID_STATUSES = {"live", "open", "remove", "target", "closed", "removed"}

# Statuses that assert "the internet can reach this today". These are the ones check 4 expects to
# find a matching firewall rule for, and vice versa.
REACHABLE_STATUSES = {"live", "open", "remove"}

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


def load_registry(repo_root: pathlib.Path) -> list[dict]:
    path = repo_root / "inventory" / "ports.yaml"
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        sys.exit(2)
    with path.open() as f:
        entries = yaml.safe_load(f) or []
    required = {"port", "proto", "scope", "status"}
    for i, e in enumerate(entries):
        missing = required - e.keys()
        if missing:
            print(f"error: {path} entry {i} missing fields: {sorted(missing)}", file=sys.stderr)
            sys.exit(2)
        if e["status"] not in VALID_STATUSES:
            print(
                f"error: {path} entry {i} (port {e['port']}) has status {e['status']!r}, "
                f"which is not one of {sorted(VALID_STATUSES)}",
                file=sys.stderr,
            )
            sys.exit(2)
    return entries


def check_duplicates(entries: list[dict]) -> list[str]:
    errors = []
    seen: dict[tuple, list[dict]] = defaultdict(list)
    for e in entries:
        if e["status"] not in ("live", "open", "target"):
            continue
        key = (e["port"], e["proto"], e["scope"])
        seen[key].append(e)
    for key, group in seen.items():
        if len(group) > 1:
            port, proto, scope = key
            services = ", ".join(g.get("service", "?") for g in group)
            errors.append(
                f"duplicate registry entry for port={port} proto={proto} scope={scope} "
                f"(status live/target): {services}"
            )
    return errors


def iter_yaml_docs(repo_root: pathlib.Path):
    k8s_dir = repo_root / "k8s"
    for path in k8s_dir.rglob("*.yaml"):
        try:
            with path.open() as f:
                for doc in yaml.safe_load_all(f):
                    if isinstance(doc, dict):
                        yield path, doc
        except yaml.YAMLError:
            continue


def find_exposed_ports(repo_root: pathlib.Path) -> list[tuple[pathlib.Path, str, int, str]]:
    """Return (file, kind, port, proto) for every NodePort/LoadBalancer Service port and hostPort."""
    found = []
    for path, doc in iter_yaml_docs(repo_root):
        kind = doc.get("kind")
        if kind == "Service":
            spec = doc.get("spec", {}) or {}
            svc_type = spec.get("type")
            if svc_type in ("NodePort", "LoadBalancer"):
                for port_spec in spec.get("ports", []) or []:
                    port = port_spec.get("nodePort") or port_spec.get("port")
                    proto = str(port_spec.get("protocol", "TCP")).lower()
                    if port:
                        found.append((path, f"Service/{svc_type}", int(port), proto))
        if kind in ("Deployment", "StatefulSet", "DaemonSet", "Pod"):
            template = doc.get("spec", {}) or {}
            pod_spec = (
                template.get("template", {}).get("spec", {})
                if kind != "Pod"
                else template
            )
            for container in (pod_spec or {}).get("containers", []) or []:
                for port_spec in container.get("ports", []) or []:
                    host_port = port_spec.get("hostPort")
                    if host_port:
                        proto = str(port_spec.get("protocol", "TCP")).lower()
                        found.append((path, "hostPort", int(host_port), proto))
    return found


def check_unregistered(entries: list[dict], repo_root: pathlib.Path) -> list[str]:
    registered_ports = {(e["port"], e["proto"]) for e in entries}
    errors = []
    for path, kind, port, proto in find_exposed_ports(repo_root):
        if (port, proto) not in registered_ports:
            errors.append(
                f"{path.relative_to(repo_root)}: {kind} exposes {proto}/{port} "
                f"with no inventory/ports.yaml entry"
            )
    return errors


def parse_firewall_rules(repo_root: pathlib.Path) -> list[tuple[str, int | None]]:
    """Return (proto, port) for every inbound rule of `hcloud_firewall.vps`.

    A deliberately small HCL reader rather than a dependency: the block is flat, machine-written
    and lives in this repository, so a brace scan is enough — and it fails loudly rather than
    returning an empty list, because "found no rules" and "could not read the file" must never look
    the same. That is the failure mode `scripts/check-redaction.sh` exists to avoid, applied here.

    `dynamic "rule"` blocks are skipped on purpose: the only one is the `emergency_ssh_cidr`
    break-glass override, which is empty unless an operator passes the variable, so it is not part
    of the committed steady state the registry describes.
    """
    path = repo_root / "terraform" / "firewall.tf"
    if not path.exists():
        print(f"error: {path} not found — cannot compare the registry against the firewall",
              file=sys.stderr)
        sys.exit(2)
    text = path.read_text()

    start = text.find('resource "hcloud_firewall" "vps"')
    if start == -1:
        print(f'error: {path} has no `resource "hcloud_firewall" "vps"` block — the parser below '
              f"assumes that name; fix the parser rather than skipping the check", file=sys.stderr)
        sys.exit(2)

    # Brace-match the resource body.
    depth, i, body_start = 0, text.index("{", start), None
    for i in range(text.index("{", start), len(text)):
        if text[i] == "{":
            depth += 1
            if depth == 1:
                body_start = i + 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                body = text[body_start:i]
                break
    else:
        print(f"error: unbalanced braces in {path}", file=sys.stderr)
        sys.exit(2)

    rules: list[tuple[str, int | None]] = []
    for m in re.finditer(r"(?<!dynamic )\brule\s*\{", body):
        depth, blk_start = 0, None
        for j in range(m.end() - 1, len(body)):
            if body[j] == "{":
                depth += 1
                if depth == 1:
                    blk_start = j + 1
            elif body[j] == "}":
                depth -= 1
                if depth == 0:
                    blk = body[blk_start:j]
                    break
        else:
            print(f"error: unbalanced braces in a rule block of {path}", file=sys.stderr)
            sys.exit(2)

        direction = re.search(r'direction\s*=\s*"([^"]+)"', blk)
        if not direction or direction.group(1) != "in":
            continue
        proto = re.search(r'protocol\s*=\s*"([^"]+)"', blk)
        if not proto:
            print(f"error: an inbound rule in {path} has no `protocol`", file=sys.stderr)
            sys.exit(2)
        port = re.search(r'port\s*=\s*"([0-9]+)"', blk)
        rules.append((proto.group(1).lower(), int(port.group(1)) if port else None))

    if not rules:
        print(f"error: parsed 0 inbound rules from {path}. The firewall has rules, so this is a "
              f"broken parser, not an open-nothing firewall — refusing to report a clean result.",
              file=sys.stderr)
        sys.exit(2)
    return rules


def check_firewall(entries: list[dict], repo_root: pathlib.Path) -> list[str]:
    """The registry and the firewall must agree on what the internet can reach."""
    errors = []
    rules = parse_firewall_rules(repo_root)

    # icmp is answered and has no port; the registry tracks ports, so it is out of scope here.
    rule_ports = {(proto, port) for proto, port in rules if port is not None}
    reachable = {
        (e["proto"], e["port"])
        for e in entries
        if str(e.get("scope", "")).startswith("public") and e["status"] in REACHABLE_STATUSES
    }

    for proto, port in sorted(rule_ports - reachable):
        errors.append(
            f"terraform/firewall.tf allows inbound {proto}/{port} from the internet, but "
            f"inventory/ports.yaml has no public entry for it with a reachable status "
            f"({sorted(REACHABLE_STATUSES)}). Either the rule should not exist or the registry "
            f"is describing a cluster that no longer matches it."
        )
    for proto, port in sorted(reachable - rule_ports):
        errors.append(
            f"inventory/ports.yaml says {proto}/{port} is publicly reachable, but "
            f"terraform/firewall.tf has no inbound rule for it. The Hetzner firewall is an "
            f"allow-list, so with no rule the port is dropped — the registry is overstating what "
            f"is exposed. Mark it `closed` (with the reason) or add the rule deliberately."
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=".", type=pathlib.Path)
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()

    entries = load_registry(repo_root)
    errors = (
        check_duplicates(entries)
        + check_unregistered(entries, repo_root)
        + check_firewall(entries, repo_root)
    )

    if errors:
        print(f"check-ports.py: {len(errors)} problem(s) found:\n", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(
        f"check-ports.py: OK — {len(entries)} registry entries, no duplicates, no unregistered "
        f"exposures, and the registry agrees with terraform/firewall.tf"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
