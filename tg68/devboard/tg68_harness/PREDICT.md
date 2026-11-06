# Next-address prediction (TG68_PREDICT)

The follow-up to SEQ_PREDICT.md: the prediction implemented in `tg68_bus.v`
under the `TG68_PREDICT` define, and measured.

## How it works

A cache hit used to cost 7 clocks: SETTLE x3, DECIDE, CLOOK, CCMP, FINISH.
The cache RAMs sat idle during SETTLE. Now:

1. Each access remembers the next word for its kind: `pr_f` for
   instruction fetches, `pr_d` for data reads.
2. During SETTLE the RAMs read at those addresses (`pr_rs` steers the read
   port). Data and tag are registered at SETTLE-2 and the tag compared at
   SETTLE-1 (`pr_fh`, `pr_dh`).
3. At DECIDE, if the kernel's address equals the prediction and the
   speculative lookup hit, the access goes straight to FINISH. A hit then
   costs 5 clocks. Otherwise the normal lookup runs, at no extra cost.
4. Any write to a predicted word cancels that prediction (`pr_fk`,
   `pr_dk`). The test suite does not trigger it (removing it changes no
   result), because with this pacing a write's cache update always lands
   before the next speculative read. It stays as a safety net.

A define, not a parameter: even dead code shifts yosys's internal names and
with them placement. Without the define the file is the original text, and
`build.py full --seed 3` (pinned tools) still gives the released step 4
bitstream.

## Results: hardware, 12x, caches on, full test program

| benchmark | before | TG68_PREDICT | gain |
| --- | --- | --- | --- |
| CRC32 bitwise, 4 KB | 39908 us | 29873 us | 1.34x |
| 3 KB straight-line code | 9777 us | 7504 us | 1.30x |
| sum 4 KB table | 22957 us | 17602 us | 1.30x |
| sum 128 B table | 23408 us | 17960 us | 1.30x |
| sieve to 8192 | 33634 us | 26523 us | 1.27x |
| memtest 15 MB random | 12233 ms | 9607 ms | 1.27x |
| fast RAM write 64 KB | 12263 us | 9817 us | 1.25x |
| CRC32 table-driven | 32521 us | 26395 us | 1.23x |
| fast RAM read 64 KB | 12327 us | 10432 us | 1.18x |
| fast RAM copy 64 KB | 20587 us | 17516 us | 1.18x |
| Chip RAM read | 2011 us | 1868 us | 1.08x |

With the caches off nothing changes, as expected. That is more than the x16
master clock gave (about 1.16x, X16.md), at today's 12x.

Glen's own benches in simulation, PREDICT off -> on:
- copy 4.85 -> 5.16 MB/s;
- read 8.03 -> 9.91 MB/s;
- scatter 11.66 -> 13.86 MB/s.

## Checks

- Harness: 38/38 in simulation and on hardware. Two checks were added for
  prediction: patching code just ahead of the PC, and a data loop that
  writes the next word and reads it back. Patching at distances 0-4 words
  gives the same result with and without prediction. At distance 0 the
  old instruction runs, because of the kernel's own prefetch, as on a real
  68020.
- `sim/run.sh` bus, top, fastmem and bench sd pass with and without
  `VLFLAGS=-DTG68_PREDICT`. The fastmem bench's data-cache hit counter now
  counts predicted hits too, and gives the same count both ways.
- Timing: check_timing.py classes `pr_f/pr_d/pr_fk/pr_dk` like `pf_a`
  (written at DECIDE, used >= 2 clocks later). With that, none of the
  prediction logic fails. Harness seed searches still fail on paths that
  fail without prediction too: the /HALT synchroniser, `dp_req` -> SDRAM,
  and the kernel clkena fan-out, depending on seed.

Build: `python3 build.py bit --predict` (harness) or
`python3 scripts/build.py full --predict` (Base64).
