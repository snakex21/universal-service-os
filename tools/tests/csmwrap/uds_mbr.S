/* USOS USB disk service (UDS) protocol test MBR, CSMWrap 3.1.2-usos16 patch 0021
 * (tools/tests/csmwrap/run_csmwrap_uds_qemu.py, assembled there with zig cc + ld.lld into a
 * flat binary at 0:7C00). Boots from QEMU NVMe through CSMWrap's SeaBIOS and drives channel 1
 * of the helper core from real mode the way USOSUSB.MPD does from ring 0: a request block in
 * low memory (1000:0000), data buffers below 640 KiB, doorbell / done in the F-segment mailbox.
 * Markers on the QEMU debug console (port 0x402):
 *   UDS-S        start                     UDS-CH       "CSMPPrxy" + channel magic "UDS1"
 *   UDS-ENUM     entry 0 present, gen 1; then UDS-OWNED (stick has a BIOS number: never probed,
 *                SCSI must give OWNED, test ends) or UDS-FREE (no BIOS number, 512-byte blocks)
 *   UDS-INQ      INQUIRY through the stick  UDS-R0       READ(10) LBA 0 = "UDSTICK0"
 *   UDS-W        WRITE(10) 16 sectors from 1F00:0000 (crosses 20000h) to LBA 64
 *   UDS-RB       READ(10) back to 2F00:0000 (crosses 30000h), equal
 *   UDS-BIG      READ(10) 128 sectors (64 KiB) to 4000:0000 and to 5800:0000 (crosses 60000h),
 *                both equal to the image (host fills LBA 256.. with a pattern; compared here
 *                between the two reads)
 *   UDS-BAD      a request with data in F0000h is refused (BADREQ)
 *   UDS-STAT     STATUS returns the "USOS" "UDSK" record, version 1
 *   UDS-SENSE    READ(10) beyond the last LBA: CHECK with sense key 5 (ILLEGAL REQUEST)
 *   UDS-RESET    RESET (BOT reset recovery), then TEST UNIT READY and a READ work
 *   UDS-UNPLUG?  the host removes the stick now (QMP device_del); 64 KiB reads in a loop
 *   UDS-GONE     a request ended with GONE; the next one is GONE at once, ENUM state 2
 * A failed step prints " UDS-F<c> " (and the status) and powers off. APM 5307h power-off at the
 * end, as in nvme_rearm_mbr.S. Layout: sector 0 = loader, LBA 1-7 = stage 2 ("UDST").
 * No USB keyboard/mouse in this VM: in real mode SeaBIOS's IRQ 0 HID poll would run on the BSP
 * next to the helper core (the OS client only runs under Windows, where all SeaBIOS 32-bit code
 * is proxied to the helper). */
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
  mov $0x4200,%ax           /* stage 2: LBA 1-7 -> 0:7E00 */
  mov $dap,%si
  mov $0x80,%dl
  int $0x13
  jc 1f
  cmpl $0x54534455,stage2   /* "UDST" */
  je stage2+4
1: mov $'0',%bl
  jmp fail
fail:
  mov %bl,m_fail+6
  mov $m_fail,%si
  call print16
  jmp apmoff
print16:
  push %dx
  mov $0x402,%dx
1: lodsb
  test %al,%al
  jz 2f
  out %al,%dx
  jmp 1b
2: pop %dx
  ret
dap:
  .byte 16, 0
  .word 7, 0x7e00, 0
  .quad 1
m_fail:  .asciz " UDS-F? "
.org 0x1fe
  .byte 0x55, 0xaa

stage2:
  .ascii "UDST"
  mov $m_start,%si
  call print16
  /* find "CSMPPrxy" in F000:0000-FFF8, 8-byte steps */
  mov $'1',%bl
  mov $0xf000,%ax
  mov %ax,%fs
  xor %di,%di
1: cmpl $0x504d5343,%fs:(%di)
  jne 2f
  cmpl $0x79787250,%fs:4(%di)
  je 3f
2: add $8,%di
  cmp $0xfff8,%di
  jb 1b
  jmp fail
3: mov %di,mbox
  mov $'2',%bl
  cmpl $0x31534455,%fs:48(%di)
  jne fail
  movl $0x10000,%fs:52(%di)  /* req_phys = 1000:0000 */
  mov $m_ch,%si
  call print16

  /* ENUM into 1100:0000 */
  mov $'3',%bl
  call reqinit
  movb $1,%es:12             /* op ENUM */
  movb $1,%es:15             /* dir IN */
  movl $0x11000,%es:16
  movl $384,%es:20
  call post
  test %eax,%eax
  jnz failst
  mov $0x1100,%ax
  mov %ax,%gs
  mov $'4',%bl
  cmpb $1,%gs:0              /* state PRESENT */
  jne fail
  cmpl $1,%gs:8              /* generation 1 */
  jne fail
  movl %gs:8,%eax
  mov %eax,gen
  mov $m_enum,%si
  call print16
  cmpb $0,%gs:1              /* bios_drive */
  je 5f
  cmpl $0,%gs:12             /* an owned stick is never probed: no block size */
  jne fail
  /* owned by INT 13h: a SCSI request must be refused with OWNED */
  mov $'5',%bl
  call tur
  cmp $7,%eax
  jne failst
  mov $m_owned,%si
  call print16
  jmp apmoff
5: cmpl $512,%gs:12           /* block size (probed at this first ENUM) */
  jne fail
  mov $m_free,%si
  call print16

  /* INQUIRY 36 bytes -> 1200:0000 */
  mov $'6',%bl
  call reqscsi
  movb $1,%es:15
  movl $0x12000,%es:16
  movl $36,%es:20
  movb $6,%es:24
  movb $0x12,%es:28
  movb $36,%es:32
  call post
  test %eax,%eax
  jnz failst
  mov $m_inq,%si
  call print16

  /* READ(10) LBA 0, 1 sector -> 1200:0000, starts with "UDSTICK0" */
  mov $'7',%bl
  mov $0x12000,%eax
  xor %ecx,%ecx
  mov $1,%dx
  call read10
  jnz failst
  mov $0x1200,%ax
  mov %ax,%gs
  mov $'8',%bl
  cmpl $0x54534455,%gs:0     /* "UDST" */
  jne fail
  cmpl $0x304b4349,%gs:4     /* "ICK0" */
  jne fail
  mov $m_r0,%si
  call print16

  /* pattern in 1F00:0000-1FFF, WRITE(10) 16 sectors to LBA 64 */
  mov $0x1f00,%ax
  mov %ax,%es
  xor %di,%di
  mov $8192,%cx
  mov $0x5a,%al
1: stosb
  add $7,%al
  loop 1b
  mov $'9',%bl
  call reqscsi
  movb $2,%es:15             /* dir OUT */
  movl $0x1f000,%es:16
  movl $8192,%es:20
  movb $10,%es:24
  movb $0x2a,%es:28          /* WRITE(10) */
  movb $64,%es:33            /* LBA 64 (big endian, low byte) */
  movb $16,%es:36            /* 16 sectors */
  call post
  test %eax,%eax
  jnz failst
  mov $m_w,%si
  call print16

  /* READ(10) back to 2F00:0000 and compare */
  mov $'A',%bl
  mov $0x2f000,%eax
  mov $64,%ecx
  mov $16,%dx
  call read10
  jnz failst
  mov $'B',%bl
  push %ds
  mov $0x1f00,%ax
  mov %ax,%ds
  mov $0x2f00,%ax
  mov %ax,%es
  xor %si,%si
  xor %di,%di
  mov $8192,%cx
  cld
  repe cmpsb
  pop %ds
  jne fail
  mov $m_rb,%si
  call print16

  /* two 64 KiB reads of LBA 256.. : 4000:0000 (no crossing), 5800:0000 (crosses 60000h) */
  mov $'C',%bl
  mov $0x40000,%eax
  mov $256,%ecx
  mov $128,%dx
  call read10
  jnz failst
  mov $'D',%bl
  mov $0x58000,%eax
  mov $256,%ecx
  mov $128,%dx
  call read10
  jnz failst
  mov $'E',%bl
  mov $0x4000,%ax
  mov %ax,%gs
  cmpl $0x47494255,%gs:0     /* "UBIG" written by the host at LBA 256 */
  jne fail
  call cmp64k
  jne fail
  mov $m_big,%si
  call print16

  /* a request with its data in F0000h: BADREQ (6) */
  mov $'F',%bl
  mov $0xf0000,%eax
  xor %ecx,%ecx
  mov $1,%dx
  call read10
  cmp $6,%eax
  jne failst
  mov $m_bad,%si
  call print16

  /* STATUS: the record */
  mov $'G',%bl
  call reqinit
  movb $5,%es:12
  movb $1,%es:15
  movl $0x13000,%es:16
  movl $768,%es:20
  call post
  test %eax,%eax
  jnz failst
  mov $0x1300,%ax
  mov %ax,%gs
  cmpl $0x534f5355,%gs:0
  jne fail
  cmpl $0x4b534455,%gs:4
  jne fail
  cmpb $1,%gs:8
  jne fail
  mov $m_stat,%si
  call print16

  /* READ(10) at LBA 0x00FFFFF0 (beyond the 64 MiB image): CHECK + sense key 5 */
  mov $'H',%bl
  mov $0x12000,%eax
  mov $0x00fffff0,%ecx
  mov $1,%dx
  call read10
  cmp $1,%eax
  jne failst
  mov $'I',%bl
  mov $0x1000,%ax
  mov %ax,%es
  cmpb $14,%es:57            /* sense_len >= 14 */
  jb fail
  mov %es:62,%al             /* sense[2] */
  and $0x0f,%al
  cmp $5,%al
  jne fail
  mov $m_sense,%si
  call print16

  /* RESET (BOT reset recovery), then TEST UNIT READY: GOOD or CHECK (a unit attention) */
  mov $'M',%bl
  call reqinit
  movb $3,%es:12             /* op RESET, no data */
  call post
  test %eax,%eax
  jnz failst
  mov $'N',%bl
  call tur
  cmp $1,%eax
  ja failst
  mov $'O',%bl               /* a READ works after the reset */
  mov $0x12000,%eax
  xor %ecx,%ecx
  mov $1,%dx
  call read10
  jz 8f
  call read10                /* once more after a CHECK */
  jnz failst
8: mov $m_reset,%si
  call print16

  /* unplug: 64 KiB reads until GONE (at most ~30 s by the BIOS tick count) */
  mov $m_unplug,%si
  call print16
  mov 0x46c,%eax
  mov %eax,loops
6: mov $'J',%bl
  mov $0x40000,%eax
  mov $256,%ecx
  mov $128,%dx
  call read10
  cmp $3,%eax
  je 7f
  test %eax,%eax
  jnz failst
  incl reads
  mov 0x46c,%eax
  sub loops,%eax
  cmp $546,%eax
  jb 6b
  jmp fail
7: mov $m_gone,%si
  call print16
  mov $'K',%bl
  call tur                   /* GONE again at once */
  cmp $3,%eax
  jne failst
  mov $'L',%bl               /* ENUM: state GONE */
  call reqinit
  movb $1,%es:12
  movb $1,%es:15
  movl $0x11000,%es:16
  movl $384,%es:20
  call post
  test %eax,%eax
  jnz failst
  mov $0x1100,%ax
  mov %ax,%gs
  cmpb $2,%gs:0
  jne fail
  mov $m_gone2,%si
  call print16

apmoff:
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

/* status in EAX; print " ST=<hex digit> " and fail with BL */
failst:
  and $0x0f,%al
  add $'0',%al
  cmp $'9',%al
  jbe 1f
  add $7,%al
1: mov %al,m_st+4
  mov $m_st,%si
  call print16
  jmp fail

/* ES = 1000h, request zeroed, magic / version / size */
reqinit:
  push %ax
  push %cx
  push %di
  mov $0x1000,%ax
  mov %ax,%es
  xor %di,%di
  xor %al,%al
  mov $80,%cx
  cld
  rep stosb
  movl $0x52534455,%es:0
  movw $1,%es:4
  movw $80,%es:6
  pop %di
  pop %cx
  pop %ax
  ret

/* SCSI request for dev 0, LUN 0, the current generation */
reqscsi:
  call reqinit
  movb $2,%es:12
  push %eax
  mov gen,%eax
  mov %eax,%es:48
  pop %eax
  ret

/* TEST UNIT READY -> EAX status */
tur:
  call reqscsi
  movb $6,%es:24
  call post
  ret

/* READ(10): EAX = data phys, ECX = LBA, DX = sectors -> EAX status, ZF = OK */
read10:
  push %eax
  call reqscsi
  pop %eax
  movb $1,%es:15
  mov %eax,%es:16
  movzwl %dx,%eax
  shl $9,%eax
  mov %eax,%es:20
  movb $10,%es:24
  movb $0x28,%es:28
  bswap %ecx
  mov %ecx,%es:30            /* LBA, big endian, CDB bytes 2-5 */
  xchg %dl,%dh
  mov %dx,%es:35             /* transfer length, CDB bytes 7-8 */
  call post
  test %eax,%eax
  ret

/* post the request at 1000:0000; EAX = status (FFFFFFFFh on a timeout of ~20 s) */
post:
  push %bx
  push %di
  push %ecx
  mov $0xf000,%ax
  mov %ax,%fs
  mov mbox,%di
  incl seq
  mov seq,%eax
  mov %eax,%es:8
  movl $0xffffffff,%es:44
  mov %eax,%fs:56(%di)       /* doorbell */
  push %ds
  xor %bx,%bx
  mov %bx,%ds
  mov 0x46c,%ebx             /* BIOS tick count */
  pop %ds
1: mov %fs:60(%di),%ecx
  cmp seq,%ecx
  je 2f
  push %ds
  xor %cx,%cx
  mov %cx,%ds
  mov 0x46c,%ecx
  pop %ds
  sub %ebx,%ecx
  cmp $364,%ecx              /* ~20 s */
  ja 3f
  pause
  jmp 1b
2: mov %es:44,%eax
  jmp 4f
3: mov $0xffffffff,%eax
4: pop %ecx
  pop %di
  pop %bx
  ret

/* compare 4000:0000 with 5800:0000, 64 KiB; ZF = equal */
cmp64k:
  push %ds
  mov $0x4000,%ax
  mov %ax,%ds
  mov $0x5800,%ax
  mov %ax,%es
  xor %si,%si
  xor %di,%di
  mov $0x4000,%ecx
  cld
  repe cmpsl
  pop %ds
  ret

mbox:    .word 0
seq:     .long 0
gen:     .long 0
loops:   .long 0
reads:   .long 0
m_start: .asciz " UDS-S "
m_ch:    .asciz " UDS-CH "
m_enum:  .asciz " UDS-ENUM "
m_owned: .asciz " UDS-OWNED "
m_free:  .asciz " UDS-FREE "
m_inq:   .asciz " UDS-INQ "
m_r0:    .asciz " UDS-R0 "
m_w:     .asciz " UDS-W "
m_rb:    .asciz " UDS-RB "
m_big:   .asciz " UDS-BIG "
m_bad:   .asciz " UDS-BAD "
m_stat:  .asciz " UDS-STAT "
m_sense: .asciz " UDS-SENSE "
m_reset: .asciz " UDS-RESET "
m_unplug: .asciz " UDS-UNPLUG? "
m_gone:  .asciz " UDS-GONE "
m_gone2: .asciz " UDS-GONE2 "
m_ret:   .asciz " UDS-RET "
m_st:    .asciz " ST=? "
.org 0x1000
