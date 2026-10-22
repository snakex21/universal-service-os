#!/bin/sh
# Experimental XP (and Server 2003 x86 SP2: the same bundle format, built by
# tools/xp_driver_overlay.py on the system's own StorPort/ACPI). Source
# preflight runs BEFORE the disk-reset dialog.

# Service level of the Setup source (RTM, SP1, SP2, SP3, unknown) from the disc
# root markers, the same markers Setup itself checks. RTM, SP1 and SP2 share the
# 5.1.2600 setup build, so only these files tell them apart.
usos_xp_media_service_pack() {
    sp_root=${1:-}
    for sp_marker in WIN51IP.SP3 WIN51IP.SP2 WIN51IP.SP1; do
        sp_lower=$(printf '%s' "$sp_marker" | tr 'A-Z' 'a-z')
        for sp_name in "$sp_marker" "$sp_lower"; do
            [ -f "$sp_root/$sp_name" ] || continue
            printf '%s\n' "${sp_marker#WIN51IP.}"
            return 0
        done
    done
    # An XP disc without a service-pack marker is the RTM build.
    if [ -f "$sp_root/WIN51IP" ] || [ -f "$sp_root/win51ip" ]; then
        printf 'RTM\n'
        return 0
    fi
    printf 'unknown\n'
}

usos_xp_driver_preflight() {
    if [ "${NT5_SYSTEM:-windows-xp}" = windows-server-2003 ]; then
        ls "$SOURCE_ROOT"/WIN51I?.SP2 >/dev/null 2>&1 || { echo '[XP_DRIVERS] STOP: this driver set requires Windows Server 2003 SP2'; return 1; }
    else
    [ -f "$SOURCE_ROOT/WIN51IP.SP3" ] || { printf '[XP_DRIVERS] STOP: this driver set requires XP Professional SP3 (media: %s)\n' "$(usos_xp_media_service_pack "$SOURCE_ROOT")"; return 1; }
    fi
    XP_DRIVER_BUNDLE=''
    for bundle in /usr/lib/usos/xp-drivers/*; do
        [ -f "$bundle/source.sha256" ] || continue
        if (cd "$SOURCE_ROOT" && sha256sum -c "$bundle/source.sha256" >/dev/null 2>&1); then
            [ -z "$XP_DRIVER_BUNDLE" ] || { echo '[XP_DRIVERS] STOP: ambiguous overlay'; return 1; }
            XP_DRIVER_BUNDLE=$bundle
        fi
    done
    [ -n "$XP_DRIVER_BUNDLE" ] || { echo '[XP_DRIVERS] STOP: ISO differs from the prepared driver package'; return 1; }
    (cd "$XP_DRIVER_BUNDLE" && sha256sum -c payload.sha256) || return 1
    export XP_DRIVER_BUNDLE
    printf '[XP_DRIVERS] PREFLIGHT PASS package=%s ACPI+SATA+USB3+KMDF; before target changes\n' "${XP_DRIVER_BUNDLE##*/}"
}

usos_xp_driver_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${XP_DRIVER_BUNDLE:?}" "${SOURCE_ROOT:?}"
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/I386"
    [ -f "$bt/TXTSETUP.SIF" ] && [ -f "$ls/TXTSETUP.SIF" ]
    (cd "$SOURCE_ROOT" && sha256sum -c "$XP_DRIVER_BUNDLE/source.sha256" >/dev/null)
    (cd "$XP_DRIVER_BUNDLE" && sha256sum -c payload.sha256 >/dev/null)
    # Remove only alternative spellings/compressed forms of selected files.
    # ntfs3 is case-sensitive; do not leave both an old SYS and a new SY_.
    while IFS= read -r name; do
        case "$name" in ''|*[!A-Z0-9_.]*) echo '[XP_DRIVERS] Invalid payload name'; exit 1 ;; esac
        for folder in "$bt" "$ls"; do
            find "$folder" -maxdepth 1 -type f \( -iname "$name" -o -iname "${name%?}_" \) -exec rm -f '{}' \;
        done
    done < "$XP_DRIVER_BUNDLE/replace-names.txt"
    for src in "$XP_DRIVER_BUNDLE"/I386/*; do
        name=${src##*/}
        for folder in "$ls" "$bt"; do
            # SP3.CAB is the installed system's source cache, not a boot file.
            # (SP2.CAB for Server 2003.)
            case "$folder:$name" in "$bt":SP3.CAB|"$bt":SP2.CAB) continue ;; esac
            find "$folder" -maxdepth 1 -type f -iname "$name" -exec rm -f '{}' \;
            cp "$src" "$folder/$name"
            cmp -s "$src" "$folder/$name"
        done
    done
    sif="$XP_DRIVER_BUNDLE/I386/TXTSETUP.SIF"
    # NVMe target (docs/nvme-nt-2026-10-11.md): the bundle's NVME/ set
    # (TXTSETUP.SIF, DOSNET.INF, HIVESYS.INF, SETUPREG.HIV with USOS's own
    # usosnvme ScsiPort miniport) replaces the base set; USOSNVME.SY_/.IN_
    # are already in both folders. A SATA/AHCI target keeps the base set.
    case "${TARGET_DEVICE:-}" in
    /dev/nvme*)
        [ -f "$XP_DRIVER_BUNDLE/nvme.sha256" ] || { echo '[XP_DRIVERS] STOP: the target is NVMe but this driver package has no NVMe driver (usosnvme); rebuild the package'; exit 1; }
        (cd "$XP_DRIVER_BUNDLE" && sha256sum -c nvme.sha256 >/dev/null)
        for src in "$XP_DRIVER_BUNDLE"/NVME/*; do
            name=${src##*/}
            for folder in "$ls" "$bt"; do
                find "$folder" -maxdepth 1 -type f -iname "$name" -exec rm -f '{}' \;
                cp "$src" "$folder/$name"
                cmp -s "$src" "$folder/$name"
            done
        done
        for name in USOSNVME.SY_ USOSNVME.IN_; do
            [ -f "$ls/$name" ] && [ -f "$bt/$name" ] || { echo "[XP_DRIVERS] STOP: $name missing from the boot/local source"; exit 1; }
        done
        sif="$XP_DRIVER_BUNDLE/NVME/TXTSETUP.SIF"
        printf '[XP_DRIVERS] NVME PASS target=%s usosnvme (TXTSETUP/DOSNET/HIVESYS/SETUPREG NVMe set)\n' "$TARGET_DEVICE"
        ;;
    esac
    cp "$sif" "$XP_TARGET_ROOT/TXTSETUP.SIF"
    cmp -s "$sif" "$XP_TARGET_ROOT/TXTSETUP.SIF"
    mkdir -p "$XP_TARGET_ROOT/USOS/XP"
    cp "$XP_DRIVER_BUNDLE/manifest.json" "$XP_TARGET_ROOT/USOS/XP/drivers-manifest.json"
    sync
    printf '[XP_DRIVERS] APPLIED PASS boot-source+local-source+setup-hive+SP3-cache verified\n'
)

if [ "${1:-}" = apply ]; then usos_xp_driver_apply; fi
