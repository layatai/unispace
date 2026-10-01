import copy
import unittest
import unicodedata

from evidence import clipboard_status, files_status, overall_status


class FeatureEvidenceTests(unittest.TestCase):
    def test_clipboard_requires_source_write_and_unispace_receipt(self):
        valid = dict(matches=True, urlMatches=True, unispaceOrigin=True)
        self.assertEqual(clipboard_status("url", valid, valid), "PASS")
        self.assertEqual(clipboard_status("text", {}, valid), "INCONCLUSIVE")
        self.assertEqual(clipboard_status("text", valid, {**valid, "unispaceOrigin": False}), "FAIL")
        self.assertEqual(clipboard_status("url", valid, {**valid, "urlMatches": False}), "FAIL")
        self.assertEqual(clipboard_status("url", {**valid, "urlMatches": False}, valid), "INCONCLUSIVE")
        self.assertEqual(clipboard_status("text", valid, {**valid, "matches": False}), "FAIL")

    def test_file_receipt_requires_every_file_hash_size_and_finder_origin(self):
        expected = [dict(name="UniSpaceVerify-a.bin", bytes=100, sha256="abc"),
                    dict(name="UniSpaceVerify-đặc-biệt.txt", bytes=32, sha256="def")]
        received = dict(unispaceOrigin=True, fileCount=2, files=[
            dict(item, path="/app/Transfers/Incoming/id/Completed/" + item["name"]) for item in expected])
        self.assertEqual(files_status(expected, received), "PASS")
        decomposed = copy.deepcopy(received)
        decomposed["files"][1]["name"] = unicodedata.normalize("NFD", expected[1]["name"])
        self.assertEqual(files_status(expected, decomposed), "PASS")
        decomposed["files"][1]["name"] = "UniSpaceVerify-dac-biet.txt"
        self.assertEqual(files_status(expected, decomposed), "FAIL")
        for key, value in [("bytes", 99), ("sha256", "wrong"), ("path", "/tmp/copied-by-scp")]:
            damaged = copy.deepcopy(received)
            damaged["files"][0][key] = value
            self.assertEqual(files_status(expected, damaged), "FAIL")
        self.assertEqual(files_status(expected, {**received, "unispaceOrigin": False}), "FAIL")
        self.assertEqual(files_status(expected, {**received, "fileCount": 3}), "FAIL")
        self.assertEqual(files_status(expected, {**received, "files": received["files"][:1]}), "FAIL")
        self.assertEqual(files_status(expected, {**received, "files": received["files"][:1] * 2}), "FAIL")
        self.assertEqual(files_status([], received), "INCONCLUSIVE")

    def test_missing_evidence_and_unrun_features_cannot_pass_the_baseline(self):
        for statuses, expected in [([], "INCONCLUSIVE"), (["PASS"], "PASS"),
                                   (["PASS", "NOT_TESTED"], "INCONCLUSIVE"),
                                   (["PASS", "INCONCLUSIVE"], "INCONCLUSIVE"),
                                   (["FAIL", "NOT_TESTED"], "FAIL")]:
            self.assertEqual(overall_status([dict(status=s) for s in statuses]), expected)


if __name__ == "__main__":
    unittest.main()
