#!/usr/bin/env python3
"""sweet-root-tweaks.py: make an iOS 16.7.16 (20H392) root tree reach the home screen on the phone.

  sweet-root-tweaks.py ROOT             edit the mounted root ROOT in place (needs root for chown)
  sweet-root-tweaks.py --plan SRC OUT   leave SRC untouched; write OUT/overlay.tar and OUT/ops.sh (no root needed).
                                        Consumer: run ops.sh with R=<target root>, then
                                        tar -x -p --numeric-owner -C "$R" -f overlay.tar

Both modes run the same tweaks (apply) over a small file-system object: Live edits a directory, Plan records
what Live would do. Paths given to the object are relative to the root.
"""
import fnmatch, io, os, plistlib, shutil, subprocess, sys, tarfile, tempfile

BUILD = '20H392'
VERSION = '16.7.16'
MOBILE = 501                      # uid and gid of the user "mobile"

USAGE = __doc__


def _join(a, b):
    return a + '/' + b if a else b


class FS:
    """Shared part: glob and walk are built on listdir/isdir, so the guard of Plan covers them."""

    def glob(self, pattern):
        """Root-relative paths matching PATTERN (fnmatch per component, sorted)."""
        found = ['']
        for comp in pattern.split('/'):
            nxt = []
            for base in found:
                if not any(c in comp for c in '*?['):
                    p = _join(base, comp)
                    if self.exists(p):
                        nxt.append(p)
                    continue
                if not self.isdir(base):
                    continue
                for name in self.listdir(base):
                    if fnmatch.fnmatchcase(name, comp):
                        p = _join(base, name)
                        self._touch_check(p)
                        nxt.append(p)
            found = nxt
        return found

    def _touch_check(self, path):
        pass

    def walk(self, path):
        """Like os.walk top-down, with sorted names and root-relative dirpaths."""
        names = self.listdir(path)
        dirs = [n for n in names if self.isdir(_join(path, n))]
        files = [n for n in names if n not in dirs]
        yield path, dirs, files
        for d in dirs:
            if not self.islink(_join(path, d)):     # like os.walk: a linked dir is listed, not entered
                yield from self.walk(_join(path, d))


class Live(FS):
    """Edits the tree under ROOT."""

    def __init__(self, root):
        self.root = root

    def _p(self, path):
        return os.path.join(self.root, path) if path else self.root

    def exists(self, path):
        return os.path.lexists(self._p(path))

    def isdir(self, path):
        return os.path.isdir(self._p(path))

    def islink(self, path):
        return os.path.islink(self._p(path))

    def listdir(self, path):
        return sorted(os.listdir(self._p(path)))

    def walk(self, path):
        for dp, dn, fn in os.walk(self._p(path)):
            dn.sort()
            rel = os.path.relpath(dp, self.root)
            yield ('' if rel == '.' else rel), dn, sorted(fn)

    def stat(self, path):
        st = os.lstat(self._p(path))
        return st.st_uid, st.st_gid, st.st_mode & 0o7777

    def read(self, path):
        with open(self._p(path), 'rb') as f:
            return f.read()

    def write(self, path, data, uid, gid, mode):
        p = self._p(path)
        if os.path.islink(p):
            raise RuntimeError(f'{path}: is a symlink, not writing through it')
        with open(p, 'wb') as f:
            f.write(data)
        os.chown(p, uid, gid)
        os.chmod(p, mode)

    def makedirs(self, path):
        os.makedirs(self._p(path), exist_ok=True)

    def touch(self, path):
        with open(self._p(path), 'ab'):
            pass

    def chown(self, path, uid, gid):
        os.chown(self._p(path), uid, gid)

    def chmod(self, path, mode):
        os.chmod(self._p(path), mode)

    def move(self, old, new):
        shutil.move(self._p(old), self._p(new))

    def heic_to_png(self, heic, png):
        dst = self._p(png)
        subprocess.run(['heif-convert', self._p(heic), dst], check=True, stdout=subprocess.DEVNULL)
        os.chown(dst, 0, 0)
        os.chmod(dst, 0o644)


class Plan(FS):
    """Records the commands (self.ops) and file contents (into TAR) that make SRC look like Live's result.
    SRC is only read. guard: root-relative paths that a later build step adds; looking at them raises."""

    def __init__(self, src, tar, guard=()):
        self.src, self.tar = src, tar
        self.guard = {g.strip('/') for g in guard}
        self.ops = []
        self.new_files = {}             # path -> (uid, gid, mode, data): the tar entries
        self.added_dirs = set()         # directories made by mkdir -p
        self.added_other = set()        # touched or moved-in non-directories
        self.gone = set()               # source paths removed or moved away
        self.meta = {}                  # path -> [uid, gid, mode] after chown/chmod

    # -- recording helpers (also used by the caller) --
    @staticmethod
    def q(path):
        return '"$R"/\'' + path.replace("'", "'\\''") + "'"

    def sh(self, *parts):
        self.ops.append(' '.join(parts))

    # -- guard --
    def _guard(self, path, mode='exists'):
        path = path.strip('/')
        for g in self.guard:
            hit = path == g or path.startswith(g + '/')
            if mode == 'list':
                hit = hit or os.path.dirname(g) == path
            elif mode == 'walk':
                hit = hit or path == '' or g.startswith(path + '/')
            if hit:
                raise RuntimeError(f'{path or "/"}: a later step changes {g}')

    def _touch_check(self, path):
        self._guard(path)

    # -- unguarded state (what the final tree holds) --
    def _planned(self, p):
        return p in self.new_files or p in self.added_dirs or p in self.added_other

    def _gone(self, p):
        while p:
            if p in self.gone:
                return True
            p = os.path.dirname(p)
        return False

    def _has(self, p):
        if p == '' or self._planned(p):
            return True
        return not self._gone(p) and os.path.lexists(os.path.join(self.src, p))

    def _isdir(self, p):
        if p == '' or p in self.added_dirs:
            return True
        if p in self.new_files or p in self.added_other or self._gone(p):
            return False
        return os.path.isdir(os.path.join(self.src, p))

    def _names(self, p):
        names = set()
        if not self._gone(p) and os.path.isdir(os.path.join(self.src, p)):
            names.update(n for n in os.listdir(os.path.join(self.src, p))
                         if self._planned(_join(p, n)) or not self._gone(_join(p, n)))
        for s in (self.new_files, self.added_dirs, self.added_other):
            names.update(os.path.basename(x) for x in s if x and os.path.dirname(x) == p)
        return sorted(names)

    def _stat(self, p):
        if p in self.meta:
            return tuple(self.meta[p])
        if p in self.new_files:
            u, g, m, _ = self.new_files[p]
            return u, g, m
        if p in self.added_dirs:
            return 0, 0, 0o755
        if p in self.added_other:
            return 0, 0, 0o644
        st = os.lstat(os.path.join(self.src, p))
        return st.st_uid, st.st_gid, st.st_mode & 0o7777

    # -- queries (guarded) --
    def exists(self, path):
        self._guard(path)
        return self._has(path.strip('/'))

    def isdir(self, path):
        self._guard(path)
        return self._isdir(path.strip('/'))

    def islink(self, path):
        p = path.strip('/')
        self._guard(p)
        if self._planned(p) or self._gone(p):
            return False
        return os.path.islink(os.path.join(self.src, p))

    def listdir(self, path):
        self._guard(path, 'list')
        p = path.strip('/')
        if not self._isdir(p):
            raise FileNotFoundError(p)
        return self._names(p)

    def walk(self, path):
        self._guard(path, 'walk')
        yield from FS.walk(self, path.strip('/'))

    def stat(self, path):
        self._guard(path)
        p = path.strip('/')
        if not self._has(p):
            raise FileNotFoundError(p)
        return self._stat(p)

    def read(self, path):
        self._guard(path)
        p = path.strip('/')
        if p in self.new_files:
            return self.new_files[p][3]
        if not self._has(p) or p in self.added_dirs or p in self.added_other:
            raise FileNotFoundError(p)
        with open(os.path.join(self.src, p), 'rb') as f:
            return f.read()

    # -- changes (recorded) --
    def write(self, path, data, uid, gid, mode):
        self._guard(path)
        p = path.strip('/')
        if not self._isdir(os.path.dirname(p)):
            raise FileNotFoundError(os.path.dirname(p))
        if p not in self.new_files and p not in self.added_other and self._has(p):
            if os.path.islink(os.path.join(self.src, p)):
                raise RuntimeError(f'{path}: is a symlink, not writing through it')
            if os.lstat(os.path.join(self.src, p)).st_nlink > 1:
                raise RuntimeError(f'{p}: has several hard links, an in-place write would change all of them')
            self.sh('rm -f', self.q(p))
        info = tarfile.TarInfo(p)
        info.size, info.uid, info.gid, info.mode = len(data), uid, gid, mode
        info.mtime = 0
        self.tar.addfile(info, io.BytesIO(data))
        self.new_files[p] = (uid, gid, mode, data)
        self.added_other.discard(p)
        self.gone.discard(p)
        self.meta.pop(p, None)

    def makedirs(self, path):
        self._guard(path)
        p = path.strip('/')
        if self._has(p):
            return
        self.sh('mkdir -p', self.q(p))
        while p and not self._has(p):
            self.added_dirs.add(p)
            p = os.path.dirname(p)

    def touch(self, path):
        self._guard(path)
        p = path.strip('/')
        if self._has(p):
            return
        self.sh('touch', self.q(p))
        self.added_other.add(p)

    def _no_overlay(self, p):
        if p in self.new_files:
            raise RuntimeError(f'{p}: already in the overlay tar, give the final owner/mode to write()')

    def chown(self, path, uid, gid):
        self._guard(path)
        p = path.strip('/')
        self._no_overlay(p)
        self.sh('chown', f'{uid}:{gid}', self.q(p))
        self.meta[p] = [uid, gid, self._stat(p)[2]]

    def chmod(self, path, mode):
        self._guard(path)
        p = path.strip('/')
        self._no_overlay(p)
        self.sh('chmod', '%o' % mode, self.q(p))
        self.meta[p] = [*self._stat(p)[:2], mode]

    def move(self, old, new):
        self._guard(old)
        self._guard(new)
        o, n = old.strip('/'), new.strip('/')
        self._no_overlay(o)
        isdir = self._isdir(o)
        self.sh('mv', self.q(o), self.q(n))
        for s in (self.added_dirs, self.added_other):
            s.discard(o)
        self.gone.add(o)
        self.gone.discard(n)
        (self.added_dirs if isdir else self.added_other).add(n)

    def heic_to_png(self, heic, png):
        with tempfile.TemporaryDirectory() as t:
            out = os.path.join(t, 'out.png')
            subprocess.run(['heif-convert', os.path.join(self.src, heic.strip('/')), out], check=True,
                           stdout=subprocess.DEVNULL)
            with open(out, 'rb') as f:
                data = f.read()
        self.write(png, data, 0, 0, 0o644)


def write_plan(plan, outdir):
    with open(os.path.join(outdir, 'ops.sh'), 'w') as f:
        f.write(''.join(op + '\n' for op in plan.ops))


# ---- tweaks ----

def edit_plist(fs, path, fn, fmt=plistlib.FMT_BINARY):
    """Load PATH, let FN change the dict in place, write it back with the same owner and mode."""
    uid, gid, mode = fs.stat(path)
    data = plistlib.loads(fs.read(path))
    fn(data)
    fs.write(path, plistlib.dumps(data, fmt=fmt), uid, gid, mode)


DROPPED_JOBS = {'com.apple.CommCenter', 'com.apple.fairplayd.H2', 'com.apple.voicemail.vmd', 'com.apple.ReportCrash',
                'com.apple.spindump', 'com.apple.tailspind', 'com.apple.aggregated', 'com.apple.aggregated.addaily'}


def tweak_launchd(fs):
    # Panic-on-crash would reboot the phone on the first crashing daemon; baseband-less CommCenter loops, fairplayd
    # relaunches forever (blocks locationd), vmd retries a missing service, the diagnostics daemons cost CPU;
    # backboardd needs CA_BACKDROP_SCALE or blurs break on the CPU renderer.
    counts = {'renamed': 0, 'removed': 0, 'backboardd': 0}

    def fix(pl):
        jobs = pl['LaunchDaemons']
        for key in [k for k, j in jobs.items() if j.get('Label') in DROPPED_JOBS]:
            del jobs[key]
            counts['removed'] += 1
        for job in jobs.values():
            if '_PanicOnCrash' in job:
                job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
                counts['renamed'] += 1
            if job.get('Label') == 'com.apple.backboardd':
                job.setdefault('EnvironmentVariables', {})['CA_BACKDROP_SCALE'] = '1'
                counts['backboardd'] += 1
    edit_plist(fs, 'System/Library/xpc/launchd.plist', fix)
    print('launchd.plist: %(renamed)d _PanicOnCrash renamed, %(removed)d jobs removed, %(backboardd)d backboardd patched' % counts)


def tweak_containers(fs):
    # containermanagerd expects these directories to exist on first boot.
    base = 'private/var/containers'
    for sub, owner in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        path = f'{base}/{sub}'
        if fs.isdir(path):
            continue
        fs.makedirs(path)
        fs.chown(path, owner, owner)
        fs.chmod(path, 0o755)
        print('made', path)


def tweak_activation(fs):
    # Mark the phone as activated so setup does not wait for Apple's servers.
    ident = 'com.apple.mobileactivationd'
    for d in fs.glob('private/var/containers/Data/System/*'):
        meta = d + '/.com.apple.mobile_container_manager.metadata.plist'
        if fs.exists(meta) and plistlib.loads(fs.read(meta)).get('MCMMetadataIdentifier') == ident:
            break
    else:
        print('warning: no mobileactivationd data container found, activation not set')
        return
    internal = d + '/Library/internal'
    fs.makedirs(internal)
    fs.chown(internal, MOBILE, MOBILE)
    fs.chmod(internal, 0o755)
    ark = {'-ActivationState': 'Activated', '-BrickState': False, '-BuildVersion': BUILD, '-ProductVersion': VERSION,
           '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True}
    fs.write(internal + '/data_ark.plist', plistlib.dumps(ark, fmt=plistlib.FMT_BINARY), MOBILE, MOBILE, 0o600)
    print('activation:', d)


def tweak_feature_flags(fs):
    # Without a signing-capable xpc cache, extension loading fails: switch the enforcement flag off.
    d = 'private/var/preferences/FeatureFlags/Domain'
    fs.makedirs(d)
    fs.write(d + '/ExtensionKit.plist',
             plistlib.dumps({'enforce_xpc_cache_code_signing': {'Enabled': False}}, fmt=plistlib.FMT_XML), 0, 0, 0o644)


def tweak_audio(fs):
    # The virtual audio HAL plug-in cannot load here; the recorder server of MediaToolbox is turned off.
    plugin = 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin'
    if fs.exists(plugin):
        fs.makedirs('Library/Audio/Plug-Ins/HAL.disabled')
        fs.move(plugin, 'Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin')
    for cfg in fs.glob('System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist'):
        edit_plist(fs, cfg, lambda pl: pl.__setitem__('StartRecorderServer', False), plistlib.FMT_XML)


def tweak_stock_apps(fs):
    # Stock apps ship staged; SpringBoard only shows those in /Applications.
    staged = 'private/var/staged_system_apps'
    if not fs.isdir(staged):
        print('no staged_system_apps, skipped')
        return
    if not fs.isdir('Applications'):
        fs.makedirs('Applications')
    moved = 0
    for name in fs.listdir(staged):
        if not fs.exists('Applications/' + name):
            fs.move(f'{staged}/{name}', 'Applications/' + name)
            moved += 1
    print('stock apps moved:', moved)


def tweak_wallpapers(fs):
    # Wallpaper layers are HEIC; the CPU renderer here reads PNG, so add PNG copies and point main.caml at them.
    top = 'Library/Wallpaper/Collections'
    if not fs.isdir(top):
        return
    if not shutil.which('heif-convert'):
        print('heif-convert not found: wallpapers not converted')
        return
    count = 0
    for dp, _, files in list(fs.walk(top)):
        for name in files:
            if name.lower().endswith('.heic'):
                count += 1
                png = _join(dp, name[:-5] + '.png')
                if not fs.exists(png):
                    fs.heic_to_png(_join(dp, name), png)
            elif name == 'main.caml':
                path = _join(dp, name)
                text = fs.read(path).decode('utf-8', 'surrogateescape')
                if '.HEIC"' in text:
                    uid, gid, mode = fs.stat(path)
                    fs.write(path, text.replace('.HEIC"', '.png"').encode('utf-8', 'surrogateescape'), uid, gid, mode)
    print('wallpaper HEIC files:', count)


def tweak_device_name(fs):
    # Show a sensible name in Settings and on the network.
    d = 'private/var/preferences/SystemConfiguration'
    fs.makedirs(d)
    path = d + '/preferences.plist'
    pl = plistlib.loads(fs.read(path)) if fs.exists(path) else {}
    name = 'Pixel 6a'
    sysd = pl.setdefault('System', {}).setdefault('System', {})
    sysd['ComputerName'] = name
    sysd['ComputerNameEncoding'] = 0x8000000
    sysd['HostName'] = name.replace(' ', '-')
    fs.write(path, plistlib.dumps(pl, fmt=plistlib.FMT_BINARY), 0, 0, 0o644)


def tweak_migration(fs):
    # An existing sentinel tells datamigrator that the data is already current.
    fs.makedirs('private/var/datamigrator')
    fs.touch('private/var/datamigrator/migrate')
    fs.chown('private/var/datamigrator/migrate', MOBILE, MOBILE)


PREFS = (
    ('com.apple.springboard', {'BKNoWatchdogs': True, 'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
                               'MCForceShowCloudConfigurationUI': False, 'BSUIVibrancyEffectViewDisabled': True}),
    ('com.apple.purplebuddy', {'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11,
                               'daemonizeNeedsToRun': False}),
    ('com.apple.purplebuddy.notbackedup', {k: False for k in (
        'ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy', 'ShouldRunKeychainSyncMiniBuddy',
        'ShouldRunMesaMiniBuddy', 'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy', 'SilentICDPUpgrade')}),
    ('com.apple.managedconfiguration.notbackedup', {'LockdownActivationIndicatesCloudConfigurationAvailable': False}),
)


def tweak_preferences(fs):
    # Skip Setup Assistant and watchdogs that kill slow first launches.
    for name, keys in PREFS:
        path = f'private/var/mobile/Library/Preferences/{name}.plist'
        pl = plistlib.loads(fs.read(path)) if fs.exists(path) else {}
        pl.update(keys)
        fs.write(path, plistlib.dumps(pl, fmt=plistlib.FMT_BINARY), MOBILE, MOBILE, 0o600)
        print(name + ':', ', '.join(sorted(keys)))


def apply(fs):
    for step in (tweak_launchd, tweak_containers, tweak_activation, tweak_feature_flags, tweak_audio,
                 tweak_stock_apps, tweak_wallpapers, tweak_device_name, tweak_migration, tweak_preferences):
        step(fs)


def main(argv):
    def usage():
        sys.stderr.write(USAGE)
        return 2

    def is_root(d):
        return os.path.isdir(os.path.join(d, 'System/Library/xpc'))

    if len(argv) == 4 and argv[1] == '--plan':
        src, outdir = argv[2], argv[3]
        if not is_root(src):
            return usage()
        os.makedirs(outdir, exist_ok=True)
        with tarfile.open(os.path.join(outdir, 'overlay.tar'), 'w', format=tarfile.GNU_FORMAT) as tar:
            plan = Plan(src, tar)
            apply(plan)
        write_plan(plan, outdir)
        return 0
    if len(argv) == 2 and not argv[1].startswith('-') and is_root(argv[1]):
        apply(Live(argv[1]))
        return 0
    return usage()


if __name__ == '__main__':
    sys.exit(main(sys.argv))
