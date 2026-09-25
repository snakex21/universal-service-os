#!/bin/sh
# Pipeline step 100: NT5 (XP / 2000) staging. Adapter over the unchanged
# legacy_xp_staging.sh; the code was the xp-staging branch of /usos-init.
usos_step_100_run() {
    NT5_SYSTEM=windows-xp
    [ "$LEGACY_ACTION" != windows2000-staging ] || NT5_SYSTEM=windows-2000
    export NT5_SYSTEM
    [ -r /usr/lib/usos/legacy_xp_staging.sh ] || stop 'legacy_xp_staging.sh is missing'
    . /usr/lib/usos/legacy_xp_staging.sh
    usos_legacy_xp_staging "$LEGACY_IMAGE_HEX" "$LEGACY_UNATTENDED_HEX"
    stop 'Legacy XP staging returned unexpectedly'
}
