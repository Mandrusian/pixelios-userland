"""sweet-root-tweaks.py: --plan (no root) must produce the same tree as the legacy in-place mode.

Both run under fakeroot on the synthetic tree of tools/rootless/selftest.py (owners 0/80/501 are faked);
skipped where fakeroot is missing.
"""
import importlib.util, io, os, shutil, subprocess, sys, tarfile, tempfile, unittest

TOOLS = os.path.dirname(os.path.abspath(__file__))
TW = os.path.join(TOOLS, 'sweet-root-tweaks.py')
LIST = ("cd %s && find . -printf '%%m %%U %%G %%y %%p -> %%l\\n' | sort; "
        "find . -type f -exec sha256sum {} + | sort -k2")


def sh(cmd, *fk):
    subprocess.run(['fakeroot', *fk, '--', 'sh', '-ec', 'umask 022; ' + cmd], check=True, env=env, stdout=subprocess.DEVNULL)


@unittest.skipUnless(shutil.which('fakeroot'), 'fakeroot not installed')
class PlanEqualsLive(unittest.TestCase):
    def test_same_tree(self):
        global env
        with tempfile.TemporaryDirectory() as t:
            os.mkdir(t + '/bin')
            with open(t + '/bin/heif-convert', 'w') as f:
                f.write('#!/bin/sh\nprintf "PNG of %s\\n" "$(basename "$1")" >"$2"\n')
            os.chmod(t + '/bin/heif-convert', 0o755)
            env = dict(os.environ, PATH=t + '/bin:' + os.environ['PATH'])
            sh(f'python3 -I {TOOLS}/rootless/selftest.py tree {t}/T', '-s', t + '/s0')
            src = t + '/T/os/root'
            sh(f'cp -a {src} {t}/A && python3 {TW} {t}/A', '-i', t + '/s0', '-s', t + '/s1')
            sh(f'cp -a {src} {t}/B && python3 {TW} --plan {t}/B {t}/P && R={t}/B sh -e {t}/P/ops.sh '
               f'&& tar -x -p --numeric-owner -C {t}/B -f {t}/P/overlay.tar', '-i', t + '/s0', '-s', t + '/s2')
            out = []
            for d, st in (('A', 's1'), ('B', 's2')):
                out.append(subprocess.run(['fakeroot', '-i', f'{t}/{st}', '--', 'sh', '-c', LIST % f'{t}/{d}'],
                                          check=True, capture_output=True, text=True).stdout)
            self.assertGreater(out[0].count('\n'), 50)
            self.maxDiff = None
            self.assertEqual(out[0], out[1])

    def test_guard(self):
        spec = importlib.util.spec_from_file_location('tw', TW)
        tw = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tw)
        with tempfile.TemporaryDirectory() as t:
            tar = tarfile.open(fileobj=io.BytesIO(), mode='w')
            plan = tw.Plan(t, tar, guard={'usr/lib/x'})
            plan.exists('usr/lib/y')                       # fine
            with self.assertRaises(RuntimeError):
                plan.exists('usr/lib/x')
            with self.assertRaises(RuntimeError):
                plan.listdir('usr/lib')                    # a later step adds a file there


if __name__ == '__main__':
    unittest.main()
