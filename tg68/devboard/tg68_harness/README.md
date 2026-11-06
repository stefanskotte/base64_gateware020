# TG68 harness: the 68020 build on a bare iCESugar-Pro

This runs the complete `base64_tg68_top` on the iCESugar-Pro module alone,
with no Base64 carrier and no Amiga: the TG68K core, `tg68_bus`, the 7M bus
bridge, the caches, and fast RAM in the module's SDRAM.

`mobo.v` stands in for the motherboard. It answers the 68000 bus the way
`sim/tb_top.sv`'s model does: Gary-style DTACK, VPA for CIA space and IACK,
a ROM with overlay, Chip RAM, plus a UART and a microsecond timer. Test
programs are sent over the iCELink serial port, so trying a new program needs
no FPGA rebuild.

```
harness_top.v   PLL 25 -> 85.7 MHz, 7M = /12, base64_tg68_top + mobo
mobo.v          motherboard model (memory map and registers in its header)
harness.lpf     clock, UART, SDRAM, SD, LED pins
rom/loader.s    boot ROM: banner, then waits for a program on the UART
sw/             test program: crt0.s, main.c, lib.c, link.ld
host/run.py     sends a program to the loader and prints its output
sim/tb.sv       the same thing in Verilator, with the checked SDRAM model
build.py        rom | sw | sim | bit
```

## Changes outside this folder

`rtl/base64_tg68/base64_tg68_top.sv` has a `DEVBOARD` define, marked
`TG68:`. Without it the file builds exactly as before: the only change is
that three internal reads now go through renamed wires. With it, the shared
nets `cpu_d`, `/RESET` and `/HALT` are split into drive, enable and read
signals. yosys cannot keep a tristate between two modules inside the FPGA,
and that is what those nets would be once the motherboard is a module.

## Use

Use the tool versions from `scripts/setup_cloud.sh` (yowasp-yosys 0.70,
yowasp-nextpnr-ecp5 0.11). The newer nextpnr in current oss-cad-suite
(0.11.1-88) aborts while packing the TG68 kernel, and it does that on the
main `full` build too.

```
python3 build.py sim                    # loader + short test, ~40 s, ends "SIM PASS"
python3 build.py sw                     # build/test.bin, the full-size test
YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-ecp5 python3 build.py bit
python3 host/run.py build/test.bin --bit build/tg68_harness.bit --port /dev/cu.usbmodemXXXX
```

`--bit` loads the FPGA over JTAG through the iCELink. That is volatile, so
the flash is untouched and a power cycle brings back whatever was there.
Plug the board into the module's own USB-C port: that iCELink has JTAG and
the FPGA UART.

The test program checks 68020 instructions (64-bit MULU/MULS/DIVU,
bitfields, scaled-index and memory-indirect addressing, CAS, PACK/UNPK,
MOVEC VBR, TRAP, autovectored IRQ) and the caches (CACR, self-modifying
code, byte and word writes over cached data). It tests 15 MB of fast RAM
with the caches off and on, tests Chip RAM through the bridge, and times
simple benchmarks with the caches off and on. It ends with
`RESULT: PASS` or `RESULT: FAIL n`, then returns to the loader, so another
program can be sent straight away.

## Results

On hardware (2026-11-06, iCESugar-Pro v1.3, harness built with yowasp 0.70 /
0.11, seed 1), all 36 checks pass. That covers 15 MB of fast RAM, three
patterns, each with the caches off and on, with 0 errors, and Chip RAM
through the bridge with 0 errors. There were no unmapped motherboard cycles.
The simulation's short variant gives the same per-loop timings.

| Benchmark (C loops) | caches off | caches on |
| --- | --- | --- |
| fast RAM write, 64 KB | 3.56 MB/s | 5.34 MB/s |
| fast RAM read, 64 KB | 3.66 MB/s | 5.31 MB/s |
| fast RAM copy, 64 KB | 2.29 MB/s | 3.18 MB/s |
| Chip RAM read (bridge, model Gary) | 1.86 MB/s | 2.03 MB/s |
| CRC32 4 KB, bitwise | 62.8 ms | 39.9 ms |
| sieve to 8192 | 51.7 ms | 33.6 ms |

These are compiled C loops, so they come out below AIBB's hand-written
ones (README step 4: 7.28 MB/s). Use them to compare builds with each
other, not with SysInfo or AIBB.

The Chip RAM figure depends on mobo.v's DTACK timing (two 7M clocks after
AS), not on a real Gary. Chip RAM speed on an Amiga can only be measured in
an Amiga.
