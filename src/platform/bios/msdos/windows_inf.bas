' USOS: Windows 3.x Setup source, before Setup runs (INSTALL.BAT).
' Central European editions (the Polish 3.1) list the code page 852 helper
' twice in SETUP.INF: in the main group (ADD852.EXE) and in Autostart
' (ADD852.EXE /A). Started from Autostart it rewrites C:\CONFIG.SYS and
' C:\AUTOEXEC.BAT (COUNTRY, DISPLAY.SYS, MODE, KEYB) and asks for a restart,
' which would replace the USOS start menu. Writes C:\WINSETUP\SETUP.NEW =
' SETUP.INF without the Autostart entry; no SETUP.NEW when there is none.
' The helper stays in the main group for a manual run.
' docs/design/bios-via-csmwrap.md section 8.5
' The Polish editions (3.1 PL, WfW 3.11 PL) default to the typist layout
' (defkeydll = poldll, KBDPL.DLL, QWERTZ); when [keyboard.tables] has the
' programmer's layout (poldl1 = KBDPL1.DLL, AltGr+a = a-ogonek), Setup gets
' that one instead, the layout Polish users expect (and the one the NT
' flows use, 00000415). docs/nt3-polish-2026-10-14.md
ON ERROR GOTO failed
prog = 0
OPEN "C:\WINSETUP\SETUP.INF" FOR INPUT AS #1
DO WHILE NOT EOF(1)
  LINE INPUT #1, l$
  IF LEFT$(LTRIM$(LCASE$(l$)), 6) = "poldl1" THEN prog = 1
LOOP
CLOSE #1
OPEN "C:\WINSETUP\SETUP.INF" FOR INPUT AS #1
OPEN "C:\WINSETUP\SETUP.TMP" FOR OUTPUT AS #2
n = 0
DO WHILE NOT EOF(1)
  LINE INPUT #1, l$
  k$ = LCASE$(l$)
  IF INSTR(k$, "add852.exe /a") > 0 THEN
    n = n + 1
  ELSEIF prog = 1 AND LEFT$(LTRIM$(k$), 9) = "defkeydll" AND INSTR(k$, "poldll") > 0 THEN
    n = n + 1
    PRINT #2, LEFT$(l$, INSTR(k$, "poldll") - 1) + "poldl1"
  ELSE
    PRINT #2, l$
  END IF
LOOP
CLOSE #1
CLOSE #2
IF n > 0 THEN
  NAME "C:\WINSETUP\SETUP.TMP" AS "C:\WINSETUP\SETUP.NEW"
ELSE
  KILL "C:\WINSETUP\SETUP.TMP"
END IF
SYSTEM

failed:
CLOSE
SYSTEM
