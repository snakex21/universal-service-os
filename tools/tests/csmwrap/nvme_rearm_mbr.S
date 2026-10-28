/* USOS NVMe re-arm test MBR (tools/tests/csmwrap/run_csmwrap_nvme_rearm_qemu.py, assembled there
 * with zig cc + ld.lld into a flat binary at 0:7C00). Boots from QEMU NVMe through CSMWrap's
 * SeaBIOS and replays what the Windows 9x miniport usosnvme.mpd does to the controller:
 *   1. INT 13h read LBA 1 (signature) through SeaBIOS's queues          -> " NVRA-R1 "
 *   2. like usosnvme's init: CC.EN = 0, own admin queue at 2000:0 / 2100:0, CC.EN = 1
 *      -> an INT 13h read must be refused at once (a live OS driver)     -> " NVRA-REF "
 *   3. like usosnvme's exit to real mode: CC.SHN normal, wait SHST, CC.EN = 0
 *      -> INT 13h read LBA 1 must work again (the BIOS re-arm)          -> " NVRA-R2 "
 *   4. INT 13h write of the LBA 1 copy to LBA 4 (FUA after a re-arm)        -> " NVRA-W "
 *   5. APM 5300h/5301h/5307h power-off (real mode, like WIN.COM /z).
 * A failed step prints " NVRA-F<n> " and still powers off. Port 0x402 = QEMU debugcon.
 * Layout: sector 0 = loader + helpers + partition table, LBA 1-2 = stage 2 (starts with "NVRA",
 * loaded by the first INT 13h read). The INT 13h write goes to LBA 4.
 * MMIO through FS in unreal mode (set again before each use; SeaBIOS's 32-bit calls reload FS). */
.code16
.globl _start
_start:
  cli
  xor %ax,%ax
  mov %ax,%ds
  mov %ax,%es
  mov %ax,%ss
  mov $0x7c00,%sp
  ljmp $0,$go
go:
  sti
  movw $2,dap+2           /* stage 2: LBA 1-2 -> 0:7E00 (the first INT 13h read) */
  movw $0x7e00,dap+4
  mov $0x4200,%ax
  call i13
  jc 1f
  cmpl $0x4152564e,stage2
  je stage2+4
1: mov $'0',%bl
  jmp fail
i13:
  mov $dap,%si
  mov $0x80,%dl
  int $0x13
  ret
fail:
  mov %bl,m_fail+7
  mov $m_fail,%si
  call print16
  jmp apmoff
print16:
  mov $0x402,%dx
1: lodsb
  test %al,%al
  jz 2f
  out %al,%dx
  jmp 1b
2: ret
dap:
  .byte 16, 0
  .word 1, 0x8000, 0
  .quad 1
m_fail:  .asciz " NVRA-F? "
.org 0x1fe
  .byte 0x55, 0xaa
stage2:
  .ascii "NVRA"
  movw $1,dap+2
  mov $m_start,%si
  call print16
  mov $'1',%bl
  call rd1                /* 1: baseline read */
  jc fail
  mov $m_r1,%si
  call print16
  mov $'2',%bl
  call findnvme           /* EBX = BAR 0 */
  jc fail
  mov %ebx,bar
  call unreal
  mov bar,%ebx
  xorl %eax,%eax          /* 2: disable, own admin queue, enable */
  mov %eax,%fs:0x14(%ebx)
  mov $1,%edx
  xor %edi,%edi
  call waitcsts
  mov $'3',%al
  jc failal
  movl $0x000f000f,%fs:0x24(%ebx)
  movl $0x20000,%fs:0x28(%ebx)
  movl $0,%fs:0x2c(%ebx)
  movl $0x21000,%fs:0x30(%ebx)
  movl $0,%fs:0x34(%ebx)
  movl $0x00460001,%fs:0x14(%ebx)
  mov $1,%edx
  mov $1,%edi
  call waitcsts
  mov $'4',%al
  jc failal
  mov $'5',%bl
  call rd1                /* must be refused */
  jnc fail
  mov $m_ref,%si
  call print16
  call unreal             /* 3: normal shutdown, then disable */
  mov bar,%ebx
  mov %fs:0x14(%ebx),%eax
  or $0x4000,%eax
  mov %eax,%fs:0x14(%ebx)
  mov $0x0c,%edx
  mov $0x08,%edi
  call waitcsts
  mov $'6',%al
  jc failal
  mov %fs:0x14(%ebx),%eax
  and $0xfffffffe,%eax
  mov %eax,%fs:0x14(%ebx)
  mov $1,%edx
  xor %edi,%edi
  call waitcsts
  mov $'7',%al
  jc failal
  mov $'8',%bl
  call rd1                /* re-armed read */
  jc fail
  mov $m_r2,%si
  call print16
  movw $0x9000,dap+4      /* 4: write the LBA 1 copy just read to LBA 4 */
  movw $0,dap+6
  movb $4,dap+8
  mov $0x4300,%ax
  mov $'9',%bl
  call i13
  jc fail
  mov $m_w,%si
  call print16
  jmp apmoff
failal:
  mov %al,%bl
  jmp fail
apmoff:                   /* 5 */
  mov $0x5300,%ax
  xor %bx,%bx
  int $0x15
  mov $0x5301,%ax
  xor %bx,%bx
  int $0x15
  mov $0x5307,%ax
  mov $1,%bx
  mov $3,%cx
  int $0x15
  mov $m_ret,%si
  call print16
halt16:
  hlt
  jmp halt16

/* INT 13h AH=42h LBA 1 -> 0:8000, CF on error or a wrong signature */
rd1:
  movw $1,dap+2           /* a failed call leaves the transferred count (0) in the DAP */
  movw $0x9000,dap+4
  movw $0,dap+6
  movb $1,dap+8
  movl $0,0x9000
  mov $0x4200,%ax
  call i13
  jc 1f
  cmpl $0x4152564e,0x9000   /* "NVRA" */
  je 1f
  stc
1: ret
/* bus 0: first function with class 010802 -> EBX = BAR 0 (below 4 GiB) */
findnvme:
  mov $0x80000008,%ecx
1: mov %ecx,%eax
  mov $0xcf8,%dx
  out %eax,%dx
  mov $0xcfc,%dl
  in %dx,%eax
  shr $8,%eax
  cmp $0x010802,%eax
  je 2f
  add $0x100,%ecx
  cmp $0x80010008,%ecx
  jb 1b
  stc
  ret
2: lea 8(%ecx),%eax       /* 0x10 = BAR 0 */
  mov $0xcf8,%dx
  out %eax,%dx
  mov $0xcfc,%dl
  in %dx,%eax
  and $0xfffffff0,%eax
  mov %eax,%ebx
  clc
  ret

unreal:
  cli
  lgdt gdtr
  mov %cr0,%eax
  or $1,%al
  mov %eax,%cr0
  jmp 1f
1: mov $8,%ax
  mov %ax,%fs
  mov %cr0,%eax
  and $0xfe,%al
  mov %eax,%cr0
  jmp 2f
2: xor %ax,%ax
  mov %ax,%fs
  sti
  ret

/* (CSTS & EDX) == EDI, bounded; CF on timeout */
waitcsts:
  mov $0x400000,%ecx
1: mov %fs:0x1c(%ebx),%eax
  and %edx,%eax
  cmp %edi,%eax
  je 2f
  dec %ecx
  jnz 1b
  stc
  ret
2: clc
  ret

.p2align 3
gdt:
  .quad 0
  .quad 0x00CF92000000FFFF
gdtr:
  .word 2*8-1
  .long gdt
bar:     .long 0
m_start: .asciz " NVRA-S "
m_r1:    .asciz " NVRA-R1 "
m_ref:   .asciz " NVRA-REF "
m_r2:    .asciz " NVRA-R2 "
m_w:     .asciz " NVRA-W "
m_ret:   .asciz " NVRA-RET "
.org 0x600
