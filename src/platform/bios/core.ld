SECTIONS
{
    . = 0x00020000;
    .early : { *(.text.early) }
    ASSERT(SIZEOF(.early) < 0x10000, "Legacy BIOS thunk must remain within first 64 KiB of Core")
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss (NOLOAD) : { *(.bss*) *(COMMON) }
    ASSERT(SIZEOF(.bss) == 0, "Legacy Core must not depend on zero-initialized BSS")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.debug*) }
}
