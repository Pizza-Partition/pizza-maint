import importlib.util
from pathlib import Path
import tempfile
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
        with tempfile.TemporaryDirectory() as root, patch.object(fetch.subprocess, 'run') as run, patch.object(fetch.subprocess, 'check_output', return_value='different-package\n'):
            with self.assertRaisesRegex(ValueError, 'locked hash'):
                fetch.fetch_archive('zig', Path(root), 'fatfs', 'https://example.invalid/ff.zip', 'expected-package')
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][0], 'curl')


if __name__ == '__main__':
    unittest.main()
