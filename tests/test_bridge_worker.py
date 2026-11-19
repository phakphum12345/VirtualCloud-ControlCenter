import hashlib
import io
import unittest
import zipfile

from bridge_worker import assert_artifact_integrity, verify_artifact_zip


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
