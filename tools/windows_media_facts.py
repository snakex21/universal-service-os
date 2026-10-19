"""Read bounded installer metadata from an ISO9660 bridge, never extract a disc.

Host inventory helper. Outputs facts only, not copies of Microsoft files.
"""
import importlib.util
import json
import pathlib
import re
import struct
import xml.etree.ElementTree as ET

BLOCK = 2048
LIMIT = 2 * 1024 * 1024


class ISO:
    def __init__(self, file):
        self.file = file
        self.entries = {}
        self.file.seek(16 * BLOCK)
        pvd = self.file.read(BLOCK)
        if pvd[:7] != b'\x01CD001\x01':
            raise ValueError('No primary ISO9660 descriptor; inspect the UDF directory with 7-Zip')
        self.label = pvd[40:72].decode('ascii', 'replace').strip()
        self._directory('', self._record(pvd[156:]), set())

    @staticmethod
    def _record(data):
        return struct.unpack_from('<I', data, 2)[0], struct.unpack_from('<I', data, 10)[0], bool(data[25] & 2)

    def _directory(self, parent, record, seen):
        lba, size, _ = record
        if lba in seen or size > LIMIT:
            return
        seen.add(lba)
        self.file.seek(lba * BLOCK)
        data = self.file.read(size)
        offset = 0
        while offset < len(data):
            length = data[offset]
            if length == 0:
                offset = (offset // BLOCK + 1) * BLOCK
                continue
            entry = data[offset:offset + length]
            if len(entry) < 34:
                raise ValueError('Invalid ISO directory record')
            name = entry[33:33 + entry[32]]
            offset += length
            if name in (b'\0', b'\1'):
                continue
            name = name.decode('ascii', 'replace').split(';')[0]
            relative = (parent + '/' + name).lstrip('/').lower()
            rec = self._record(entry)
            self.entries[relative] = rec
            if rec[2]:
                self._directory(relative, rec, seen)

    def read(self, name, offset=0, length=None):
        lba, size, directory = self.entries[name.lower()]
        if directory:
            raise ValueError('Not a file')
        length = size - offset if length is None else length
        if offset < 0 or length < 0 or length > LIMIT or offset + length > size:
            raise ValueError('Bounded metadata read exceeded')
        self.file.seek(lba * BLOCK + offset)
        data = self.file.read(length)
        if len(data) != length:
            raise ValueError('Truncated metadata')
        return data


def decode(data):
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16')
    return data.decode('utf-8-sig', 'replace')


def ini_facts(text):
    result = {}
    wanted = {'majorversion', 'minorversion', 'buildnumber', 'producttype', 'architecture',
              'defaultlayout', 'pid', 'product', 'version', 'localization', 'buildbranch',
              'buildarch', 'buildtype', 'productname', 'winntversion', 'win95version'}
    section = ''
    for line in text.splitlines():
        line = line.split(';', 1)[0].strip()
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1]
        elif '=' in line:
            key, value = (part.strip() for part in line.split('=', 1))
            if key.lower() in wanted:
                result[section + '.' + key.lower()] = value.strip('"')
            if section.lower() == 'available ui languages':
                result.setdefault('available_languages', {})[key] = value
    return result


def pe_facts(data):
    result = {}
    if data[:2] != b'MZ' or len(data) < 64:
        return result
    pe = struct.unpack_from('<I', data, 60)[0]
    if data[pe:pe + 2] not in (b'PE', b'NE'):
        return result
    if data[pe:pe + 4] == b'PE\0\0' and pe + 6 <= len(data):
        result['machine'] = hex(struct.unpack_from('<H', data, pe + 4)[0])
    fixed = data.find(b'\xbd\x04\xef\xfe\x00\x00\x01\x00')
    if fixed >= 0 and fixed + 24 <= len(data):
        ms, ls = struct.unpack_from('<II', data, fixed + 8)
        result['file_version'] = [ms >> 16, ms & 65535, ls >> 16, ls & 65535]
    return result


def wim_facts(iso, name):
    header = iso.read(name, length=208)
    if header[:8] != b'MSWIM\0\0\0':
        return {'format': 'pre-RTM/unknown', 'header_signature': header[:8].hex()}
    version = struct.unpack_from('<I', header, 12)[0]
    if version not in (0x10d00, 0xe00):
        result = {'format': hex(version), 'xml': 'unsupported header layout; standard offsets must not be used'}
        # Old WIM metadata may be plain XML at the tail, but has no WINDOWS/
        # VERSION subtree. Read at most LIMIT bytes; never decode image data.
        if version in (0x10a00, 0x10c00):
            total = iso.entries[name.lower()][1]
            tail = iso.read(name, max(0, total - LIMIT), min(total, LIMIT))
            start = tail.find('<WIM'.encode('utf-16le'))
            close = '</WIM>'.encode('utf-16le')
            end = tail.rfind(close)
            if start >= 0 and end >= start:
                try:
                    tree = ET.fromstring(tail[start:end + len(close)].decode('utf-16le'))
                    result['metadata_method'] = 'bounded tail XML, no modern resource offsets'
                    result['images'] = [{k: image.findtext(k) for k in ('DESCRIPTION', 'FLAGS') if image.findtext(k) is not None} for image in tree.findall('IMAGE')]
                    result['image_count'] = len(result['images'])
                except (UnicodeError, ET.ParseError):
                    pass
        return result
    size_flags, offset, original = struct.unpack_from('<QQQ', header, 72)
    size = size_flags & ((1 << 56) - 1)
    result = {'format': hex(struct.unpack_from('<I', header, 12)[0]), 'xml_bytes': size,
              'image_count': struct.unpack_from('<I', header, 44)[0]}
    if size != original:
        result['xml'] = 'compressed; not read'
        return result
    xml = iso.read(name, offset, size)
    tree = ET.fromstring(xml.decode('utf-16').lstrip('\ufeff'))
    fields = ['NAME', 'FLAGS', 'WINDOWS/ARCH', 'WINDOWS/EDITIONID', 'WINDOWS/PRODUCTNAME',
              'WINDOWS/INSTALLATIONTYPE', 'WINDOWS/PRODUCTTYPE', 'WINDOWS/LANGUAGES/LANGUAGE',
              'WINDOWS/VERSION/MAJOR', 'WINDOWS/VERSION/MINOR', 'WINDOWS/VERSION/BUILD', 'WINDOWS/VERSION/SPBUILD']
    result['images'] = [{key: image.findtext(key) for key in fields if image.findtext(key) is not None}
                        for image in tree.findall('IMAGE')]
    return result


def inspect(path):
    result = {'path': str(path), 'bytes': path.stat().st_size, 'metadata': {}, 'read_only': True}
    with path.open('rb') as file:
        iso = ISO(file)
        result['volume_label'] = iso.label
        if 'sources/install.wim' not in iso.entries and 'i386/txtsetup.sif' not in iso.entries:
            try:
                spec = importlib.util.spec_from_file_location('usos_udf_metadata', pathlib.Path(__file__).with_name('udf_metadata.py'))
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                iso = module.UDF(file)
                result['filesystem'] = 'UDF'
            except (ValueError, KeyError):
                pass
        result['cd_markers'] = sorted(n for n in iso.entries if '/' not in n and (n.startswith('win51') or n.startswith('cdrom')))
        result['setup_layout'] = [n for n in iso.entries if n in {
            'sources/boot.wim', 'sources/install.wim', 'sources/install.esd', 'sources/install.swm', 'sources/setup.exe', 'setup/wim/setup.wim',
            'setup/wim/winflp.wim', 'setup/setup.exe', 'i386/txtsetup.sif', 'amd64/txtsetup.sif'}]
        for name in iso.entries:
            if name in {'i386/txtsetup.sif', 'amd64/txtsetup.sif', 'i386/setupp.ini', 'i386/prodspec.ini',
                        'sources/idwbinfo.txt', 'sources/lang.ini', 'sources/setupp.ini'}:
                result['metadata'][name] = ini_facts(decode(iso.read(name)))
            if name in {'setup.exe', 'sources/setup.exe', 'i386/setupx.dll'}:
                result['metadata'][name] = pe_facts(iso.read(name, length=min(iso.entries[name][1], LIMIT)))
            if name in {'sources/install.wim', 'sources/install.esd', 'sources/install.swm', 'sources/boot.wim', 'setup/wim/winflp.wim'}:
                try:
                    result['metadata'][name] = wim_facts(iso, name)
                except (ValueError, ET.ParseError) as e:
                    result['metadata'][name] = {'read_error': str(e)}
    return result


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('iso', type=pathlib.Path, nargs='+')
    p.add_argument('--output', type=pathlib.Path, required=True)
    args = p.parse_args()
    facts = []
    for image in args.iso:
        try:
            facts.append(inspect(image))
        except (ValueError, KeyError) as e:
            facts.append({'path': str(image), 'read_error': str(e)})
    args.output.write_text(json.dumps(facts, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Read-only media facts:', len(facts))
