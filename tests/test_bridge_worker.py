import hashlib
import io
import unittest
import zipfile

from bridge_worker import assert_artifact_integrity, find_named_files, validate_run_id, verify_artifact_zip


def make_artifact_zip(content=b"payload", manifest_name="SHA256SUMS.txt", manifest_line=None):
    digest = hashlib.sha256(content).hexdigest()
    if manifest_line is None:
        manifest_line = f"{digest}  artifact.txt\n"
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("artifact.txt", content)
        if manifest_name:
            archive.writestr(manifest_name, manifest_line)
    return stream.getvalue()


class RunIdValidationTests(unittest.TestCase):
    def test_ascii_numeric_run_id_is_accepted(self):
        self.assertEqual(validate_run_id("123456"), "123456")

    def test_invalid_run_ids_are_rejected(self):
        for value in ("", "../123", "123?x=1", "١٢٣", " 123 "):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "ASCII digits"):
                    validate_run_id(value)


class DriveFilePaginationTests(unittest.TestCase):
    class FakeRequest:
        def __init__(self, response):
            self.response = response

        def execute(self):
            return self.response

    class FakeFiles:
        def __init__(self):
            self.calls = []

        def list(self, **kwargs):
            self.calls.append(kwargs)
            if kwargs.get("pageToken") is None:
                return DriveFilePaginationTests.FakeRequest({
                    "files": [{"id": "first", "name": "receipt.json"}],
                    "nextPageToken": "next-page",
                })
            return DriveFilePaginationTests.FakeRequest({
                "files": [{"id": "second", "name": "receipt.json"}],
            })

    class FakeDrive:
        def __init__(self):
            self.file_api = DriveFilePaginationTests.FakeFiles()

        def files(self):
            return self.file_api

    def test_find_named_files_reads_all_pages(self):
        drive = self.FakeDrive()
        result = find_named_files(drive, "folder-id", "receipt.json")
        self.assertEqual([item["id"] for item in result], ["first", "second"])
        self.assertEqual(len(drive.file_api.calls), 2)
        self.assertEqual(drive.file_api.calls[0]["pageSize"], 1000)
        self.assertEqual(drive.file_api.calls[1]["pageToken"], "next-page")


class VerifyArtifactZipTests(unittest.TestCase):
    def test_valid_manifest_passes(self):
        result = verify_artifact_zip(make_artifact_zip())
        self.assertTrue(result["ok"])
        self.assertEqual(result["checked"], 1)
        self.assertEqual(result["errors"], [])

    def test_checksum_mismatch_fails(self):
        result = verify_artifact_zip(make_artifact_zip(manifest_line=f"{'0' * 64}  artifact.txt\n"))
        self.assertFalse(result["ok"])
        self.assertTrue(any("checksum mismatch" in error for error in result["errors"]))

    def test_missing_manifest_fails(self):
        result = verify_artifact_zip(make_artifact_zip(manifest_name=""))
        self.assertFalse(result["ok"])
        self.assertIn("SHA256SUMS.txt missing", result["errors"])

    def test_multiple_manifests_fail_closed(self):
        content = b"payload"
        digest = hashlib.sha256(content).hexdigest()
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("artifact.txt", content)
            archive.writestr("SHA256SUMS.txt", f"{digest}  artifact.txt" + chr(10))
            archive.writestr("nested/SHA256SUMS.txt", f"{digest}  artifact.txt" + chr(10))
        result = verify_artifact_zip(stream.getvalue())
        self.assertFalse(result["ok"])
        self.assertIn("multiple SHA256SUMS.txt manifests", result["errors"])

    def test_duplicate_zip_member_names_fail_closed(self):
        content = b"payload"
        digest = hashlib.sha256(content).hexdigest()
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("artifact.txt", content)
            with self.assertWarns(UserWarning):
                archive.writestr("artifact.txt", content)
            archive.writestr("SHA256SUMS.txt", f"{digest}  artifact.txt" + chr(10))
        result = verify_artifact_zip(stream.getvalue())
        self.assertFalse(result["ok"])
        self.assertIn("duplicate ZIP member names", result["errors"])

    def test_malformed_digest_fails(self):
        result = verify_artifact_zip(make_artifact_zip(manifest_line="not-a-hash  artifact.txt\n"))
        self.assertFalse(result["ok"])
        self.assertTrue(any("unsafe or invalid" in error for error in result["errors"]))

    def test_parent_traversal_manifest_path_fails(self):
        result = verify_artifact_zip(make_artifact_zip(manifest_line=f"{hashlib.sha256(b'x').hexdigest()}  ../outside.txt\n"))
        self.assertFalse(result["ok"])
        self.assertTrue(any("unsafe or invalid" in error for error in result["errors"]))


class ArtifactIntegrityGateTests(unittest.TestCase):
    def test_failed_artifact_prevents_success_receipt(self):
        with self.assertRaisesRegex(RuntimeError, "Artifact integrity verification failed"):
            assert_artifact_integrity({"bundle": {"ok": False, "errors": ["checksum mismatch"]}})

    def test_empty_artifact_set_is_allowed(self):
        assert_artifact_integrity({})


if __name__ == "__main__":
    unittest.main()
