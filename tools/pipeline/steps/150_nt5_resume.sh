#!/bin/sh
# Pipeline step 150: continue a prepared XP installation (Core "CONTINUE XP").
# Adapter over the unchanged legacy_xp_resume.sh; the code was the xp-resume
# branch of /usos-init.
usos_step_150_run() {
    # Resume runs a single step; do not show four stages that never run.
    usos_ui_declare_stages 'Continuing Windows XP installation'
    usos_ui_stage 1 1 'Continuing Windows XP installation' 'Checking the prepared XP target.' || true
    sh /usr/lib/usos/legacy_xp_resume.sh || stop 'XP resume refused; see EFI/USOS/legacy-xp-resume.log'
    umount /mnt/esp || stop 'cannot unmount ESP after XP resume'
    sync
    enable_emergency_input || true
    usos_ui_done 'XP - KONTYNUACJA GOTOWA' 'REMOVE USOS USB, THEN PRESS ENTER TO POWER OFF.' || true
    printf '[XP_RESUME] Remove USOS USB, press ENTER, then start target disk.\n'
    if [ -r "$USOS_UI_TTY" ]; then IFS= read -r _resume_poweroff < "$USOS_UI_TTY" || true; else IFS= read -r _resume_poweroff || true; fi
    poweroff -f
    while true; do sleep 3600; done
}
