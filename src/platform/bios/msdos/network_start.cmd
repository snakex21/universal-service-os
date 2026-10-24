@echo off
rem USOS network for MS-DOS (C:\NET\NETSTART.BAT, called from AUTOEXEC.BAT).
rem USOSPKT.COM: own packet driver for Intel I211 / I210 / 82576 (igb) on
rem INT 60h; mTCP DHCP then writes the address into C:\NET\MTCP.CFG.
rem The boot never waits long: no supported NIC = USOSPKT exits at once
rem with errorlevel 1 and nothing else runs; no DHCP answer = at most two
rem tries of 6 seconds (Esc skips). Logs: C:\NET\USOSPKT.LOG, C:\NET\DHCP.LOG.
set MTCPCFG=C:\NET\MTCP.CFG
path %PATH%;C:\NET
if not exist C:\NET\MTCP.CFG copy C:\NET\MTCP.DEF C:\NET\MTCP.CFG >nul
C:\NET\USOSPKT.COM 0x60 >C:\NET\USOSPKT.LOG
if errorlevel 1 goto no_driver
C:\NET\DHCP.EXE -retries 2 -timeout 6 >C:\NET\DHCP.LOG
if errorlevel 1 goto no_dhcp
echo USOS: network ready (DHCP), mTCP programs in C:\NET (HTGET, PING, FTP, TELNET).
goto end
:no_dhcp
echo USOS: no DHCP answer, network without an address (C:\NET\DHCP.LOG).
goto end
:no_driver
echo USOS: no supported network card (C:\NET\USOSPKT.LOG).
:end
