/* USOS PCI IRQ routing test MBR (tools/tests/csmwrap/run_csmwrap_pciirq_qemu.py, assembled there
 * with zig cc + ld.lld into a flat binary at 0:7C00). Boots through CSMWrap's SeaBIOS and prints
 * to the QEMU debug console (port 0x402) what a Windows 9x PCI enumerator reads:
 *   " PIR <ah> <size> <bx> "         INT 1Ah AX=B10Eh (GET_IRQ_ROUTING_OPTIONS), 1 KiB buffer
 *   " R <16 bytes hex> "             every $PIR slot record returned
 *   " F <bus><devfn> <line><pin> "   every PCI function on buses 0-7 with Interrupt Pin != 0
 *   " ELCR <4d1><4d0> "
 *   " PCIIRQ-END "                   then out 0xF4 (isa-debug-exit) ends QEMU.
 * One sector, no disk reads. */
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
  /* INT 1Ah B10Eh: ES:DI -> {size, off, seg}, DS = F000h per PCI BIOS 2.1 */
  movw $1024,%es:rbuf
  movw $0x8000,%es:rbuf+2
  movw $0,%es:rbuf+4
  mov $rbuf,%di
  xor %bx,%bx
  push %ds
  mov $0xf000,%ax
  mov %ax,%ds
  mov $0xb10e,%ax
  int $0x1a
  pop %ds
  mov %bx,%bp
  mov $m_pir,%si
  call puts
  mov %ah,%al
  jnc 1f
  mov $0xee,%al
1: call hex8
  call sp
  mov rbuf,%ax
  call hex16
  call sp
  mov %bp,%ax
  call hex16
  call sp
  /* slot records */
  mov rbuf,%cx
  shr $4,%cx
  cmp $64,%cx
  jbe 2f
  mov $64,%cx
2: mov $0x8000,%si
3: jcxz 5f
  push %cx
  push %si
  mov $m_r,%si
  call puts
  pop %si
  mov $16,%cx
4: lodsb
  call hex8
  loop 4b
  call sp
  pop %cx
  dec %cx
  jmp 3b
5:
  /* PCI functions with a pin, buses 0-7 */
  xor %ebx,%ebx           /* BH = bus, BL = devfn */
6: mov $0x00,%cl
  call cfg32
  cmp $0xffff,%ax
  je 8f
  mov $0x3c,%cl
  call cfg32
  test %ah,%ah
  jz 8f
  push %ax
  mov $m_f,%si
  call puts
  mov %bx,%ax
  call hex16
  call sp
  pop %ax
  xchg %al,%ah
  call hex16
  call sp
8: inc %bl
  jnz 6b
  inc %bh
  cmp $8,%bh
  jb 6b
  mov $m_elcr,%si
  call puts
  mov $0x4d1,%dx
  in %dx,%al
  mov %al,%ah
  dec %dx
  in %dx,%al
  call hex16
  call sp
  mov $m_end,%si
  call puts
  mov $0xf4,%dx
  mov $0,%al
  out %al,%dx
  cli
9: hlt
  jmp 9b

/* EAX = config dword at bus BH, devfn BL, offset CL */
cfg32:
  mov %ebx,%eax
  and $0xffff,%eax
  shl $8,%eax
  or $0x80000000,%eax
  or %cl,%al
  mov $0xcf8,%dx
  out %eax,%dx
  mov $0xcfc,%dx
  in %dx,%eax
  ret
puts:
  push %dx
  mov $0x402,%dx
1: lodsb
  test %al,%al
  jz 2f
  out %al,%dx
  jmp 1b
2: pop %dx
  ret
sp:
  push %ax
  push %dx
  mov $' ',%al
  mov $0x402,%dx
  out %al,%dx
  pop %dx
  pop %ax
  ret
hex16:
  push %ax
  mov %ah,%al
  call hex8
  pop %ax
hex8:
  push %ax
  shr $4,%al
  call nib
  pop %ax
  push %ax
  call nib
  pop %ax
  ret
nib:
  push %dx
  and $0xf,%al
  add $'0',%al
  cmp $'9',%al
  jbe 1f
  add $7,%al
1: mov $0x402,%dx
  out %al,%dx
  pop %dx
  ret
m_pir:  .asciz " PIR "
m_r:    .asciz " R "
m_f:    .asciz " F "
m_elcr: .asciz " ELCR "
m_end:  .asciz " PCIIRQ-END "
rbuf = 0x7e00
.org 0x1b8
.org 0x1fe
  .byte 0x55, 0xaa
