ENTRY(xp_vbr_start)
SECTIONS
{
    /* FAT32 BPB/EBPB occupies bytes 0..89. mkfs.fat emits EB 58 90,
     * which transfers control to physical 0000:7C5A. Force the input
     * section alignment down to one byte so every absolute symbol in the
     * VBR is linked for exactly the address where the raw code is installed.
     */
    .text 0x7C5A : SUBALIGN(1) { *(.text*) }
    ASSERT(xp_vbr_start == 0x7C5A, "XP VBR entry must be linked at physical 0x7C5A")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) }
}
