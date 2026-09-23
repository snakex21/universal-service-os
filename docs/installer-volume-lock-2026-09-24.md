# Installer: "volume lock denied" (drive in use)

Install, update, repair, uninstall and `usos-physical-update` lock every
volume of the target disk (`FSCTL_LOCK_VOLUME`, then `FSCTL_DISMOUNT_VOLUME`)
before they write the partition table or the Legacy boot area. Windows denies
the lock while any other handle is open on the volume, typically an Explorer
window showing the stick (ESP `J:`).

Behaviour (`installer/internal/volumelock`, `internal/winhost/volume_lock_windows.go`):

- A denied lock (`ERROR_ACCESS_DENIED`, `ERROR_SHARING_VIOLATION`,
  `ERROR_LOCK_VIOLATION`) is retried automatically: 5 attempts, pauses of
  1, 2, 4 and 8 s (15 s). A holder that lets go by itself (indexer, antivirus,
  thumbnail cache) no longer fails the operation. Other errors stop at once.
- Safety semantics are unchanged: the dismount only follows a successful lock
  (the lock is the exclusive intent; it proves no other handle is open). A
  busy volume is never force-dismounted, so no program's open handle is
  invalidated.
- After the automatic attempts the holders are named: the file system reports
  the processes with the volume's root or a folder up to two levels deep open
  (`FileProcessIdsUsingFile`; an Explorer window holds the folder it shows),
  and the Restart Manager (`rstrtmgr.dll`, built into Windows) gives their
  display names in the Windows language, e.g. "Eksplorator Windows". The
  volume device itself is not queried: its answer lists every process with a
  handle on the device stack.
- Installer UI: the progress page shows a warning card "Nośnik jest używany" -
  "Nośnik jest używany przez: Eksplorator Windows. Zamknij okna z tym nośnikiem
  i kliknij Ponów." with [Anuluj] and [Ponów] (Enter/Esc). Ponów starts a new
  round of 5 attempts; Anuluj fails the stage with the named holders in the
  error and the log. Keys `installer.volume_busy.*` (27 locales,
  machine-translated except en/pl).
- `usos-physical-update` prints `VOLUME_BUSY <localized message>` and
  `VOLUME_BUSY_DETAIL <volume, holders, attempts, error>`; on an interactive
  console it asks "Press Enter to retry, or type Q ..." (localized), without a
  console it cancels after the automatic attempts.

Tests: `go test ./internal/volumelock` (fake locker: transient holder retried
with backoff, persistent holder fails after 5 attempts without any dismount,
Retry starts a new round, Cancel, non-busy errors not retried, localized
message) and `go test ./internal/winhost -run VolumeHolders` (a real process
holding a folder is named by the Restart Manager). UI screenshot:
`usos-installer-uidemo -shots DIR` (15-update-volume-busy.png).
