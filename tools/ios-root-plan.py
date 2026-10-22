#!/usr/bin/env python3
"""Rootless plan for the file-level steps tools/build-ios-root.sh does as root after the rsync copy.

  ios-root-plan.py OS_ROOT SYSOS_ROOT APPOS_ROOT OUTDIR [STREAMS]

The three roots are the apfs-fuse mounts (<mount>/root) of the OS, SystemOS and AppOS dmgs; they are only read.
Writes OUTDIR/ops.sh (sh lines, run in the qemu guest with R=<mounted HFS+ volume>) and OUTDIR/overlay.tar
(files with explicit owner/mode; extract it AFTER ops.sh with `tar -x -p --numeric-owner`). Together they
do what, on a volume that already holds the three trees (tools/build-ios-root-rootless.sh streams them):
  * tools/mkiosroot.sh: hard link the SystemOS shared cache to /System/Library/Caches/com.apple.dyld, hard link
    (symlinks: copy) every cryptex file that has no counterpart in the OS root, logd's db directories, the system keybag;
  * tools/sweet-root-tweaks.py (its Plan mode).
The tweaks must not look at a path that the cryptex links add (Plan raises if they do).

It also writes the payload: OUTDIR/shell.tar (the directories above the units, extract it first) and OUTDIR/s1.tar ..
sSTREAMS.tar (default 6; extract them in parallel into the same volume: a tar of the three trees, cut into disjoint
directory subtrees of about equal cost, see split()). Each stream is a concatenation of GNU tar archives without end
markers plus one end marker; the cryptex trees are renamed to private/preboot/Cryptexes/{OS,App}. Hard linked files
must stay inside one subtree (checked; the build fails otherwise).
"""
import concurrent.futures, time, os, shutil, stat, subprocess, sys, tarfile, tempfile, threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
spec = importlib.util.spec_from_file_location('tweaks', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sweet-root-tweaks.py'))
tweaks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tweaks)

DSC = 'System/Library/Caches/com.apple.dyld'
PREBOOT = 'private/preboot/Cryptexes'


class Volume:
    """The finished volume as the kernel sees it: the OS root, the SystemOS/AppOS roots at private/preboot/Cryptexes/{OS,App}
    and the links made so far. Symlinks (relative or absolute) resolve inside this layout, not on the host: the OS root links
    e.g. System/Library/Accounts/.../Bookmarks.bundle into /System/Cryptexes/OS, so the file already exists there."""

    def __init__(self, os_root, sysos, appos):
        self.maps = [(f'{PREBOOT}/OS', sysos), (f'{PREBOOT}/App', appos)]
        self.os_root = os_root
        self.have, self.have_dirs = set(), {PREBOOT}

    def real(self, v):
        for pre, root in self.maps:
            if v == pre or v.startswith(pre + '/'):
                return os.path.join(root, v[len(pre):].lstrip('/'))
        return os.path.join(self.os_root, v)

    def present(self, v):
        return v == '' or v in self.have or v in self.have_dirs or os.path.lexists(self.real(v))

    def resolve(self, rel):
        """(canonical path, whether the last component exists): symlinks are followed except a final one (test -e || test -L)."""
        todo, cur, hops = [c for c in rel.split('/') if c], '', 0
        while todo:
            c = todo.pop(0)
            if c == '.':
                continue
            if c == '..':
                cur = os.path.dirname(cur)
                continue
            nxt = os.path.join(cur, c)
            if not self.present(nxt):
                return os.path.join(nxt, *todo), False
            if todo and nxt not in self.have and nxt not in self.have_dirs and os.path.islink(self.real(nxt)):
                hops += 1
                if hops > 40:
                    raise SystemExit(f'symlink loop at {rel}')
                t = os.readlink(self.real(nxt))
                if t.startswith('/'):
                    cur = ''
                todo = [x for x in t.split('/') if x] + todo
                continue
            cur = nxt
        return cur, True

    def add(self, v):
        self.have.add(v)
        d = os.path.dirname(v)
        while d:
            self.have_dirs.add(d)
            d = os.path.dirname(d)


def cryptex_links(os_root, cryptexes):
    """[(cp?, src rel (inside the volume), dst rel)] in the order mkiosroot.sh creates them.
    cryptexes: [('OS', SYSOS_ROOT), ('App', APPOS_ROOT)]."""
    out = []
    vol = Volume(os_root, cryptexes[0][1], cryptexes[1][1])
    cdsc = os.path.join(cryptexes[0][1], DSC)
    for name in sorted(os.listdir(cdsc)) if os.path.isdir(cdsc) else []:
        if name.startswith('.'):
            continue                                        # the bash glob mkiosroot.sh uses skips dot files
        if os.path.isdir(os.path.join(cdsc, name)) and not os.path.islink(os.path.join(cdsc, name)):
            raise SystemExit(f'{cdsc}/{name} is a directory: mkiosroot.sh would fail on it')
        out.append((False, f'{PREBOOT}/OS/{DSC}/{name}', f'{DSC}/{name}'))
        if vol.resolve(f'{DSC}/{name}')[1]:
            raise SystemExit(f'{DSC}/{name} already exists in the OS root: mkiosroot.sh would fail on it')
        vol.add(f'{DSC}/{name}')
    for c, root in cryptexes:
        for dp, dn, fn in sorted(os.walk(root), key=lambda t: t[0]):
            rel = os.path.relpath(dp, root)
            if rel == DSC or rel.startswith(DSC + '/'):
                continue
            for f in sorted(fn + [d for d in dn if os.path.islink(os.path.join(dp, d))]):    # find ! -type d
                f = os.path.normpath(os.path.join(rel, f))
                parent, ok = vol.resolve(os.path.dirname(f))
                dst = os.path.join(parent, os.path.basename(f))
                if ok and vol.resolve(dst)[1] or dst in vol.have:
                    continue
                vol.add(dst)
                out.append((os.path.islink(os.path.join(root, f)), f'{PREBOOT}/{c}/{f}', dst))
    return out


# What the guest pays (measured under qemu TCG, hfsplus): about 1.6 ms per entry and 17 ms per MB.
ENTRY_COST, BYTE_COST = 1600, 0.017


class Node:
    def __init__(self, rel):
        self.rel, self.kids, self.files, self.own, self.w = rel, [], [], 0, 0


def scan(root, links):
    """Node tree of ROOT with weights; links: {(dev, ino): [rel]} of hard linked non-directories; returns (node, [(rel, uid, gid)] symlinks)."""
    owners = []

    def rec(rel):
        n = Node(rel)
        with os.scandir(os.path.join(root, rel)) as it:
            for e in sorted(it, key=lambda e: e.name):
                st = e.stat(follow_symlinks=False)
                r = os.path.join(rel, e.name) if rel != '.' else e.name
                n.own += 1
                n.w += ENTRY_COST + st.st_size * BYTE_COST * (stat.S_ISREG(st.st_mode))
                if stat.S_ISDIR(st.st_mode):
                    n.kids.append(rec(r))
                    continue
                n.files.append(r)
                if st.st_nlink > 1:
                    links.setdefault((st.st_dev, st.st_ino), []).append(r)
                if stat.S_ISLNK(st.st_mode) and (st.st_uid, st.st_gid) != (0, 0):
                    owners.append((r, st.st_uid, st.st_gid))
        n.w += sum(k.w for k in n.kids)
        return n

    return rec('.'), owners


def split(trees, k):
    """trees: [(name, node)]. -> (shell [(tree, rel)], units [(weight, tree, kind, rel|[rel])]): kind 'tree' = whole subtree,
    'files' = the non-directory entries of a split directory. Cut so that no unit is above half the per-stream cost."""
    limit = sum(n.w for _, n in trees) / k / 2
    shell, units = [], []

    def go(t, n):
        if n.w <= limit or not n.kids:
            units.append((n.w, t, 'tree', n.rel))
            return
        shell.append((t, n.rel))
        if n.files:
            units.append((n.own * ENTRY_COST, t, 'files', n.files))
        for c in n.kids:
            go(t, c)

    for t, n in trees:
        go(t, n)
    return shell, units


def check_links(tree, groups, units):
    """tar only keeps a hard link inside one archive: every group of hard linked files must sit in one unit."""
    owner = {}
    for i, (_, t, kind, rel) in enumerate(units):
        if t == tree:
            owner[('tree', rel) if kind == 'tree' else ('files', os.path.dirname(rel[0]) or '.')] = i
    for group in groups:
        found = set()
        for rel in group:
            d = os.path.dirname(rel) or '.'
            if ('files', d) in owner:
                found.add(owner[('files', d)])
                continue
            while ('tree', d) not in owner:
                d = os.path.dirname(d) or '.'
            found.add(owner[('tree', d)])
        if len(found) > 1:
            raise SystemExit(f'hard linked files in different archives (ROOTLESS_STREAMS=1 avoids this): {group[:3]}')


# apfs-fuse returns I/O errors when one mount is read by several processes at once (observed): one reader per mount.
# Its throughput does not grow with readers either (~70 MB/s), so nothing is lost; the three mounts are independent.
MOUNT_LOCK = {}


def run_tar(out, root, prefix, args, listfile=None):
    """Append one GNU tar archive without its end marker to the open file OUT."""
    with MOUNT_LOCK.setdefault(root, threading.Lock()):
        _run_tar(out, root, prefix, args, listfile)


def _run_tar(out, root, prefix, args, listfile):
    cmd = ['tar', '-c', '--numeric-owner', '--format=gnu', '-b1', '-C', root, '-f', '-']
    if prefix:
        cmd += ['--transform', f's,^\\.,{prefix},xS']          # S: leave symlink targets alone
    if listfile:
        cmd += ['--no-recursion', '--null', '-T', listfile]
    else:
        cmd += args
    with subprocess.Popen(cmd, stdout=subprocess.PIPE) as p:
        hold = b''
        while True:
            b = p.stdout.read(1 << 20)
            if not b:
                break
            b = hold + b
            out.write(b[:-1024])
            hold = b[-1024:]
        if p.wait() or hold != bytes(1024):
            raise SystemExit(f'tar {cmd[-3:]} failed (rc {p.returncode}) or did not end with the end marker')


def write_payload(outdir, roots, prefixes, shell, units, k):
    """shell.tar and s1.tar..sK.tar; the streams are filled by k threads (tar of the units, largest first)."""
    lists = tempfile.mkdtemp(dir=outdir)
    n = [0]

    def listfile(rels):
        n[0] += 1
        path = os.path.join(lists, str(n[0]))
        with open(path, 'wb') as f:
            f.write(b''.join(b'./' + os.fsencode(r) + b'\0' if r != '.' else b'.\0' for r in rels))
        return path

    with open(os.path.join(outdir, 'shell.tar'), 'wb') as out:
        for t in roots:
            dirs = [r for tt, r in shell if tt == t]
            if dirs:
                run_tar(out, roots[t], prefixes[t], None, listfile(dirs))
        out.write(bytes(1024))
    bins = [[] for _ in range(k)]
    load = [0] * k
    for w, t, kind, rel in sorted(units, key=lambda u: -u[0]):
        i = load.index(min(load))
        load[i] += w
        bins[i].append((t, kind, rel))
    print('streams (estimated seconds):', ' '.join('%.0f' % (x / 1e6) for x in load), flush=True)

    def fill(i):
        with open(os.path.join(outdir, f's{i + 1}.tar'), 'wb') as out:
            for t, kind, rel in bins[i]:
                if kind == 'tree':
                    run_tar(out, roots[t], prefixes[t], ['./' + rel if rel != '.' else '.'])
                else:
                    run_tar(out, roots[t], prefixes[t], None, listfile(rel))
            out.write(bytes(1024))

    ex = concurrent.futures.ThreadPoolExecutor(k)
    return lists, ex, [ex.submit(fill, i) for i in range(k)]


def main():
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    os_root, sysos, appos, outdir = sys.argv[1:5]
    k = int(sys.argv[5]) if len(sys.argv) == 6 else 6
    os.makedirs(outdir, exist_ok=True)
    t0 = time.monotonic()
    roots = {'os': os_root, 'sysos': sysos, 'appos': appos}
    prefixes = {'os': '', 'sysos': f'{PREBOOT}/OS', 'appos': f'{PREBOOT}/App'}
    link_sets = {}
    with concurrent.futures.ThreadPoolExecutor(3) as ex:
        futs = {t: ex.submit(scan, r, link_sets.setdefault(t, {})) for t, r in roots.items()}
        scanned = {t: f.result() for t, f in futs.items()}
    print(f'scanned in {time.monotonic() - t0:.0f} s; estimated guest seconds:', ', '.join(f'{t} {n.w / 1e6:.0f}' for t, (n, _) in scanned.items()), flush=True)
    shell, units = split([(t, scanned[t][0]) for t in roots], k)
    for t in roots:
        check_links(t, link_sets[t].values(), units)
    links = cryptex_links(os_root, [('OS', sysos), ('App', appos)])
    guard = {dst for _, _, dst in links}
    for dst in list(guard):                                  # directories the links create
        d = os.path.dirname(dst)
        while d and not os.path.lexists(os.path.join(os_root, d)):
            guard.add(d)
            d = os.path.dirname(d)
    os.makedirs(outdir, exist_ok=True)
    with tarfile.open(os.path.join(outdir, 'overlay.tar'), 'w', format=tarfile.GNU_FORMAT) as tar:
        plan = tweaks.Plan(os_root, tar, guard)
        made = set()
        for cp, src, dst in links:
            d = os.path.dirname(dst)
            if d and d not in made:
                made.add(d)
                plan.sh('mkdir -p', plan.q(d))
            plan.sh('cp -P' if cp else 'ln', plan.q(src), plan.q(dst))
        # busybox tar does not give symlinks their owner (rsync -a did: /var is root:wheel)
        for t in roots:
            for rel, uid, gid in sorted(scanned[t][1]):
                plan.sh('chown -h', f'{uid}:{gid}', plan.q(os.path.join(prefixes[t], rel).lstrip('/')))
        # logd's log stores (it checks owner _logd and mode, plus a .migrated marker)
        db = 'private/var/db'
        for d, mode in (('diagnostics', 0o751), ('uuidtext', 0o755), ('diagnostics/timesync', 0o755)):
            plan.makedirs(f'{db}/{d}')
            plan.chown(f'{db}/{d}', 272, 272)
            plan.chmod(f'{db}/{d}', mode)
        for d in ('diagnostics', 'uuidtext', 'diagnostics/timesync'):
            plan.write(f'{db}/{d}/.migrated', b'', 272, 272, 0o644)
        # system keybag for the built-in AppleKeyStore (no passcode)
        plan.makedirs('private/var/keybags')
        plan.chown('private/var/keybags', 0, 0)
        plan.chmod('private/var/keybags', 0o700)
        plan.write('private/var/keybags/systembag.kb', ('\n'.join([
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
            '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>']) + '\n').encode(), 0, 0, 0o600)
        tweaks.apply(plan)
    tweaks.write_plan(plan, outdir)
    print(f'plan after {time.monotonic() - t0:.0f} s: {len(links)} cryptex links, {len(plan.ops)} ops, {len(plan.new_files)} files in the overlay', flush=True)
    lists, ex, payload = write_payload(outdir, roots, prefixes, shell, units, k)
    for f in payload:
        f.result()
    ex.shutdown()
    shutil.rmtree(lists)
    print(f'payload after {time.monotonic() - t0:.0f} s')


if __name__ == '__main__':
    main()
