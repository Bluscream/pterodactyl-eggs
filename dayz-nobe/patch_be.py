#!/usr/bin/env python3
import os, sys

target = sys.argv[1] if len(sys.argv) > 1 else 'DayZServer'
if not os.path.exists(target):
    sys.exit(0)

with open(target, 'rb') as f:
    data = bytearray(f.read())

patched = False
if data.startswith(b'MZ'):
    sigs = [
        bytes.fromhex('40 53 55 56 57 41 54 48 81 EC'),
        bytes.fromhex('48 89 5C 24 08 48 89 6C 24 10 56 57 41 56 48 81 EC')
    ]
    for pat in sigs:
        pos = data.find(pat)
        if pos != -1:
            data[pos:pos+3] = bytes([0xB0, 0x01, 0xC3])
            patched = True
            break
elif data.startswith(b'\x7fELF'):
    pat = bytes.fromhex('41 55 41 54 55 53 48 89 fb 48 81 ec 28 01 00 00 c7 07 00 00 00 00 c6 47 10 00')
    pos = data.find(pat)
    if pos != -1:
        data[pos:pos+3] = bytes([0xB0, 0x01, 0xC3])
        patched = True
    elif data[0x11e9e10:0x11e9e13] == bytes([0xB0, 0x01, 0xC3]):
        patched = True
    else:
        p2 = bytes.fromhex('41 55 41 54 55 53 48 89 fb 48 81 ec 28 01 00 00')
        pos = data.find(p2, 0x1000000)
        if pos != -1:
            data[pos:pos+3] = bytes([0xB0, 0x01, 0xC3])
            patched = True

if patched:
    tmp = target + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.chmod(tmp, 0o755)
    os.replace(tmp, target)
    print(f"BattlEye patch applied to {target}")
