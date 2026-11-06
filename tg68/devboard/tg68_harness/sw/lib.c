// lib.c -- UART output, timer and checks for harness test programs.
#include "lib.h"

int fails, passes;

void putc(char c)
{
    if (c == '\n') putc('\r');
    while (H_UART & 1) ;
    H_UART = (u8)c;
}

void puts(const char *s) { while (*s) putc(*s++); }

void puthex(u32 v, int digits)
{
    for (int i = digits - 1; i >= 0; i--)
        putc("0123456789ABCDEF"[(v >> (4 * i)) & 15]);
}

void putdec(u32 v)
{
    char b[11]; int n = 0;
    do { b[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n) putc(b[--n]);
}

void putfix(u32 v, int dec)
{
    u32 p = 1;
    for (int i = 0; i < dec; i++) p *= 10;
    putdec(v / p);
    if (dec) {
        putc('.');
        u32 f = v % p;
        for (u32 q = p / 10; q; q /= 10) { putc('0' + f / q); f %= q; }
    }
}

u32 micros(void)
{
    u32 hi = H_US_HI;            // reading the high half latches the low
    return (hi << 16) | H_US_LO;
}

void set_cacr(u32 v) { __asm__ volatile ("movec %0,%%cacr" :: "d"(v)); }
u32  get_cacr(void)  { u32 v; __asm__ volatile ("movec %%cacr,%0" : "=d"(v)); return v; }

void check(const char *what, u32 got, u32 exp)
{
    if (got == exp) { passes++; puts("  ok   "); puts(what); putc('\n'); return; }
    fails++;
    puts("  FAIL "); puts(what); puts(": got $"); puthex(got, 8);
    puts(", expected $"); puthex(exp, 8); putc('\n');
}
