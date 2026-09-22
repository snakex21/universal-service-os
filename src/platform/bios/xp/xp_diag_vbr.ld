ENTRY(xp_diag_vbr_helper)
SECTIONS
{
    .text 0x7D7B : SUBALIGN(1) { *(.text*) }
    ASSERT(xp_diag_vbr_helper == 0x7D7B, "XP NT52 diagnostic VBR helper must be linked at 0x7D7B")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
