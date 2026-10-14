/* USOS APM power-off test MBR (tools/tests/csmwrap/run_csmwrap_apmoff_qemu.py, assembled
 * there with zig cc + ld.lld into a flat binary at 0:7C00).
 * mode byte at 0x1EE (unused 4th partition entry): 0 = real-mode INT 15h 5307h, 1 = 32-bit protected-mode
 * interface (5303h) with paging on, 2 = 16-bit protected-mode interface
 * (5302h). Messages go to the QEMU debug console (port 0x402). */
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
  mov $m_start,%si
  call print16
  mov $0x5300,%ax
  xor %bx,%bx
  int $0x15
  jc fail
  cmp $0x504d,%bx
  jne fail
  mov mode,%al
  cmp $1,%al
  je pm32
  cmp $2,%al
  je pm16
  /* real mode */
  mov $0x5301,%ax
  xor %bx,%bx
  int $0x15
  mov $0x530e,%ax
  xor %bx,%bx
  mov $0x0102,%cx
  int $0x15
  mov $0x5307,%ax
  mov $1,%bx
  mov $3,%cx
  int $0x15
  mov $m_ret,%si
  call print16
  jmp halt16
pm16:
  mov $0x5302,%ax
  xor %bx,%bx
  int $0x15
  jc fail
  mov %bx,ptr16
  call setbase20          /* code16 base AX -> 0x20 */
  mov %cx,%ax
  mov $gdt+0x28,%di
  call setbase
  jmp enter_pm
pm32:
  mov $0x5303,%ax
  xor %bx,%bx
  int $0x15
  jc fail
  mov %ebx,ptr32
  mov $gdt+0x18,%di       /* code32 base AX */
  call setbase
  mov %cx,%ax             /* code16 base CX */
  call setbase20
  mov %dx,%ax             /* data base DX */
  mov $gdt+0x28,%di
  call setbase
enter_pm:
  lgdt gdtr
  mov %cr0,%eax
  or $1,%eax
  mov %eax,%cr0
  ljmp $0x08,$pm
setbase20:
  mov $gdt+0x20,%di
setbase:                  /* descriptor at DI gets base AX*16 */
  push %eax
  movzwl %ax,%eax
  shl $4,%eax
  mov %ax,2(%di)
  shr $16,%eax
  mov %al,4(%di)
  pop %eax
  ret
fail:
  mov $m_fail,%si
  call print16
halt16:
  hlt
  jmp halt16
print16:
  mov $0x402,%dx
1: lodsb
  test %al,%al
  jz 2f
  out %al,%dx
  jmp 1b
2: ret

.code32
pm:
  mov $0x10,%ax
  mov %ax,%ds
  mov %ax,%es
  mov %ax,%ss
  mov %ax,%fs
  mov %ax,%gs
  mov $0x9000,%edi        /* identity map 0-4 MiB with one PSE page, paging on */
  xor %eax,%eax
  mov $1024,%ecx
  rep stosl
  movl $0x83,0x9000
  mov %cr4,%eax
  or $0x10,%eax
  mov %eax,%cr4
  mov $0x9000,%eax
  mov %eax,%cr3
  mov %cr0,%eax
  or $0x80000000,%eax
  mov %eax,%cr0
  mov $0x5307,%eax
  mov $1,%ebx
  mov $3,%ecx
  cmpb $2,mode
  je 3f
  lcall *ptr32
  jmp 4f
3: lcallw *ptr16
4: mov $m_ret,%esi
  mov $0x402,%dx
5: lodsb
  test %al,%al
  jz 6f
  out %al,%dx
  jmp 5b
6: hlt
  jmp 6b

.p2align 3
gdt:
  .quad 0
  .quad 0x00CF9A000000FFFF
  .quad 0x00CF92000000FFFF
  .quad 0x00409A000000FFFF
  .quad 0x00009A000000FFFF
  .quad 0x000092000000FFFF
gdtr:
  .word 6*8-1
  .long gdt
ptr32:
  .long 0
  .word 0x18
ptr16:
  .word 0
  .word 0x20
m_start: .asciz " APMT-S "
m_ret:   .asciz " APMT-RET "
m_fail:  .asciz " APMT-NO "
.org 0x1ee
mode: .byte 0
