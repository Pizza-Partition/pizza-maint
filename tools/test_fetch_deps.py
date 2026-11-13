import importlib.util
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fetch_deps', Path(__file__).with_name('fetch-deps.py'))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)


class SourceFetchTests(unittest.TestCase):
    def test_lock_selects_https_archives_and_keeps_the_expected_hash(self):
        actual = fetch.archives(Path('build.zig.zon').read_text())
        self.assertEqual({name for name, _, _ in actual}, {'e2fsprogs', 'fatfs', 'ntfs3g', 'btrfs'})
        self.assertTrue(all(expected.startswith('N-V-') for _, _, expected in actual))
        with self.assertRaises(ValueError):
            fetch.archives('not a dependency lock')

    def test_wrong_archive_identity_fails_before_building_sources(self):
        with tempfile.TemporaryDirectory() as root, patch.object(fetch.subprocess, 'run') as run, patch.object(fetch.subprocess, 'check_output', return_value=''), patch.object(fetch.Path, 'read_text', return_value='.{ .fatfs = .{ .url = "/tmp/ff.zip", .hash = "different-package" } }'):
            with self.assertRaisesRegex(ValueError, 'locked hash'):
                fetch.fetch_archive('zig', Path(root), Path(root) / 'packages', 'fatfs', 'https://example.invalid/ff.zip', 'expected-package')
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][0], 'curl')

    def test_download_failure_falls_back_to_zig_and_verifies_identity(self):
        with tempfile.TemporaryDirectory() as root, patch.object(fetch.subprocess, 'run', side_effect=subprocess.CalledProcessError(22, 'curl')), patch.object(fetch.subprocess, 'check_output', return_value='') as get, patch.object(fetch.Path, 'read_text', return_value='.{ .ntfs3g = .{ .url = "/tmp/source.tgz", .hash = "expected-package" } }'):
            fetch.fetch_archive('zig', Path(root), Path(root) / 'packages', 'ntfs3g', 'https://example.invalid/source.tgz', 'expected-package')
            self.assertEqual(get.call_args.kwargs['cwd'], Path(root))
            self.assertEqual(get.call_args.args[0], ['zig', 'fetch', '--save-exact=ntfs3g', '--pkg-dir', str(Path(root) / 'packages'), 'https://example.invalid/source.tgz'])

    def test_fallback_identity_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as root, patch.object(fetch.subprocess, 'run', side_effect=subprocess.CalledProcessError(22, 'curl')), patch.object(fetch.subprocess, 'check_output', return_value=''), patch.object(fetch.Path, 'read_text', return_value='.{ .ntfs3g = .{ .url = "/tmp/source.tgz", .hash = "different-package" } }'):
            with self.assertRaisesRegex(ValueError, 'locked hash'):
                fetch.fetch_archive('zig', Path(root), Path(root) / 'packages', 'ntfs3g', 'https://example.invalid/source.tgz', 'expected-package')

    def test_failure_of_both_transports_is_reported(self):
        with tempfile.TemporaryDirectory() as root, patch.object(fetch.subprocess, 'run', side_effect=subprocess.CalledProcessError(22, 'curl')), patch.object(fetch.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'zig')):
            with self.assertRaises(subprocess.CalledProcessError):
                fetch.fetch_archive('zig', Path(root), Path(root) / 'packages', 'ntfs3g', 'https://example.invalid/source.tgz', 'expected-package')


if __name__ == '__main__':
    unittest.main()
