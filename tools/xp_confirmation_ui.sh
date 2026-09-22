. /usr/lib/usos/xp_menu_ui.sh
usos_xp_confirm() {
    confirm_info=$1
    confirm_title=$2
    confirm_menu=/run/xp-confirm-menu.state
    {
        printf 'title=%s\nsubtitle=Review the selected disk and confirm the operation.\nselected=1\n' "$confirm_title"
        printf 'item=Confirm|%s\nitem=Cancel|Return to disk selection\n' "${3:-Prepare Windows XP installation}"
        usos_xp_menu_info "$confirm_info"
    } > "$confirm_menu"
    usos_xp_menu "$confirm_menu" || return 1
    [ "$USOS_MENU_RESULT" = 1 ]
}
