ENTRY(xp_diag_prelude_start)
SECTIONS
{
    . = 0x8000;
    .text : SUBALIGN(1) { *(.text*) }
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
