"""Host test: MS-DOS install parity with MS-DOS 6.22 Setup (2026-10-24).

docs/dos-setup-parity-2026-10-24.md compares a disk made by the real
MS-DOS 6.22 Setup (QEMU, US/English defaults) with the USOS install. The
functional differences found there are fixed in PREPDOS / INSTALL.BAT:

  PREPDOS     GRAPHICS.PR_ -> GRAPHICS.PRO, MEMMAKER.IN_ / DRVSPACE.IN_ ->
              .INF (not .INI), WNTOOLS.GR_ -> WNTOOLS.GRP (Setup's name)
  INSTALL     C:\\DOS\\COMMAND.COM, no Supplemental Disk installer files in
              C:\\DOS, volume label MS-DOS_6, DEVICE=SETVER.EXE first in the
              MS-DOS CONFIG.SYS, C:\\USOSDOS removed after a DOS-only install
  kept        HIMEMX (not HIMEM.SYS), no SMARTDRV, no EMM386 (USOSPKT MMIO)

The rename list is the compressed -> expanded column of the MS-DOS 6.22
PACKING.LST (file names only); the run below replays PREPDOS's REN lines on
it in order, with MS-DOS wildcard semantics for "*.XX_ *.YYY".
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MSDOS = ROOT / 'src/platform/bios/msdos'

PACKING = '''
    COUNTRY.TX_=COUNTRY.TXT DEFRAG.HL_=DEFRAG.HLP EGA.CP_=EGA.CPI EGA2.CP_=EGA2.CPI
    EGA3.CP_=EGA3.CPI EMM386.EX_=EMM386.EXE ISO.CP_=ISO.CPI KEYBRD2.SY_=KEYBRD2.SYS MEM.EX_=MEM.EXE
    REPLACE.EX_=REPLACE.EXE RESTORE.EX_=RESTORE.EXE XCOPY.EX_=XCOPY.EXE ANSI.SY_=ANSI.SYS
    APPEND.EX_=APPEND.EXE CHKSTATE.SY_=CHKSTATE.SYS DBLWIN.HL_=DBLWIN.HLP DELTREE.EX_=DELTREE.EXE
    DISKCOMP.CO_=DISKCOMP.COM DISKCOPY.CO_=DISKCOPY.COM DISPLAY.SY_=DISPLAY.SYS
    DOSHELP.HL_=DOSHELP.HLP DOSKEY.CO_=DOSKEY.COM DRIVER.SY_=DRIVER.SYS DRVSPACE.HL_=DRVSPACE.HLP
    DRVSPACE.IN_=DRVSPACE.INF DRVSPACE.SY_=DRVSPACE.SYS DRVSPACE.TX_=DRVSPACE.TXT EDIT.HL_=EDIT.HLP
    FASTHELP.EX_=FASTHELP.EXE FASTOPEN.EX_=FASTOPEN.EXE FC.EX_=FC.EXE FIND.EX_=FIND.EXE
    GRAPHICS.CO_=GRAPHICS.COM GRAPHICS.PR_=GRAPHICS.PRO HELP.HL_=HELP.HLP HIMEM.SY_=HIMEM.SYS
    INTERLNK.EX_=INTERLNK.EXE INTERSVR.EX_=INTERSVR.EXE LABEL.EX_=LABEL.EXE LOADFIX.CO_=LOADFIX.COM
    MEMMAKER.HL_=MEMMAKER.HLP MEMMAKER.IN_=MEMMAKER.INF MODE.CO_=MODE.COM MONOUMB.38_=MONOUMB.386
    MOVE.EX_=MOVE.EXE MSBACKUP.EX_=MSBACKUP.EXE MSBCONFG.HL_=MSBCONFG.HLP MSTOOLS.DL_=MSTOOLS.DLL
    MWBACKR.DL_=MWBACKR.DLL POWER.EX_=POWER.EXE PRINT.EX_=PRINT.EXE QBASIC.HL_=QBASIC.HLP
    RAMDRIVE.SY_=RAMDRIVE.SYS SETVER.EX_=SETVER.EXE SHARE.EX_=SHARE.EXE SIZER.EX_=SIZER.EXE
    SMARTDRV.EX_=SMARTDRV.EXE SMARTMON.EX_=SMARTMON.EXE SMARTMON.HL_=SMARTMON.HLP SORT.EX_=SORT.EXE
    SUBST.EX_=SUBST.EXE TREE.CO_=TREE.COM VFINTD.38_=VFINTD.386 WINA20.38_=WINA20.386
    MSAV.HL_=MSAV.HLP MSAVHELP.OV_=MSAVHELP.OVL MSAVIRUS.LS_=MSAVIRUS.LST MSBACKUP.HL_=MSBACKUP.HLP
    MWAV.EX_=MWAV.EXE MWAV.HL_=MWAV.HLP MWAVABSI.DL_=MWAVABSI.DLL MWAVDLG.DL_=MWAVDLG.DLL
    MWAVDOSL.DL_=MWAVDOSL.DLL MWAVDRVL.DL_=MWAVDRVL.DLL MWAVMGR.DL_=MWAVMGR.DLL
    MWAVSCAN.DL_=MWAVSCAN.DLL MWAVSOS.DL_=MWAVSOS.DLL MWAVTSR.EX_=MWAVTSR.EXE
    MWBACKF.DL_=MWBACKF.DLL MWBACKUP.EX_=MWBACKUP.EXE MWBACKUP.HL_=MWBACKUP.HLP
    MWGRAFIC.DL_=MWGRAFIC.DLL MWUNDEL.EX_=MWUNDEL.EXE MWUNDEL.HL_=MWUNDEL.HLP VSAFE.CO_=VSAFE.COM
    WNTOOLS.GR_=WNTOOLS.GRB
'''


def packing_pairs():
    """PACKING.LST pairs (the three Setup disks) plus Supplemental Disk names of the same media."""
    pairs = dict(x.split('=') for x in PACKING.split())
    pairs.update({
        'DRVSPACE.IN_': 'DRVSPACE.INF', 'MEMMAKER.IN_': 'MEMMAKER.INF', 'GRAPHICS.PR_': 'GRAPHICS.PRO',
        'WNTOOLS.GR_': 'WNTOOLS.GRP',  # PACKING.LST says .GRB; Setup writes C:\DOS\WNTOOLS.GRP
        'ANSI.SY_': 'ANSI.SYS', 'APPEND.EX_': 'APPEND.EXE', 'DOSKEY.CO_': 'DOSKEY.COM',
        'MSTOOLS.DL_': 'MSTOOLS.DLL', 'MSAVHELP.OV_': 'MSAVHELP.OVL', 'MSAVIRUS.LS_': 'MSAVIRUS.LST',
        'MONOUMB.38_': 'MONOUMB.386', 'VFINTD.38_': 'VFINTD.386', 'WINA20.38_': 'WINA20.386',
        'HELP.HL_': 'HELP.HLP', 'SMARTDRV.EX_': 'SMARTDRV.EXE', 'SETVER.EX_': 'SETVER.EXE',
        'DRVSPACE.TX_': 'DRVSPACE.TXT', 'MWAVTSR.EX_': 'MWAVTSR.EXE',
        # Supplemental Disk files on the same media (shell .INI files, samples)
        'CGA.IN_': 'CGA.INI', 'EGA.IN_': 'EGA.INI', 'MONO.IN_': 'MONO.INI', 'VGA.GR_': 'VGA.GRB',
        'EGA.VI_': 'EGA.VID', 'GORILLA.BA_': 'GORILLA.BAS', 'DRVBOOT.BA_': 'DRVBOOT.BAT',
        'NETBEUI.DO_': 'NETBEUI.DOS',
    })
    return pairs


def code(name):
    return [l.strip() for l in (MSDOS / name).read_text(encoding='ascii').splitlines()
            if l.strip() and not l.strip().lower().startswith('rem')]


def dos_ren(names, src, dst):
    """MS-DOS REN with an optional *.EXT pattern; names: set of upper-case 8.3 names."""
    out = set()
    for n in names:
        base, _, ext = n.partition('.')
        sb, _, se = src.partition('.')
        if sb == '*':
            if ext != se:
                out.add(n); continue
            db, _, de = dst.partition('.')
            out.add(base + '.' + de)
        elif n == src:
            out.add(dst)
        else:
            out.add(n)
    return out


class PrepdosNames(unittest.TestCase):
    def replay(self, names):
        for line in code('prepare_files.cmd'):
            m = re.fullmatch(r'if exist %2\\(\S+) ren %2\\(\S+) (\S+)', line, re.I)
            if not m:
                continue
            self.assertEqual(m.group(1).upper(), m.group(2).upper(), line)
            names = dos_ren(names, m.group(2).upper(), m.group(3).upper())
        return names

    def test_every_compressed_file_gets_its_setup_name(self):
        pairs = packing_pairs()
        result = self.replay(set(pairs))
        self.assertEqual(sorted(result), sorted(pairs.values()))

    def test_specific_names_before_the_extension_rules(self):
        lines = code('prepare_files.cmd')
        first_wild = next(i for i, l in enumerate(lines) if re.search(r'ren %2\\\*\.', l))
        for name in ('MEMMAKER.IN_', 'DRVSPACE.IN_', 'GRAPHICS.PR_', 'WNTOOLS.GR_'):
            i = next(i for i, l in enumerate(lines) if ('ren %2\\' + name) in l)
            self.assertLess(i, first_wild, name)
        # The required-file checks stay as before (MS-DOS 6.0 / 6.2 media too).
        self.assertNotIn(r'if not exist %2\GRAPHICS.PRO goto failed', lines)


class InstallParity(unittest.TestCase):
    def setUp(self):
        self.code = code('install.cmd')

    def test_c_dos_like_setup_after_prepdos(self):
        ready = self.code.index(r'if not exist C:\DOS\READY.TAG goto failed')
        copy = self.code.index(r'copy C:\COMMAND.COM C:\DOS /y >nul')
        label = self.code.index(r'if exist C:\DOS\LABEL.EXE C:\DOS\LABEL.EXE C:MS-DOS_6')
        self.assertLess(ready, copy)
        self.assertLess(copy, label)
        removed = ' '.join(l for l in self.code if l.startswith('for %%f in (') and r'del C:\DOS\%%f' in l)
        for name in ('SETUP.BAT', 'SETUP.MSG', 'SD6COPY.BAT', '720ID01.BAT', '720ID02.BAT'):
            self.assertIn(name, removed)
        # Setup's own files stay (SETUP.EXE /U, DOSSETUP.INI).
        self.assertNotIn('SETUP.EXE', removed)
        self.assertNotIn('DOSSETUP.INI', removed)

    def test_config_setver_first_no_smartdrv_no_emm386(self):
        first = self.code.index(r'echo DEVICE=C:\DOS\SETVER.EXE>C:\CONFIG.SYS')
        self.assertEqual(self.code[first + 1], r'echo DEVICE=C:\DOS\HIMEMX.EXE /MAX=32768 /X2MAX32>>C:\CONFIG.SYS')
        text = '\n'.join(self.code).upper()
        self.assertNotIn('SMARTDRV', text)
        self.assertNotIn('EMM386', text)

    def test_usosdos_removed_only_after_dos_only_install(self):
        go = self.code.index(':restart_go')
        fin = self.code.index(r'C:\TEMP\USOSFIN.BAT')
        self.assertLess(go, fin)
        block = self.code[go:fin + 1]
        self.assertIn(r'if exist C:\WINSETUP\SETUP.EXE goto finreboot', block)
        self.assertIn(r'echo C:\DOS\DELTREE.EXE /Y C:\USOSDOS>>C:\TEMP\USOSFIN.BAT', block)
        self.assertIn(r'echo C:\DOS\REBOOT.COM>>C:\TEMP\USOSFIN.BAT', block)
        # the batch is chained (no CALL): INSTALL.BAT inside C:\USOSDOS is not read again
        self.assertEqual(block[-1], r'C:\TEMP\USOSFIN.BAT')
        self.assertEqual(self.code[fin + 1], ':finreboot')


if __name__ == '__main__':
    unittest.main()
