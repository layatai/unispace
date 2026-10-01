"""Acceptance rules shared by live probes and their regression tests."""
import unicodedata


def clipboard_status(kind, source, received):
    if not source.get("matches") or (kind == "url" and not source.get("urlMatches")):
        return "INCONCLUSIVE"
    delivered = received.get("matches") and received.get("unispaceOrigin")
    if kind == "url":
        delivered = delivered and received.get("urlMatches")
    return "PASS" if delivered else "FAIL"


def file_payloads_match(expected, received):
    """Compare the complete batch; usable for source setup and receiver checks."""
    if not expected:
        return False
    actual = received.get("files", [])
    if len(actual) != len(expected) or received.get("fileCount") != len(expected):
        return False
    canonical = lambda name: unicodedata.normalize("NFC", name)
    by_name = {canonical(item["name"]): item for item in actual}
    if len(by_name) != len(actual) or len({canonical(item["name"]) for item in expected}) != len(expected):
        return False
    for wanted in expected:
        found = by_name.get(canonical(wanted["name"]))
        if not found or any(found.get(key) != wanted[key] for key in ("bytes", "sha256")):
            return False
    return True


def files_status(expected, received):
    """Require the exact batch, verified bytes, and UniSpace Finder publication."""
    if not expected:
        return "INCONCLUSIVE"
    if not received.get("unispaceOrigin") or not file_payloads_match(expected, received):
        return "FAIL"
    for found in received["files"]:
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
