# Dev-board tests (iCESugar-Pro on its own, no Base64 carrier)

Tools for checking an iCESugar-Pro module before it goes into a Base64.
Nothing here is part of the Amiga gateware, and nothing outside `devboard/`
is changed.

## sdram_test: full-chip SDRAM soak test

Some iCESugar-Pro modules have shipped with faulty SDRAM. This bitstream tests
all 32 MB using the TG68 build's own `rtl/base64_fx68k/sdram_ctrl.v`, at the
same ~86 MHz clock and CL2. A pass therefore checks both the memory chip and
the controller, exactly as the 68020 build drives them. A 50 MHz build is
included as a fallback, to tell a timing-margin problem apart from a bad cell.

Passes cycle through four pattern types:

| Type | Pattern |
| --- | --- |
| T0 | address hash ^ seed, written as two byte writes (tests the DQM lanes) |
| T1 | inverse of T0, word writes |
| T2 | AAAA/5555 checkerboard, inverted every pass |
| T3 | 32-bit LFSR stream, replayed on read |

Before the first pass, a walking-1s/0s test runs on the data bus.

LEDs (the module's RGB LED):

- **Blue**: test running.
- **Green**: toggles once per full 32 MB pass, about every 1.5 s.
- **Red**: latched on at the first error, ever. Red means the module is bad.

The UART (FPGA TX on B9, 115200 8N1) prints a banner, one line per error
(`E aaaaaa wXXXX rYYYY Tn`, at most 16 per pass), and one summary line per
pass: `P0003 T2 E00000000 B0000 OK`. The fields are the pass number, the
pattern type, the error count and the OR of all failing data bits.
Reading it needs an iCELink firmware that bridges the FPGA UART; see below.

```
sh build.sh sim      # 5 passes over a 4K-word window: total_errs 0
sh build.sh inject   # flips two cells mid-test: must report B4080 FAIL
sh build.sh bit      # build/sdram_test_86mhz.bit and _50mhz.bit
```

Flash by copying the `.bit` onto the iCELink drive, then let it run for
15–30 minutes. No red LED means the module is good.

Pins (`top.lpf`): the SDRAM and LED pins are those of the Base64 constraints.
On the module, the 25 MHz oscillator is on P6, UART TX on B9 and RX on A9.

## icelink/rawcopy_fat16.py: iCELink firmware update from macOS

On recent macOS, USB FAT drives are mounted through FSKit. FSKit writes
files in fragments and with delays, so the DAPLink bootloader (MAINTENANCE
drive) aborts with "update sent was incomplete" or "transfer timed out".
`mount -o sync` has no effect on FSKit. This script writes the file straight
to the raw disk instead: data sectors in order, then the FAT, then the
directory entry.

```
diskutil list external                     # find the MAINTENANCE disk number
diskutil unmount /Volumes/MAINTENANCE
sudo python3 rawcopy_fat16.py /dev/rdiskN firmware.hex   # --dry-run to only print the plan
```

Copying `.bit` files to the normal iCELink drive works with Finder or `cp`.
Only the bootloader update needs this script.

## tg68_harness: the whole 68020 build on the module

`base64_tg68_top` runs on the bare module with a motherboard model inside
the FPGA, a serial program loader, and a C test program covering 68020
instructions, the caches, fast RAM and benchmarks. See
[tg68_harness/README.md](tg68_harness/README.md).
