// lib.h -- tiny runtime for harness test programs (no libc).
#pragma once
typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef signed int     s32;

#define REG16(a) (*(volatile u16 *)(a))
#define H_UART   REG16(0xDE0000)   // W tx byte, R bit0 busy
#define H_RX     REG16(0xDE0002)
#define H_US_HI  REG16(0xDE0004)
#define H_US_LO  REG16(0xDE0006)
#define H_IPL    REG16(0xDE0008)
#define H_CTRL   REG16(0xDE000A)
#define H_UNMCNT REG16(0xDE000C)
#define H_UNM_HI REG16(0xDE000E)
#define H_UNM_LO REG16(0xDE0010)
#define H_ID     REG16(0xDE0012)

void putc(char c);
void puts(const char *s);
void puthex(u32 v, int digits);
void putdec(u32 v);
void putfix(u32 v, int dec);        // v / 10^dec with dec decimals
u32  micros(void);
void set_cacr(u32 v);
u32  get_cacr(void);

extern int fails, passes;
void check(const char *what, u32 got, u32 exp);
