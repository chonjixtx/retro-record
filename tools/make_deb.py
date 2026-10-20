#!/usr/bin/env python3
"""
纯 Python 打 deb（CI 上没有 dpkg-deb 也能用）。

产出三份东西，都以 base64 打到构建日志里带回：
  1) RetroSaveInGame.dylib 本体（手动用 Filza 放也能用）
  2) rootless 版 deb：data.tar 里路径带 var/jb 前缀（dopamine / palera1n rootless）
  3) roothide 版 deb：data.tar 里路径不带前缀（roothide 的 dpkg 会自动重定位到随机 jbroot）
"""
import sys, os, io, gzip, tarfile, base64

def tar_gz(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        for name, data, mode in files:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mode = mode
            ti.uid = 0
            ti.gid = 0
            ti.uname = 'root'
            ti.gname = 'wheel'
            ti.mtime = 0
            tf.addfile(ti, io.BytesIO(data))
    return gzip.compress(buf.getvalue(), 9)

def ar_pack(members):
    out = io.BytesIO()
    out.write(b'!<arch>\n')
    for name, data in members:
        n = name.encode() + b'/'
        h = bytearray(b' ' * 60)
        h[0:len(n)] = n
        h[16:28] = b'0'.ljust(12)
        h[28:34] = b'0'.ljust(6)
        h[34:40] = b'0'.ljust(6)
        h[40:48] = b'100644'.ljust(8)
        h[48:58] = ('%d' % len(data)).encode().ljust(10)
        h[58:60] = b'`\n'
        out.write(bytes(h))
        out.write(data)
        if len(data) % 2:
            out.write(b'\n')
    return out.getvalue()

def build_deb(dylib, plist, control, out, prefix):
    ctrl = open(control, 'rb').read()
    dy = open(dylib, 'rb').read()
    pl = open(plist, 'rb').read()
    d = prefix + 'Library/MobileSubstrate/DynamicLibraries/'
    data = tar_gz([
        ('./' + d + 'RetroSaveInGame.dylib', dy, 0o755),
        ('./' + d + 'RetroSaveInGame.plist', pl, 0o644),
    ])
    ctl = tar_gz([('./control', ctrl, 0o644)])
    blob = ar_pack([
        ('debian-binary', b'2.0\n'),
        ('control.tar.gz', ctl),
        ('data.tar.gz', data),
    ])
    open(out, 'wb').write(blob)
    return len(blob)

def emit(tag, path):
    if not os.path.exists(path):
        print('MISSING', tag)
        return
    raw = open(path, 'rb').read()
    b64 = base64.b64encode(raw).decode('ascii')
    print('===B64_%s_START===' % tag)
    for i in range(0, len(b64), 3000):
        print(b64[i:i + 3000])
    print('===B64_%s_END===' % tag)
    print('SIZE_%s=%d' % (tag, len(raw)))

def main():
    dylib, plist, ctrl_rootless, ctrl_roothide, outdir = sys.argv[1:6]
    os.makedirs(outdir, exist_ok=True)

    emit('DYLIB', dylib)

    p1 = os.path.join(outdir, 'RetroSaveInGame-rootless.deb')
    n1 = build_deb(dylib, plist, ctrl_rootless, p1, 'var/jb/')
    print('rootless deb bytes=%d' % n1)
    emit('DEB_ROOTLESS', p1)

    p2 = os.path.join(outdir, 'RetroSaveInGame-roothide.deb')
    n2 = build_deb(dylib, plist, ctrl_roothide, p2, '')
    print('roothide deb bytes=%d' % n2)
    emit('DEB_ROOTHIDE', p2)

main()
