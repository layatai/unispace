#!/usr/bin/env python3
"""Baseline installed UniSpace clipboard delivery and verified Finder file receipts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools/FeatureBaseline"))
from evidence import clipboard_status, files_status, overall_status

SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10"]
METADATA = r'''
import json,plistlib,subprocess
from pathlib import Path
p=Path('/Applications/UniSpace.app/Contents/Info.plist')
info=plistlib.loads(p.read_bytes())
result=subprocess.run(['pgrep','-f',r'^/Applications/UniSpace[.]app/Contents/MacOS/UniSpace([[:space:]]|$)'],capture_output=True,text=True)
print(json.dumps(dict(build=info['CFBundleVersion'],version=info['CFBundleShortVersionString'],pids=result.stdout.split())))
'''


def run_json(command):
    return json.loads(subprocess.check_output(command, text=True, timeout=20))


class Endpoints:
    def __init__(self, peer, output):
        if peer.startswith("-"):
            raise ValueError("SSH peer must be a host or user@host")
        self.ssh = ["ssh", *SSH_OPTIONS, peer]
        self.output = output
        self.remote = ".unispace-feature-baseline/" + output.name
        self.helper = output / "PasteboardProbe"
        subprocess.run(["swiftc", "-O", str(ROOT / "Tools/FeatureBaseline/PasteboardProbe.swift"),
                        "-o", str(self.helper)], check=True, timeout=60)
        subprocess.run(self.ssh + [shlex.join(["mkdir", "-p", "-m", "700", self.remote])], check=True, timeout=20)
        subprocess.run(["scp", *SSH_OPTIONS, str(self.helper), peer + ":" + self.remote + "/PasteboardProbe"],
                       check=True, timeout=20)

    def call(self, host, *arguments):
        command = [str(self.helper), *arguments] if host == "local" else self.ssh + [
            shlex.join([self.remote + "/PasteboardProbe", *arguments])]
        return run_json(command)

    def metadata(self):
        return {host: run_json([sys.executable, "-c", METADATA] if host == "local" else
                              self.ssh + [shlex.join(["python3", "-c", METADATA])])
                for host in ("local", "peer")}

    def snapshot_path(self, host):
        return str(self.output / "clipboard.plist") if host == "local" else self.remote + "/clipboard.plist"

    def remove_snapshot(self, host):
        if host == "local":
            Path(self.snapshot_path(host)).unlink()
        else:
            subprocess.run(self.ssh + [shlex.join(["rm", "--", self.snapshot_path(host)])], check=True, timeout=20)


def clipboard_checks(endpoints, prefix, timeout):
    results, saved = [], []
    try:
        for host in ("local", "peer"):
            endpoints.call(host, "snapshot", endpoints.snapshot_path(host))
            saved.append(host)
        for kind in ("text", "url"):
            for source, target in (("local", "peer"), ("peer", "local")):
                token = f"{prefix}-{source}-{kind}"
                if kind == "url":
                    token = "https://example.com/" + token
                endpoints.call(source, kind, token)
                source_check = endpoints.call(source, "check", token)
                started = time.monotonic()
                received = {}
                while time.monotonic() - started < timeout:
                    received = endpoints.call(target, "check", token)
                    if clipboard_status(kind, source_check, received) == "PASS":
                        break
                    time.sleep(0.25)
                result = dict(feature=f"clipboard-{kind}-{source}-to-{target}",
                              status=clipboard_status(kind, source_check, received),
                              source=source_check, received=received,
                              elapsedSeconds=round(time.monotonic() - started, 2))
                results.append(result)
                print(json.dumps(result), flush=True)
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        results.append(dict(feature="clipboard-probe-execution", status="INCONCLUSIVE", error=type(error).__name__))
    finally:
        for host in saved:
            try:
                restoration = endpoints.call(host, "restore", endpoints.snapshot_path(host), prefix)
                safe = restoration.get("restored") or restoration.get("preservedNewerClipboard")
                if safe:
                    endpoints.remove_snapshot(host)
                results.append(dict(feature=f"clipboard-restoration-{host}",
                                    status="PASS" if safe else "FAIL", **restoration))
            except (subprocess.SubprocessError, OSError, ValueError) as error:
                results.append(dict(feature=f"clipboard-restoration-{host}", status="INCONCLUSIVE",
                                    error=type(error).__name__, snapshot=endpoints.snapshot_path(host)))
        # Persist even when a probe/SSH process fails partway through.
        (endpoints.output / "clipboard-results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results


def prepare_files(output):
    prefix = "UniSpaceVerify-" + uuid.uuid4().hex
    directory = output / "send"
    directory.mkdir()
    fixtures = {prefix + "-empty.txt": b"", prefix + "-đặc-biệt.txt": "Unicode baseline: Việt Nam\n".encode(),
                prefix + "-binary.bin": os.urandom(2 * 1024 * 1024)}
    expected = []
    for name, data in fixtures.items():
        (directory / name).write_bytes(data)
        expected.append(dict(name=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
    manifest = output / "manifest.json"
    manifest.write_text(json.dumps(dict(prefix=prefix, files=expected), indent=2) + "\n")
    print(f"Send all three fixtures through UniSpace: {directory}")
    print(f"Manifest: {manifest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["clipboard", "prepare-files", "verify-files"])
    parser.add_argument("--peer", help="Receiving Mac SSH user@host")
    parser.add_argument("--expected-build")
    parser.add_argument("--timeout", type=float, default=12)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/feature-baseline" / uuid.uuid4().hex)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.mode != "prepare-files" and (not args.peer or not args.expected_build):
        parser.error("live probes require --peer and --expected-build")
    if args.mode == "verify-files" and not args.manifest:
        parser.error("verify-files requires --manifest")
    os.umask(0o077)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    if args.mode == "prepare-files":
        prepare_files(args.output)
        return 0
    results, metadata = [], {}
    try:
        endpoints = Endpoints(args.peer, args.output)
        metadata = endpoints.metadata()
        if any(value["build"] != args.expected_build or len(value["pids"]) != 1 for value in metadata.values()):
            results.append(dict(feature="installed-app-identity", status="FAIL", reason="Wrong build or process count"))
        elif args.mode == "clipboard":
            results = clipboard_checks(endpoints, "UniSpaceVerify-" + uuid.uuid4().hex, args.timeout)
        else:
            manifest = json.loads(args.manifest.read_text())
            received = endpoints.call("peer", "files", manifest["prefix"])
            results.append(dict(feature="file-batch-and-Finder-publication",
                                status=files_status(manifest["files"], received), received=received))
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        results.append(dict(feature="probe-execution", status="INCONCLUSIVE", error=type(error).__name__))
    report = dict(status=overall_status(results), metadata=metadata, results=results,
                  scope="Installed apps only; no simulated input or file delivery via SSH")
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print(f"Report: {args.output / 'report.json'}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
