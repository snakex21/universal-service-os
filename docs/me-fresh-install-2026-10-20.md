# Windows Me fresh install on the X470 — fixes, 2026-10-20

Fresh install from build B261019-210547-5FDA8767 (int/me-round, cab60988)
onto the Micron 3400 (RTL9210B-CG enclosure), stock USOS answer (no
profile). Working: USB mouse, buttons, wheel, DOS-box mouse, USB stick
hot-swap, restart and power-off. The logs were read from the disk
read-only (disk signature 440e416f, partition 1 WINDOWSME 9508-EA3B FAT32,
32 GiB at 1 MiB; partition 2 CSMWRAP 64 MiB at the disk end).

| Problem | Evidence | Cause | Fix |
| --- | --- | --- | --- |
| I211 Code 2 | `Class\Net\0000` complete (DeviceVxDs/NTMPDriver usosnet.sys, DriverVersion 0.4.0.0, DevLoader `*ndis,*ntkern,*ndis` as with the working hand-made kit); `C:\WINDOWS\SYSTEM\USOSNET.SYS` absent, the file only in `C:\WIN9X` and `C:\USOS9X\NET`; NETLOG `NdiGenInstallDriverDoFiles: Skipping file copy`, `DiInstallDevice with DI_NOFILECOPY`; BOOTLOG `Loading PNP drivers of ... (USOS usosnet)` without `Loaded` | During Setup NETDI leaves file copies to Setup's own queue, which does not copy the OEM INF's file | INSTALL.BAT: Me copies `USOSNET.SYS` into `C:\WINDOWS\SYSTEM` before Setup (like USOSKEY/USOSMOUS); 95/98/98 SE get an AUTOEXEC.BAT copy before the first Windows start |
| Password dialog once | Winlogon `AutoAdminLogon=1`, `DefaultUserName=USOS`, `DefaultPassword=""` present; `C:\WINDOWS\USOS.PWL` dated 23:59:22, 20 s after the first start; SYSTEM.INI `[Password Lists] USOS=C:\WINDOWS\USOS.PWL` | No password list on the first start: Windows Logon asks once and creates it; later starts with the empty password are silent | Me, stock user USOS: `tools/w9x_logon.sh` stages the empty-password list (`src/platform/bios/win9x/usosme.pwl`, the 688-byte list from this install; data, no code) plus `[Password Lists]` and `Network\Logon username`; other user names keep Windows' dialog. **Untested**: next fresh install |
| ICW icon | `C:\WINDOWS\All Users\Pulpit\Połącz z Internetem.LNK` -> `ICWCONN1.EXE`; HKLM Shell Folders `Common Desktop` | The 9x LAN helper scanned only the user desktop (common desktop was NT-only) | USOSLAN scans `Common Desktop` on 9x too (verified target ICWCONN1.EXE) |
| 640x480 | No `;USOS-DISPLAY=` in the stock answer: no request | Auto was opt-in | Default `autoxauto` for every USOS-made answer (9x, NT4 with VESA, 2000 VESA); user files copied 1:1 get none; NT 3.x stays explicit |
| Mouse in Setup's GUI phase | Setup's own mouse detection writes `mouse.drv=mouse.drv`; USOSMOUS is switched on at the first sign-in | Not changed (low priority) | — |
| "installed 0/10" | ADDONS.LOG `staging complete files=0 missing=10`, runner registered | Runner staged with nothing to install | `legacy_addons.sh` removes USOSADD.EXE / ADDONS.REG when nothing was staged; the callers then drop the Run entry |

Also fixed: `usos_display_9x_answer` appended `[USOS.Display]` after
`[USOS.Csm]`; INSTALL.BAT appends Me's `system.ini,boot,drivers,,usoskey.drv`
to the last section, so a Me display request would have lost the USB
keyboard driver line. Both new answer sections now go before `[USOS.Csm]`.

Next fresh Me install should show: `C:\WINDOWS\SYSTEM\USOSNET.SYS` present,
the I211 working (no Code 2, DHCP address), no password dialog on the first
start, no ICW icon, USOSRES log `DISPLAY request=autoxauto` and the chosen
mode after the first sign-in, no compatibility pack window with an empty
DATA\Addons.
