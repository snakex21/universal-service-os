#!/bin/sh
# Pipeline step 610: Vista SP2 x64 without firmware CSM (profile
# vista-x64-sp2-uefi-csmwrap, experimental): USOS writes the PE10 staging
# partition and the CSMWrap ESP to the chosen disk (tools/vista_csmwrap_prepare.sh).
# Ends the session with a restart; the firmware then boots that disk.
usos_step_610_run() {
    [ "$LEGACY_ACTION" = vista-csmwrap ] || stop 'Unexpected Vista CSMWrap action'
    [ -r /usr/lib/usos/vista_csmwrap_prepare.sh ] || stop 'vista_csmwrap_prepare.sh is missing'
    . /usr/lib/usos/vista_csmwrap_prepare.sh
    usos_vista_csmwrap_prepare
    stop 'Vista CSMWrap preparation returned unexpectedly'
}
