SECTIONS
{
    . = 0x0000;
    .text : { *(.text*) }
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) *(.rodata*) }
}
