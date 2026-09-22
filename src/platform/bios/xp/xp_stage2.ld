ENTRY(xp_stage2_start)
SECTIONS
{
    . = 0x8000;
    .text : { *(.text*) }
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) }
}
