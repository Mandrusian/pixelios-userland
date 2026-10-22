"""Runs tools/check-ios-root.py --selftest (synthetic HFSX images only, no root, no phone)."""
import pathlib
import subprocess
import sys
import unittest


class CheckIosRoot(unittest.TestCase):
    def test_userdata_limits_match_board_json(self):
        import glob, json, os
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        lim = json.load(open(os.path.join(root, 'tools', 'userdata-limits.json')))
        for board, mib in lim.items():
            for p in glob.glob(os.path.join(root, 'device', '*', board, 'board.json')):
                self.assertEqual(json.load(open(p)).get('userdata_mib'), mib, p)


    def test_selftest(self):
        tool = pathlib.Path(__file__).resolve().parent / "check-ios-root.py"
        r = subprocess.run([sys.executable, "-I", str(tool), "--selftest"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("selftest OK", r.stdout)


if __name__ == "__main__":
    unittest.main()
