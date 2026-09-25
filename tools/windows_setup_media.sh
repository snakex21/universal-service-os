# Sourced by extract.sh (and its tests): recognise Windows Setup media on WORK
# and map a catalog system id to its DATA\Drivers folder (docs/drivers.md).

# First sources/install.wim|esd|swm below $1 (case-insensitive), or nothing.
# Windows Setup accepts all three; .swm is the first part of a split image.
windows_install_image() {
    find "$1" -type f 2>/dev/null | awk -v root="$1" '
        { rel = tolower(substr($0, length(root) + 1)) }
        rel ~ /^\/sources\/install\.(wim|esd|swm)$/ { print; exit }'
}

# Success when $1 has sources/setup.exe (case-insensitive).
windows_setup_exe() {
    find "$1" -type f 2>/dev/null | awk -v root="$1" '
        tolower(substr($0, length(root) + 1)) == "/sources/setup.exe" { found = 1; exit }
        END { exit found ? 0 : 1 }'
}

# DATA\Drivers\<folder> for catalog id $1; without an id, the folder of the
# selected image path $2 (requests written before selected_system existed).
# Vista and XP folders exist but are not wired (docs/drivers.md).
user_drivers_os() {
    case "$1" in
        windows-7) printf 'Windows 7' ;;
        windows-8) printf 'Windows 8' ;;
        windows-8-1) printf 'Windows 8.1' ;;
        windows-10) printf 'Windows 10' ;;
        windows-11) printf 'Windows 11' ;;
        # Windows Server (src/catalog/windows_server.zig); 2008 like Vista is not wired.
        windows-server-2025) printf 'Windows Server 2025' ;;
        windows-server-2022) printf 'Windows Server 2022' ;;
        windows-server-2019) printf 'Windows Server 2019' ;;
        windows-server-2016) printf 'Windows Server 2016' ;;
        windows-server-2012-r2) printf 'Windows Server 2012 R2' ;;
        windows-server-2012) printf 'Windows Server 2012' ;;
        windows-server-2008-r2) printf 'Windows Server 2008 R2' ;;
        '')
            case "$2" in
                'Systems/Windows/Windows 7/Images/'*) printf 'Windows 7' ;;
                'Systems/Windows/Windows 8/Images/'*) printf 'Windows 8' ;;
                'Systems/Windows/Windows 8.1/Images/'*) printf 'Windows 8.1' ;;
                'Systems/Windows/Windows 10/Images/'*) printf 'Windows 10' ;;
                'Systems/Windows/Windows 11/Images/'*) printf 'Windows 11' ;;
            esac ;;
    esac
    return 0
}
