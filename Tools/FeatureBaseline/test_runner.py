import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location("continuity_probe",
    Path(__file__).resolve().parents[2] / "Scripts/verify-live-continuity.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FakeEndpoints:
    def __init__(self, output, failure=None, restoration=None):
        self.output = Path(output)
        self.failure = failure
        self.restoration = restoration or dict(restored=True)
        self.calls = []
        self.removed = []
        self.writer = None

    def snapshot_path(self, host):
        return host + "-snapshot"

    def remove_snapshot(self, host):
        self.removed.append(host)

    def begin_file_copy(self, paths):
        self.writer = Mock()
        return self.writer, self.call("local", "copy-files", *paths)

    def call(self, host, mode, *arguments):
        self.calls.append((host, mode))
        if self.failure == (host, mode):
            raise subprocess.TimeoutExpired("probe", 20)
        if mode == "restore":
            return self.restoration
        if mode == "check":
            return dict(matches=True, urlMatches=True, unispaceOrigin=True)
        if mode == "files":
            manifest = json.loads((self.output / "manifest.json").read_text())
            return dict(unispaceOrigin=True, fileCount=3, files=[dict(item,
                path="/app/Transfers/Incoming/probe/Completed/" + item["name"]) for item in manifest["files"]])
        return dict(saved=True, written=True)


class LiveProbeRunnerTests(unittest.TestCase):
    def run_checks(self, endpoints):
        with patch("sys.stdout", new=io.StringIO()):
            return probe.clipboard_checks(endpoints, "UniSpaceVerify-test", 1)

    def test_four_delivery_checks_restore_both_endpoints(self):
        with tempfile.TemporaryDirectory() as directory:
            endpoints = FakeEndpoints(directory)
            results = self.run_checks(endpoints)
            self.assertEqual(len(results), 6)
            self.assertEqual(probe.overall_status(results), "PASS")
            self.assertEqual(endpoints.removed, ["local", "peer"])
            self.assertEqual(json.loads((Path(directory) / "clipboard-results.json").read_text()), results)

    def test_timeout_restores_saved_clipboards_and_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            endpoints = FakeEndpoints(directory, failure=("peer", "check"))
            results = self.run_checks(endpoints)
            self.assertEqual(probe.overall_status(results), "INCONCLUSIVE")
            self.assertEqual(endpoints.removed, ["local", "peer"])
            self.assertIn(("local", "restore"), endpoints.calls)
            self.assertIn(("peer", "restore"), endpoints.calls)

    def test_second_snapshot_failure_still_cleans_up_first(self):
        with tempfile.TemporaryDirectory() as directory:
            endpoints = FakeEndpoints(directory, failure=("peer", "snapshot"))
            results = self.run_checks(endpoints)
            self.assertEqual(probe.overall_status(results), "INCONCLUSIVE")
            self.assertEqual(endpoints.removed, ["local"])
            self.assertNotIn(("local", "text"), endpoints.calls)

    def test_restore_failure_retains_private_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            endpoints = FakeEndpoints(directory, restoration=dict(restored=False))
            self.assertEqual(probe.overall_status(self.run_checks(endpoints)), "FAIL")
            self.assertEqual(endpoints.removed, [])

    def test_newer_user_clipboard_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            endpoints = FakeEndpoints(directory, restoration=dict(restored=False, preservedNewerClipboard=True))
            self.assertEqual(probe.overall_status(self.run_checks(endpoints)), "PASS")
            self.assertEqual(endpoints.removed, ["local", "peer"])

    def test_finder_batch_uses_source_pasteboard_and_verifies_receiver_before_restore(self):
        with tempfile.TemporaryDirectory() as directory, patch("sys.stdout", new=io.StringIO()):
            endpoints = FakeEndpoints(directory)
            results = probe.finder_file_checks(endpoints, 1)
            self.assertEqual(probe.overall_status(results), "PASS")
            self.assertIn(("local", "copy-files"), endpoints.calls)
            self.assertIn(("peer", "files"), endpoints.calls)
            self.assertEqual(endpoints.removed, ["local", "peer"])
            self.assertEqual(len(list((Path(directory) / "send").iterdir())), 3)
            endpoints.writer.terminate.assert_called_once()
            endpoints.writer.wait.assert_called_once_with(timeout=5)

    def test_finder_receiver_failure_restores_clipboards(self):
        with tempfile.TemporaryDirectory() as directory, patch("sys.stdout", new=io.StringIO()):
            endpoints = FakeEndpoints(directory, failure=("peer", "files"))
            results = probe.finder_file_checks(endpoints, 1)
            self.assertEqual(probe.overall_status(results), "INCONCLUSIVE")
            self.assertEqual(endpoints.removed, ["local", "peer"])
            endpoints.writer.terminate.assert_called_once()

    def test_incomplete_source_file_setup_is_not_reported_as_a_product_failure(self):
        with tempfile.TemporaryDirectory() as directory, patch("sys.stdout", new=io.StringIO()):
            endpoints = FakeEndpoints(directory)
            original_call = endpoints.call
            def partial_source(host, mode, *arguments):
                if host == "local" and mode == "files":
                    return dict(fileCount=1, files=[])
                return original_call(host, mode, *arguments)
            endpoints.call = partial_source
            results = probe.finder_file_checks(endpoints, 1)
            self.assertEqual(probe.overall_status(results), "INCONCLUSIVE")
            self.assertNotIn(("peer", "files"), endpoints.calls)
            self.assertEqual(endpoints.removed, ["local", "peer"])


if __name__ == "__main__":
    unittest.main()
