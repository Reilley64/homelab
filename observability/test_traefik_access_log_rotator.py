import gzip
import os
import tempfile
import unittest

from traefik_access_log_rotator import rotate_if_needed


class RotationTests(unittest.TestCase):
    def test_does_not_rotate_below_threshold(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "access.json")
            with open(path, "wb") as handle:
                handle.write(b"small")
            self.assertFalse(rotate_if_needed(path, max_bytes=10, copies=2))
            self.assertFalse(os.path.exists(path + ".1.gz"))

    def test_compresses_and_truncates_without_changing_inode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "access.json")
            with open(path, "wb") as handle:
                handle.write(b"0123456789")
            inode = os.stat(path).st_ino
            self.assertTrue(rotate_if_needed(path, max_bytes=10, copies=2))
            self.assertEqual(os.stat(path).st_ino, inode)
            self.assertEqual(os.path.getsize(path), 0)
            with gzip.open(path + ".1.gz", "rb") as handle:
                self.assertEqual(handle.read(), b"0123456789")

    def test_shifts_and_bounds_retained_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "access.json")
            for payload in (b"first", b"second", b"third"):
                with open(path, "wb") as handle:
                    handle.write(payload)
                rotate_if_needed(path, max_bytes=1, copies=2)
            with gzip.open(path + ".1.gz", "rb") as handle:
                self.assertEqual(handle.read(), b"third")
            with gzip.open(path + ".2.gz", "rb") as handle:
                self.assertEqual(handle.read(), b"second")
            self.assertFalse(os.path.exists(path + ".3.gz"))
