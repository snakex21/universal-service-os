SECTIONS
{
    . = 0x7C00;
    .text : { *(.text*) }
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
