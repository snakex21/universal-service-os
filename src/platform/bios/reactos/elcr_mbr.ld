ENTRY(elcr_mbr_start)
SECTIONS
{
    .text 0x7C00 : SUBALIGN(1) { *(.text*) }
    ASSERT(elcr_mbr_start == 0x7C00, "ELCR MBR entry must be 0x7C00")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
