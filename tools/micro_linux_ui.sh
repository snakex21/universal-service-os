#!/bin/sh

USOS_UI_TTY=${USOS_UI_TTY:-/dev/tty1}
[ -w "$USOS_UI_TTY" ] || USOS_UI_TTY=/dev/console

usos_ui_stage() {
    current=$1
    total=$2
    title=$3
    detail=${4:-}

    case "$current" in
        ''|*[!0-9]*) current=1 ;;
    esac
    case "$total" in
        ''|*[!0-9]*) total=1 ;;
    esac
    [ "$total" -gt 0 ] || total=1
    [ "$current" -le "$total" ] || current=$total

    {
        printf '\033[2J\033[H\033[?25l'
        printf '\n'
        printf '      \033[1;36m\033[1mUSOS\033[0m  \033[2mUniversal Service OS\033[0m\n'
        printf '      \033[2m--------------------------------------------------------------\033[0m\n\n'
        printf '      \033[1;37m\033[1mPreparing Windows installer\033[0m\n'
        printf '      \033[2mVerified micro-Linux preparation backend\033[0m\n\n'
        printf '      \033[1;36mStage %d of %d\033[0m\n' "$current" "$total"
        printf '      \033[1;37m%s\033[0m\n' "$title"
        if [ -n "$detail" ]; then
            printf '      \033[2m%s\033[0m\n' "$detail"
        else
            printf '\n'
        fi
        printf '\n'
        printf '      \033[2mNo estimated percentage is shown for setup stages.\033[0m\n'
        printf '      \033[2mA measured progress bar appears when Windows files start copying.\033[0m\n\n'
        printf '      \033[2mDo not disconnect the drive or turn off the computer.\033[0m\n'
    } > "$USOS_UI_TTY"
}

usos_ui_done() {
    title=$1
    detail=${2:-}
    {
        printf '\033[2J\033[H\033[?25l'
        printf '\n'
        printf '      \033[1;36m\033[1mUSOS\033[0m  \033[2mUniversal Service OS\033[0m\n'
        printf '      \033[2m--------------------------------------------------------------\033[0m\n\n'
        printf '      \033[1;32m\033[1m%s\033[0m\n' "$title"
        if [ -n "$detail" ]; then
            printf '      \033[2m%s\033[0m\n' "$detail"
        fi
        printf '\n'
        printf '      [\033[1;32m====================================================\033[0m]\n'
        printf '      \033[1;32m\033[1mDONE\033[0m\n\n'
        printf '      \033[2mPreparation is complete. One reboot will now start Windows Setup.\033[0m\n'
    } > "$USOS_UI_TTY"
}

usos_ui_restore_cursor() {
    printf '\033[0m\033[?25h' > "$USOS_UI_TTY" 2>/dev/null || true
}
