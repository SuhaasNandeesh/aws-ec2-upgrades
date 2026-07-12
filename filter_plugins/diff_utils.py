"""Diff utilities for EC2 patch reports.

Provides Ansible custom filters:
  - service_diff: compare pre/post running services.
  - package_diff: list upgraded packages from apt history log parsing.
  - docker_diff: compare pre/post docker containers.
  - to_nice_json_safe: json.dumps with indent and sort_keys, never raises.
"""

from __future__ import annotations

import json
from typing import Any


class FilterModule:
    def filters(self) -> dict[str, Any]:
        return {
            "service_diff": service_diff,
            "package_diff": package_diff,
            "docker_diff": docker_diff,
            "to_nice_json_safe": to_nice_json_safe,
        }


def service_diff(pre_services: list[str], post_services: list[str]) -> dict[str, list[str]]:
    """Return dropped (was running, now not) and added (now running, was not)."""
    pre_set = set(pre_services or [])
    post_set = set(post_services or [])
    return {
        "dropped": sorted(pre_set - post_set),
        "added": sorted(post_set - pre_set),
    }


def docker_diff(pre_containers: list[dict], post_containers: list[dict]) -> dict[str, list[str]]:
    """Compare docker containers by name. Return dropped/added container names."""
    pre_names = {c.get("name", "") for c in (pre_containers or [])}
    post_names = {c.get("name", "") for c in (post_containers or [])}
    return {
        "dropped": sorted(pre_names - post_names),
        "added": sorted(post_names - pre_names),
    }


def package_diff(pre_packages: dict, post_packages: dict) -> list[dict]:
    """Compare package_facts before/after and return list of upgraded packages.

    pre_packages/post_packages: dict mapping package name -> version string
    (the first/selected version from ansible.builtin.package_facts).
    Returns: [{"name": ..., "old": ..., "new": ...}, ...]
    """
    pre = pre_packages or {}
    post = post_packages or {}
    upgraded = []
    for name, new_version in post.items():
        old_version = pre.get(name)
        if old_version != new_version:
            upgraded.append({
                "name": name,
                "old": old_version,
                "new": new_version,
            })
    upgraded.sort(key=lambda p: p["name"])
    return upgraded


def to_nice_json_safe(obj: Any) -> str:
    """json.dumps with indent=2 and sort_keys, falling back to str on failure."""
    try:
        return json.dumps(obj, indent=2, sort_keys=True, default=str)
    except (TypeError, ValueError):
        return str(obj)