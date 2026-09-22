ENTRY(xp_diag_stage2_dispatch)
SECTIONS
{
    .text 0x8148 : SUBALIGN(1) { *(.text*) }
    ASSERT(xp_diag_stage2_dispatch == 0x8148, "XP NT52 diagnostic stage2 helper must be linked at 0x8148")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
