#!/bin/sh
# USOS: the answer file the boot menu rendered from an answer profile
# (docs/answer-profiles.md, src/flow/answer/plan_file.zig).
#
#   usos_answer_plan_value PLAN KEY
#       Prints [answer] KEY= of PLAN (usos-plan.ini).
#   usos_answer_plan_take PLAN FORMAT OUT
#       PLAN = /mnt/esp/EFI/USOS/answer/usos-plan.ini. Checks source=profile,
#       format=FORMAT and the fixed file name next to PLAN, copies that file to
#       OUT (verified with cmp) and deletes it from the ESP, because it may
#       hold a product key or a password. The plan itself (no secrets) stays
#       for diagnostics. Returns 1 with a message on stdout; nothing printed
#       ever contains the file's values.

usos_answer_plan_value() {
    awk -v wanted="$2" '
        { sub(/\r$/, "") }
        /^\[/ { section = tolower($0); next }
        section == "[answer]" { eq = index($0, "="); if (eq && tolower(substr($0, 1, eq - 1)) == wanted) { print substr($0, eq + 1); exit } }
    ' "$1"
}

usos_answer_plan_take() {
    _ap_plan=$1
    _ap_format=$2
    _ap_out=$3
    [ -f "$_ap_plan" ] || { printf '[ANSWER] STOP: answer plan is missing\n'; return 1; }
    [ "$(usos_answer_plan_value "$_ap_plan" source)" = profile ] || { printf '[ANSWER] STOP: answer plan has no profile\n'; return 1; }
    [ "$(usos_answer_plan_value "$_ap_plan" format)" = "$_ap_format" ] || { printf '[ANSWER] STOP: answer plan format is not %s\n' "$_ap_format"; return 1; }
    case $_ap_format in
        autounattend_xml) _ap_name=autounattend.xml ;;
        nt5_settings) _ap_name=nt5-settings.ini ;;
        *) printf '[ANSWER] STOP: unknown answer format\n'; return 1 ;;
    esac
    [ "$(usos_answer_plan_value "$_ap_plan" file)" = "EFI/USOS/answer/$_ap_name" ] || { printf '[ANSWER] STOP: unexpected answer file in the plan\n'; return 1; }
    _ap_file=${_ap_plan%/*}/$_ap_name
    [ -f "$_ap_file" ] || { printf '[ANSWER] STOP: rendered answer file is missing\n'; return 1; }
    mkdir -p "${_ap_out%/*}" || return 1
    cp -f "$_ap_file" "$_ap_out" && cmp -s "$_ap_file" "$_ap_out" || { rm -f "$_ap_out"; printf '[ANSWER] STOP: cannot copy the rendered answer file\n'; return 1; }
    rm -f "$_ap_file"
    sync
    printf '[ANSWER] profile "%s" format=%s arch=%s key=%s bytes=%s\n' \
        "$(usos_answer_plan_value "$_ap_plan" name | tr -cd 'A-Za-z0-9 ._-')" "$_ap_format" \
        "$(usos_answer_plan_value "$_ap_plan" arch)" "$(usos_answer_plan_value "$_ap_plan" key)" "$(wc -c < "$_ap_out" | tr -d ' ')"
    return 0
}
