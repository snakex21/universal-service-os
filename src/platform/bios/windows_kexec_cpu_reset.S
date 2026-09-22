/* Restore BIOS-like CPU control state before entering wimboot from Linux kexec.
 *
 * A 64-bit Linux kernel can leave EFER.LME/NXE and CR4 paging/OS state set
 * even after kexec has returned the processor to real mode.  That state is
 * harmless for the wimboot setup stub itself while paging is off, but a BIOS
 * bootmgr expects to own the transition back into paged protected/long mode.
 * If EFER.LME is still set, enabling PAE+paging can enter IA-32e unexpectedly.
 *
 * This routine runs with paging disabled, interrupts disabled and CS already
 * normalized by wimboot's real-mode setup entry.  It preserves all general
 * registers and returns in real mode.  It is used only on x86-64-capable
 * Windows BIOS requests after micro-Linux/kexec.
 */
.intel_syntax noprefix
.section .rodata.windows_kexec_cpu_reset,"a",@progbits
.code16
.global windows_kexec_cpu_reset_start
windows_kexec_cpu_reset_start:
    pushad

    /* BIOS boot starts with paging-related CR4 state clear. */
    xor eax, eax
    mov cr4, eax
    mov cr3, eax

    /* EFER is available on every CPU accepted by the x64 Windows path.
     * LMA is already clear because paging is off; clear the writable EFER
     * state left by the 64-bit Linux kernel, including LME and NXE. */
    mov ecx, 0xc0000080
    xor eax, eax
    xor edx, edx
    wrmsr

    /* Linux may leave CR0.TS set during final CPU shutdown. */
    clts

    popad
    .byte 0xc3 /* 16-bit RET */

.org 0x40
.code32
