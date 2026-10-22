"""ios-root-plan.py: the payload split covers every entry exactly once and refuses hard links across archives."""
import importlib.util, os, tempfile, unittest

spec = importlib.util.spec_from_file_location('plan', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ios-root-plan.py'))
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


def tree(t):
    for d in 'abcd':
        for i in range(30):
            os.makedirs(f'{t}/{d}/sub{i}', exist_ok=True)
            open(f'{t}/{d}/sub{i}/f', 'w').write('x' * 100)
    open(f'{t}/top', 'w').write('t')


class Split(unittest.TestCase):
    def test_cover_and_links(self):
        with tempfile.TemporaryDirectory() as t:
            tree(t)
            links = {}
            node, _ = plan.scan(t, links)
            shell, units = plan.split([('os', node)], 4)
            self.assertGreater(len(units), 4)
            seen = []
            for _, _, kind, rel in units:
                if kind == 'files':
                    seen += rel
                else:
                    seen += [rel] if rel != '.' else []
                    for dp, dn, fn in os.walk(os.path.join(t, rel)):
                        seen += [os.path.relpath(os.path.join(dp, n), t) for n in dn + fn]
            seen += [r for _, r in shell if r != '.']
            expect = [os.path.relpath(os.path.join(dp, n), t) for dp, dn, fn in os.walk(t) for n in dn + fn]
            self.assertEqual(sorted(seen), sorted(expect))  
            os.link(f'{t}/a/sub1/f', f'{t}/a/sub1/g')           # same unit: fine
            node, _ = plan.scan(t, links := {})
            shell, units = plan.split([('os', node)], 4)
            plan.check_links('os', links.values(), units)
            os.link(f'{t}/a/sub1/f', f'{t}/d/sub9/g')           # two units: refused
            node, _ = plan.scan(t, links := {})
            shell, units = plan.split([('os', node)], 4)
            with self.assertRaises(SystemExit):
                plan.check_links('os', links.values(), units)


if __name__ == '__main__':
    unittest.main()
