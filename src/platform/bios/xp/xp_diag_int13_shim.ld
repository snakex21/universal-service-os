ENTRY(xp_diag_int13_shim_install)
SECTIONS
{
    . = 0x1200;
    .text : SUBALIGN(1) { *(.text*) }
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
