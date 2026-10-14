/* One flat Windows 1.0x driver segment starting at offset 0 (the NE file
 * around it is written by tools/build_win3_usb_keyboard.py). */
ENTRY(seg_start)
SECTIONS
{
    . = 0;
    .text : { *(.text) *(.rodata*) *(.data) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
