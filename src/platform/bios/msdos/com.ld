/* DOS .COM image: one flat segment starting at offset 0100h (after the PSP). */
ENTRY(_start)
SECTIONS
{
    . = 0x100;
    .text : { *(.text) *(.rodata*) *(.data) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
