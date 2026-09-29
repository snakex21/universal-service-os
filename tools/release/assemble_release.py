"""Assemble the USOS release folder from finished build outputs.

Called by tools/release/make_release.ps1 after build.bat and the XP package
builds; it never builds anything itself and never touches a USB stick.

  python tools/release/assemble_release.py --out zig-out/release-1.0
      --installer "installer/USOS Installer.exe"
      --xp pl=zig-out/release-work/xp-pl --xp en=zig-out/release-work/xp-en
      --winpe L:/Programs/USOS/WinPE/PE10_x64_19041_USOS.iso

Layout (VERSION = build-info.ini version, e.g. 1.0.0):
  USOS-Installer-VERSION.exe
  USOS-VERSION-WinPE-PE10-donor.zip   Programs/USOS/WinPE/<donor ISO> + README.txt
  USOS-VERSION-XP-package-PL.zip      EFI/USOS-XP/* + install-xp-package.ps1 + README.txt
  USOS-VERSION-XP-package-EN.zip
  USOS-VERSION-sources.zip            third-party sources (tools/release/third-party.json)
  LICENSES/<component>/...            licence texts, LICENSES-AUDIT.md
  THIRD-PARTY-NOTICES.txt, SOURCE-OFFER.txt
  RELEASE-NOTES.md, README.md, USER-GUIDE.pl.md, USER-GUIDE.en.md
  SHA256SUMS                          written last, over every other file

Zips are deterministic: sorted entries, fixed timestamps (the build epoch),
fixed permissions. The folder is then checked by scan_release.py.

The installer downloads the WinPE and XP zips itself and pins their SHA-256
(buildinfo.ComponentSHA256). make_release.ps1 therefore runs this script
twice: --components-only writes the zips and component-sha256.txt, the
installer is rebuilt with that list, and the full run (--components DIR)
copies the zips and refuses an installer that does not embed every hash.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, os, shutil, sys, zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import scan_release  # noqa: E402

# The PE10 donor the Vista/Windows 7 paths were validated with
# (.supercli/scratchpad/pe10-donor-final.md, docs/windows-native-uefi-win10-11-2026-09-25.md).
WINPE_DONOR_NAME = 'PE10_x64_19041_USOS.iso'
WINPE_DONOR_SHA256 = 'a44ab63a1ddb415d8c216f104a3532cfc7fb3a951bd62a939d93991784306a5e'
WINPE_DONOR_SIZE = 459735040

# XP package ESP payload, as tools/deploy_xp_uefi_csm_trial.ps1 installs it.
XP_PACKAGE_FILES = ('initramfs-xp', 'vmlinuz.efi', 'manifest.json')
XP_SOURCES = {
    'pl': ('pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso',
           'bd3234250a6e2f68fbacf0a46cf42a7d711811e428210c0d60649a054f28ff0b'),
    'en': ('en_windows_xp_professional_with_service_pack_3_x86_cd_x14-80428.iso',
           '62b6c91563bad6cd12a352aa018627c314cfc5162d8e9f8af0756a642e602a46'),
}
# Contact for the written source offer: the issue tracker of the public USOS
# repository. Fill in at publish time (make_release.ps1 -IssuesUrl, the
# USOS_ISSUES_URL environment variable, or this default).
ISSUES_URL_PLACEHOLDER = 'https://github.com/OWNER/REPOSITORY/issues'
ISSUES_URL = os.environ.get('USOS_ISSUES_URL', ISSUES_URL_PLACEHOLDER)
GITHUB_ASSET_LIMIT = 2 * 1024 ** 3
# Alpine virt 3.24.1 ISO in the build kit (micro-Linux lock, CSMWrap build VM).
ALPINE_ISO_SHA256 = 'e73a6241bd5f3c5c2d4d38c02cc52c378c0415a7c888bd292066bf36e0f41a39'  # GitHub Releases: each asset must be under 2 GiB


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def read_build_info():
    info = {}
    section = ''
    for line in (ROOT / 'build/generated/build-info.ini').read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1].lower()
        elif section == 'build' and '=' in line:
            key, value = line.split('=', 1)
            info[key.strip().lower()] = value.strip()
    for key in ('id', 'version', 'epoch'):
        if not info.get(key):
            raise SystemExit('build-info.ini has no ' + key + ' (run build.bat first)')
    version_file = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
    if info['version'] != version_file:
        raise SystemExit('build-info.ini version %s differs from VERSION %s: rebuild' % (info['version'], version_file))
    return info


class Zip:
    """Deterministic zip writer: entries sorted at close, fixed time and mode."""

    STORE_SUFFIXES = ('.iso', '.efi', '.xz', '.gz', '.zip', '.7z', '.cab', '.wim')

    def __init__(self, path, epoch):
        self.path = path
        stamp = datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)
        self.date_time = (max(stamp.year, 1980), stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second & ~1)
        self.entries = {}

    def add_file(self, name, source):
        name = name.replace('\\', '/')
        if name in self.entries:
            raise ValueError('duplicate zip entry ' + name)
        self.entries[name] = ('file', Path(source))

    def add_text(self, name, text):
        self.entries[name] = ('data', text.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))

    def add_tree(self, prefix, folder):
        folder = Path(folder)
        for item in sorted(folder.rglob('*')):
            if item.is_file() and '__pycache__' not in item.parts:
                self.add_file(prefix + '/' + item.relative_to(folder).as_posix(), item)

    def close(self):
        with zipfile.ZipFile(self.path, 'w', allowZip64=True) as z:
            for name in sorted(self.entries):
                kind, value = self.entries[name]
                info = zipfile.ZipInfo(name, self.date_time)
                info.external_attr = 0o644 << 16
                initramfs = name.rsplit('/', 1)[-1].startswith('initramfs')
                stored = kind == 'file' and (initramfs or value.suffix.lower() in self.STORE_SUFFIXES or name.endswith('vmlinuz.efi'))
                info.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
                if kind == 'data':
                    z.writestr(info, value, compresslevel=9)
                else:
                    with open(value, 'rb') as src, z.open(info, 'w', force_zip64=value.stat().st_size > 0x7FFFFFFF) as dst:
                        shutil.copyfileobj(src, dst, 1 << 20)


def xp_readme(lang, version, build_id, manifest):
    iso, iso_sha = XP_SOURCES[lang]
    return f"""USOS {version} - Windows XP x86 SP3 UEFI package ({lang.upper()})
Build {build_id}

What it is
  The Windows XP preparation package for the USOS UEFI menu (EFI\\USOS-XP on
  the stick's USOS_ESP partition): the USOS micro-Linux, the PAE helper and
  the driver bundle (AHCI, USB 3, ACPI, KMDF) built for exactly this ISO:

    {iso}
    SHA-256 {iso_sha}

  Other XP ISOs are not supported by this package. No Windows files are
  included beyond what the driver bundle derives from that ISO, no ISO, no
  product key. Windows 2000, XP x64 and Server 2003 from UEFI stay
  experimental; this package carries no Server 2003 driver bundle.

Install with the installer (recommended)
  USOS-Installer-{version}.exe downloads and installs this package itself
  in its "Components" step after Install, Update USOS or Repair. Offline,
  choose "I already have the file" there and pick this zip (it is checked
  by SHA-256 like a download).

Install by hand (Windows, PowerShell as administrator, USOS stick plugged in)
  1. Update the stick to USOS {version} first (USOS-Installer-{version}.exe,
     "Update USOS"). The package matches only that build's micro-Linux.
  2. Extract this zip to a folder, open PowerShell as administrator there:
       powershell -ExecutionPolicy Bypass -File .\\install-xp-package.ps1
     The script finds the USOS_ESP partition, checks the build, copies
     EFI\\USOS-XP and verifies every file by SHA-256. Only one XP package
     (PL or EN) can be installed at a time; installing one replaces the other.
  3. Copy the ISO itself to DATA: Systems\\Windows\\Windows XP\\Images.

Checksums of the package files
""" + ''.join(f"  {manifest['sha256'][n]}  EFI/USOS-XP/{n}\n" for n in ('initramfs-xp', 'vmlinuz.efi')) + f"""
Licences: see THIRD-PARTY-NOTICES.txt and LICENSES/ in the release.
"""


def winpe_readme(version, build_id):
    return f"""USOS {version} - WinPE PE10 donor
Build {build_id}

What it is
  {WINPE_DONOR_NAME} (SHA-256 {WINPE_DONOR_SHA256},
  {WINPE_DONOR_SIZE} bytes): a minimal Windows PE 10.0.19041 x64 image with
  Windows Setup (boot/bcd, boot/boot.sdi, sources/boot.wim, sources/setup.exe;
  no install image). USOS uses it to start Windows Vista and original
  Windows 7 ISOs (UEFI and CSMWrap paths). It is not a system to install and
  never shows up in the menu.

  It consists of Microsoft files, redistributed by the USOS maintainer at
  their own responsibility. No product key, no activation change.

Install with the installer (recommended)
  USOS-Installer-{version}.exe downloads and installs this donor itself in
  its "Components" step after Install, Update USOS or Repair. Offline,
  choose "I already have the file" there and pick this zip (it is checked
  by SHA-256 like a download).

Install by hand
  1. Copy the folder Programs from this zip to the root of the stick's
     USOS_DATA partition, so the file ends up in
     USOS_DATA:\\Programs\\USOS\\WinPE\\{WINPE_DONOR_NAME}
  2. Run USOS-Installer-{version}.exe and choose "Update USOS" (or "Repair ESP"):
     it records the donor's SHA-256 on the ESP (EFI\\USOS\\winpe-donor.ini)
     and marks the file hidden and read-only.
"""


def notice_copyright():
    """The copyright line of NOTICE (the single place to change the holder)."""
    for line in (ROOT / 'NOTICE').read_text(encoding='utf-8').splitlines():
        if line.startswith('Copyright'):
            return line.strip()
    raise SystemExit('NOTICE has no Copyright line')


def component_text(c):
    lines = [f"{c['name']} {c['version']}", f"  Licence: {c['license']}" + ('  (MODIFIED by USOS)' if c.get('modified') else '')]
    if c.get('notice'):
        lines.append('  ' + c['notice'])
    if c.get('ships_in'):
        lines.append('  Ships in: ' + ', '.join(c['ships_in']))
    if c.get('license_files'):
        lines.append('  Licence texts: ' + ', '.join('LICENSES/%s/%s' % (c['id'], Path(p).name) for p in c['license_files']))
    src = c.get('source') or {}
    if src.get('bundle_paths'):
        lines.append('  Source: USOS-<version>-sources.zip, folder ' + c['id'] + '/')
    if src.get('offer'):
        lines.append('  Source: available on request, see SOURCE-OFFER.txt')
    for url in src.get('urls') or []:
        lines.append('  Upstream: ' + url)
    return '\n'.join(lines)


def licences(out, version, sources_zip, issues_url=ISSUES_URL):
    manifest = json.loads((ROOT / 'tools/release/third-party.json').read_text(encoding='utf-8'))
    components = manifest['components']
    ids = [c['id'] for c in components]
    if len(ids) != len(set(ids)):
        raise SystemExit('third-party.json: duplicate component ids')
    lic = out / 'LICENSES'
    lic.mkdir()
    audit = ROOT / 'docs/LICENSES-AUDIT.md'
    if audit.is_file():
        shutil.copyfile(audit, lic / 'LICENSES-AUDIT.md')
    offers = []
    for c in components:
        folder = lic / c['id']
        for p in c.get('license_files') or []:
            source = ROOT / p
            if not source.is_file():
                raise SystemExit('third-party.json: missing licence file ' + p)
            folder.mkdir(exist_ok=True)
            target = folder / source.name
            if target.exists() and sha256(target) != sha256(source):
                target = folder / (source.parent.name + '-' + source.name)
            shutil.copyfile(source, target)
        src = c.get('source') or {}
        for p in src.get('bundle_paths') or []:
            source = ROOT / p
            if source.is_dir():
                sources_zip.add_tree(c['id'] + '/' + source.name, source)
            elif source.is_file():
                sources_zip.add_file(c['id'] + '/' + source.name, source)
            else:
                raise SystemExit('third-party.json: missing source path ' + p)
        if src.get('offer'):
            offers.append(c)
    header = f"""USOS {version} - third-party notices

USOS itself: {notice_copyright()}, licensed under GPL-3.0-or-later (LICENSE,
NOTICE). The third-party components below are separate programs that are
aggregated with USOS on the stick and in the release (a "mere aggregation"
in the sense of the GPL), not parts of USOS; each keeps its own licence, and
the licence texts are in the LICENSES folder. USOS's own binaries link only
GPL-compatible code (Zig runtime and musl: MIT; Go runtime and x/sys:
BSD-3-Clause; fonts: Apache-2.0 / OFL-1.1). Components marked MODIFIED were changed by USOS; their
sources and patches are in USOS-{version}-sources.zip. Microsoft files (the
WinPE donor, driver bundles derived from the user's XP ISO, redistributable
Microsoft drivers) remain Microsoft's property: the maintainer keeps them
deliberately, for preservation, redistributes them at the maintainer's own
risk, and will remove them on request of the rights holder. Windows ISOs and
product keys are never included.

"""
    body = '\n\n'.join(component_text(c).replace('<version>', version) for c in components)
    (out / 'THIRD-PARTY-NOTICES.txt').write_text((header + body + '\n').replace('\n', '\r\n'), encoding='utf-8', newline='')
    offer = f"""USOS {version} - written offer for source code (GPL / LGPL)

Sources that USOS modified (for example CSMWrap 3.1.2-usos1 with SeaBIOS)
and the other sources available locally are included in
USOS-{version}-sources.zip next to this file.

For the components below, which USOS redistributes unmodified as binaries
from the listed upstream releases, the corresponding source code is
available from the upstream URLs given. In addition, for at least three
years after the release date of USOS {version}, the USOS maintainer will
provide anyone who asks with a complete machine-readable copy of the
corresponding source code of these components, for no more than the cost of
physically performing the distribution. Ask through the issue tracker of
the USOS project repository:

  {issues_url}

"""
    offer += '\n\n'.join(component_text(c).replace('<version>', version) for c in offers) + '\n'
    (out / 'SOURCE-OFFER.txt').write_text(offer.replace('\n', '\r\n'), encoding='utf-8', newline='')
    sources_zip.add_text('SOURCE-OFFER.txt', offer)
    sources_zip.add_text('THIRD-PARTY-NOTICES.txt', header + body + '\n')
    return components


def component_names(version):
    """The optional component zips the installer downloads (internal/components)."""
    return [f'USOS-{version}-WinPE-PE10-donor.zip'] + [f'USOS-{version}-XP-package-{lang.upper()}.zip' for lang in sorted(XP_SOURCES)]


def pin_text(folder, version):
    """ASSET=sha256;... as injected into the installer (buildinfo.ComponentSHA256)."""
    return ';'.join('%s=%s' % (name, sha256(folder / name)) for name in component_names(version))


def check_installer_pins(installer, folder, version):
    """The installer must carry the SHA-256 of every component zip it may download."""
    data = Path(installer).read_bytes()
    for name in component_names(version):
        pin = ('%s=%s' % (name, sha256(folder / name))).encode('ascii')
        if pin not in data:
            raise SystemExit(f'{installer} does not embed {pin.decode()} (build it with make_release.ps1)')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, default=ROOT / 'zig-out/release-1.0')
    p.add_argument('--installer', type=Path, default=ROOT / 'installer/USOS Installer.exe')
    p.add_argument('--xp', action='append', default=[], help='LANG=PACKAGE_DIR (pl, en)')
    p.add_argument('--winpe', type=Path)
    p.add_argument('--buildkit', type=Path, action='append', default=[], help='USOS-VERSION-buildkit.zip (or its .001.. parts) from make_buildkit.py')
    p.add_argument('--components-only', action='store_true',
                   help='write only the WinPE and XP zips (and component-sha256.txt) to --out, for the installer build')
    p.add_argument('--components', type=Path,
                   help='folder from --components-only: copy those zips and require their hashes in the installer')
    a = p.parse_args()

    info = read_build_info()
    version, build_id, epoch = info['version'], info['id'], info['epoch']
    out = a.out.resolve()
    allowed = {(ROOT / 'zig-out').resolve(), (ROOT / 'zig-out/release-work').resolve()} if a.components_only else {(ROOT / 'zig-out').resolve()}
    if out.parent not in allowed:
        raise SystemExit('refusing to write outside zig-out: ' + str(out))
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    if a.components:
        components = a.components.resolve()
        for name in component_names(version):
            if not (components / name).is_file():
                raise SystemExit(f'--components {components}: missing {name}')
        check_installer_pins(a.installer, components, version)
    else:
        if a.winpe is None:
            raise SystemExit('need --winpe (or --components)')
        build_components(a, out, version, build_id, epoch)
        if not a.components_only:
            check_installer_pins(a.installer, out, version)
        if a.components_only:
            (out / 'component-sha256.txt').write_text(pin_text(out, version) + '\n', encoding='ascii', newline='\n')
            print('COMPONENTS PASS', out)
            return

    # Installer
    installer = out / f'USOS-Installer-{version}.exe'
    shutil.copyfile(a.installer, installer)
    if a.components:
        for name in component_names(version):
            shutil.copyfile(components / name, out / name)
    finish_release(a, out, version, build_id, epoch)


def build_components(a, out, version, build_id, epoch):
    # WinPE donor
    donor = a.winpe.resolve()
    if donor.name != WINPE_DONOR_NAME or donor.stat().st_size != WINPE_DONOR_SIZE or sha256(donor) != WINPE_DONOR_SHA256:
        raise SystemExit('WinPE donor is not the validated ' + WINPE_DONOR_NAME + ' (name, size or SHA-256 differ): ' + str(donor))
    z = Zip(out / f'USOS-{version}-WinPE-PE10-donor.zip', epoch)
    z.add_file('Programs/USOS/WinPE/' + WINPE_DONOR_NAME, donor)
    z.add_text('README.txt', winpe_readme(version, build_id))
    z.close()

    # XP packages
    xp = dict(item.split('=', 1) for item in a.xp)
    if sorted(xp) != sorted(XP_SOURCES):
        raise SystemExit('need --xp pl=DIR and --xp en=DIR')
    base = sha256(ROOT / 'zig-out/micro-linux/initramfs-usos')
    for lang, folder in sorted(xp.items()):
        folder = Path(folder).resolve()
        manifest = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
        iso, iso_sha = XP_SOURCES[lang]
        if not manifest.get('release') or manifest.get('release_lang') != lang:
            raise SystemExit(f'{folder}: not a --release --release-lang {lang} package')
        if [s['sha256'] for s in manifest['driver_sources']] != [iso_sha] or manifest.get('nt52_driver_sources'):
            raise SystemExit(f'{folder}: package sources are not exactly {iso}')
        if manifest['base_initramfs_sha256'] != base:
            raise SystemExit(f'{folder}: built from another micro-Linux than this build (rebuild the XP package)')
        for name in ('initramfs-xp', 'vmlinuz.efi'):
            if sha256(folder / name) != manifest['sha256'][name]:
                raise SystemExit(f'{folder}/{name}: SHA-256 differs from manifest.json')
        z = Zip(out / f'USOS-{version}-XP-package-{lang.upper()}.zip', epoch)
        for name in XP_PACKAGE_FILES:
            z.add_file('EFI/USOS-XP/' + name, folder / name)
        z.add_file('install-xp-package.ps1', ROOT / 'tools/release/install-xp-package.ps1')
        z.add_text('README.txt', xp_readme(lang, version, build_id, manifest))
        z.close()


def finish_release(a, out, version, build_id, epoch):
    # Build kit (made by make_buildkit.py; copied as it is)
    if not a.buildkit:
        raise SystemExit('need --buildkit (tools/release/make_buildkit.py)')
    for part in a.buildkit:
        if not part.name.startswith(f'USOS-{version}-buildkit.zip'):
            raise SystemExit('unexpected build kit file name: ' + part.name)
        shutil.copyfile(part, out / part.name)

    # Licences, notices, sources
    sources = Zip(out / f'USOS-{version}-sources.zip', epoch)
    licences(out, version, sources)
    sources.close()

    # Documentation
    docs = {
        'RELEASE-NOTES.md': ROOT / 'docs/release-notes-1.0.md',
        'README.md': ROOT / 'README.md',
        'USER-GUIDE.pl.md': ROOT / 'docs/USER-GUIDE.pl.md',
        'USER-GUIDE.en.md': ROOT / 'docs/USER-GUIDE.en.md',
        'LICENSE.txt': ROOT / 'LICENSE',
        'NOTICE.txt': ROOT / 'NOTICE',
        'CONTRIBUTING.md': ROOT / 'CONTRIBUTING.md',
    }
    for name, source in docs.items():
        if not source.is_file():
            raise SystemExit('missing release document ' + str(source))
        shutil.copyfile(source, out / name)

    # Size limit per asset
    for f in sorted(out.rglob('*')):
        if f.is_file() and f.stat().st_size >= GITHUB_ASSET_LIMIT:
            raise SystemExit(f'{f.name} is {f.stat().st_size} bytes: over the 2 GiB GitHub release asset limit')

    # Forbidden content, then checksums
    scan_release.trust_buildkit_lock(ROOT / 'tools/release/buildkit.lock.json')
    findings = scan_release.scan(out, extra=[ROOT / 'installer/internal/payload/assets/payload.zip'],
                                 allowed_iso_sha256={WINPE_DONOR_SHA256, ALPINE_ISO_SHA256})
    if findings:
        for f in findings:
            print('SCAN FAIL:', f)
        raise SystemExit('release scan failed: %d finding(s)' % len(findings))
    print('SCAN PASS: no private keys, key files, product keys, foreign ISOs or filled answer profiles')

    files = sorted(f for f in out.rglob('*') if f.is_file())
    lines = ['%s *%s' % (sha256(f), f.relative_to(out).as_posix()) for f in files]
    (out / 'SHA256SUMS').write_text('\n'.join(lines) + '\n', encoding='ascii', newline='\n')
    total = 0
    for f in files + [out / 'SHA256SUMS']:
        size = f.stat().st_size
        total += size
        if f.parent == out:
            print('%12d  %s' % (size, f.name))
    print('%12d  total (%d files incl. LICENSES/)' % (total, len(files) + 1))
    print('RELEASE PASS', version, build_id, out)
    if ISSUES_URL == ISSUES_URL_PLACEHOLDER:
        print('NOTE: SOURCE-OFFER.txt still names the placeholder', ISSUES_URL_PLACEHOLDER,
              '- set -IssuesUrl (make_release.ps1) or USOS_ISSUES_URL before publishing')


if __name__ == '__main__':
    main()
