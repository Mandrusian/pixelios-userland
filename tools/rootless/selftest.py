#!/usr/bin/env python3
"""Synthetic input + expectations for `tools/build-ios-root-rootless.sh --selftest`.

  selftest.py tree DIR      write DIR/{os,sysos,appos}/root (run under fakeroot: some files are owned by 0/80/501/33)
  selftest.py keys          the files whose sha256 the guest reports
  selftest.py verify FILE   check the guest's report (vm.sh run list ...) of the built volume
"""
import os, plistlib, re, sys

LAUNCHD = {'LaunchDaemons': {
    'a': {'Label': 'com.apple.a', '_PanicOnCrash': True},
    'b': {'Label': 'com.apple.CommCenter', 'Program': '/usr/sbin/CommCenter'},
    'c': {'Label': 'com.apple.backboardd'},
    'd': {'Label': 'com.apple.ReportCrash'}}}
LONG = 'private/var/' + '/'.join(c * 40 for c in 'xyz') + '/file-with-a-long-path'   # > 100 chars: GNU tar long name
DSC = 'System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64'
CX = 'private/preboot/Cryptexes/'
KEYS = ['sbin/launchd', 'System/Library/xpc/launchd.plist', DSC, CX + 'OS/' + DSC,
        'usr/lib/libobjc-trampolines.dylib', 'usr/lib/libhl1', 'usr/lib/libhl2', 'usr/lib/libsym', 'usr/lib/libappsym',
        'usr/lib/libapp.dylib', 'private/var/keybags/systembag.kb',
        'private/var/mobile/Library/Preferences/com.apple.springboard.plist',
        'private/var/preferences/FeatureFlags/Domain/ExtensionKit.plist', 'Applications/A.app/Info.plist',
        'Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin/Contents/Info.plist', LONG,
        'Library/Wallpaper/Collections/X.wallpaperCollection/main.caml',
        'Library/Wallpaper/Collections/X.wallpaperCollection/layer.png']


def put(root, rel, data=b'', uid=0, gid=0, mode=0o644):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data)
    os.chown(p, uid, gid)
    os.chmod(p, mode)


def tree(d):
    os.umask(0o022)
    o = os.path.join(d, 'os/root')
    put(o, 'sbin/launchd', b'L' * 3000, mode=0o755)
    put(o, 'usr/lib/dyld', b'D' * 100, mode=0o755)
    put(o, 'System/Library/xpc/launchd.plist', plistlib.dumps(LAUNCHD), 0, 80)
    put(o, 'private/var/mobile/Library/Preferences/com.apple.springboard.plist', plistlib.dumps({'Keep': 1}), 501, 501, 0o600)
    put(o, 'private/var/db/placeholder', b'p')
    put(o, 'private/var/staged_system_apps/A.app/Info.plist', b'A')
    put(o, 'private/var/staged_system_apps/B.app/Info.plist', b'B-staged')
    put(o, 'Applications/B.app/Info.plist', b'B-installed')
    put(o, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/Contents/Info.plist', b'va')
    put(o, 'System/Library/Frameworks/MediaToolbox.framework/A/SubServerConfiguration.plist',
        plistlib.dumps({'StartRecorderServer': True}, fmt=plistlib.FMT_XML), 0, 80)
    put(o, 'private/var/containers/Data/System/UUID1/.com.apple.mobile_container_manager.metadata.plist',
        plistlib.dumps({'MCMMetadataIdentifier': 'com.apple.mobileactivationd'}))
    os.makedirs(os.path.join(o, 'private/var/containers/Data/System/UUID1/Library'))
    put(o, 'Library/Wallpaper/Collections/X.wallpaperCollection/main.caml', b'<a src="layer.HEIC"/>')
    put(o, 'Library/Wallpaper/Collections/X.wallpaperCollection/layer.HEIC', b'heic')
    put(o, LONG, b'long', 501, 501)
    os.makedirs(os.path.join(o, 'private/preboot'))
    os.symlink('private/var', os.path.join(o, 'var'))
    os.lchown(os.path.join(o, 'var'), 0, 80)
    s = os.path.join(d, 'sysos/root')
    put(s, DSC, b'C' * 5000)
    put(s, 'usr/lib/dyld', b'cryptex copy of an OS file: must not be linked')
    put(s, 'usr/lib/libobjc-trampolines.dylib', b'T' * 100)
    put(s, 'usr/lib/libhl1', b'hl')
    os.link(os.path.join(s, 'usr/lib/libhl1'), os.path.join(s, 'usr/lib/libhl2'))
    os.symlink('libobjc-trampolines.dylib', os.path.join(s, 'usr/lib/libsym'))
    a = os.path.join(d, 'appos/root')
    put(a, 'usr/lib/libapp.dylib', b'app')
    os.symlink('./libapp.dylib', os.path.join(a, 'usr/lib/libappsym'))
    put(a, 'usr/lib/libobjc-trampolines.dylib', b'already linked from the SystemOS cryptex')


def verify(report):
    with open(report, 'rb') as f:
        text = f.read().replace(b'\0', b'').decode('utf-8', 'surrogateescape')
    sec, cur = {}, None
    for line in text.splitlines():
        if line.startswith('== '):
            cur = line[3:].split()[0]
            sec[cur] = []
        elif cur:
            sec[cur].append(line)
    assert 'END' in sec, 'report is truncated'
    ls = {}
    for line in sec['LISTING']:
        m = re.match(r'(\d+) (\d+) (\d+) (directory|regular empty file|regular file|symbolic link) (.*)$', line)
        ls[m[5]] = (m[1], int(m[2]), int(m[3]), m[4])
    links = {l.split(' ', 1)[1]: int(l.split(' ', 1)[0]) for l in sec['LINKS']}
    hashes = {l.split('  ', 1)[1]: l.split('  ', 1)[0] for l in sec['HASHES'] if '  ' in l}
    bad = []

    def want(path, mode=None, uid=None, gid=None, typ=None):
        e = ls.get('./' + path)
        if e is None:
            bad.append('missing ' + path)
            return
        for name, w, g in (('mode', mode, e[0]), ('uid', uid, e[1]), ('gid', gid, e[2]), ('type', typ, e[3])):
            if w is not None and w != g:
                bad.append(f'{path}: {name} {g}, expected {w}')

    def nlink(path, n):
        if links.get('./' + path) != n:
            bad.append(f'{path}: {links.get("./" + path)} links, expected {n}')

    want('sbin/launchd', '755', 0, 0)
    want('System/Library/xpc/launchd.plist', '644', 0, 80)
    want(DSC, '644', 0, 0)
    nlink(DSC, 2)
    nlink(CX + 'OS/' + DSC, 2)
    want('usr/lib/libobjc-trampolines.dylib', '644', 0, 0)
    nlink('usr/lib/libobjc-trampolines.dylib', 2)
    nlink(CX + 'OS/usr/lib/libobjc-trampolines.dylib', 2)
    nlink('usr/lib/libhl1', 4)                       # root links + the two cryptex names share one inode
    nlink('usr/lib/libhl2', 4)
    want('usr/lib/libsym', typ='symbolic link')
    want('usr/lib/libappsym', typ='symbolic link')
    want(CX + 'App/usr/lib/libappsym', typ='symbolic link')
    want('usr/lib/dyld', '755', 0, 0)
    want('private/var/keybags', '700', 0, 0)
    want('private/var/keybags/systembag.kb', '600', 0, 0)
    for d, m in (('diagnostics', '751'), ('uuidtext', '755'), ('diagnostics/timesync', '755')):
        want('private/var/db/' + d, m, 272, 272)
        want(f'private/var/db/{d}/.migrated', '644', 272, 272)
    for sub, uid in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        want('private/var/containers/' + sub, '755', uid, uid)
    want('private/var/containers/Data/System/UUID1/Library/internal', '755', 501, 501)
    want('private/var/containers/Data/System/UUID1/Library/internal/data_ark.plist', '600', 501, 501)
    want('private/var/datamigrator/migrate', '644', 501, 501)
    want('private/var/mobile/Library/Preferences/com.apple.springboard.plist', '600', 501, 501)
    want('private/var/mobile/Library/Preferences/com.apple.purplebuddy.plist', '600', 501, 501)
    want('private/var/preferences/FeatureFlags/Domain/ExtensionKit.plist', '644', 0, 0)
    want('Applications/A.app/Info.plist', '644', 0, 0)
    want('Applications/B.app/Info.plist', '644')
    want('private/var/staged_system_apps/B.app/Info.plist', '644')
    want('Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin/Contents/Info.plist', '644')
    want('Library/Wallpaper/Collections/X.wallpaperCollection/layer.png', '644', 0, 0)
    want(LONG, '644', 501, 501)
    want('var', uid=0, gid=80, typ='symbolic link')
    for gone in ('private/var/staged_system_apps/A.app', 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin'):
        if './' + gone in ls:
            bad.append('should be gone: ' + gone)
    if hashes.get('usr/lib/libappsym') != hashes.get('usr/lib/libapp.dylib'):
        bad.append('libappsym does not resolve to libapp.dylib (symlink target mangled?)')
    if hashes.get('usr/lib/libhl1') != hashes.get('usr/lib/libhl2'):
        bad.append('hard linked cryptex files differ')
    for k in KEYS:
        if k not in hashes:
            bad.append('not hashed (missing or unreadable): ' + k)
    for b in bad:
        print('FAIL', b)
    if bad:
        sys.exit(1)
    print(f'verify: {len(ls)} entries, {len(KEYS)} key files hashed, all expectations hold')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'tree':
        tree(sys.argv[2])
    elif sys.argv[1:] == ['keys']:
        print('\n'.join(KEYS))
    elif len(sys.argv) == 3 and sys.argv[1] == 'verify':
        verify(sys.argv[2])
    else:
        sys.exit(__doc__)
