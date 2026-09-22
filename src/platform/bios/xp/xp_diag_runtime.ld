ENTRY(xp_diag_runtime_start)
SECTIONS
{
    . = 0x1000;
    .text : SUBALIGN(1) { *(.text*) }
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
