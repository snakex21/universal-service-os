#!/bin/sh
# Pipeline step 600: Vista SP2 x64 on UEFI, USOS prepares the target disk
# (tools/vista_disk_prepare.sh). Ends the session with a reboot into USOS.
usos_step_600_run() {
    [ "$LEGACY_ACTION" = vista-disk ] || stop 'Unexpected Vista disk action'
    [ -r /usr/lib/usos/vista_disk_prepare.sh ] || stop 'vista_disk_prepare.sh is missing'
    . /usr/lib/usos/vista_disk_prepare.sh
    usos_vista_disk_prepare
    stop 'Vista disk preparation returned unexpectedly'
}
