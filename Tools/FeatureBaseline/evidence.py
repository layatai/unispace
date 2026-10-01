"""Acceptance rules shared by live probes and their regression tests."""


def clipboard_status(kind, source, received):
    if not source.get("matches") or (kind == "url" and not source.get("urlMatches")):
        return "INCONCLUSIVE"
    delivered = received.get("matches") and received.get("unispaceOrigin")
    if kind == "url":
        delivered = delivered and received.get("urlMatches")
    return "PASS" if delivered else "FAIL"


def files_status(expected, received):
    """Require the exact batch, verified bytes, and UniSpace Finder publication."""
    if not expected:
        return "INCONCLUSIVE"
    actual = received.get("files", [])
    if not received.get("unispaceOrigin") or len(actual) != len(expected) or received.get("fileCount") != len(expected):
        return "FAIL"
    by_name = {item["name"]: item for item in actual}
    if len(by_name) != len(actual):
        return "FAIL"
    for wanted in expected:
        found = by_name.get(wanted["name"])
        if not found or any(found.get(key) != wanted[key] for key in ("bytes", "sha256")):
            return "FAIL"
        if "/Transfers/Incoming/" not in found.get("path", "") or "/Completed/" not in found["path"]:
            return "FAIL"
    return "PASS"


def overall_status(results):
    statuses = [result["status"] for result in results]
    if "FAIL" in statuses:
        return "FAIL"
    if not statuses or any(value != "PASS" for value in statuses):
        return "INCONCLUSIVE"
    return "PASS"
