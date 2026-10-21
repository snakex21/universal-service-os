# Windows 95 PL OEM Setup input, gated by the native page classifier.
# Sourced by w9x_phase1_qemu.sh; contains no key or Windows implementation.
W9X_VM_95_HELPER=${W9X_VM_95_HELPER:-/usr/lib/usos/win95-setup-ui}
W9X_VM_OWNER=${W9X_VM_OWNER:-USOS}
W9X_VM_ORG=${W9X_VM_ORG:-}

w9x_vm_owner_value() {
    awk -v wanted="$2" '
        { sub(/\r$/, "") }
        /^\[/ { section=tolower($0); next }
        section == "[nameandorg]" && index($0,"=") {
            at=index($0,"="); field=substr($0,1,at-1); gsub(/^[ \t]+|[ \t]+$/, "", field)
            if (tolower(field) != tolower(wanted)) next
            value=substr($0,at+1); gsub(/^[ \t]+|[ \t]+$/, "", value)
            sub(/^"/, "", value); sub(/"$/, "", value); print value; exit
        }' "$1" 2>/dev/null
}

w9x_vm_private_key() {
    printf 'sendkey %s\n' "$1" 1<> "$W9X_VM_RUN/key.in" 2>/dev/null || return 1
    sleep 1
}

w9x_vm_clear_edit() {
    for w95_edit_key in home shift-end backspace; do w9x_vm_private_key "$w95_edit_key" || return 1; done
}

w9x_vm_owner_valid() {
    [ -n "$W9X_VM_OWNER" ] && [ "$W9X_VM_OWNER" != "${1:-${key:-}}" ] &&
        printf '%s\n' "$W9X_VM_OWNER" | LC_ALL=C grep -Eq '^[A-Za-z0-9_. -]{1,40}$' &&
        printf '%s\n' "$W9X_VM_ORG" | LC_ALL=C grep -Eq '^[A-Za-z0-9_. -]{0,40}$'
}

w9x_vm_type_owner_text() {
    w95_text=$1
    while [ -n "$w95_text" ]; do
        w95_char=${w95_text%"${w95_text#?}"}
        w95_text=${w95_text#?}
        case "$w95_char" in
            [A-Z]) w95_scan="shift-$(printf '%s' "$w95_char" | tr A-Z a-z)" ;;
            [a-z0-9]) w95_scan=$w95_char ;;
            ' ') w95_scan=spc ;; '.') w95_scan=dot ;; '-') w95_scan=minus ;; '_') w95_scan=shift-minus ;;
            *) return 1 ;;
        esac
        w9x_vm_private_key "$w95_scan" || return 1
    done
}

w9x_vm_95_page_ready() {
    [ "$W9X_VM_PAGE" != "$w95_last_page" ] || return 1
    case "$W9X_VM_PAGE" in
        coa|coa-single) [ "$key_tries" = 0 ] && [ "${#key}" = 17 ] && [ "$written" -lt "$W9X_VM_KEY_MAX_MB" ] ;;
        owner) w9x_vm_owner_valid ;;
        recovery|welcome|directory|setup-type|hardware-list|components|computer-options|startup-disk|copy-ready|restart|reboot-confirm) return 0 ;;
        *) return 1 ;;
    esac
}

w9x_vm_95_input() {
    case "$W9X_VM_PAGE" in
        coa-single)
            key_on_screen=1
            w9x_vm_clear_edit || return 1
            w95_remaining=$key
            w95_group=0
            for w95_length in 5 7 5; do
                case "$w95_group" in
                    1) for w95_scan in minus shift-o shift-e shift-m minus; do
                           w9x_vm_private_key "$w95_scan" || return 1
                       done ;;
                    2) w9x_vm_private_key minus || return 1 ;;
                esac
                w95_count=0
                while [ "$w95_count" -lt "$w95_length" ]; do
                    w95_digit=${w95_remaining%"${w95_remaining#?}"}
                    w95_remaining=${w95_remaining#?}
                    w9x_vm_private_key "$w95_digit" || return 1
                    w95_count=$((w95_count + 1))
                done
                w95_group=$((w95_group + 1))
            done
            w95_remaining=''; w95_digit=''
            key_tries=$((key_tries + 1))
            w9x_vm_private_key ret || return 1
            ;;
        coa)
            key_on_screen=1
            w95_remaining=$key
            for w95_length in 5 7 5; do
                w9x_vm_clear_edit || return 1
                w95_count=0
                while [ "$w95_count" -lt "$w95_length" ]; do
                    w95_digit=${w95_remaining%"${w95_remaining#?}"}
                    w95_remaining=${w95_remaining#?}
                    w9x_vm_private_key "$w95_digit" || return 1
                    w95_count=$((w95_count + 1))
                done
            done
            w95_remaining=''; w95_digit=''
            key_tries=$((key_tries + 1))
            w9x_vm_private_key ret || return 1
            ;;
        owner)
            w9x_vm_owner_valid || return 1
            w9x_vm_clear_edit && w9x_vm_type_owner_text "$W9X_VM_OWNER" &&
                w9x_vm_private_key tab && w9x_vm_clear_edit && w9x_vm_type_owner_text "$W9X_VM_ORG" &&
                w9x_vm_private_key ret || return 1
            key_on_screen=0
            ;;
        startup-disk)
            w9x_vm_private_key down && w9x_vm_private_key ret || return 1
            key_on_screen=0
            ;;
        recovery|welcome|directory|setup-type|hardware-list|components|computer-options|copy-ready|restart|reboot-confirm)
            w9x_vm_private_key ret || return 1
            key_on_screen=0
            ;;
        *) return 1 ;;
    esac
    w95_last_page=$W9X_VM_PAGE
    printf '95 input: %s (values omitted)\n' "$W9X_VM_PAGE" >> "$W9X_VM_RUN/command.txt"
}
