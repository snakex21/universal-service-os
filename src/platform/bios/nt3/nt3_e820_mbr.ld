ENTRY(nt3_e820_mbr_start)
SECTIONS
{
    .text 0x7C00 : SUBALIGN(1) { *(.text*) }
    ASSERT(nt3_e820_mbr_start == 0x7C00, "NT3 E820 MBR entry must be 0x7C00")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
