# Sequential cache hits: how much can Glen's idea and next-address prediction save?

Measured in simulation (`STATS=1 python3 build.py sim`). The test program
marks each benchmark (mobo register $DE0014, caches on). For every cache
lookup, the bench records hit or miss, fetch or data, and whether the
address is the previous access of the same kind + 2 ("sequential").

A cache hit costs 7 clocks: SETTLE x3, DECIDE, CLOOK, CCMP, FINISH. Both
ideas remove CLOOK and CCMP, 2 clocks, from some hits:

- **Two words per entry (Glen):** the second word of an aligned longword,
  so sequential hits on odd words.
- **Next-address prediction:** look up last address + 2 during SETTLE,
  confirm at DECIDE. Every sequential hit.

| benchmark | clocks | fetch hits (seq) | data hits (seq) | saving: prediction | saving: Glen |
| --- | --- | --- | --- | --- | --- |
| CRC32 bitwise, 512 B | 428484 | 57854 (53757) | 132 (2) | **25.1%** | 12.7% |
| sieve to 2048 | 688260 | 79408 (72691) | 1680 (143) | **21.2%** | 11.2% |
| CRC32 table-driven | 174792 | 16388 (15363) | 2310 (1027) | **18.8%** | 10.6% |
| sum 4 KB table | 123804 | 12286 (10239) | 4100 (4096) | **23.2%** | 13.2% |
| 3 KB straight-line code* | 62196 | 4661 (4650) | 20 (14) | **15.0%** | 7.5% |
| fast RAM read stream | 33768 | 3086 (2573) | 4 (2) | **15.3%** | 9.2% |
| fast RAM copy | 55932 | 4609 (4097) | 6 (3) | **14.7%** | 7.3% |

\* Two calls in simulation, so the cold first call dominates (75% hit rate).
On hardware the function is called 64 times, which would push this towards
the other code-bound rows.

"Saving" is 2 clocks x qualifying hits / all clocks in the benchmark. It is
an upper bound: it assumes the 2 clocks are not swallowed by something else,
such as waiting for the SDRAM port (CFREE) or the 4-clock minimum step.

## What it says

- **Fetches dominate.** Close to every kernel step waits on an instruction
  fetch (CRC32: 63033 steps, 57854 fetch hits), and over 90% of fetch hits
  are sequential.
- **Prediction saves about twice as much as two-word entries,** 15-25% of
  all clocks against 7-13%. That is 1.18-1.33x against 1.08-1.15x, if the
  savings turn fully into speed.
- On the data side, streams mostly bypass the cache already: the direct
  path's prefetch buffer serves them (the "pf" counts in the raw output).
  Data hits that repeat, such as the 4 KB table sums, are almost all
  sequential, so prediction helps there too.

Raw counters: `[stats]` lines at the end of the simulation output.
