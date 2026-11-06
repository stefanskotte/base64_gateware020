| loader.s -- boot ROM for the TG68 dev-board harness (mobo.v).
| Runs from $F80000 (mirrored at $000000 while OVL=1). Prints a banner,
| then waits on the UART for a program:
|   "B64L"  len.l  load.l  entry.l  <len bytes>  sum.l
| (big endian; sum = 32-bit sum of the data bytes). Replies "OK" and jumps
| to entry, or "ERR" and waits again. host/run.py speaks this protocol.
        .equ    UART,   0xDE0000        | W: tx byte   R: bit0 tx busy
        .equ    RXD,    0xDE0002        | R: bit15 valid, [7:0] byte
        .equ    CTRL,   0xDE000A        | bit0 OVL

        .text
        .org    0
        .long   0x00008000              | initial SSP: top of Chip RAM
        .long   0xF80000 + start        | initial PC (absolute, ROM)

        .org    0x40
start:
        move.w  #0x2700,%sr
        move.w  #0,CTRL                 | OVL off: Chip RAM at $000000
        lea     0x8000,%sp
        moveq   #9,%d0                  | CACR: clear + enable caches, so the
        movec   %d0,%cacr               | receive loop runs from the I-cache
        lea     banner(%pc),%a0
        bsr     puts
wait:   lea     magic(%pc),%a1
        moveq   #3,%d3
sync:   bsr     getc
        cmp.b   (%a1),%d0
        beq.s   1f
        lea     magic(%pc),%a1          | mismatch: restart the match
        moveq   #3,%d3
        cmp.b   (%a1),%d0
        bne.s   sync
1:      addq.l  #1,%a1
        dbra    %d3,sync
        bsr     getl
        move.l  %d0,%d4                 | length
        bsr     getl
        move.l  %d0,%a2                 | load address
        bsr     getl
        move.l  %d0,%a3                 | entry
        moveq   #0,%d5                  | checksum
        move.l  %d4,%d6
        beq.s   3f
2:      bsr     getc
        move.b  %d0,(%a2)+
        and.l   #0xFF,%d0
        add.l   %d0,%d5
        subq.l  #1,%d6
        bne.s   2b
3:      bsr     getl
        cmp.l   %d0,%d5
        bne.s   bad
        lea     ok(%pc),%a0
        bsr     puts
        jmp     (%a3)
bad:    lea     err(%pc),%a0
        bsr     puts
        bra     wait

| d0.b <- next byte (d0 upper bits cleared)
getc:   move.w  RXD,%d0
        bpl.s   getc
        and.l   #0xFF,%d0
        rts
| d0.l <- next 4 bytes, big endian
getl:   moveq   #3,%d2
        moveq   #0,%d1
1:      bsr     getc
        lsl.l   #8,%d1
        or.b    %d0,%d1
        dbra    %d2,1b
        move.l  %d1,%d0
        rts
putc:   btst    #0,UART+1
        bne.s   putc
        move.w  %d0,UART
        rts
puts:   move.b  (%a0)+,%d0
        beq.s   1f
        and.w   #0xFF,%d0               | word write: byte in [7:0]
        bsr     putc
        bra.s   puts
1:      rts

banner: .asciz  "\r\nB64 TG68 harness loader\r\n"
ok:     .asciz  "OK\r\n"
err:    .asciz  "ERR\r\n"
magic:  .ascii  "B64L"
