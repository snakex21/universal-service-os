#!/bin/sh
# Pipeline step 620: Windows 95/98/Me from the UEFI menu without firmware CSM
# (profile w9x-uefi-csmwrap, experimental): USOS writes the FAT32 Setup disk,
# its one-time DOS start and the CSMWrap ESP (tools/w9x_csmwrap_prepare.sh).
# Ends the session with a restart; the firmware then boots that disk.
usos_step_620_run() {
    [ "$LEGACY_ACTION" = w9x-csmwrap ] || stop 'Unexpected Windows 9x CSMWrap action'
    [ -r /usr/lib/usos/w9x_csmwrap_prepare.sh ] || stop 'w9x_csmwrap_prepare.sh is missing'
    . /usr/lib/usos/w9x_csmwrap_prepare.sh
    usos_w9x_csmwrap_prepare
    stop 'Windows 9x CSMWrap preparation returned unexpectedly'
}
