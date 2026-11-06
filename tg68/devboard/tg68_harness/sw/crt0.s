| crt0.s -- start-up for harness test programs (fast RAM, $08000000).
        .section .text.start,"ax"
        .globl  _start
_start:
        move.w  #0x2700,%sr
        lea     0x080FFFF0,%sp          | stack: top of the first fast-RAM MB
        lea     __bss_start,%a0
        lea     __bss_end,%a1
1:      cmp.l   %a1,%a0
        bcc.s   2f
        clr.l   (%a0)+
        bra.s   1b
2:      lea     vectors,%a0
        movec   %a0,%vbr
        jsr     main
        jmp     0xF80040                | back to the ROM loader

| exception vectors: every one goes to trap_entry with the vector offset
        .globl  vectors
        .balign 4
vectors:
        .rept   256
        .long   trap_entry
        .endr

        .globl  trap_entry
trap_entry:
        movem.l %d0-%d1/%a0-%a1,-(%sp)
        move.w  22(%sp),%d0             | format/vector word of the frame
        and.l   #0xFFF,%d0
        lsr.l   #2,%d0
        move.l  %d0,-(%sp)
        pea     16+4(%sp)               | pointer to the frame (SR, PC, ...)
        jsr     exception
        addq.l  #8,%sp
        movem.l (%sp)+,%d0-%d1/%a0-%a1
        rte
