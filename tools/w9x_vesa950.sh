# MIT vmdisp9x 119b compatibility derivative for SETUP 4.0.0.950 only.
# The published VESA Disable hangs inside CallVDD(0x81) on the tested RTM.
# R137 isolated that call; R141 skipped it and completed a VESA warm restart.
# Keep the published NE ABI. Never patch the shared vendor/payload original.
# Exact input/output digests make this fail closed for another driver version.
# See docs/win95-vesa950-unregister-2026-10-23.md for proof and limitations.

w9x_vesa950_prepare() (
    [ "${2:-}" = '4 0 0 950' ] || return 0
    directory=$1
    driver=$directory/VESAMINI.DRV
    notice=$directory/VMDISP9X.TXT
    candidate=$directory/VES950.TMP
    [ -f "$driver" ] && [ ! -L "$driver" ] && [ -f "$notice" ] || return 1
    before=2e661f2c17b5e7d6bcaa2c93cf3f79d38e70ab901850d7e5e3d26658aa697ddc
    after=3658d7c3c3314f50ac6f05a034109dd88993433b6d1b216f07297f96c66bdd67
    actual=$(sha256sum "$driver") || return 1
    actual=${actual%% *}
    [ "$actual" != "$after" ] || return 0
    [ "$actual" = "$before" ] && [ ! -e "$candidate" ] || return 1
    cp "$driver" "$candidate" || return 1
    trap 'rm -f "$candidate"' 0
    # File offset 7873 = code segment offset 0x19f3 + NE segment file offset.
    # FF 1E B2 07: CALL FAR [VDDEntryPoint]. Preserve its EAX/EBX wrapper.
    printf '\220\220\220\220' | dd of="$candidate" bs=1 seek=7873 conv=notrunc 2>/dev/null || return 1
    actual=$(sha256sum "$candidate") || return 1
    [ "${actual%% *}" = "$after" ] || return 1
    cat >> "$notice" <<'EOF' || return 1

USOS MODIFICATION, 2026-10-23, source SETUP 4.0.0.950 only:
VESAMINI.DRV is a four-byte derivative of the published MIT 119b binary.
Disable skips CallVDD(VDD_DRIVER_UNREGISTER=0x81), bytes FF1EB207 -> 90909090
at file offset7873. Source-level equivalent: omit that single CallVDD in
enable.c::Disable. All other bytes, NE tables and exports are unchanged.
Recipe: tools/w9x_vesa950.sh; original sources and MIT license remain bundled.
Input SHA256: 2e661f2c17b5e7d6bcaa2c93cf3f79d38e70ab901850d7e5e3d26658aa697ddc
Output SHA256: 3658d7c3c3314f50ac6f05a034109dd88993433b6d1b216f07297f96c66bdd67
QEMU RTM shutdown/restart compatibility workaround; X470 and other releases
require independent runtime validation. See the dated review document.
EOF
    mv "$candidate" "$driver" || return 1
)
