# Cache size: 8 KB (this build) vs 256 bytes (a real 68020)

A real 68020 has a 256-byte instruction cache and no data cache. The TG68
build has 8 KB of each: direct-mapped, one 16-bit word per entry, in block
RAM. This compares the two on the dev-board harness, on hardware, at 12x
(85.7 MHz), caches on, with the full test program (`build.py sw`). The
cache-size benchmarks repeat 32 times, so these are steady-state numbers.

| benchmark | 8 KB I + 8 KB D | 256 B I + 256 B D | 256 B I, no D (real 68020) |
| --- | --- | --- | --- |
| 3 KB straight-line code, 64 calls | **9777 us** | 16876 us (1.73x slower) | 16887 us (1.73x slower) |
| CRC32 table-driven, 1 KB table, 16 KB | 32522 us | 33652 us (+3.5%) | 34797 us (+7.0%) |
| sum 4 KB table, 32 passes | 22957 us | 24665 us (+7.4%) | 24665 us (+7.4%) |
| sum 128 B table, 1024 passes | 23408 us | 23388 us | 25123 us (+7.3%) |
| sieve to 8192 (8 KB array) | 33594 us | 34285 us (+2.1%) | 34426 us (+2.5%) |
| tight loops: bitwise CRC32, fast RAM read/copy | — | within 1% | within 1% |

All three pass the full test (36/36). Simulation (`build.py sim --ic-aw 7
[--no-dcache]`) shows the same pattern.

## What it means

- **Instruction cache size matters for code bigger than 256 bytes.** A
  3 KB routine runs 1.73x faster from the 8 KB cache. That covers most real
  inner loops beyond a few instructions: game engines, decompressors,
  Kickstart and library code. A program tuned for a real 68020's 256 bytes
  (tight loops) gains little, because its loops already fit.
- **Data cache size barely matters (at most 7%).** A fast-RAM read on the
  direct path with its one-word prefetch already costs almost as much as a
  cache hit (5.31 vs 5.70 MB/s), so a data hit saves little. The data
  cache's value is in hits: one 16-bit word per entry and about 7 clocks per
  hit make the hit itself the cost. That is why two words per entry, or a
  shorter hit path, would pay off more than a bigger cache.
- 256 B I + 256 B D is roughly a 68030's cache sizes, but without the
  68030's 16-byte lines and burst fills.

Bitstreams: `build.py bit --ic-aw 7 [--no-dcache]` (seed 5). The 8 KB
column uses the seed-5 build from the main harness branch, which is nearly
timing-clean. The 256 B builds miss the harness timing check by at most
1.4 ns. That is acceptable for a room-temperature comparison, and their
results match simulation.
