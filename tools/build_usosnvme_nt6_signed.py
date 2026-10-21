"""Signed usosnvme package for 32-bit Vista / Server 2008 (NT 6.0) and 7.

Why (docs/nvme-nt6-2026-10-12.md section 9): in specialize, NT 6.0 PnP
installs the NULL driver on the NVMe controller unless a driver package for
it is in the driver store; an unsigned package cannot be staged silently
(pnputil prompts, as SYSTEM it fails). A package signed by a publisher in the
machine's TrustedPublisher store (chain to a Root certificate) is staged and
installed without a prompt.

Per build: a fresh self-signed code-signing certificate (RSA 2048, SHA-1 for
NT 6.0; valid 1990-2049 because the signature has no timestamp and the
target's clock is checked against the certificate: a QEMU guest whose RTC is
UTC but whose time zone is CET was two hours "before" a certificate created
at build time, CERT_E_EXPIRED 0x800b0101, 2026-10-13) is created in the build user's CurrentUser\\My store with a
non-exportable key, usosnvme.sys (embedded) and usosnvme.cat are signed with
it, the public certificate is exported (usosnvme.cer) and the certificate and
its private key are deleted from the store again (finally block, checked).
The private key never exists as a file, is never stored or committed, and
nothing can be signed with this certificate after the build. Only the
installed system that gets this package trusts the certificate (the Vista
OOBE gate adds it to the machine's Root + TrustedPublisher stores before
specialize, tools/windows_vista_oobe_gate.c).

Output folder: usosnvme.inf (NT6 copy with CatalogFile), usosnvme.sys
(signed copy of the committed NT6 build: src\2KXP with -DUSOSNVME_NT6, no
HwInterrupt, so ScsiPort connects no interrupt; the X470 Win10 x86 WinPE
failed the 2KXP build's start with Problem 10 / 0xC000000D, 2026-10-14),
usosnvme.cat, usosnvme.cer. arch='amd64': the NT6X64 build (WDK 7.1 fre x64
WLH, same polled source) with NTamd64 models, for Vista / Server 2008 SP2 x64,
which load it in test mode (docs/vista-x64-nvme-2026-10-21.md).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

INF_DATE_IN = b'DriverVer=10/11/2026,1.0.0.0'
# Older than every inbox stornvme.inf (kept from the PE10 donor route).
INF_DATE_OUT = b'DriverVer=01/01/2001,1.0.0.0'


# arch='amd64' (Vista / Server 2008 SP2 x64, docs/vista-x64-nvme-2026-10-21.md):
# NTamd64 models and the NT6/amd64 binary. The Vista x64 path runs with
# testsigning on (PE10 staging BCD and the installed system), like the
# test-signed USB backport of the v11 payload. modern=True (8.1/10 exact-ID
# package) stays x86-only.
ARCHES = ('x86', 'amd64')


def nt6_inf(root: Path, modern: bool = False, arch: str = 'x86') -> bytes:
    if arch not in ARCHES:
        raise ValueError('unsupported usosnvme architecture: ' + arch)
    if modern and arch != 'x86':
        raise ValueError('the modern usosnvme package is x86 only')
    inf = (root / 'tools/nt/usosnvme/usosnvme.inf').read_bytes()
    if INF_DATE_IN not in inf:
        raise ValueError('usosnvme.inf DriverVer changed; update the NT6 copy')
    inf = inf.replace(INF_DATE_IN, INF_DATE_OUT + b'\r\nCatalogFile=usosnvme.cat')
    inf = inf.replace(b'\r\n', b'\n')
    if arch == 'amd64':
        # 64-bit PnP reads only decorated models sections.
        for old, new in ((b'%USOS% = Nvme_Models\n', b'%USOS% = Nvme_Models, NTamd64\n'),
                         (b'[Nvme_Models]\n', b'[Nvme_Models.NTamd64]\n')):
            if old not in inf:
                raise ValueError('usosnvme INF models changed')
            inf = inf.replace(old, new)
    inf = inf.replace(b'\n', b'\r\n')
    if modern:
        # Separate owned package, exact IDs reviewed for the first opt-in trial.
        # Retain the boot-critical service identity without replacing its inbox file.
        inf = inf.replace(b'AddService = usosnvme,', b'AddService = stornvme,')
        inf = inf.replace(b'%Nvme.DeviceDesc% = Nvme_Inst, PCI\\CC_010802',
                          b'%Nvme.DeviceDesc% = Nvme_Inst, PCI\\VEN_1344&DEV_5407\r\n'
                          b'%Nvme.DeviceDesc% = Nvme_Inst, PCI\\VEN_1B36&DEV_0010')
    return inf


def find_tools() -> tuple[Path, Path]:
    """signtool.exe + makecat.exe: Windows 10 SDK/WDK (newest), else WDK 7.1."""
    candidates = []
    kits = Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Windows Kits/10/bin'
    if kits.is_dir():
        for version in sorted((p for p in kits.iterdir() if p.name.startswith('10.')), key=lambda p: [int(x) for x in p.name.split('.') if x.isdigit()], reverse=True):
            candidates.append(version / 'x64')
            candidates.append(version / 'x86')
        candidates += [kits / 'x64', kits / 'x86']
    wdk = os.environ.get('WDKROOT')
    if wdk:
        candidates.append(Path(wdk) / 'bin/x86')
    for folder in candidates:
        if (folder / 'signtool.exe').is_file() and (folder / 'makecat.exe').is_file():
            return folder / 'signtool.exe', folder / 'makecat.exe'
    raise FileNotFoundError('signtool.exe + makecat.exe not found (Windows 10 SDK/WDK or WDKROOT); '
                            'they sign the per-build usosnvme NT6 package')


PS_SIGN = r'''
$ErrorActionPreference = 'Stop'
$out = $env:USOS_SIGN_OUT; $signtool = $env:USOS_SIGNTOOL; $makecat = $env:USOS_MAKECAT
$subject = 'CN=USOS usosnvme ' + $env:USOS_SIGN_BUILD + ' (per-build test signature, key destroyed after signing), O=Universal Service OS'
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA1 -KeyExportPolicy NonExportable `
    -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' `
    -NotBefore ([datetime]::new(1990, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)) -NotAfter ([datetime]::new(2049, 12, 31, 0, 0, 0, [DateTimeKind]::Utc))
$thumb = $cert.Thumbprint
try {
    Export-Certificate -Cert $cert -FilePath (Join-Path $out 'usosnvme.cer') -Type CERT | Out-Null
    & $signtool sign /q /fd sha1 /s My /sha1 $thumb (Join-Path $out 'usosnvme.sys')
    if ($LASTEXITCODE -ne 0) { throw "signtool (sys) exit $LASTEXITCODE" }
    Push-Location $out
    try { & $makecat -v usosnvme.cdf | Out-Null; if ($LASTEXITCODE -ne 0) { throw "makecat exit $LASTEXITCODE" } } finally { Pop-Location }
    & $signtool sign /q /fd sha1 /s My /sha1 $thumb (Join-Path $out 'usosnvme.cat')
    if ($LASTEXITCODE -ne 0) { throw "signtool (cat) exit $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $thumb) -DeleteKey -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath ('Cert:\CurrentUser\My\' + $thumb)) { throw 'signing certificate still in CurrentUser\My' }
foreach ($f in 'usosnvme.sys', 'usosnvme.cat') {
    $s = Get-AuthenticodeSignature -LiteralPath (Join-Path $out $f)
    if (-not $s.SignerCertificate -or $s.SignerCertificate.Thumbprint -ne $thumb) { throw "$f is not signed by $thumb" }
}
Write-Output $thumb
'''


def build(root: Path, out: Path, *, modern: bool = False, arch: str = 'x86') -> str:
    """Writes the signed package to out; returns the certificate thumbprint."""
    if arch not in ARCHES:
        raise ValueError('unsupported usosnvme architecture: ' + arch)
    out = out.resolve()
    if out == root.resolve() or not out.name or out == Path(out.anchor):
        raise ValueError('unsafe signing output directory')
    inf = nt6_inf(root, modern, arch)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    (out / 'usosnvme.inf').write_bytes(inf)
    shutil.copyfile(root / ('tools/nt/usosnvme/bin/NT6/i386/usosnvme.sys' if arch == 'x86' else
                            'tools/nt/usosnvme/bin/NT6/amd64/usosnvme.sys'), out / 'usosnvme.sys')
    (out / 'usosnvme.cdf').write_bytes(
        b'[CatalogHeader]\r\nName=usosnvme.cat\r\nResultDir=.\r\nPublicVersion=0x0000001\r\nEncodingType=0x00010001\r\n' +
        (b'CATATTR1=0x10010001:OSAttr:2:6.3,2:10.0\r\n\r\n' if modern else
         b'CATATTR1=0x10010001:OSAttr:2:6.0,2:6.1\r\n\r\n') +
        b'[CatalogFiles]\r\n<hash>usosnvme.inf=usosnvme.inf\r\n<hash>usosnvme.sys=usosnvme.sys\r\n')
    signtool, makecat = find_tools()
    env = dict(os.environ, USOS_SIGN_OUT=str(out), USOS_SIGNTOOL=str(signtool), USOS_MAKECAT=str(makecat),
               USOS_SIGN_BUILD=os.environ.get('USOS_BUILD_ID', 'DEV') + ('' if arch == 'x86' else ' amd64'))
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', PS_SIGN],
                            env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError('usosnvme NT6 signing failed:\n' + result.stdout + result.stderr)
    thumb = result.stdout.strip().splitlines()[-1].strip()
    (out / 'usosnvme.cdf').unlink()
    for name in ('usosnvme.inf', 'usosnvme.sys', 'usosnvme.cat', 'usosnvme.cer'):
        if not (out / name).is_file():
            raise FileNotFoundError(name)
    print('[PASS] usosnvme NT6 package signed, certificate', thumb, '(private key deleted)')
    return thumb


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    build(root, Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'zig-out/windows-modern/usosnvme-nt6')
