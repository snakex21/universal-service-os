' USOS: Windows 3.x Setup source, before Setup runs (INSTALL.BAT).
' Central European editions (the Polish 3.1) list the code page 852 helper
' twice in SETUP.INF: in the main group (ADD852.EXE) and in Autostart
' (ADD852.EXE /A). Started from Autostart it rewrites C:\CONFIG.SYS and
' C:\AUTOEXEC.BAT (COUNTRY, DISPLAY.SYS, MODE, KEYB) and asks for a restart,
' which would replace the USOS start menu. Writes C:\WINSETUP\SETUP.NEW =
' SETUP.INF without the Autostart entry; no SETUP.NEW when there is none.
' The helper stays in the main group for a manual run.
' docs/design/bios-via-csmwrap.md section 8.5
ON ERROR GOTO failed
OPEN "C:\WINSETUP\SETUP.INF" FOR INPUT AS #1
OPEN "C:\WINSETUP\SETUP.TMP" FOR OUTPUT AS #2
n = 0
DO WHILE NOT EOF(1)
  LINE INPUT #1, l$
  IF INSTR(LCASE$(l$), "add852.exe /a") > 0 THEN
    n = n + 1
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
