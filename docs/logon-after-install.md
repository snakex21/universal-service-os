# How to log on after a Windows installation

Added 2026-10-14 after the NT 3.51 test: the install finished hands-free,
but nothing said which account to use at the logon screen.

## What the user sees

- **Last preparation page before the restart** (micro-Linux notice of the
  NT5 staging, step 610 and step 620; the last stage page of the WORK
  preparation; the progress page of the native wimboot ISO starts): one line
  such as "After the installation log on as Administrator (no password)."
  in the menu language. The password is never shown: it is "set in the answer
  profile", "the one in usos-xp.ini" or "no password".
- **DATA note**: `Systems\Windows\<folder>\last-install-login.txt` (CR LF),
  the same sentence in English and in the menu language plus `user=`,
  `domain=`, `password=` (none / set in the answer profile (not stored here) /
  chosen during Windows Setup), `autologon=`, `prepared=` (UTC). It never holds
  a password. Written by the micro-Linux flows only (DATA is remounted
  read-write for this one file and back to read-only); the native wimboot
  starts cannot write DATA (the UEFI menu has no NTFS writer) and only show
  the line.

## How it works

1. `src/flow/answer/logon.zig` derives the logon from the system id and the
   answer the start really hands over (`Source`: answer profile, DATA's
   `usos-xp.ini`, the user's own answer file, none) and the flow's built-in
   defaults; `Logon.sentence` builds the English sentence from the
   `Template` strings, which are catalog values (`boot.lx.logon_*`, 27
   languages), so usos-fb-ui and the menu translate them by their English
   text.
2. `manual_summary.recordLogon` runs at every start (after `clearRendered`):
   it writes `\EFI\USOS\answer\logon.ini` (`answer_profiles.writeLogon`;
   `system`, `kind`, `user`, `domain`, `password=none|profile|file`,
   `autologon`, `file`, `line`, `line_local`), removes it for systems without
   a logon prompt, and sets the line of the native ISO progress page.
3. micro-Linux (`tools/micro_linux_ui.sh`): `usos_logon_take ESP [SYSTEM]`
   copies it to `/run` (ignored when it names another system; the NT5
   staging passes its family id, an edition suffix such as `-mce` matches),
   `USOS_UI_LOGON` then goes into every later page as `logon=`
   (`fb_ui_state.zig`, drawn by `preparation_screen.zig`: a second line of the
   notice panel or its own panel). `usos_logon_save DATA DIR` writes the DATA
   note. Called before DATA is unmounted in `legacy_xp_staging.sh`,
   `w9x_csmwrap_prepare.sh`, `vista_csmwrap_prepare.sh` and the WORK part of
   `micro_linux_init.sh`.

The Legacy BIOS Core starts (no UEFI menu) write no `logon.ini`, so they show
no line.

## Default logon per flow

| Flow (USOS path) | No answer chosen | With an answer profile | Own answer file |
|---|---|---|---|
| NT 3.51 / 3.5 / 3.1 WS (step 620, VM install) | Administrator, no password | profile user (own account in Administrators; the same password for Administrator), automatic logon if the option is on; `Administrator`/`Guest` as user name = Administrator | account from that file |
| NT 3.1 Advanced Server (step 620) | Administrator in domain USOSDOMAIN, no password | as above, in domain USOSDOMAIN | account from that file |
| NT 4.0 WS / Server / TSE (step 620) | Administrator, no password (`OEMBlankAdminPassword = 1`; the VM's one automatic logon is switched off at the end) | the same: NT 4.0 applies no profile account or password | account from that file |
| Windows 2000 / XP / XP x64 / MCE / Tablet / Server 2003 (NT5 staging) | Setup asks (name and password pages); with an active `usos-xp.ini`: its `user=`, password from that file | profile user (local administrator; the same password for Administrator); automatic logon if the option is on (2003 / 2000 Server: one automatic Administrator logon at the end of Setup) | account from that `.sif` |
| POSReady 2009 (step 620, VM install) | Administrator, no password | Administrator with the profile password (`AdminPassword`) | - |
| Vista / 7 / 8.x / 10 / 11 / Server 2008-2025 (native wimboot, WORK, step 610 incl. 32-bit CSMWrap) | Setup / OOBE asks | profile user (LocalAccounts, Administrators; Server: Administrator gets the same password), automatic logon if the option is on | account from that file |
| Windows 95 / 98 / Me | no logon prompt (MSBATCH.INF installs no network client): no line | no line | no line |

Sources: `src/flow/answer/nt3.zig` + `tools/nt3/usosnt3` (ACCOUNT.TXT),
`src/flow/answer/nt4.zig` + `tools/nt4_csmwrap_target.sh` (SETUP.REG /
DONE.REG), `src/flow/answer/nt5.zig` + `tools/xp_user_settings.sh`,
`src/flow/answer/posready.zig` + `tools/posready_unattended.xml`,
`src/flow/answer/autounattend.zig`, `src/flow/answer/msbatch.zig`;
hardware results in the nt3 / nt4 / w2k / xp / posready status notes
(NT 3.51 Server X470 2026-10-09: Administrator, blank password).

Known gap: `tools/posready_logon.reg` assumes a blank Administrator password
for the install VM's one automatic logon; with a profile password that logon
would not succeed (not changed here).

## Tests

- `src/flow/answer/logon.zig`: derivation per flow, sentences, logon.ini
  without the password, every template present in the boot catalog.
- `src/gui/preparation_screen.zig`: the line rendered (notice and stage
  pages) and translated (Polish fixture).
- `src/platform/linux/fb_ui_state.zig`: `logon=` parsed.
- `src/flow/xp_settings_summary.zig`: `password_set` without the value.
- `tools/tests/test_logon_hint.py`: take / system check / DATA note / state
  file, and every Windows flow takes the hint before DATA is unmounted.
