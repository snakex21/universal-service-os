# Pure beta RTC argument policy. No date/hwclock calls; never changes host RTC.
# Off/default preserves the existing VM clock. Unknown auto builds fail closed.
usos_beta_clock_applies() {
    case "${1:-}" in
        windows-whistler|windows-neptune|windows-longhorn|windows-7-beta|windows-millennium|windows-nashville|windows-chicago|windows-memphis|windows-nt-3-beta|windows-nt-4-beta|windows-2000-beta|windows-cairo) return 0 ;;
    esac
    return 1
}
usos_beta_clock_date() {
    if ! usos_beta_clock_applies "${2:-}"; then
        case "${1:-}" in ''|off) ;; *) printf '[BETA_CLOCK] ignored setting for non-beta system=%s\n' "${2:-unknown}" >&2 ;; esac
        return 0
    fi
    case "${1:-}" in ''|off) return 0 ;; auto)
        case "${2:-}:${3:-}" in
            windows-whistler:2542) printf '%s\n' 2001-08-15 ;;
            windows-neptune:5111) printf '%s\n' 1999-12-11 ;;
            windows-longhorn:5048) printf '%s\n' 2005-05-01 ;;
            windows-7-beta:7000) printf '%s\n' 2009-01-15 ;;
            windows-millennium:2525) printf '%s\n' 2000-05-15 ;;
            windows-nashville:999) printf '%s\n' 1995-12-01 ;;
            *) printf '[BETA_CLOCK] STOP unknown auto build\n' >&2; return 1 ;;
        esac
        return 0 ;;
    esac
    printf '%s\n' "$1" | awk '
      /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
        y=substr($0,1,4)+0;m=substr($0,6,2)+0;d=substr($0,9,2)+0
        split("31 28 31 30 31 30 31 31 30 31 30 31",days," ")
        if(y%4==0 && (y%100!=0 || y%400==0)) days[2]=29
        if(y>=1980 && y<=2099 && m>=1 && m<=12 && d>=1 && d<=days[m]) {print;ok=1}
      } END {exit !ok}'
}
usos_beta_clock_rtc() {
    beta_date=$(usos_beta_clock_date "${1:-}" "${2:-}" "${3:-0}") || return 1
    if [ -z "$beta_date" ]; then printf '%s\n' base=localtime
    else printf 'base=%sT12:00:00\n' "$beta_date"; fi
}
# Rendered answer comments are own metadata, never Setup directives.
usos_beta_clock_from_answer() {
    awk '/^;USOS-BETA-CLOCK=/ {sub(/^[^=]*=/, "");sub(/\r$/, ""); print; n++} END {if(n>1)exit 1}' "$1"
}
