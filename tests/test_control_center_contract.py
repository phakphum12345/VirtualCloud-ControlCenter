import hashlib
import re
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

import control_center


ROOT = Path(__file__).resolve().parents[1]


class BootstrapCommandContractTests(unittest.TestCase):
    def test_command_uses_only_supported_bootstrap_parameter(self):
        script = ROOT / "bootstrap-control-plane.ps1"
        command = control_center.build_bootstrap_command(script, "owner/control-plane")
        self.assertEqual(
            command,
            [
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(script), "-Repo", "owner/control-plane",
            ],
        )
        source = script.read_text(encoding="utf-8")
        match = re.search(r"(?s)param\((.*?)\n\)", source)
        self.assertIsNotNone(match, "Bootstrap script parameter block must exist")
        declared = set(re.findall(r"\$([A-Za-z_]\w*)", match.group(1)))
        passed = {command[i][1:] for i in range(command.index("-Repo"), len(command), 2) if command[i].startswith("-")}
        self.assertTrue(passed.issubset(declared))
        self.assertNotIn("-DriveUserCredentialsJsonPath", command)
        self.assertNotIn("-SkipSecrets", command)


class RunnerWorkflowCredentialTests(unittest.TestCase):
    def test_checkout_does_not_persist_cross_repository_token(self):
        workflow = (ROOT / "virtual-cloud-runners.yml").read_text(encoding="utf-8")
        self.assertIn("persist-credentials: false", workflow)

    def test_missing_build_hook_fails_unless_noop_is_explicit(self):
        workflow = (ROOT / "virtual-cloud-runners.yml").read_text(encoding="utf-8")
        self.assertIn("allow_noop:", workflow)
        self.assertIn("default: false", workflow)
        self.assertIn("explicitly set allow_noop=true", workflow)
        self.assertIn("exit 1", workflow)
        self.assertIn("throw 'No project build hook was found.", workflow)


class OAuthRedirectValidationTests(unittest.TestCase):
    def test_localhost_redirect_with_port_is_allowed(self):
        self.assertTrue(control_center.is_safe_local_redirect_uri("http://localhost:8765/oauth2callback"))

    def test_ipv4_loopback_redirect_with_port_is_allowed(self):
        self.assertTrue(control_center.is_safe_local_redirect_uri("http://127.0.0.1:7357/oauth2callback"))

    def test_userinfo_host_confusion_is_rejected(self):
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://localhost:8765@attacker.example:80/oauth2callback"))

    def test_non_loopback_host_is_rejected(self):
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://attacker.example:8765/oauth2callback"))

    def test_https_and_missing_port_are_rejected(self):
        self.assertFalse(control_center.is_safe_local_redirect_uri("https://localhost:8765/oauth2callback"))
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://localhost/oauth2callback"))

    def test_query_and_fragment_are_rejected(self):
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://localhost:8765/oauth2callback?next=evil"))
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://localhost:8765/oauth2callback#fragment"))
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://localhost:8765/oauth2callback?"))
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://localhost:8765/oauth2callback#"))

    def test_control_characters_are_rejected(self):
        self.assertFalse(control_center.is_safe_local_redirect_uri("http://localhost:8765/oauth2callback\r\n"))

    def test_oauth_error_is_html_escaped_and_bounded(self):
        rendered = control_center.escape_oauth_error_html("<script>alert(1)</script>")
        self.assertEqual(rendered, "&lt;script&gt;alert(1)&lt;/script&gt;")
        self.assertLessEqual(len(control_center.escape_oauth_error_html("x" * 5000)), 1000)


class OAuthRedirectBackslashTests(unittest.TestCase):
    def test_backslash_url_confusion_is_rejected(self):
        uri = "http://localhost:8765" + chr(92) + "@attacker.example/oauth2callback"
        self.assertFalse(control_center.is_safe_local_redirect_uri(uri))


class ArtifactDownloadPathTests(unittest.TestCase):
    def test_artifact_name_cannot_escape_download_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            path = control_center.build_artifact_download_path(base, "12345", "67890", "../../outside/evil")
            self.assertEqual(path.resolve().parent.parent, base.resolve())
            self.assertNotIn("..", path.parts)
            self.assertTrue(path.name.endswith("-67890"))

    def test_non_numeric_run_id_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "run ID"):
                control_center.build_artifact_download_path(Path(tmp), "../123", "67890", "bundle")


class AtomicSettingsPersistenceTests(unittest.TestCase):
    def test_atomic_write_replaces_file_with_complete_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "config.json"
            target.write_text('{"old": true}', encoding="utf-8")
            control_center.atomic_write_text(target, '{"new": true}')
            self.assertEqual(target.read_text(encoding="utf-8"), '{"new": true}')

    def test_failed_replace_preserves_previous_file_and_cleans_temp(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "config.json"
            target.write_text('{"preserve": true}', encoding="utf-8")
            with patch("control_center.os.replace", side_effect=OSError("replace failed")):
                with self.assertRaisesRegex(OSError, "replace failed"):
                    control_center.atomic_write_text(target, '{"new": true}')
            self.assertEqual(target.read_text(encoding="utf-8"), '{"preserve": true}')
            self.assertEqual(list(Path(tmp).glob(".config.json.*.tmp")), [])

    def test_config_mapping_rejects_invalid_types_and_clamps_ranges(self):
        config = control_center.AppConfig.from_mapping({
            "repo": [],
            "auto_refresh": "false",
            "notifications": False,
            "refresh_seconds": 999999,
            "retention_days": -10,
            "download_dir": "",
        })
        self.assertEqual(config.repo, control_center.DEFAULT_REPO)
        self.assertTrue(config.auto_refresh)
        self.assertFalse(config.notifications)
        self.assertEqual(config.refresh_seconds, 3600)
        self.assertEqual(config.retention_days, 1)
        self.assertEqual(config.download_dir, control_center.default_download_dir())

    def test_config_load_preserves_corrupt_source_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "config.json"
            original = "{invalid-json"
            target.write_text(original, encoding="utf-8")
            with patch.object(control_center, "CONFIG_PATH", target):
                loaded = control_center.AppConfig.load()
            self.assertEqual(loaded.repo, control_center.DEFAULT_REPO)
            self.assertEqual(target.read_text(encoding="utf-8"), original)

    def test_app_config_save_and_load_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "config.json"
            with patch.object(control_center, "CONFIG_PATH", target):
                control_center.AppConfig(repo="owner/repository", refresh_seconds=30).save()
                loaded = control_center.AppConfig.load()
            self.assertEqual(loaded.repo, "owner/repository")
            self.assertEqual(loaded.refresh_seconds, 30)


class DriveCleanupResultTests(unittest.TestCase):
    class FakeDelete:
        def __init__(self, file_id, failed_ids):
            self.file_id = file_id
            self.failed_ids = failed_ids

        def execute(self):
            if self.file_id in self.failed_ids:
                raise PermissionError("denied")

    class FakeDrive:
        def __init__(self, failed_ids=()):
            self.failed_ids = set(failed_ids)

        def files(self):
            return self

        def delete(self, fileId):
            return DriveCleanupResultTests.FakeDelete(fileId, self.failed_ids)

    def test_cleanup_reports_partial_failures(self):
        drive = self.FakeDrive(failed_ids={"2"})
        candidates = [("logs", {"id": "1"}), ("logs", {"id": "2"})]
        removed, failed, first_error = control_center.delete_drive_candidates(drive, candidates)
        self.assertEqual((removed, failed, first_error), (1, 1, "PermissionError"))

    def test_cleanup_empty_list_is_successful_noop(self):
        removed, failed, first_error = control_center.delete_drive_candidates(self.FakeDrive(), [])
        self.assertEqual((removed, failed, first_error), (0, 0, None))


class ArtifactDirectoryVerificationTests(unittest.TestCase):
    def test_valid_manifest_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = b"artifact payload"
            (root / "artifact.bin").write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            (root / "SHA256SUMS.txt").write_text(f"{digest}  artifact.bin\n", encoding="utf-8")
            ok, detail = control_center.ControlCenter._verify_directory(root)
            self.assertTrue(ok, detail)
            self.assertIn("Verified 1 files", detail)

    def test_parent_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "artifact"
            root.mkdir()
            outside = Path(tmp) / "outside.txt"
            outside.write_text("must not be read", encoding="utf-8")
            digest = hashlib.sha256(b"must not be read").hexdigest()
            (root / "SHA256SUMS.txt").write_text(f"{digest}  ../outside.txt\n", encoding="utf-8")
            ok, detail = control_center.ControlCenter._verify_directory(root)
            self.assertFalse(ok)
            self.assertIn("unsafe or invalid", detail)

    def test_malformed_digest_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "artifact.bin").write_bytes(b"x")
            (root / "SHA256SUMS.txt").write_text("not-a-digest  artifact.bin\n", encoding="utf-8")
            ok, detail = control_center.ControlCenter._verify_directory(root)
            self.assertFalse(ok)
            self.assertIn("unsafe or invalid", detail)


if __name__ == "__main__":
    unittest.main()
