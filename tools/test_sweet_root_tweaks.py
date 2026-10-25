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
            # F3: the change operations are guarded too
            for op in (lambda: plan.write('usr/lib/x', b'', 0, 0, 0o644), lambda: plan.makedirs('usr/lib/x/d'),
                       lambda: plan.touch('usr/lib/x'), lambda: plan.chown('usr/lib/x', 0, 0),
                       lambda: plan.chmod('usr/lib/x', 0o644), lambda: plan.move('usr/lib/y', 'usr/lib/x'),
                       lambda: plan.move('usr/lib/x', 'usr/lib/y')):
                with self.assertRaises(RuntimeError):
                    op()
            plan.makedirs('usr/lib/y')                     # allow: a path outside the guard still works
            plan.write('usr/lib/y/f', b'', 0, 0, 0o644)

    def _tw(self):
        spec = importlib.util.spec_from_file_location('tw', TW)
        tw = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tw)
        return tw

    def test_symlink_write(self):
        # F1: writing through a symlink is refused in both modes and leaves the target alone.
        tw = self._tw()
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(t + '/d')
            with open(t + '/d/real', 'w') as f:
                f.write('x')
            os.chmod(t + '/d/real', 0o600)
            os.symlink('real', t + '/d/link')
            for fs in (tw.Live(t), tw.Plan(t, tarfile.open(fileobj=io.BytesIO(), mode='w'))):
                with self.assertRaises(RuntimeError):
                    fs.write('d/link', b'y', 0, 0, 0o777)
            self.assertEqual(os.stat(t + '/d/real').st_mode & 0o7777, 0o600)
            with open(t + '/d/real') as f:
                self.assertEqual(f.read(), 'x')
            tw.Live(t).write('d/new', b'z', os.getuid(), os.getgid(), 0o644)    # allow: a plain file
            tw.Plan(t, tarfile.open(fileobj=io.BytesIO(), mode='w')).write('d/real', b'y', 0, 0, 0o644)

    def test_walk_same_in_both_modes(self):
        # F2: a directory symlink is listed but not entered, in plan mode as in live mode.
        tw = self._tw()
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(t + '/a/real')
            open(t + '/a/real/f', 'w').close()
            os.symlink('real', t + '/a/link')
            walks = [[(p, d, fl) for p, d, fl in fs.walk('')]
                     for fs in (tw.Live(t), tw.Plan(t, tarfile.open(fileobj=io.BytesIO(), mode='w')))]
            self.assertEqual(walks[0], walks[1])
            self.assertNotIn('a/link', [p for p, _, _ in walks[1]])
            self.assertIn('a/real', [p for p, _, _ in walks[1]])


if __name__ == '__main__':
    unittest.main()
