' USOS: Windows 3.x installed under CSMWrap (UEFI PC without a CSM).
' Writes C:\USOSW3\SYSTEM.NEW = C:\WINDOWS\SYSTEM.INI with the settings
' below; WINMENU.BAT backs up the original and installs the new file.
' USB mouse: VBADOS VBMOUSE.EXE (DOS, INT 33h from SeaBIOS INT 15h C2) and
' its Windows driver VBMOUSE.DRV. USB keyboard: USOSKEY.DRV, an installable
' driver next to the stock KEYBOARD.DRV (fed by the DOS TSR USOSKEY.COM).
' A value starting with "+" is appended to the key's list instead.
' docs/design/bios-via-csmwrap.md
DATA 4
DATA "[boot]", "mouse.drv", "vbmouse.drv"
DATA "[boot.description]", "mouse.drv", "USB mouse through the BIOS (VBADOS VBMOUSE)"
DATA "[386enh]", "mouse", "*vmd"
DATA "[boot]", "drivers", "+usoskey.drv"
ON ERROR GOTO failed
READ n
DIM sc$(n), ky$(n), vl$(n), dn(n)
FOR i = 1 TO n
  READ sc$(i), ky$(i), vl$(i)
  dn(i) = 0
NEXT i
OPEN "C:\WINDOWS\SYSTEM.INI" FOR INPUT AS #1
OPEN "C:\USOSW3\SYSTEM.TMP" FOR OUTPUT AS #2
cur$ = ""
DO WHILE NOT EOF(1)
  LINE INPUT #1, l$
  t$ = LCASE$(LTRIM$(RTRIM$(l$)))
  IF LEFT$(t$, 1) = "[" THEN
    GOSUB missing
    cur$ = t$
    PRINT #2, l$
  ELSE
    hit = 0
    p = INSTR(t$, "=")
    IF p > 1 THEN
      k$ = RTRIM$(LEFT$(t$, p - 1))
      FOR i = 1 TO n
        IF cur$ = sc$(i) AND k$ = ky$(i) THEN
          IF dn(i) = 0 THEN
            IF LEFT$(vl$(i), 1) = "+" THEN
              IF INSTR(LCASE$(l$), MID$(vl$(i), 2)) = 0 THEN
                PRINT #2, RTRIM$(l$); " "; MID$(vl$(i), 2)
              ELSE
                PRINT #2, l$
              END IF
            ELSE
              PRINT #2, ky$(i); "="; vl$(i)
            END IF
          END IF
          dn(i) = 1
          hit = 1
        END IF
      NEXT i
    END IF
    IF hit = 0 THEN PRINT #2, l$
  END IF
LOOP
GOSUB missing
CLOSE #1
CLOSE #2
NAME "C:\USOSW3\SYSTEM.TMP" AS "C:\USOSW3\SYSTEM.NEW"
SYSTEM

' Keys the current section should have but did not: added at its end.
missing:
FOR i = 1 TO n
  IF cur$ = sc$(i) AND dn(i) = 0 THEN
    v$ = vl$(i)
    IF LEFT$(v$, 1) = "+" THEN v$ = MID$(v$, 2)
    PRINT #2, ky$(i); "="; v$
    dn(i) = 1
  END IF
NEXT i
RETURN

failed:
CLOSE
SYSTEM
