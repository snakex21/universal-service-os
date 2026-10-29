ENTRY(nt3_e820_mbr_start)
SECTIONS
{
    .text 0x7C00 : SUBALIGN(1) { *(.text*) }
    ASSERT(nt3_e820_mbr_start == 0x7C00, "NT3 E820 MBR entry must be 0x7C00")
    /* Resident hooks (sector 1), run at offset 0 of their own segment. */
    .hook 0 : AT(0x10000) SUBALIGN(1) { *(.hook*) }
    ASSERT(hook_start == 0, "NT3 MBR hook sector must start at 0")
    /* Bus-master quiesce (sector 3), called at 0000:7C00; position
       independent, linked apart from .text and .hook. */
    .quiesce 0x1000 : AT(0x20000) SUBALIGN(1) { *(.quiesce*) }
    ASSERT(SIZEOF(.quiesce) == 512, "NT3 MBR quiesce sector must be 512 bytes")
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) *(.data*) *(.bss*) }
}
