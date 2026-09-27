#!/bin/sh
# USOS micro-Linux pipeline (refactor M3, docs/design/refactor-os-pipeline.md 2.5).
#
# Sourced by /usos-init (installed as /usr/lib/usos/pipeline/run.sh). It
# decides WHICH steps run from the profile; the steps are thin adapters over
# the existing, unchanged scripts (steps/<id>_<name>.sh).
#
# Where the profile comes from, in order:
#   1. usos.plan_profile=<id> on the kernel command line (BIOS Core and the
#      UEFI XP launcher put it there);
#   2. the legacy action (usos.legacy_action=), through the one table below,
#      so older Core builds keep working;
#   3. for the WORK preparation (no legacy action): plan_profile in
#      install-state.ini (written by the UEFI menu, src/flow/plan.zig),
#      checked by usos_pipeline_check_work_plan.
#
# Profile ids are the ones of src/catalog/os_profiles.zig; `nt5-resume` is the
# Core's "CONTINUE XP" action (not a menu selection).
# Temporaries are _pl_-prefixed: this file is sourced into /usos-init.
# Step contract: a step that ends the session never returns (it powers off,
# hands over or calls stop); step 200 (work_prepare) is the inline WORK body
# of /usos-init, so the pipeline returns to it.

USOS_PIPELINE_DIR=${USOS_PIPELINE_DIR:-/usr/lib/usos/pipeline}
USOS_PLAN_PROFILE=''
USOS_PLAN_STEPS=''

# The five default micro-Linux stages (boot.prep.stage.1..5): a plan with
# exactly these keeps the renderer's own (translated) rows.
USOS_PIPELINE_DEFAULT_STAGES='Starting environment|Verifying target device|Preparing workspace|Copying files|Verification and finalization'

usos_pipeline_log() {
    printf '[PIPELINE] %s\n' "$*"
}

# Legacy action -> profile id. The only mapping table.
usos_pipeline_profile_for_action() {
    case "$1" in
        xp-staging)
            if [ -d "${USOS_PIPELINE_EFI_DIR:-/sys/firmware/efi}" ]; then printf 'xp-x86-sp3-uefi-csm'; else printf 'nt5-staging'; fi ;;
        windows2000-staging)
            if [ -d "${USOS_PIPELINE_EFI_DIR:-/sys/firmware/efi}" ]; then printf 'w2k-x86-sp4-uefi-csm'; else printf 'nt5-staging'; fi ;;
        windows7-iso|windows-vista-iso) printf 'windows-pe-bios-iso' ;;
        xp-resume) printf 'nt5-resume' ;;
        vista-disk) printf 'vista-uefi-disk' ;;
        *) return 1 ;;
    esac
}

# Profile id -> ordered step ids.
usos_pipeline_steps() {
    case "$1" in
        nt5-staging|xp-x86-sp3-uefi-csm|w2k-x86-sp4-uefi-csm) printf '100' ;;
        nt5-resume) printf '150' ;;
        vista-uefi-disk) printf '600' ;;
        windows-pe-bios-iso) printf '500 200' ;;
        iso-work-chainload|wim-wimboot|vhd-vhdboot) printf '200' ;;
        *) return 1 ;;
    esac
}

usos_pipeline_step_name() {
    case "$1" in
        100) printf 'nt5_staging' ;;
        150) printf 'nt5_resume' ;;
        200) printf 'work_prepare' ;;
        500) printf 'windows_pe_bios_request' ;;
        600) printf 'vista_disk_prepare' ;;
        *) return 1 ;;
    esac
}

# The selected_method the menu persists for a WORK profile (Backend.method()).
usos_pipeline_work_method() {
    case "$1" in
        iso-work-chainload) printf 'chainload' ;;
        wim-wimboot) printf 'wimboot' ;;
        vhd-vhdboot) printf 'vhdboot' ;;
        *) return 1 ;;
    esac
}

# Legacy action (may be empty) + optional command-line profile token.
# Sets USOS_PLAN_PROFILE and USOS_PLAN_STEPS; fails on an unknown action,
# an unknown profile or a token that belongs to another action.
usos_pipeline_resolve_action() {
    _pl_action=$1
    _pl_token=$2
    _pl_from_action=$(usos_pipeline_profile_for_action "$_pl_action") || return 1
    _pl_profile=$_pl_from_action
    if [ -n "$_pl_token" ]; then
        # nt5-staging and the UEFI-CSM profile share the xp-staging action
        # (windows2000-staging: the Windows 2000 UEFI-CSM profile).
        case "$_pl_from_action:$_pl_token" in
            "$_pl_token:$_pl_token") _pl_profile=$_pl_token ;;
            nt5-staging:xp-x86-sp3-uefi-csm|xp-x86-sp3-uefi-csm:nt5-staging|nt5-staging:w2k-x86-sp4-uefi-csm|w2k-x86-sp4-uefi-csm:nt5-staging)
                case "$_pl_action:$_pl_token" in
                    xp-staging:xp-x86-sp3-uefi-csm|xp-staging:nt5-staging|windows2000-staging:w2k-x86-sp4-uefi-csm|windows2000-staging:nt5-staging) _pl_profile=$_pl_token ;;
                    *) usos_pipeline_log "profile token $_pl_token does not match action $_pl_action"; return 1 ;;
                esac ;;
            *) usos_pipeline_log "profile token $_pl_token does not match action $_pl_action"; return 1 ;;
        esac
    fi
    _pl_steps=$(usos_pipeline_steps "$_pl_profile") || return 1
    for _pl_step in $_pl_steps; do
        usos_pipeline_step_name "$_pl_step" >/dev/null || return 1
        [ "$_pl_step" = 200 ] || [ -r "$USOS_PIPELINE_DIR/steps/${_pl_step}_$(usos_pipeline_step_name "$_pl_step").sh" ] || { usos_pipeline_log "step $_pl_step missing"; return 1; }
    done
    USOS_PLAN_PROFILE=$_pl_profile
    USOS_PLAN_STEPS=$_pl_steps
    export USOS_PLAN_PROFILE USOS_PLAN_STEPS
    _pl_source=action
    [ -z "$_pl_token" ] || _pl_source=cmdline
    usos_pipeline_log "profile=$_pl_profile steps=$_pl_steps source=$_pl_source"
}

# Runs the resolved steps. Returns 0 when step 200 is reached (the caller
# continues with the WORK body); a session-ending step never returns.
usos_pipeline_run() {
    for _pl_step in $USOS_PLAN_STEPS; do
        _pl_name=$(usos_pipeline_step_name "$_pl_step") || return 1
        usos_pipeline_log "step $_pl_step $_pl_name"
        [ "$_pl_step" != 200 ] || return 0
        . "$USOS_PIPELINE_DIR/steps/${_pl_step}_$_pl_name.sh" || return 1
        "usos_step_${_pl_step}_run" || return 1
    done
    return 0
}

usos_pipeline_ini() {
    awk -F= -v wanted="$1" '
        $1 == wanted { value=$0; sub(/^[^=]*=/, "", value); gsub(/\r/, "", value); print value; found=1; exit }
        END { if (!found) exit 1 }
    ' "$2"
}

# WORK preparation: the plan_* keys of install-state.ini must agree with the
# request. No plan_version: a request from an older menu (accepted as before).
usos_pipeline_check_work_plan() {
    _pl_state=$1
    _pl_method=$2
    _pl_version=$(usos_pipeline_ini plan_version "$_pl_state" 2>/dev/null) || { usos_pipeline_log 'no plan in install-state.ini (older menu)'; return 0; }
    [ "$_pl_version" = 1 ] || { usos_pipeline_log "unsupported plan_version=$_pl_version"; return 1; }
    _pl_profile=$(usos_pipeline_ini plan_profile "$_pl_state" 2>/dev/null) || { usos_pipeline_log 'plan_profile missing'; return 1; }
    _pl_expected=$(usos_pipeline_work_method "$_pl_profile") || { usos_pipeline_log "plan profile $_pl_profile is not a WORK preparation"; return 1; }
    [ "$_pl_expected" = "$_pl_method" ] || { usos_pipeline_log "plan profile $_pl_profile expects method $_pl_expected, request has $_pl_method"; return 1; }
    USOS_PLAN_PROFILE=$_pl_profile
    USOS_PLAN_STEPS=$(usos_pipeline_steps "$_pl_profile")
    export USOS_PLAN_PROFILE USOS_PLAN_STEPS
    _pl_stages=$(usos_pipeline_ini plan_stages "$_pl_state" 2>/dev/null || true)
    if [ -n "$_pl_stages" ] && [ "$_pl_stages" != "$USOS_PIPELINE_DEFAULT_STAGES" ] && command -v usos_ui_declare_stages >/dev/null 2>&1; then
        usos_ui_declare_stages "$_pl_stages"
    fi
    usos_pipeline_log "profile=$_pl_profile steps=$USOS_PLAN_STEPS source=install-state.ini"
}
