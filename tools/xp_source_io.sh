# Local-source I/O shared by the FAT32 and mounted NTFS preparation paths.
# The mtools-compatible functions are scoped to the sourcing preparation shell.
if [ -n "${XP_TARGET_ROOT:-}" ]; then
    xp_source_path() {
        case "$1" in
            ::/*)
                relative=${1#::/}
                case "/$relative/" in */../*|*/./*) return 1 ;; esac
                printf '%s/%s\n' "$XP_TARGET_ROOT" "$relative"
                ;;
            *) printf '%s\n' "$1" ;;
        esac
    }
    mcopy() (
        while [ "$#" -gt 0 ]; do
            case "$1" in -i) shift 2 ;; -s|-o) shift ;; *) break ;; esac
        done
        [ "$#" -ge 2 ] || return 1
        for argument do destination=$argument; done
        destination=$(xp_source_path "$destination") || return 1
        while [ "$#" -gt 1 ]; do
            source=$(xp_source_path "$1") || return 1
            cp -R "$source" "$destination" || return 1
            shift
        done
    )
    mmd() (
        [ "$1" != -i ] || shift 2
        [ "$#" = 1 ] || return 1
        destination=$(xp_source_path "$1") || return 1
        mkdir "$destination"
    )
    mdir() (
        [ "$1" != -i ] || shift 2
        [ "$#" = 1 ] || return 1
        destination=$(xp_source_path "$1") || return 1
        [ -e "$destination" ]
    )
fi
