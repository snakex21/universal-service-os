#!/bin/sh
# Pipeline step 500: Windows 7 / Vista ISO from the BIOS Core. Adapter over
# the unchanged legacy_windows_request.sh (writes the WORK request); the WORK
# body of /usos-init (step 200) follows.
usos_step_500_run() {
    . /usr/lib/usos/legacy_windows_request.sh
    legacy_windows_request
}
