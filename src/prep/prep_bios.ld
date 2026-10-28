/* Separate target, identical low-memory thunk placement to Legacy Core. */
SECTIONS
{
    . = 0x00020000;
    .early : { *(.text.early) }
    ASSERT(SIZEOF(.early) < 0x10000, "BIOS thunk exceeds first 64KiB")
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss (NOLOAD) : {
        __prep_bss_start = .;
        *(.bss*) *(COMMON)
        __prep_bss_end = .;
    }
    ASSERT(SIZEOF(.bss) < 0x10000, "Prep BIOS BSS exceeds64KiB")
    ASSERT(__prep_bss_end <= 0x00060000, "Prep BIOS BSS overlaps low-memory stack reserve")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.debug*) }
}
