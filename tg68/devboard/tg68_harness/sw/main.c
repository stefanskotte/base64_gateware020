// main.c -- TG68 (68020) self-test and benchmarks for the dev-board harness.
// Loaded into fast RAM at $08000000 by the ROM loader (host/run.py).
// Prints "ok"/"FAIL" per check and ends with "RESULT: PASS" or
// "RESULT: FAIL n", which run.py and the simulation look for.
#include "lib.h"

#ifdef SIM
#define MEM_TEST_BYTES  (16u * 1024)        // simulation: a taste of each
#define BENCH_BYTES     2048u
#define SIEVE_N         2048u
#define SIEVE_PRIMES    309u
#define CRC_BYTES       512u
#else
#define MEM_TEST_BYTES  (15u * 1024 * 1024) // $08100000-$08FFFFFF
#define BENCH_BYTES     65536u
#define SIEVE_N         8192u
#define SIEVE_PRIMES    1028u
#define CRC_BYTES       4096u
#endif
static volatile u32 sink;                  // keeps benchmark results alive

#define CACHES_ON  0x0009                   // EI + clear
#define CACHES_OFF 0x0008                   // clear, disabled

// ---------------------------------------------------------------------------
// exceptions (crt0's trap_entry calls this with the vector number)
static volatile u32 n_irq3, n_trap5, n_other, last_vec;
void exception(u16 *frame, u32 vec)
{
    if (vec == 27) { n_irq3++; H_IPL = 0; return; }   // level 3 autovector
    if (vec == 37) { n_trap5++; return; }             // TRAP #5
    n_other++; last_vec = vec;
    puts("\n  unexpected exception, vector "); putdec(vec);
    puts(" at PC $"); puthex(((u32)frame[1] << 16) | frame[2], 8); putc('\n');
}

// ---------------------------------------------------------------------------
static void test_cpu(void)
{
    u32 hi, lo, q, r, x;
    puts("68020 instructions\n");

    lo = 0x12345678;
    __asm__ ("mulu.l %2,%1:%0" : "=d"(lo), "=d"(hi) : "d"(0x9ABCDEF0), "0"(lo));
    check("MULU.L 32x32->64 hi", hi, 0x0B00EA4E);
    check("MULU.L 32x32->64 lo", lo, 0x242D2080);

    lo = (u32)-123456789;
    __asm__ ("muls.l %2,%1:%0" : "=d"(lo), "=d"(hi) : "d"(987654321), "0"(lo));
    check("MULS.L 32x32->64 hi", hi, 0xFE4ECEEB);
    check("MULS.L 32x32->64 lo", lo, 0x0400AC7B);

    q = 0x23456789; r = 1;
    __asm__ ("divu.l %2,%1:%0" : "=d"(q), "=d"(r) : "d"(0x12345), "0"(q), "1"(r));
    check("DIVU.L 64/32 quotient", q, 0x00010000);
    check("DIVU.L 64/32 remainder", r, 0x00006789);

    q = (u32)-1000000;
    __asm__ ("divsl.l %2,%1:%0" : "=d"(q), "=d"(r) : "d"(7), "0"(q));
    check("DIVSL.L quotient", q, 0xFFFDD1F7);
    check("DIVSL.L remainder", r, 0xFFFFFFFF);

    __asm__ ("bfextu %1{#4:#12},%0" : "=d"(x) : "d"(0x12345678));
    check("BFEXTU", x, 0x234);
    __asm__ ("bfexts %1{#8:#8},%0" : "=d"(x) : "d"(0x12F45678));
    check("BFEXTS", x, 0xFFFFFFF4);
    __asm__ ("bfffo %1{#0:#32},%0" : "=d"(x) : "d"(0x00010000));
    check("BFFFO", x, 15);
    x = 0x11111111;
    __asm__ ("bfins %1,%0{#28:#4}" : "+d"(x) : "d"(0xA));
    check("BFINS", x, 0x1111111A);

    x = 0x80;
    __asm__ ("extb.l %0" : "+d"(x));
    check("EXTB.L", x, 0xFFFFFF80);

    static u32 tab[8] = { 10, 11, 12, 13, 14, 15, 16, 17 };
    __asm__ ("move.l (%1,%2.l*4),%0" : "=d"(x) : "a"(tab), "d"(5));
    check("scaled index (An,Dn*4)", x, 15);

    static u32 tgt[4] = { 0, 0, 0x5EED1234, 0 };
    static u32 *ptrs[2];
    ptrs[1] = tgt;
    __asm__ ("move.l ([4,%1],8),%0" : "=d"(x) : "a"(ptrs));
    check("memory indirect ([4,An],8)", x, 0x5EED1234);

    static u32 cell = 0x11112222;
    u32 cmp = 0x11112222, upd = 0x33334444;
    __asm__ volatile ("cas.l %0,%1,(%2)" : "+d"(cmp) : "d"(upd), "a"(&cell) : "memory", "cc");
    check("CAS.L (match) memory", cell, 0x33334444);

    __asm__ ("pack %1,%0,#0" : "=d"(x) : "d"(0x0304));
    check("PACK", x & 0xFF, 0x34);
    __asm__ ("unpk %1,%0,#0x3030" : "=d"(x) : "d"(0x47));
    check("UNPK", x & 0xFFFF, 0x3437);

    u32 v;
    __asm__ volatile ("movec %%vbr,%0" : "=d"(v));
    extern u32 vectors[];
    check("MOVEC VBR read-back", v, (u32)vectors);

    __asm__ volatile ("trap #5");
    check("TRAP #5 via VBR table", n_trap5, 1);

    H_IPL = 3;
    __asm__ volatile ("move.w #0x2000,%%sr" ::: "memory");
    for (int i = 0; i < 1000 && !n_irq3; i++) ;
    __asm__ volatile ("move.w #0x2700,%%sr" ::: "memory");
    check("IRQ level 3 autovector", n_irq3, 1);
}

// ---------------------------------------------------------------------------
static u32 memtest(volatile u32 *base, u32 bytes, int pat)
{
    u32 n = bytes / 4, errs = 0, s = 0x1234567;
    for (u32 i = 0; i < n; i++) {
        u32 v = pat == 0 ? (u32)&base[i] : pat == 1 ? ~(u32)&base[i]
              : (s = s * 1103515245u + 12345u);
        base[i] = v;
    }
    s = 0x1234567;
    for (u32 i = 0; i < n; i++) {
        u32 v = pat == 0 ? (u32)&base[i] : pat == 1 ? ~(u32)&base[i]
              : (s = s * 1103515245u + 12345u);
        u32 g = base[i];
        if (g != v) {
            if (errs < 4) {
                puts("    $"); puthex((u32)&base[i], 8); puts(" got $"); puthex(g, 8);
                puts(" want $"); puthex(v, 8); putc('\n');
            }
            errs++;
        }
    }
    return errs;
}

static void test_mem(void)
{
    static const char *pname[3] = { "address", "~address", "random" };
    puts("Fast RAM $08100000, "); putdec(MEM_TEST_BYTES >> 10); puts(" KB\n");
    for (int c = 0; c < 2; c++) {
        set_cacr(c ? CACHES_ON : CACHES_OFF);
        for (int p = 0; p < 3; p++) {
            u32 t = micros();
            u32 e = memtest((volatile u32 *)0x08100000, MEM_TEST_BYTES, p);
            t = micros() - t;
            puts(c ? "  [caches on ] " : "  [caches off] ");
            puts(pname[p]); puts(": "); putdec(e); puts(" errors, ");
            putdec(t / 1000); puts(" ms\n");
            if (e) fails++; else passes++;
        }
    }
    puts("Chip RAM (motherboard bus) $001000, 16 KB\n");
    set_cacr(CACHES_ON);
    for (int p = 0; p < 3; p++) {
        u32 e = memtest((volatile u32 *)0x00001000, 16384, p);
        puts("  "); puts(pname[p]); puts(": "); putdec(e); puts(" errors\n");
        if (e) fails++; else passes++;
    }
}

// ---------------------------------------------------------------------------
// The instruction cache drops an entry on any write to it, so code written
// at run time must execute as written, with the caches on.
static void test_cache(void)
{
    puts("Caches\n");
    set_cacr(CACHES_ON);
    check("CACR read-back (EI)", get_cacr() & 1, 1);
    static u16 code[2];
    int (*fn)(void) = (int (*)(void))code;
    int sum = 0;
    for (int k = 1; k <= 3; k++) {
        code[0] = 0x7000 | k;              // moveq #k,d0
        code[1] = 0x4E75;                  // rts
        for (int j = 0; j < 4; j++) sum += fn();
    }
    check("self-modifying code (I-cache)", sum, 4 * (1 + 2 + 3));
    volatile u32 *p = (volatile u32 *)0x08200000;
    p[0] = 0xCAFEF00D; (void)p[0];
    ((volatile u8 *)p)[1] = 0x55;          // byte write over a cached long
    check("D-cache byte write", p[0], 0xCA55F00D);
    ((volatile u16 *)p)[1] = 0x1234;
    check("D-cache word write", p[0], 0xCA551234);
    set_cacr(CACHES_OFF);
    p[0] = 0x0BADBEEF;
    set_cacr(CACHES_ON);
    check("write with caches off", p[0], 0x0BADBEEF);
    check("unmapped motherboard cycles", H_UNMCNT, 0);
}

// ---------------------------------------------------------------------------
static void report(const char *what, u32 bytes, u32 us)
{
    if (*what) { puts("  "); puts(what); } puts(": ");
    putdec(us); puts(" us");
    if (bytes) { puts(", "); putfix(us ? (u32)((unsigned long long)bytes * 100 / us) : 0, 2); puts(" MB/s"); }
    putc('\n');
}

static u32 crc32(const u8 *p, u32 n)
{
    u32 c = 0xFFFFFFFF;
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320 & -(c & 1));
    }
    return ~c;
}

static u32 sieve(u8 *f, u32 n)
{
    u32 cnt = 0;
    for (u32 i = 0; i < n; i++) f[i] = 1;
    for (u32 i = 2; i < n; i++)
        if (f[i]) { cnt++; for (u32 j = i + i; j < n; j += i) f[j] = 0; }
    return cnt;
}

static void bench(void)
{
    volatile u32 *src = (volatile u32 *)0x08400000, *dst = (volatile u32 *)0x08500000;
    u32 n = BENCH_BYTES / 4, t, sum = 0;
    for (int c = 0; c < 2; c++) {
        set_cacr(c ? CACHES_ON : CACHES_OFF);
        puts(c ? "Benchmarks, caches on\n" : "Benchmarks, caches off\n");
        t = micros(); for (u32 i = 0; i < n; i++) dst[i] = i; t = micros() - t;
        report("fast RAM write", BENCH_BYTES, t);
        t = micros(); for (u32 i = 0; i < n; i++) sum += src[i]; t = micros() - t;
        report("fast RAM read ", BENCH_BYTES, t);
        t = micros(); for (u32 i = 0; i < n; i++) dst[i] = src[i]; t = micros() - t;
        report("fast RAM copy ", BENCH_BYTES, t);
        t = micros(); for (u32 i = 0; i < 1024; i++) sum += ((volatile u32 *)0x1000)[i]; t = micros() - t;
        report("chip RAM read ", 4096, t);
        t = micros(); u32 crc = crc32((const u8 *)0x08000000, CRC_BYTES); t = micros() - t;
        puts("  CRC32 "); putdec(CRC_BYTES); puts(" bytes, bitwise"); report("", 0, t);
        sink = crc;
        t = micros(); u32 pr = sieve((u8 *)0x08600000, SIEVE_N); t = micros() - t;
        puts("  sieve to "); putdec(SIEVE_N); report("", 0, t);
        if (pr != SIEVE_PRIMES) { puts("  FAIL sieve count "); putdec(pr); putc('\n'); fails++; }
    }
    sink = sum;
}

// ---------------------------------------------------------------------------
// Cache-size benchmarks: working sets between 256 bytes (a real 68020's
// I-cache) and 8 KB (this build's), so the cache size shows.
#ifdef SIM
#define CS_REPS 2
#else
#define CS_REPS 32
#endif
static u32 crc_tab[256];                        // 1 KB, reused for every byte
static u32 crc32_tab(const u8 *p, u32 n)
{
    u32 c = 0xFFFFFFFF;
    while (n--) c = crc_tab[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return ~c;
}

// ~3 KB of straight-line code: bigger than 256 bytes, well inside 8 KB
#define OP(k) s = (s ^ (s >> 3)) + (u32)(k) * 0x9E3779B9u;
#define R4(k)   OP(k) OP(k + 1) OP(k + 2) OP(k + 3)
#define R16(k)  R4(k) R4(k + 4) R4(k + 8) R4(k + 12)
#define R64(k)  R16(k) R16(k + 16) R16(k + 32) R16(k + 48)
#define R256(k) R64(k) R64(k + 64) R64(k + 128) R64(k + 192)
static __attribute__((noinline)) u32 bigcode(u32 s) { R256(1) return s; }
static __attribute__((noinline)) u32 bigcode_end(void) { return 0; }

static u32 table_sum(const volatile u32 *t, u32 words, u32 passes)
{
    u32 sum = 0;
    while (passes--) for (u32 i = 0; i < words; i++) sum += t[i];
    return sum;
}

static void bench_cache_size(void)
{
    u32 t, x;
    for (u32 i = 0; i < 256; i++) {
        u32 c = i;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320 & -(c & 1));
        crc_tab[i] = c;
    }
    puts("Cache-size benchmarks, caches on (bigcode is ");
    putdec((u32)bigcode_end - (u32)bigcode); puts(" bytes)\n");
    set_cacr(CACHES_ON);
    t = micros(); x = crc32_tab((const u8 *)0x08000000, CS_REPS * 512); t = micros() - t;
    sink = x; puts("  CRC32 table-driven, 1 KB table"); report("", CS_REPS * 512, t);
    volatile u32 *tab = (volatile u32 *)0x08700000;
    for (u32 i = 0; i < 1024; i++) tab[i] = i;
    t = micros(); x = table_sum(tab, 1024, CS_REPS); t = micros() - t;
    sink = x; puts("  sum 4 KB table"); report("", CS_REPS * 4096, t);
    t = micros(); x = table_sum(tab, 32, CS_REPS * 32); t = micros() - t;
    sink = x; puts("  sum 128 B table"); report("", CS_REPS * 4096, t);
    t = micros(); x = 1; for (u32 i = 0; i < CS_REPS * 2; i++) x = bigcode(x); t = micros() - t;
    sink = x; puts("  3 KB straight-line code"); report("", 0, t);
}

int main(void)
{
    puts("\nTG68 68020 harness test, harness id $"); puthex(H_ID, 4); putc('\n');
    test_cpu();
    test_cache();
    test_mem();
    bench();
    bench_cache_size();
    if (n_other) { puts("unexpected exceptions: "); putdec(n_other); putc('\n'); fails++; }
    puts("passed "); putdec(passes); puts(", failed "); putdec(fails); putc('\n');
    if (fails) { puts("RESULT: FAIL "); putdec(fails); putc('\n'); }
    else puts("RESULT: PASS\n");
    return 0;
}
