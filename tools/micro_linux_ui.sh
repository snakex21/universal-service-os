#!/bin/sh

USOS_UI_TTY=${USOS_UI_TTY:-/dev/tty1}
[ -w "$USOS_UI_TTY" ] || USOS_UI_TTY=/dev/console
USOS_FB_UI=${USOS_FB_UI:-/usr/bin/usos-fb-ui}
USOS_FB_STATE=${USOS_FB_STATE:-/run/usos-fb-ui.state}
USOS_FB_MODULES=${USOS_FB_MODULES:-/usr/lib/usos/simpledrm.modules}
USOS_FB_ACTIVE=${USOS_FB_ACTIVE:-no}
USOS_UI_CURRENT=${USOS_UI_CURRENT:-1}
# A path that runs other stages than the five micro-Linux preparation stages
# declares them: USOS_UI_LABELS='First|Second' (the count becomes the total).
USOS_UI_LABELS=${USOS_UI_LABELS:-}
USOS_UI_TOTAL=${USOS_UI_TOTAL:-}
USOS_UI_HEADING=${USOS_UI_HEADING:-}
# Windows XP / 2000 staging shows one progress page from the UEFI handoff to
# the end, with the stages this path really runs (the UEFI menu already drew
# stage 1 of the same list; boot.xp_prep.* and boot.prep.stage.3 in the
# catalogs). The shared scripts keep calling the generic five stages; they
# are mapped onto this list by usos_ui_nt5_stage.
USOS_UI_NT5=${USOS_UI_NT5:-no}
case " $(cat /proc/cmdline 2>/dev/null) " in
    *' usos.legacy_action=xp-staging '*) USOS_UI_NT5=yes; USOS_UI_HEADING='Windows XP' ;;
    *' usos.legacy_action=windows2000-staging '*) USOS_UI_NT5=yes; USOS_UI_HEADING='Windows 2000' ;;
    *' usos.legacy_action=windows2003-staging '*) USOS_UI_NT5=yes; USOS_UI_HEADING='Windows Server 2003' ;;
    *' usos.legacy_action=xp64-staging '*) USOS_UI_NT5=yes; USOS_UI_HEADING='Windows XP x64' ;;
esac
if [ "$USOS_UI_NT5" = yes ] && [ -z "$USOS_UI_LABELS" ]; then
    USOS_UI_LABELS='Loading the preparation environment|Detecting disks|Choosing the target disk|Preparing workspace|Copying and verifying files'
    USOS_UI_TOTAL=5
fi
# Vista without firmware CSM (step 610) continues the UEFI menu's progress
# page of the same flow (VistaCsmwrapStage in
# src/flow/preparation_boot_progress.zig): UEFI drew stages 1 and 2, this
# session runs 2 (environment) to 5 (restart into Setup). The generic stage
# calls of /usos-init all belong to stage 2.
USOS_UI_VISTA=${USOS_UI_VISTA:-no}
case " $(cat /proc/cmdline 2>/dev/null) " in
    *' usos.legacy_action=vista-csmwrap '*) USOS_UI_VISTA=yes; [ -n "$USOS_UI_HEADING" ] || USOS_UI_HEADING='Windows Vista' ;;
esac
if [ "$USOS_UI_VISTA" = yes ] && [ -z "$USOS_UI_LABELS" ]; then
    USOS_UI_LABELS='Validating installation ISO|Loading the preparation environment|Choosing the target disk|Preparing the disk|Starting Windows Setup'
    USOS_UI_TOTAL=5
fi
export USOS_UI_TTY USOS_FB_UI USOS_FB_STATE USOS_FB_MODULES USOS_FB_ACTIVE USOS_UI_CURRENT USOS_UI_LABELS USOS_UI_TOTAL USOS_UI_HEADING USOS_UI_NT5 USOS_UI_VISTA

usos_ui_declare_stages() {
    USOS_UI_LABELS=$1
    USOS_UI_TOTAL=$(printf '%s' "$1" | awk -F'|' '{print NF}')
    export USOS_UI_LABELS USOS_UI_TOTAL
}

usos_ui_total() {
    printf '%s' "${USOS_UI_TOTAL:-${1:-5}}"
}

usos_ui_stage_label() {
    if [ -n "$USOS_UI_LABELS" ]; then
        printf '%s' "$USOS_UI_LABELS" | awk -F'|' -v n="$1" '{ if (n >= 1 && n <= NF) printf "%s", $n; else printf "Preparation" }'
        return 0
    fi
    case "$1" in
        1) printf '%s' 'Starting environment' ;;
        2) printf '%s' 'Verifying target device' ;;
        3) printf '%s' 'Preparing workspace' ;;
        4) printf '%s' 'Copying files' ;;
        5) printf '%s' 'Verification and finalization' ;;
        *) printf '%s' 'Preparation' ;;
    esac
}

# Generic stage number (1-5 of the shared scripts) -> NT5 stage. Checks that
# run while the disk menus are in use belong to "Choosing the target disk".
usos_ui_nt5_stage() {
    if [ "${USOS_XP_CHOOSING:-no}" = yes ] && [ "${USOS_XP_MENU_SHOWN:-no}" = yes ]; then
        printf '3'
        return 0
    fi
    case "$1" in
        1) printf '1' ;;
        2) printf '2' ;;
        3) printf '4' ;;
        *) printf '5' ;;
    esac
}

# A script title that only names its generic stage is replaced by the NT5
# stage name; specific activity titles are kept.
usos_ui_nt5_title() {
    case "$2" in
        'Starting environment'|'Verifying target device'|'Preparing workspace'|'Copying files'|'Verification and finalization')
            usos_ui_stage_label "$1"
            ;;
        *) printf '%s' "$2" ;;
    esac
}

usos_perf_mark() {
    label=$1
    perf_uptime=unknown
    if [ -r /proc/uptime ]; then
        read perf_uptime _perf_idle < /proc/uptime || perf_uptime=unknown
    fi
    printf '[USOS-PERF] uptime=%ss %s\n' "$perf_uptime" "$label"
}

usos_ui_log() {
    printf '[USOS-FB-UI] %s\n' "$1" > /dev/console 2>/dev/null || true
}

usos_ui_make_fb_node() {
    [ -e /dev/fb0 ] && return 0
    [ -r /sys/class/graphics/fb0/dev ] || return 1
    IFS=: read -r fb_major fb_minor < /sys/class/graphics/fb0/dev || return 1
    case "$fb_major:$fb_minor" in
        *[!0-9:]*|:|*: ) return 1 ;;
    esac
    mknod /dev/fb0 c "$fb_major" "$fb_minor" 2>/dev/null || true
    [ -e /dev/fb0 ]
}

usos_ui_load_framebuffer() {
    [ -e /dev/fb0 ] && return 0
    [ -r "$USOS_FB_MODULES" ] || return 1

    kernel_release=$(uname -r)
    while IFS= read -r module; do
        [ -n "$module" ] || continue
        module_path="/usr/lib/modules/$kernel_release/$module"
        [ -f "$module_path" ] || return 1
        module_name=${module##*/}
        module_name=${module_name%.ko}
        module_name=$(printf '%s' "$module_name" | tr '-' '_')
        if [ ! -d "/sys/module/$module_name" ]; then
            insmod "$module_path" 2>/dev/null || return 1
        fi
    done < "$USOS_FB_MODULES"

    # Do not run a full mdev scan here. The first USOS frame is latency
    # critical: use the fb class device immediately after simpledrm registers
    # it and create /dev/fb0 directly only when devtmpfs did not do so.
    usos_ui_make_fb_node
}

usos_ui_log_framebuffer_resource() {
    current=$(readlink -f /sys/class/graphics/fb0/device 2>/dev/null || true)
    depth=0
    while [ -n "$current" ] && [ "$depth" -lt 8 ]; do
        resource="$current/resource"
        if [ -r "$resource" ]; then
            IFS=' ' read -r fb_resource_start fb_resource_end fb_resource_flags < "$resource" || true
            if [ -n "${fb_resource_start:-}" ] && [ -n "${fb_resource_end:-}" ]; then
                usos_ui_log "RESOURCE start=$fb_resource_start end=$fb_resource_end flags=${fb_resource_flags:-unknown} path=$current"
                return 0
            fi
        fi
        parent=$(dirname "$current")
        [ "$parent" != "$current" ] || break
        current=$parent
        depth=$((depth + 1))
    done
    usos_ui_log 'RESOURCE unavailable'
    return 1
}

usos_ui_bootstrap_frame() {
    # The UEFI menu leaves its "Starting..." splash on screen and the kernel
    # keeps it (deferred fbcon takeover), so this first frame is the same
    # splash and the takeover is invisible. After the Legacy BIOS loader's
    # progress screen it is a neutral "Starting..." for every session
    # (preparation, Hardware & SMART, XP) until the session's own screen.
    # For Windows XP / 2000 the UEFI menu left the progress page at stage 1;
    # the first Linux frame is the same page.
    if [ "$USOS_UI_NT5" = yes ]; then
        {
            printf 'mode=stage\n'
            printf 'current=1\n'
            printf 'total=5\n'
            printf 'heading=%s\n' "$USOS_UI_HEADING"
            printf 'title=%s\n' "$(usos_ui_stage_label 1)"
            printf 'detail=%s\n' 'The kernel is loading the XP environment; the disk selection follows'
            printf '%s\n' "$USOS_UI_LABELS" | tr '|' '\n' | while IFS= read -r stage_name; do
                printf 'label=%s\n' "$stage_name"
            done
        } | "$USOS_FB_UI" >/dev/null 2>&1
        return
    fi
    # Vista without CSM: the UEFI menu left its page at stage 2 with this
    # detail (VistaCsmwrapStage.loading_detail); the first frame is the same.
    if [ "$USOS_UI_VISTA" = yes ]; then
        {
            printf 'mode=stage\n'
            printf 'current=2\n'
            printf 'total=5\n'
            printf 'heading=%s\n' "$USOS_UI_HEADING"
            printf 'title=%s\n' "$(usos_ui_stage_label 2)"
            printf 'detail=%s\n' 'Loading the micro-Linux kernel from the USB drive'
            printf '%s\n' "$USOS_UI_LABELS" | tr '|' '\n' | while IFS= read -r stage_name; do
                printf 'label=%s\n' "$stage_name"
            done
        } | "$USOS_FB_UI" >/dev/null 2>&1
        return
    fi
    {
        printf 'mode=splash\n'
        printf 'current=1\n'
        printf 'total=5\n'
        printf 'title=STARTING ENVIRONMENT\n'
        printf 'detail=\n'
        printf 'image=\n'
        printf 'percent=0\n'
        printf 'bytes_done=0\n'
        printf 'bytes_total=0\n'
        printf 'speed_bps=0\n'
    } | "$USOS_FB_UI" >/dev/null 2>&1
}

usos_ui_init() {
    USOS_FB_ACTIVE=no
    [ -x "$USOS_FB_UI" ] || return 1
    if ! usos_ui_load_framebuffer; then
        usos_ui_log 'simpledrm framebuffer unavailable; using console fallback'
        return 1
    fi
    usos_ui_log_framebuffer_resource || true

    # The very next external program after simpledrm/fb0 is the renderer.
    # It opens fb0 and clears to the USOS background before reading this state.
    USOS_FB_ACTIVE=yes
    if ! usos_ui_bootstrap_frame; then
        USOS_FB_ACTIVE=no
        usos_ui_log 'initial framebuffer render failed; using console fallback'
        return 1
    fi
    first_frame_uptime=unknown
    if [ -r /proc/uptime ]; then
        read first_frame_uptime _first_frame_idle < /proc/uptime || first_frame_uptime=unknown
    fi
    usos_ui_log "FIRST_FRAME uptime=${first_frame_uptime}s"
    return 0
}

usos_ui_render_state() {
    mode=$1
    current=$2
    total=$3
    title=$4
    detail=${5:-}
    image=${6:-}
    percent=${7:-0}
    bytes_done=${8:-0}
    bytes_total=${9:-0}
    speed_bps=${10:-0}

    [ "$USOS_FB_ACTIVE" = yes ] || return 1
    {
        printf 'mode=%s\n' "$mode"
        printf 'current=%s\n' "$current"
        printf 'total=%s\n' "$total"
        printf 'title=%s\n' "$title"
        printf 'detail=%s\n' "$detail"
        printf 'image=%s\n' "$image"
        printf 'percent=%s\n' "$percent"
        printf 'bytes_done=%s\n' "$bytes_done"
        printf 'bytes_total=%s\n' "$bytes_total"
        printf 'speed_bps=%s\n' "$speed_bps"
        [ -z "$USOS_UI_HEADING" ] || printf 'heading=%s\n' "$USOS_UI_HEADING"
        [ -z "${USOS_UI_NOTICE:-}" ] || printf 'notice=%s\n' "$USOS_UI_NOTICE"
        [ -z "${USOS_UI_ACTION:-}" ] || printf 'action=%s\n' "$USOS_UI_ACTION"
        if [ -n "$USOS_UI_LABELS" ]; then
            printf '%s\n' "$USOS_UI_LABELS" | tr '|' '\n' | while IFS= read -r stage_name; do
                printf 'label=%s\n' "$stage_name"
            done
        fi
    } > "$USOS_FB_STATE"
    if "$USOS_FB_UI" "$USOS_FB_STATE" >/dev/null 2>&1; then
        return 0
    fi
    USOS_FB_ACTIVE=no
    usos_ui_log 'renderer failed; using console fallback'
    return 1
}

usos_ui_stage() {
    current=$1
    total=$(usos_ui_total "$2")
    [ "$current" -le "$total" ] || current=$total
    USOS_UI_CURRENT=$current
    title=$3
    detail=${4:-}
    if [ "$USOS_UI_NT5" = yes ]; then
        current=$(usos_ui_nt5_stage "$1")
        title=$(usos_ui_nt5_title "$current" "$title")
        USOS_UI_CURRENT=$current
    elif [ "$USOS_UI_VISTA" = yes ]; then
        [ "$current" -ge 2 ] || current=2
        USOS_UI_CURRENT=$current
    elif [ "${USOS_XP_CHOOSING:-no}" = yes ]; then
        # Keep the selected menu visible while read-only checks run between
        # choices. The initial detection screen is shown only before a menu.
        [ "${USOS_XP_MENU_SHOWN:-no}" != yes ] || return 0
        usos_ui_render_state notice 1 5 'WINDOWS XP' 'Detecting disks. No installation changes have started.' '' 0 0 0 0 && return 0
    fi
    usos_ui_log "STAGE current=$current/$total title=$title"
    if usos_ui_render_state stage "$current" "$total" "$title" "$detail" '' 0 0 0 0; then
        return 0
    fi
    usos_ui_console_stage "$current" "$total" "$title" "$detail"
}

usos_ui_progress() {
    current=$1
    total=$(usos_ui_total "$2")
    [ "$current" -le "$total" ] || current=$total
    USOS_UI_CURRENT=$current
    percent=$3
    bytes_done=$4
    bytes_total=$5
    speed_bps=$6
    title=$7
    detail=${8:-}
    image=${9:-}
    if [ "$USOS_UI_NT5" = yes ]; then
        current=$(usos_ui_nt5_stage "$1")
        USOS_UI_CURRENT=$current
    elif [ "$USOS_UI_VISTA" = yes ]; then
        [ "$current" -ge 2 ] || current=2
        USOS_UI_CURRENT=$current
    fi
    if usos_ui_render_state progress "$current" "$total" "$title" "$detail" "$image" "$percent" "$bytes_done" "$bytes_total" "$speed_bps"; then
        return 0
    fi
    usos_ui_console_progress "$percent" "$title" "$detail"
}

usos_ui_format_bytes() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes >= 1099511627776) printf "%.1f TB", bytes / 1099511627776
        else if (bytes >= 1073741824) printf "%.1f GB", bytes / 1073741824
        else if (bytes >= 1048576) printf "%.1f MB", bytes / 1048576
        else if (bytes >= 1024) printf "%.1f KB", bytes / 1024
        else printf "%.0f B", bytes
    }'
}

usos_ui_wait_activity() {
    activity_pid=$1
    activity_title=$2
    activity_detail=$3
    activity_frame=0
    while kill -0 "$activity_pid" 2>/dev/null; do
        case "$activity_frame" in
            0) activity_glyph='|' ;;
            1) activity_glyph='/' ;;
            2) activity_glyph='-' ;;
            *) activity_glyph='\\' ;;
        esac
        activity_total=$(usos_ui_total 5)
        usos_ui_stage "$activity_total" "$activity_total" "$activity_title" "$activity_detail [$activity_glyph]" || true
        activity_frame=$(( (activity_frame + 1) % 4 ))
        sleep 0.2
    done
    if wait "$activity_pid"; then
        return 0
    else
        activity_rc=$?
        return "$activity_rc"
    fi
}

usos_ui_sync_with_activity() {
    activity_title=${1:-'Flushing to disk'}
    activity_detail=${2:-'Writing buffered data to the USB drive.'}
    sync &
    activity_pid=$!
    usos_ui_wait_activity "$activity_pid" "$activity_title" "$activity_detail"
}

usos_ui_done() {
    title=$1
    detail=${2:-}
    done_total=$(usos_ui_total 5)
    USOS_UI_CURRENT=$done_total
    usos_ui_log "DONE title=$title detail=$detail"
    if usos_ui_render_state done "$done_total" "$done_total" "$title" "$detail" '' 100 0 0 0; then
        usos_ui_log "DONE RENDER PASS backend=framebuffer action=[ENTER]-POWER-OFF"
        return 0
    fi
    usos_ui_console_done "$title" "$detail"
    usos_ui_log "DONE RENDER PASS backend=console action=[ENTER]-POWER-OFF"
}

# Done page with a notice the user acknowledges with Enter (the caller reads
# the key): every stage done, the notice below the progress card.
usos_ui_notice_continue() {
    notice_title=$1
    USOS_UI_NOTICE=$2
    USOS_UI_ACTION=${3:-Proceed}
    notice_total=$(usos_ui_total 5)
    USOS_UI_CURRENT=$notice_total
    usos_ui_log "NOTICE title=$notice_title action=$USOS_UI_ACTION"
    if usos_ui_render_state done "$notice_total" "$notice_total" "$notice_title" '' '' 100 0 0 0; then
        USOS_UI_NOTICE='' USOS_UI_ACTION=''
        return 0
    fi
    {
        printf '\033[2J\033[H\033[?25l\n'
        printf '      \033[1;33m\033[1m%s\033[0m\n\n' "$notice_title"
        printf '      \033[1;37m%s\033[0m\n\n' "$USOS_UI_NOTICE"
        printf '      \033[1;36m\033[1m[ ENTER ]  %s\033[0m\n\n' "$USOS_UI_ACTION"
    } > "$USOS_UI_TTY" 2>/dev/null || true
    USOS_UI_NOTICE='' USOS_UI_ACTION=''
}

usos_ui_fail() {
    title=$1
    detail=${2:-}
    usos_ui_render_state failure "$USOS_UI_CURRENT" "$(usos_ui_total 5)" "$title" "$detail" '' 0 0 0 0 || true
}

usos_ui_diagnostic() {
    diagnostic_file=$1
    diagnostic_title=${2:-}
    [ -r "$diagnostic_file" ] || return 1

    # Always mirror the complete diagnostic record to the active console/serial
    # before rendering it. The framebuffer may clip very long hardware output,
    # while serial keeps the unabridged evidence.
    {
        printf '[USOS-DIAG] BEGIN\n'
        cat "$diagnostic_file"
        printf '[USOS-DIAG] END\n'
    } > /dev/console 2>/dev/null || true

    if [ "$USOS_FB_ACTIVE" = yes ]; then
        {
            printf 'mode=diagnostic\n'
            [ -z "$diagnostic_title" ] || printf 'title=%s\n' "$diagnostic_title"
            printf 'current=1\n'
            printf 'total=5\n'
            while IFS= read -r diagnostic_line || [ -n "$diagnostic_line" ]; do
                clean_line=$(printf '%s' "$diagnostic_line" | tr '\t\r' '  ')
                printf 'diag=%s\n' "$clean_line"
            done < "$diagnostic_file"
        } > "$USOS_FB_STATE"
        if "$USOS_FB_UI" "$USOS_FB_STATE" >/dev/null 2>&1; then
            return 0
        fi
    fi

    {
        printf '\033[2J\033[H\033[?25l'
        cat "$diagnostic_file"
    } > "$USOS_UI_TTY" 2>/dev/null || true
    return 0
}

# Console rendering is only a compatibility fallback for machines where Linux
# cannot expose the firmware framebuffer.
usos_ui_console_stage() {
    current=$1
    total=$(usos_ui_total "$2")
    title=$3
    detail=${4:-}
    footer=${5:-'Do not disconnect the drive or turn off the computer.'}
    {
        printf '\033[2J\033[H\033[?25l\n'
        printf '      \033[1;36m\033[1mUNIVERSAL SERVICE OS\033[0m\n'
        printf '      \033[2mPREPARING WINDOWS INSTALLER\033[0m\n'
        printf '      \033[2m--------------------------------------------------------------\033[0m\n\n'
        printf '      \033[1;37m\033[1m%s\033[0m\n' "$title"
        [ -n "$detail" ] && printf '      \033[2m%s\033[0m\n' "$detail"
        printf '\n'
        stage=1
        while [ "$stage" -le "$total" ]; do
            label=$(usos_ui_stage_label "$stage")
            if [ "$stage" -lt "$current" ]; then
                printf '      \033[1;34m[%d/%d] %-45s\033[0m \033[1;32mOK\033[0m\n' "$stage" "$total" "$label"
            elif [ "$stage" -eq "$current" ]; then
                printf '      \033[1;36m\033[1m[%d/%d] %-45s RUNNING\033[0m\n' "$stage" "$total" "$label"
            else
                printf '      \033[2m[%d/%d] %-45s waiting\033[0m\n' "$stage" "$total" "$label"
            fi
            stage=$((stage + 1))
        done
        printf '\n      \033[2m%s\033[0m\n' "$footer"
    } > "$USOS_UI_TTY"
}

usos_ui_console_progress() {
    percent=$1
    title=$2
    detail=${3:-}
    usos_ui_console_stage "$USOS_UI_CURRENT" "$(usos_ui_total 5)" "$title" "$detail"
    printf '\n      Progress: %s%%\n' "$percent" >> "$USOS_UI_TTY"
}

usos_ui_console_done() {
    title=$1
    detail=${2:-}
    {
        printf '\033[2J\033[H\033[?25l\n'
        printf '      \033[1;36m\033[1mUNIVERSAL SERVICE OS\033[0m\n'
        printf '      \033[2mPREPARING WINDOWS INSTALLER\033[0m\n'
        printf '      \033[2m--------------------------------------------------------------\033[0m\n\n'
        printf '      \033[1;32m\033[1m%s\033[0m\n' "$title"
        [ -n "$detail" ] && printf '      \033[1;37m%s\033[0m\n' "$detail"
        printf '\n'
        printf '      \033[1;37mREMOVE THE USOS USB DRIVE BEFORE POWERING OFF.\033[0m\n\n'
        printf '      \033[1;36m\033[1m[ ENTER ]  POWER OFF\033[0m\n\n'
        printf '      \033[2mNEXT POWER-ON: BOOT THE TARGET DISK WITHOUT USOS.\033[0m\n'
    } > "$USOS_UI_TTY"
}

usos_ui_restore_cursor() {
    [ "$USOS_FB_ACTIVE" = yes ] && return 0
    printf '\033[0m\033[?25h' > "$USOS_UI_TTY" 2>/dev/null || true
}
