#!/usr/bin/env python3
"""Static inspection only: never loads native code or executes a plugin."""
import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path


def dex_summary(data):
    if data[:4] != b'dex\n':
        raise ValueError('Not a DEX file')
    def u32(offset):
        return struct.unpack_from('<I', data, offset)[0]
    def uleb(offset):
        value = 0
        for shift in range(0, 35, 7):
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, offset
        raise ValueError('Invalid ULEB128')
    strings = []
    for index in range(u32(56)):
        offset = u32(u32(60) + 4 * index)
        _, start = uleb(offset)
        strings.append(data[start:data.index(b'\0', start)].decode('utf-8', errors='replace'))
    types = [strings[u32(u32(68) + 4 * i)] for i in range(u32(64))]
    methods = []
    for i in range(u32(88)):
        cls, proto, name = struct.unpack_from('<HHI', data, u32(92) + i * 8)
        methods.append(types[cls] + '->' + strings[name])
    native = []
    for i in range(u32(96)):
        offset = u32(u32(100) + i * 32 + 24)
        if not offset:
            continue
        counts = []
        for _ in range(4):
            count, offset = uleb(offset)
            counts.append(count)
        for _ in range(counts[0] + counts[1]):
            _, offset = uleb(offset)
            _, offset = uleb(offset)
        for count in counts[2:]:
            index = 0
            for _ in range(count):
                delta, offset = uleb(offset)
                flags, offset = uleb(offset)
                code, offset = uleb(offset)
                index += delta
                if flags & 0x100:
                    native.append(methods[index])
    return {
        'version': data[4:7].decode(),
        'classes': u32(96),
        'method_references': len(methods),
        'native_methods': native,
        'android_type_references': [t for t in types if t.startswith(('Landroid/', 'Ldalvik/'))],
    }


def elf_summary(data):
    if data[:4] != b'\x7fELF':
        return {'format': 'not ELF'}
    bits = 64 if data[4] == 2 else 32
    order = '<' if data[5] == 1 else '>'
    machine = struct.unpack_from(order + 'H', data, 18)[0]
    if bits == 64:
        phoff = struct.unpack_from(order + 'Q', data, 32)[0]
        entsize, count = struct.unpack_from(order + 'HH', data, 54)
    else:
        phoff = struct.unpack_from(order + 'I', data, 28)[0]
        entsize, count = struct.unpack_from(order + 'HH', data, 42)
    loads, dynamic = [], None
    for i in range(count):
        pos = phoff + i * entsize
        if bits == 64:
            kind, flags, offset, address, physical, size, memsize, align = struct.unpack_from(order + 'IIQQQQQQ', data, pos)
        else:
            kind, offset, address, physical, size, memsize, flags, align = struct.unpack_from(order + 'IIIIIIII', data, pos)
        if kind == 1:
            loads.append((address, offset, size))
        if kind == 2:
            dynamic = (offset, size)
    needed, str_address = [], None
    if dynamic:
        step = 16 if bits == 64 else 8
        for pos in range(dynamic[0], dynamic[0] + dynamic[1], step):
            tag, value = struct.unpack_from(order + ('QQ' if bits == 64 else 'II'), data, pos)
            if tag == 0:
                break
            if tag == 1:
                needed.append(value)
            if tag == 5:
                str_address = value
    libraries = []
    if str_address is not None:
        for address, offset, size in loads:
            if address <= str_address < address + size:
                start = offset + str_address - address
                for entry in needed:
                    begin = start + entry
                    libraries.append(data[begin:data.index(b'\0', begin)].decode())
    return {'format': 'ELF', 'bits': bits, 'machine': {40: 'ARM', 183: 'AArch64'}.get(machine, str(machine)), 'needed_libraries': libraries}


def inspect(path):
    raw = path.read_bytes()
    result = {'file': path.name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'md5': hashlib.md5(raw).hexdigest(), 'entries': []}
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            value = {'name': entry.filename, 'bytes': entry.file_size}
            if entry.file_size > 20_000_000:
                raise ValueError('Entry too large')
            if entry.filename.endswith('.dex'):
                value['dex'] = dex_summary(archive.read(entry))
            if entry.filename.endswith('.so'):
                value['native'] = elf_summary(archive.read(entry))
            result['entries'].append(value)
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('jar', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    text = json.dumps(inspect(args.jar), ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')
