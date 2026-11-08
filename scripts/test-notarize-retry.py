#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("notarize", Path(__file__).with_name("notarize-with-retry.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SUBMISSION = "12345678-1234-1234-1234-123456789abc"


def response(payload=None, code=0, error=""):
    return subprocess.CompletedProcess([], code, "" if payload is None else json.dumps(payload), error)


class NotarizationRetryTests(unittest.TestCase):
    def execute(self, responses):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        result = Path(temporary.name) / "notarization.json"
        mock = patch.object(module.subprocess, "run", side_effect=responses).start()
        self.addCleanup(patch.stopall)
        patch.object(module.time, "sleep").start()
        return result, mock

    def testAbortedUploadRetriesThenWaitsOnID(self):
        result, mock = self.execute([response(code=1, error="abortedUpload(request: ..., error: connectTimeout)"),
            response({"id": SUBMISSION}), response({"id": SUBMISSION, "status": "Accepted"})])
        module.notarize(Path("test image.dmg"), "test-profile", result)
        actions = [call.args[0][2] for call in mock.call_args_list]
        self.assertEqual(actions, ["submit", "submit", "wait"])
        for call in mock.call_args_list[:2]:
            self.assertIn("--no-s3-acceleration", call.args[0])
            self.assertIn("--no-wait", call.args[0])
        self.assertEqual(json.loads(result.read_text())["status"], "Accepted")

    def testWaitNetworkFailureKeepsSameSubmission(self):
        result, mock = self.execute([response({"id": SUBMISSION}), response(code=1, error="connectTimeout"),
            response({"id": SUBMISSION, "status": "In Progress"}), response({"id": SUBMISSION, "status": "Accepted"})])
        module.notarize(Path("app.zip"), "test-profile", result)
        self.assertEqual([call.args[0][2] for call in mock.call_args_list], ["submit", "wait", "wait", "wait"])
        self.assertTrue(all(call.args[0][3] == SUBMISSION for call in mock.call_args_list[1:]))

    def testAmbiguousEmptyOrMalformedSubmitDoesNotRetryOrFetchLog(self):
        for payload in [None, {"id": "parse error"}]:
            with self.subTest(payload=payload):
                result, mock = self.execute([response(payload, code=1, error="connectTimeout")])
                with self.assertRaisesRegex(ValueError, "valid submission ID"):
                    module.notarize(Path("app.dmg"), "test-profile", result)
                self.assertEqual(mock.call_count, 1)

    def testInvalidSubmissionStopsAndFetchesOnlyItsLog(self):
        result, mock = self.execute([response({"id": SUBMISSION}), response({"id": SUBMISSION, "status": "Invalid"}), response()])
        with self.assertRaisesRegex(ValueError, "Invalid"):
            module.notarize(Path("app.dmg"), "test-profile", result)
        self.assertEqual([call.args[0][2] for call in mock.call_args_list], ["submit", "wait", "log"])
        self.assertEqual(mock.call_args_list[-1].args[0][3], SUBMISSION)

    def testRepeatedAbortedUploadStopsAfterThreeAttempts(self):
        result, mock = self.execute([response(code=1, error="abortedUpload(request, error: connectTimeout)")] * 3)
        with self.assertRaises(ValueError):
            module.notarize(Path("app.dmg"), "test-profile", result)
        self.assertEqual(mock.call_count, 3)

    def testPermanentUploadFailureStopsImmediately(self):
        result, mock = self.execute([response(code=1, error="abortedUpload(request, error: HTTP 403)")])
        with self.assertRaises(ValueError):
            module.notarize(Path("app.dmg"), "test-profile", result)
        self.assertEqual(mock.call_count, 1)

    def testPendingSubmissionDoesNotResubmit(self):
        result, mock = self.execute([response({"id": SUBMISSION})] + [response({"id": SUBMISSION, "status": "In Progress"})] * 3)
        with self.assertRaisesRegex(ValueError, SUBMISSION):
            module.notarize(Path("app.dmg"), "test-profile", result)
        self.assertEqual([call.args[0][2] for call in mock.call_args_list], ["submit", "wait", "wait", "wait"])

    def testDifferentWaitIDRejected(self):
        result, mock = self.execute([response({"id": SUBMISSION}), response({"id": "other", "status": "Accepted"})])
        with self.assertRaisesRegex(ValueError, "different submission ID"):
            module.notarize(Path("app.dmg"), "test-profile", result)


if __name__ == "__main__":
    unittest.main()
