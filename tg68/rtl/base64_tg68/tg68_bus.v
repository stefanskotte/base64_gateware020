// ============================================================================
// tg68_bus.v -- TG68K.C kernel (68020 mode) behind an fx68k-shaped port list
//
// base64_top was written around fx68k, which looks to the rest of the design
// like a real 68000: AS/UDS/LDS/RW out, DTACK/BERR in, address held for the
// whole cycle. Everything downstream -- the RETIME bridge to the motherboard,
// fast RAM, the turbomem ROM board, the SD card -- is an ordinary
// asynchronous 68000 slave. This module makes TG68K look the same, so none
// of that has to change.
//
// TG68K is not a bus master. It is a state machine that advances one step
// per clkena pulse and tells you, via busstate, what it wants next:
//   00 fetch, 10 read, 11 write  -> run a bus cycle, then pulse clkena with
//                                   the read data on data_in
//   01 internal                  -> just pulse clkena
// (busstate 00 with skipFetch=1 is also internal, as in TG68K.vhd.)
//
// TIMING MODEL -- READ THIS BEFORE CHANGING THE PARAMETERS
// Every register inside the kernel is gated by clkena (checked: Kernel and
// ALU, all processes). So kernel-internal paths have STEP master clocks to
// settle, not one. The adapter keeps that true at the interface as well:
//   * kernel OUTPUTS are only looked at SETTLE clocks after a clkena
//   * kernel INPUTS (data_in, IPL, berr, nReset) only change on a clkena
//     edge or at least DIN_SETUP clocks before the next one
// so no path through the kernel is single-cycle. nextpnr cannot express
// that (no multicycle constraints) and will report the kernel as failing
// 85 MHz; that report is expected. What has to be true is that each class
// of kernel path fits its budget -- scripts/check_timing.py checks this on
// the routed design: internal paths < STEP, outputs < SETTLE, inputs <
// DIN_SETUP clocks. Routed they are ~42, ~32 and ~14 ns.
//
// The adapter itself, the bridge and the slaves are normal single-cycle
// logic and must meet 85 MHz for real.
//
// BUS SHAPE (master clocks of ~11.75 ns)
//   address/FC/RW/data out ..ADDR_SETUP.. AS low (+DS for reads)
//   writes: DS follows AS by WDS_DELAY (a 68000 asserts write DS at S4)
//   DTACK or BERR seen ..DATA_DELAY.. latch read data, AS/DS high
//   address/RW/data held until the next cycle is set up (>= SETTLE clocks)
// AS-high time between cycles is always >= DIN_SETUP+SETTLE+ADDR_SETUP.
// ============================================================================
`default_nettype none

module tg68_bus #(
    parameter integer STEP       = 4,  // min clocks between clkena pulses
    parameter integer SETTLE     = 3,  // clocks after clkena before sampling
    parameter integer DIN_SETUP  = 1,  // read data -> clkena. The kernel
                                       // samples on the clock AFTER clkena is
                                       // set, so data_in gets DIN_SETUP+1.
    parameter integer ADDR_SETUP = 1,  // address valid -> AS; the port AS is a
                                       // further clock later (strobe pipeline),
                                       // so slaves see ADDR_SETUP+1 = 2, which
                                       // is what their registered decodes need
                                       // and what fx68k at 6x gives them.
    parameter integer WDS_DELAY  = 2,  // AS -> DS on writes
    parameter integer DATA_DELAY = 2,  // DTACK -> data latch / AS negate
    parameter integer ICACHE     = 1,  // instruction cache, see ICACHE below
    parameter integer DIRECT     = 1,  // direct SDRAM path, see DIRECT below
    parameter integer DCACHE     = 1,  // data cache, see DCACHE below
    parameter integer IC_AW      = 12, // log2(cache words): 12 = 4096 = 8 KB
    parameter integer BARREL     = 0   // documentation only: which netlist
)(
    input  wire        clk,
    input  wire        enPhi1,     // unused, kept for drop-in compatibility
    input  wire        enPhi2,     // unused
    input  wire        HALTn,      // external HALT: holds off new cycles
    input  wire        extReset,   // core reset (RESET+HALT, power-up)
    input  wire        pwrUp,      // unused, extReset already covers it
    output reg         oRESETn,    // RESET instruction
    output wire        oHALTEDn,   // TG68 has no double-fault halt: always 1
    output wire        E,          // unused by base64_top
    input  wire        VPAn,       // unused: the bridge owns 6800 cycles
    output wire        VMAn,
    output reg         ASn,       // see "STROBE PIPELINE" below
    output reg         eRWn,
    output reg         LDSn,
    output reg         UDSn,
    output wire        FC2, FC1, FC0,
    input  wire        DTACKn,
    input  wire        BERRn,
    input  wire        BRn,
    output reg         BGn,
    input  wire        BGACKn,
    input  wire        IPL2n, IPL1n, IPL0n,
    input  wire [15:0] iEdb,
    input  wire        icache_win, // registered: eab is in on-board fast RAM
    // direct SDRAM path (to fastmem_zii's dp_* port)
    input  wire        fm_on,      // fast RAM block is built and configured
    input  wire [7:0]  fm_match,   //   ... and owns these Zorro II slots
    input  wire        cpu_win_en, // the $08000000 window exists
    input  wire        mr_load,    // MapROM: writes to the ROM banks -> SDRAM
    input  wire        mr_active,  // MapROM: reads from the ROM banks <- SDRAM
    output reg         dp_req,
    output reg         dp_inc,     // a prefetch of the next word is about to
                                   // be requested (see DIRECT)
    output wire [31:1] eab_early,  // the kernel's address, final at DECIDE
    output wire        dp_hold,    // a direct request is outstanding
    output reg         dp_we,
    output reg  [15:0] dp_wdata,
    output reg  [1:0]  dp_be,
    input  wire        dp_ack,
    input  wire [15:0] dp_rdata,
    output reg  [15:0] oEdb,
    output wire [31:1] eab,
    // diagnostics
    output reg         stalled     // a bus cycle has waited ~100 ms for DTACK
);

    assign oHALTEDn = 1'b1;
    assign E        = 1'b0;
    assign VMAn     = 1'b1;

    // ------------------------------------------------------------------
    // Kernel
    // ------------------------------------------------------------------
    reg         k_clkena = 1'b0;
    reg         k_nreset = 1'b0;
    reg  [15:0] k_din    = 16'hFFFF;
    reg  [2:0]  k_ipl    = 3'b111;
    reg         k_berr   = 1'b0;

    wire [31:0] k_addr;
    wire [15:0] k_dout;
    wire        k_nwr, k_nuds, k_nlds, k_nresetout, k_skip;
    wire [1:0]  k_bs;
    wire [2:0]  k_fc;
    wire [3:0]  k_cacr;            // 68020 CACR: 0 EI, 1 FI, 2 CEI, 3 CI
                                   // (EI also enables the data cache)

    tg68_020 core (
        .clk        (clk),
        .nreset     (k_nreset),
        .clkena_in  (k_clkena),
        .data_in    (k_din),
        .ipl        (k_ipl),
        .berr       (k_berr),
        .addr_out   (k_addr),
        .data_write (k_dout),
        .nwr        (k_nwr),
        .nuds       (k_nuds),
        .nlds       (k_nlds),
        .busstate   (k_bs),
        .nresetout  (k_nresetout),
        .fc         (k_fc),
        .skipfetch  (k_skip),
        .cacr       (k_cacr)
    );

    // ------------------------------------------------------------------
    // Bus-side registers (held for the whole cycle)
    // ------------------------------------------------------------------
    reg [31:1] a_r  = 31'd0;
    reg [2:0]  fc_r = 3'b110;
    reg        uds_want = 1'b1, lds_want = 1'b1;
    assign eab = a_r;
    assign {FC2, FC1, FC0} = fc_r;

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    localparam [3:0] Q_SETTLE = 4'd0,  // waiting for kernel outputs to settle
                     Q_DECIDE = 4'd1,  // internal step or bus cycle?
                     Q_SETUP  = 4'd2,  // address out, waiting to assert AS
                     Q_WDS    = 4'd3,  // write: AS out, waiting to assert DS
                     Q_WAIT   = 4'd4,  // waiting for DTACK/BERR
                     Q_LATCH  = 4'd5,  // DTACK seen, counting to data latch
                     Q_FINISH = 4'd6,  // data latched, counting to clkena
                     Q_CLOOK  = 4'd7,  // fetch: cache RAM being read
                     Q_CCMP   = 4'd8,  // fetch: compare tag, hit or go to bus
                     Q_DWAIT  = 4'd9,  // direct SDRAM access in progress
                     Q_DDATA  = 4'd10, // direct SDRAM data captured
                     Q_CFREE  = 4'd11; // cache miss: waiting for the SDRAM port

    reg [3:0] q    = Q_SETTLE;

    // ------------------------------------------------------------------
    // ICACHE -- instruction cache
    //
    // Direct-mapped, one 16-bit word per entry, 2^IC_AW entries in block
    // RAM. Only instruction fetches (busstate 00) are looked up or filled,
    // and only from memory nothing but this CPU can change:
    //   * on-board fast RAM (Zorro II window and $08000000), as reported by
    //     fastmem_zii's registered window decode (icache_win). DMA into it
    //     is not supported at all (see the fx68k README), so the CPU is the
    //     only writer;
    //   * the Kickstart ROM, $F80000-$FFFFFF.
    // Chip RAM is never cached: the blitter and disk DMA write it.
    //
    // Coherency: every CPU write to a cacheable address invalidates its
    // entry, whatever CACR says. So self-modifying code and LoadSeg work
    // without CacheClearU, and CACR's clear bits (CI/CEI) are not needed:
    // they are ignored. TG68 also latches CI rather than self-clearing it,
    // so it could not be used as a clear strobe reliably anyway.
    // CACR EI (bit 0) enables the cache, as on a real 68020 (off at reset;
    // Kickstart 2.0+ turns it on). FI (bit 1) freezes it: hits, no fills.
    // The whole cache is invalidated after any reset, because autoconfig
    // may give the Zorro II RAM a different address next time.
    //
    // Timing: the cache RAM's read address is the kernel's own address
    // output, so the read happens on the DECIDE edge (a kernel -> logic
    // path, SETTLE budget). Its output is registered (ic_q*) before the
    // compare, so the hit decision and the hit data into k_din are
    // ordinary single-cycle paths. A hit costs 3 clocks from DECIDE to the
    // step, against 7+ for fast RAM and ~45 for the ROM over the 7M bus.
    // ------------------------------------------------------------------
    localparam integer IC_N  = 1 << IC_AW;
`ifdef TG68_PREDICT
    // ------------------------------------------------------------------
    // TG68_PREDICT -- next-address prediction (a define, not a parameter:
    // without it this file is the original text, and the released
    // bitstreams stay reproducible bit for bit)
    //
    // A cache hit costs SETTLE + DECIDE + CLOOK + CCMP + FINISH, and the
    // cache RAMs sit idle during SETTLE while the kernel's address settles.
    // Over 90% of cache hits are to the previous access of the same kind
    // plus one word (devboard/tg68_harness/SEQ_PREDICT.md). Here the RAMs
    // are read at that predicted address during SETTLE (fetches from the
    // instruction cache, data reads from the data cache, each with its own
    // prediction); the data and tag are registered SETTLE-2 clocks after
    // the step and the tag compared at SETTLE-1, so at DECIDE a hit needs
    // only "kernel address == prediction" and goes straight to FINISH, like
    // a prefetch-buffer hit: 2 clocks less. A wrong guess costs nothing:
    // the normal lookup from the kernel's address runs as before.
    //
    // Coherency: a cache entry can only change under a prediction through a
    // CPU write (fills always carry the memory contents). A write's cache
    // update lands up to two clocks after its DECIDE, possibly on the edge
    // the speculative read uses, so any write to a predicted word kills
    // that prediction until the next access of its kind. (With the current
    // pacing the update always lands earlier; the kill is a safety net.)
    // Needs SETTLE >= 3 (read, register, compare).
    // ------------------------------------------------------------------
    reg  [31:1]      pr_f = 31'd0, pr_d = 31'd0;    // predicted next fetch / data read
    reg  [15:0]      pr_fd, pr_dd;                  // speculative data and tags
    reg  [TAGW-1:0]  pr_ft, pr_dt;
    reg              pr_fh = 1'b0, pr_dh = 1'b0;    // ...and their tag hits
    reg              pr_fk = 1'b0, pr_dk = 1'b0;    // killed by a write
    reg              pr_rs = 1'b1;  // == (q == Q_SETTLE), as its own register:
                                    // it steers the cache RAM read address
`endif
    localparam integer TAGW  = 1 + 2 + (23 - IC_AW);     // valid, region, a[23:IC_AW+1]

    (* ram_style = "block" *) reg [15:0]     ic_data [0:IC_N-1];
    (* ram_style = "block" *) reg [TAGW-1:0] ic_tag  [0:IC_N-1];
    integer ic_i;
    initial for (ic_i = 0; ic_i < IC_N; ic_i = ic_i + 1) begin
        ic_data[ic_i] = 16'd0;
        ic_tag[ic_i]  = {TAGW{1'b0}};
    end

    wire [IC_AW-1:0] ic_ra = k_addr[IC_AW:1];
`ifdef TG68_PREDICT
    // during SETTLE the read ports look up the predictions instead
    wire [IC_AW-1:0] pr_ic_ra = pr_rs ? pr_f[IC_AW:1] : ic_ra;
    wire [IC_AW-1:0] pr_dc_ra = pr_rs ? pr_d[IC_AW:1] : ic_ra;
`define TG_IC_RA pr_ic_ra
`define TG_DC_RA pr_dc_ra
`else
`define TG_IC_RA ic_ra
`define TG_DC_RA ic_ra
`endif
    reg  [15:0]      ic_dq;
    reg  [TAGW-1:0]  ic_tq;
    reg              ic_we = 1'b0;
    reg  [IC_AW-1:0] ic_wa;
    reg  [15:0]      ic_wd;
    reg  [TAGW-1:0]  ic_wt;
    always @(posedge clk) begin
        ic_dq <= ic_data[`TG_IC_RA];
        ic_tq <= ic_tag[`TG_IC_RA];
        if (ic_we) begin
            ic_data[ic_wa] <= ic_wd;
            ic_tag[ic_wa]  <= ic_wt;
        end
    end

    reg  [15:0]      ic_qd;            // registered cache outputs
    reg  [TAGW-1:0]  ic_qt;
    reg              ic_flush = 1'b1;  // sweeping all entries invalid
    reg  [IC_AW-1:0] ic_fcnt = {IC_AW{1'b0}};
    reg              cyc_fetch = 1'b0; // current bus cycle is a fetch

    // Cacheability and tag of the cycle in a_r (stable from DECIDE on).
    wire ic_rom  = (a_r[31:19] == 13'h001F);              // $F80000-$FFFFFF
    wire ic_ok   = (ICACHE != 0) && (ic_rom || icache_win);
    wire [TAGW-1:0] ic_want = {1'b1, (a_r[31:24] == 8'h08), (a_r[31:24] == 8'h00),
                               a_r[23:IC_AW+1]};
    // ic_on/dc_on are registered (they sit at the head of DECIDE's whole
    // decision tree). They use the flush flag's NEXT value, so they are
    // exactly "EI and not flushing" in every clock; only CACR is a clock
    // late, and the next DECIDE is >= SETTLE clocks after the MOVEC step.
    reg  mr_act_d = 1'b0;  // MapROM state last clock (flush on change)
    wire flush_trig = extReset || !oRESETn || (mr_active != mr_act_d);
    wire flush_nxt  = flush_trig || (ic_flush && !(&ic_fcnt));
    reg  ic_on_r = 1'b0, dc_on_r = 1'b0;
    wire ic_on   = ic_on_r;

    // ------------------------------------------------------------------
    // DCACHE -- data cache
    //
    // Same geometry, tags and cacheable area as the instruction cache
    // (2^IC_AW 16-bit words, direct-mapped; on-board fast RAM and the
    // Kickstart ROM), in its own block RAM, for data reads (busstate 10).
    // It shares the lookup pipeline: the RAMs are read from the kernel's
    // address on the DECIDE edge, CLOOK registers whichever cache this cycle
    // uses into ic_qd/ic_qt, and CCMP compares. So the compare and the hit
    // path into k_din are the instruction cache's, unchanged.
    //
    // Write-through. Every CPU write reaches memory as before. A whole-word
    // write to fast RAM also writes the cache entry (allocate), so a value
    // just stored reads back from the cache; a byte write, or any write to
    // a cacheable address that is not plain fast RAM (MapROM loading),
    // invalidates the entry instead. The CPU is the only writer of on-board
    // fast RAM (the SD card does not write memory, and nothing else on the
    // motherboard can reach this RAM), so that keeps the cache exact.
    // Filled on a data read miss, and by the next-word prefetch, so a
    // sequential read caches every word, not every other one.
    //
    // ENABLE: there is no data cache on a real 68020, and its CACR has no
    // data cache bits. Exec, SysInfo and most CPU checks tell a 68020 from
    // a 68030 by setting the 68030's data-cache enable bit (CACR bit 8) and
    // reading it back, so storing it would make this CPU look like a 68030
    // (and invite MMU code). So the data cache follows EI (CACR bit 0): it is
    // on whenever the instruction cache is. SysInfo's/CPU's "data cache"
    // switch does nothing, exactly as on a real 68020. FI freezes only the
    // instruction cache. DCACHE=0 removes the data cache from the build.
    //
    // Both caches are flushed after any reset and whenever MapROM is
    // switched on or off, since the ROM addresses then return other data.
    // ------------------------------------------------------------------
    wire [15:0]      dc_dq;
    wire [TAGW-1:0]  dc_tq;
    reg              dc_we = 1'b0;
    reg  [IC_AW-1:0] dc_wa;
    reg  [15:0]      dc_wd;
    reg  [TAGW-1:0]  dc_wt;
    generate if (DCACHE != 0) begin : g_dcache
        (* ram_style = "block" *) reg [15:0]     dc_data [0:IC_N-1];
        (* ram_style = "block" *) reg [TAGW-1:0] dc_tag  [0:IC_N-1];
        reg [15:0]     dq;
        reg [TAGW-1:0] tq;
        integer i;
        initial for (i = 0; i < IC_N; i = i + 1) begin
            dc_data[i] = 16'd0;
            dc_tag[i]  = {TAGW{1'b0}};
        end
        always @(posedge clk) begin
            dq <= dc_data[`TG_DC_RA];
            tq <= dc_tag[`TG_DC_RA];
            if (dc_we) begin
                dc_data[dc_wa] <= dc_wd;
                dc_tag[dc_wa]  <= dc_wt;
            end
        end
        assign dc_dq = dq;
        assign dc_tq = tq;
    end else begin : g_no_dcache
        assign dc_dq = 16'd0;
        assign dc_tq = {TAGW{1'b0}};
    end endgenerate

    wire dc_on   = dc_on_r;
    // the tag an address would have (same layout as ic_want)
    function [TAGW-1:0] tag_of(input [31:1] ad);
        tag_of = {1'b1, (ad[31:24] == 8'h08), (ad[31:24] == 8'h00), ad[23:IC_AW+1]};
    endfunction
    wire k_rom   = (k_addr[31:19] == 13'h001F);           // $F80000-$FFFFFF
    reg  pf_dc   = 1'b0;   // the prefetch in flight may fill the data cache
    reg  pf_fill = 1'b0;   // prefetched word arrived: write it to the cache
    // A posted write updates the caches one clock after DECIDE, from the
    // registers DECIDE latched (a_r, dp_wdata), so none of DECIDE's branch
    // logic reaches the cache write ports. The next lookup is >= SETTLE
    // clocks away. Instruction cache: entry dropped. Data cache: a whole
    // word in plain fast RAM is written in (write-through, allocate);
    // anything else drops the entry.
    reg  pw_upd = 1'b0;
    reg  pw_dc  = 1'b0;    // ...and the data-cache entry becomes valid
    //
    // OVERLAP. A cache lookup does not need the SDRAM, so it may start while
    // a posted write, a prefetch or a discarded read is still finishing in
    // the background (only a miss then waits, in CFREE). Before, every
    // access waited for the port to go idle, instruction-cache hits included.
    // The one exception: a data read of the very word being prefetched waits
    // in DECIDE, as before, and takes it from the buffer.
    //
    // SPECULATIVE READ. A data read from fast RAM is sent to the SDRAM at
    // DECIDE, alongside the lookup, so a miss costs nothing extra. On a hit
    // the read is left to finish in the background and its data dropped
    // (it becomes dp_kind 2, like a posted write). The controller cannot
    // answer before CCMP: its quickest request->ack is 3 clocks, CCMP is 2
    // (the test bench checks this).
    reg  dp_spec = 1'b0;   // this lookup has a speculative read in flight
    wire k_look  = ((ICACHE != 0) && k_bs == 2'b00 && ic_on)
                 || ((DCACHE != 0) && k_bs == 2'b10 && dc_on && (k_fast || k_rom));
    wire pf_wait = (dp_kind == 2'd3) && (k_addr[31:1] == pf_a);

    // ------------------------------------------------------------------
    // DIRECT -- direct SDRAM path for on-board fast RAM
    //
    // A fast RAM access through the 68000-style slave costs ~17 clocks, of
    // which the SDRAM needs ~5: the rest is address setup, the strobe
    // register, DTACK and the data-latch delay. Here the adapter decides
    // "this is fast RAM" itself and asks the SDRAM controller directly
    // through fastmem_zii's dp_* port. No AS/DS is driven, so neither the
    // motherboard nor any other slave sees the cycle.
    //
    // The decision is made from the kernel's address at DECIDE, so it is a
    // kernel -> logic path (SETTLE budget), using the fast RAM block's
    // static slot assignment. Exactly fastmem_zii's own window: Zorro II
    // slots it owns, and $08000000-$08FFFFFF. MapROM and everything else
    // keep the old route.
    //
    // dp_req_i is the decision; dp_req is a plain copy one clock later, so
    // the register that feeds the SDRAM command logic can sit beside it
    // (the same reason as the strobe pipeline). fastmem_zii's saddr_r tracks
    // a_r one clock behind, so it is valid by the time the controller sees
    // the request. Read data is captured into dp_q before it goes to the
    // kernel, so no new path into k_din is longer than one clock from a
    // register.
    // ------------------------------------------------------------------
    wire [3:0] k_reg  = k_addr[23:20];
    wire [2:0] k_slot = k_reg[2:0] - 3'd2;
    wire k_z2    = fm_on && (k_addr[31:24] == 8'h00) && (k_reg >= 4'h2) && (k_reg <= 4'h9)
                   && fm_match[k_slot];
    wire k_cpuw  = cpu_win_en && (k_addr[31:24] == 8'h08);
    // MapROM banks, exactly fastmem_zii's mr_win: $F80000-$FFFFFF and
    // $E00000-$E7FFFF. Reads go to the shadow when ACTIVE, writes when LOAD;
    // otherwise these addresses take the old route to the motherboard.
    wire k_mrwin = (k_addr[31:24] == 8'h00)
                   && (k_addr[23:19] == 5'b11111 || k_addr[23:19] == 5'b11100);
    wire k_mr    = k_mrwin && (k_nwr ? mr_active : mr_load);
    wire k_fast  = (DIRECT != 0) && (k_z2 || k_cpuw || k_mr);
    //
    // Two things keep the CPU from waiting on the SDRAM at all:
    //   * POSTED WRITES. A fast RAM write is handed to the controller and
    //     the CPU steps on at once; the write completes while the kernel
    //     settles its next step.
    //   * NEXT-WORD PREFETCH. After a fast RAM data read of word A, the
    //     controller is immediately asked for A+2 (same row, so cheap) into
    //     a one-word buffer. The second half of a longword, or the next word
    //     of a sequential read, is then answered from the buffer.
    // Only one request is ever in flight (dp_busy). Nothing that needs the
    // SDRAM -- a direct access, or an old-route cycle that fastmem_zii
    // might serve (MapROM) -- starts until it has finished. The CPU is the
    // only writer of fast RAM, so the buffer stays correct by dropping it
    // on any write to its word, and on reset.
    reg         dp_req_i = 1'b0;
    reg         dp_fast  = 1'b0;   // current cycle is a fast RAM cycle
    reg  [15:0] dp_q;
    reg         dp_busy  = 1'b0;   // a request is in flight
    reg  [1:0]  dp_kind  = 2'd0;   // 1 read (sequencer), 2 posted write, 3 prefetch
    reg         pf_valid = 1'b0;
    reg  [31:1] pf_a;      // written only when a prefetch is issued (DDATA);
                           // every use is >= 4 clocks later (next DECIDE,
                           // or the fill after its ack): a 2T source
    reg  [15:0] pf_d;
    always @(posedge clk) begin
        dp_req <= dp_req_i;
    end
    // dp_inc is raised the clock BEFORE dp_req_i for a prefetch (at the
    // read's ack), so fastmem_zii's SDRAM address register holds the next
    // word for two clocks before the controller samples it; it drops when
    // the prefetch is acknowledged. eab_early lets that register follow the
    // kernel's address, which is final at DECIDE, rather than eab.
    assign eab_early = k_addr[31:1];
    // fastmem_zii freezes its SDRAM address while a request is outstanding:
    // after a posted write or a prefetch is issued the kernel steps on and
    // its address moves, and the controller may accept the request late
    // (refresh). dp_busy is set on the very edge the address is captured.
    assign dp_hold = dp_busy;
    // k_fast too: if MapROM was switched off after a shadow word was
    // prefetched, that address now belongs to the motherboard ROM again.
    wire k_pf_hit = (DIRECT != 0) && pf_valid && (k_bs == 2'b10) && k_nwr
                    && (k_addr[31:1] == pf_a) && k_fast;

    // ------------------------------------------------------------------
    // STROBE PIPELINE
    // The sequencer drives as_i/uds_i/lds_i; the ports are those, one clock
    // later. Every bus consumer (motherboard bridge, fast RAM, turbomem, SD,
    // hi_null) sees the same delayed strobes, so their relative timing is
    // unchanged. The point is placement: this register can sit next to the
    // slaves, where DS feeds the fast RAM request and the SDRAM command
    // logic within one 86 MHz clock, instead of beside the CPU core on the
    // far side of the chip. Costs one clock per bus cycle. The sequencer
    // already waits for DTACK, so a slave answering a clock later needs no
    // change, and read data is latched while the port AS is still low.
    reg as_i = 1'b1, uds_i = 1'b1, lds_i = 1'b1;
    always @(posedge clk) begin
        ASn  <= as_i;
        UDSn <= uds_i;
        LDSn <= lds_i;
    end
    reg [5:0] cnt  = 6'd0;   // clocks since last clkena (saturating)
    reg [5:0] tmr  = 6'd0;   // per-state timer
    reg       bus_berr = 1'b0;

    // Watchdog for the stall LED: ~2^23 clocks = ~98 ms
    reg [23:0] wd = 24'd0;

    // Registered "previous cycle's DTACK/BERR have gone": only a guard
    // before starting a cycle, so one clock stale is fine, and it keeps the
    // slaves' combinational DTACK out of the bus-output register enables.
    reg  ack_idle = 1'b1;
    always @(posedge clk) ack_idle <= DTACKn & BERRn;

    wire internal_step = (k_bs == 2'b01) || (k_bs == 2'b00 && k_skip);
    wire bus_free      = BGn && BGACKn && BRn && HALTn;
    // CLOOK/CCMP count: a miss goes straight on to a bus cycle.
    wire in_cycle      = (q == Q_SETUP) || (q == Q_WDS) || (q == Q_WAIT)
                       || (q == Q_LATCH) || (q == Q_CLOOK) || (q == Q_CCMP)
                       || (q == Q_DWAIT) || (q == Q_DDATA) || (q == Q_CFREE)
                       || ~as_i || ~ASn;

    always @(posedge clk) begin
        k_clkena <= 1'b0;
        ic_we    <= 1'b0;
        dc_we    <= 1'b0;
        mr_act_d <= mr_active;
        ic_on_r  <= (ICACHE != 0) && k_cacr[0] && !flush_nxt;
        dc_on_r  <= (DCACHE != 0) && k_cacr[0] && !flush_nxt;
        if (cnt != 6'h3F) cnt <= cnt + 6'd1;
        if (tmr != 6'h3F) tmr <= tmr + 6'd1;

        // ---- bus arbitration (68000 rules, between cycles only) ------
        if (!BGACKn)                BGn <= 1'b1;   // new master has it
        else if (!BRn && !in_cycle) BGn <= 1'b0;
        else if (BRn)               BGn <= 1'b1;

        if (extReset) begin
            // Hold the kernel in reset, but keep stepping it: its internal
            // synchronous Reset only advances on clkena.
            k_nreset <= 1'b0;
            as_i  <= 1'b1; uds_i <= 1'b1; lds_i <= 1'b1; eRWn <= 1'b1;
            oRESETn  <= 1'b1;
            k_berr   <= 1'b0;
            dp_req_i <= 1'b0;
            dp_busy  <= 1'b0; dp_kind <= 2'd0;
            dp_inc   <= 1'b0;
            pf_valid <= 1'b0;
            pf_fill  <= 1'b0; pf_dc <= 1'b0;
            pw_upd   <= 1'b0;
            dp_spec  <= 1'b0;
            stalled  <= 1'b0;
            wd       <= 24'd0;
            q        <= Q_SETTLE;
`ifdef TG68_PREDICT
            pr_rs    <= 1'b1;
`endif
            if (cnt >= STEP - 1) begin
                k_clkena <= 1'b1;
                cnt      <= 6'd0;
                k_ipl    <= {IPL2n, IPL1n, IPL0n};
            end
        end else begin
            // The prefetched word goes into the data cache one clock after
            // it arrives (from pf_d, a register). Written before the case so
            // any cache write the sequencer makes on this edge (a posted
            // write to the same word, say) wins; a lost fill is only a miss.
            // (dp_q holds the prefetched word too, so every data-cache fill
            // takes its data from dp_q or iEdb.) pf_fill and pw_upd never
            // fall on the same clock: a posted write needs the port idle at
            // DECIDE, which is at the earliest the clock pf_fill is set.
`ifdef TG68_PREDICT
            if (q == Q_SETTLE) begin
                if (cnt == SETTLE - 2) begin
                    pr_fd <= ic_dq; pr_ft <= ic_tq;
                    pr_dd <= dc_dq; pr_dt <= dc_tq;
                end
                if (cnt == SETTLE - 1) begin
                    pr_fh <= (pr_ft == tag_of(pr_f));
                    pr_dh <= (pr_dt == tag_of(pr_d));
                end
            end
`endif
            if (pf_fill) begin
                pf_fill <= 1'b0;
                dc_wa <= pf_a[IC_AW:1]; dc_wt <= tag_of(pf_a); dc_wd <= dp_q;
                if (dc_on) dc_we <= 1'b1;
            end
            if (pw_upd) begin
                pw_upd <= 1'b0;
                if (ICACHE != 0 && !ic_flush) begin
                    ic_we <= 1'b1; ic_wa <= a_r[IC_AW:1]; ic_wt <= {TAGW{1'b0}};
                end
                if (DCACHE != 0) begin
                    dc_we <= 1'b1; dc_wa <= a_r[IC_AW:1];
                    dc_wt <= ic_want; dc_wt[TAGW-1] <= pw_dc;
                    dc_wd <= dp_wdata;
                end
            end
            case (q)
            // ----------------------------------------------------------
`ifdef TG68_PREDICT
            Q_SETTLE: if (cnt >= SETTLE - 1) begin q <= Q_DECIDE; pr_rs <= 1'b0; end
`else
            Q_SETTLE: if (cnt >= SETTLE - 1) q <= Q_DECIDE;
`endif
            // ----------------------------------------------------------
            Q_DECIDE: begin
                // nResetOut is combinational in the kernel; only trust it
                // here, after the outputs have settled. A glitch would
                // reset every peripheral on the motherboard.
                oRESETn <= k_nresetout;
                if (internal_step) begin
                    if (cnt >= STEP - 1) step();
                end else if (k_pf_hit && !dp_busy) begin
                    // second half of a longword / next sequential word:
                    // already fetched, no SDRAM access at all
                    k_din    <= pf_d;
                    bus_berr <= 1'b0;
                    tmr      <= 6'd0;
                    q        <= Q_FINISH;
`ifdef TG68_PREDICT
                    pr_d     <= k_addr[31:1] + 31'd1; pr_dk <= 1'b0;
                end else if (k_bs == 2'b00 && ic_on && pr_fh && !pr_fk
                             && k_addr[31:1] == pr_f) begin
                    // predicted fetch, looked up during SETTLE: a hit
                    k_din    <= pr_fd;
                    bus_berr <= 1'b0;
                    tmr      <= 6'd0;
                    q        <= Q_FINISH;
                    pr_f     <= k_addr[31:1] + 31'd1;
                end else if (k_bs == 2'b10 && k_nwr && dc_on && (k_fast || k_rom)
                             && pr_dh && !pr_dk && k_addr[31:1] == pr_d) begin
                    // predicted data read: a hit
                    k_din    <= pr_dd;
                    bus_berr <= 1'b0;
                    tmr      <= 6'd0;
                    q        <= Q_FINISH;
                    pr_d     <= k_addr[31:1] + 31'd1;
`endif
                end else if (bus_free && ack_idle && (!dp_busy || (k_look && !pf_wait))) begin
                    a_r      <= k_addr[31:1];
                    fc_r     <= k_fc;
                    eRWn     <= k_nwr;          // RW valid before AS, like S1
                    oEdb     <= k_dout;
                    uds_want <= k_nuds;
                    lds_want <= k_nlds;
                    tmr      <= 6'd0;
                    cyc_fetch <= (k_bs == 2'b00);
                    dp_fast   <= k_fast;
`ifdef TG68_PREDICT
                    if (k_bs == 2'b00) begin pr_f <= k_addr[31:1] + 31'd1; pr_fk <= 1'b0; end
                    if (k_bs == 2'b10 && k_nwr) begin pr_d <= k_addr[31:1] + 31'd1; pr_dk <= 1'b0; end
                    if (!k_nwr) begin   // a write: drop predictions of this word
                        if (k_addr[31:1] == pr_f) pr_fk <= 1'b1;
                        if (k_addr[31:1] == pr_d) pr_dk <= 1'b1;
                    end
`endif
                    // the port's write data belong to a request still in
                    // flight, if there is one
                    if (!dp_busy) begin
                        dp_we    <= ~k_nwr;
                        dp_wdata <= k_dout;
                        dp_be    <= ~{k_nuds, k_nlds};
                    end
                    dp_spec  <= 1'b0;
                    // The cache RAMs read on this edge used k_addr already.
                    if (k_look) begin
                        q <= Q_CLOOK;            // look in the cache first
                        if (k_bs == 2'b10 && k_fast && !dp_busy) begin
                            dp_req_i <= 1'b1;    // speculative read
                            dp_busy  <= 1'b1; dp_kind <= 2'd1;
                            dp_spec  <= 1'b1;
                        end
                    end else if (k_fast && !k_nwr) begin
                        // posted write: issue it and step on
                        dp_req_i <= 1'b1;
                        dp_busy  <= 1'b1; dp_kind  <= 2'd2;
                        if (pf_valid && k_addr[31:1] == pf_a) pf_valid <= 1'b0;
                        // the caches are updated on the next clock (pw_upd)
                        pw_upd <= 1'b1;
                        pw_dc  <= dc_on && !k_nuds && !k_nlds && (k_z2 || k_cpuw);
                        bus_berr <= 1'b0;
                        tmr      <= 6'd0;
                        q        <= Q_FINISH;
                    end else if (k_fast) begin
                        dp_req_i <= 1'b1;   // direct read
                        dp_busy  <= 1'b1; dp_kind  <= 2'd1;
                        q        <= Q_DWAIT;
                    end else
                        q <= Q_SETUP;
                end
            end
            // ----------------------------------------------------------
            // ic_qd/ic_qt carry whichever cache this cycle uses
            Q_CLOOK: begin
                ic_qd <= cyc_fetch ? ic_dq : dc_dq;
                ic_qt <= cyc_fetch ? ic_tq : dc_tq;
                q     <= Q_CCMP;
            end
            // icache_win is one clock behind a_r, which changed at DECIDE,
            // so it is valid here.
            Q_CCMP: begin
                tmr <= 6'd0;
                dp_spec <= 1'b0;
                // k_din is loaded whether or not this is a hit, so the tag
                // compare only steers the state, not the data register. On
                // a miss it is overwritten before the kernel steps.
                k_din   <= ic_qd;
                if (ic_ok && ic_qt == ic_want && (cyc_fetch ? ic_on : dc_on)) begin
                    bus_berr <= 1'b0;        // hit: no bus cycle at all
                    q        <= Q_FINISH;
                    if (dp_spec) dp_kind <= 2'd2;   // drop the speculative read
                end else if (dp_spec) begin
                    q        <= Q_DWAIT;     // miss: the read is already out
                end else if (dp_busy) begin
                    q        <= Q_CFREE;     // miss: port still busy
                end else if (dp_fast) begin
                    dp_req_i <= 1'b1;        // miss in fast RAM: direct
                    dp_busy  <= 1'b1; dp_kind <= 2'd1;
                    dp_we    <= 1'b0;
                    q        <= Q_DWAIT;
                end else begin
                    q        <= Q_SETUP;     // miss: address is already out
                end
            end
            // A miss that found the port busy. fastmem_zii's SDRAM address
            // follows the kernel's address again from the clock after the
            // port frees, so issuing here gives it the same two clocks as
            // a request from DECIDE.
            Q_CFREE: if (!dp_busy) begin
                if (dp_fast) begin
                    dp_req_i <= 1'b1;
                    dp_busy  <= 1'b1; dp_kind <= 2'd1;
                    dp_we    <= 1'b0;
                    q        <= Q_DWAIT;
                end else
                    q        <= Q_SETUP;
            end
            // ----------------------------------------------------------
            Q_DWAIT: if (dp_ack) begin
                dp_q     <= dp_rdata;
                dp_req_i <= 1'b0;
                dp_busy  <= 1'b0; dp_kind <= 2'd0;
                // a data read will be followed by a prefetch: point the
                // SDRAM address at the next word now
                if (!cyc_fetch && (a_r[9:1] != 9'h1FF)) dp_inc <= 1'b1;
                q        <= Q_DDATA;
            end
            Q_DDATA: begin
                // Cache fills (only reads come here: writes are posted).
                // Address, tag and data load regardless; the conditions
                // only drive the write enables.
                ic_wa <= a_r[IC_AW:1]; ic_wt <= ic_want; ic_wd <= dp_q;
                if (ic_ok && !ic_flush && cyc_fetch && ic_on && !k_cacr[1])
                    ic_we <= 1'b1;
                // data-cache fill (address/tag/data loaded regardless; only
                // the write enable depends on the conditions)
                dc_wa <= a_r[IC_AW:1]; dc_wt <= ic_want; dc_wd <= dp_q;
                if (DCACHE != 0 && ic_ok && eRWn && !cyc_fetch && dc_on)
                    dc_we <= 1'b1;
                k_din    <= dp_q;
                bus_berr <= 1'b0;
                tmr      <= 6'd0;
                q        <= Q_FINISH;
                // Data read: fetch the next word while the kernel settles,
                // unless that would leave this 1 KB (row/slot boundaries).
                if (!cyc_fetch && (a_r[9:1] != 9'h1FF)) begin
                    dp_req_i <= 1'b1;
                    dp_busy  <= 1'b1; dp_kind  <= 2'd3;
                    dp_we    <= 1'b0;
                    pf_a     <= a_r + 31'd1;
                    pf_valid <= 1'b0;
                    pf_dc    <= (DCACHE != 0) && ic_ok && dc_on;
                end
            end
            // ----------------------------------------------------------
            Q_SETUP: if (tmr >= ADDR_SETUP - 1) begin
                as_i <= 1'b0;
                tmr <= 6'd0;
                if (eRWn) begin                 // read: DS with AS
                    uds_i <= uds_want;
                    lds_i <= lds_want;
                    q    <= Q_WAIT;
                end else begin
                    q    <= Q_WDS;
                end
            end
            // ----------------------------------------------------------
            Q_WDS: if (tmr >= WDS_DELAY - 1) begin
                uds_i <= uds_want;
                lds_i <= lds_want;
                q    <= Q_WAIT;
            end
            // ----------------------------------------------------------
            Q_WAIT: begin
                if (!DTACKn || !BERRn) begin
                    bus_berr <= ~BERRn & DTACKn;
                    tmr      <= 6'd0;
                    q        <= Q_LATCH;
                end
            end
            // ----------------------------------------------------------
            Q_LATCH: begin
                // The data registers load on every LATCH clock; the last
                // load, on the edge that leaves LATCH, is the one that
                // counts. Only the write enables and the state change wait
                // for the timer, which keeps its compare out of their paths.
                ic_wd <= iEdb;
                ic_wa <= a_r[IC_AW:1]; ic_wt <= ic_want;
                ic_wt[TAGW-1] <= eRWn;   // a write only invalidates
                dc_wa <= a_r[IC_AW:1]; dc_wt <= ic_want; dc_wd <= iEdb;
                dc_wt[TAGW-1] <= eRWn;   // a write only invalidates
                k_din <= bus_berr ? 16'hFFFF : iEdb;
                if (tmr >= DATA_DELAY - 1) begin
                    // Cache fill on a fetch miss; invalidate on any write.
                    if (ic_ok && !ic_flush
                        && (!eRWn || (cyc_fetch && ic_on && !k_cacr[1] && !bus_berr)))
                        ic_we <= 1'b1;
                    // Data cache: invalidate on a write; fill on a whole-
                    // word read (a byte read over the motherboard bus need
                    // not drive the other byte).
                    if (DCACHE != 0 && ic_ok
                        && (!eRWn || (!cyc_fetch && dc_on && !bus_berr && !uds_want && !lds_want)))
                        dc_we <= 1'b1;
                    k_berr <= bus_berr;   // seen by the clkena that ends the cycle
                    as_i   <= 1'b1;
                    uds_i  <= 1'b1;
                    lds_i  <= 1'b1;
                    tmr   <= 6'd0;
                    q     <= Q_FINISH;
                end
            end
            // ----------------------------------------------------------
            // R/W, address and write data stay where they are: a slave may
            // latch a write on the AS rising edge, and the bridge holds the
            // motherboard copy for one more clock. They change only when
            // the next cycle is set up, >= SETTLE clocks from now.
            Q_FINISH: if (tmr >= DIN_SETUP - 1 && cnt >= STEP - 1) step();
`ifdef TG68_PREDICT
            default: begin q <= Q_SETTLE; pr_rs <= 1'b1; end
`else
            default: q <= Q_SETTLE;
`endif
            endcase

            // Posted writes and prefetches complete in the background. (A
            // read's second ack pulse, one clock after the first, arrives
            // with dp_kind already 0 and is ignored.)
            if (dp_ack && dp_kind == 2'd2) begin
                dp_req_i <= 1'b0; dp_busy <= 1'b0; dp_kind <= 2'd0;
            end
            if (dp_ack && dp_kind == 2'd3) begin
                dp_req_i <= 1'b0; dp_busy <= 1'b0; dp_kind <= 2'd0;
                dp_inc   <= 1'b0;
                pf_d <= dp_rdata; pf_valid <= 1'b1;
                dp_q <= dp_rdata;          // for the data-cache fill
                pf_fill <= pf_dc;
            end

            // Stall watchdog (diagnostic only): a cycle no slave answers.
            if (q == Q_WAIT || q == Q_DWAIT || q == Q_CFREE) begin
                if (!wd[23]) wd <= wd + 24'd1;
                else         stalled <= 1'b1;
            end else begin
                wd <= 24'd0;
                stalled <= 1'b0;
            end
        end

        // Cache flush: after any reset (external, or the RESET instruction,
        // which re-runs autoconfig). Takes 2^IC_AW clocks (~48 us at 8 KB);
        // the cache is simply off meanwhile. Flush writes win the RAM port:
        // fills are already blocked, and an invalidate lost here is covered
        // by the sweep.
        // Both caches share the sweep. MapROM switching on or off changes
        // what the ROM addresses return, so it flushes too.
        if (flush_trig) begin
            ic_flush <= 1'b1;
            ic_fcnt  <= {IC_AW{1'b0}};
        end else if (ic_flush) begin
            ic_we   <= 1'b1;
            ic_wa   <= ic_fcnt;
            ic_wt   <= {TAGW{1'b0}};
            dc_we   <= 1'b1;
            dc_wa   <= ic_fcnt;
            dc_wt   <= {TAGW{1'b0}};
            ic_fcnt <= ic_fcnt + 1'b1;
            if (&ic_fcnt) ic_flush <= 1'b0;
        end

        // nReset is released on a clkena edge so it is stable for the
        // kernel's next STEP clocks.
        if (!extReset && k_clkena) k_nreset <= 1'b1;
    end

    // One kernel step. IPL is re-sampled on the same edge so it is stable
    // for the next STEP clocks; base64_top already debounces it on the 7M
    // grid. berr is held for exactly the step that consumes it.
    task step;
        begin
            k_clkena <= 1'b1;
            cnt      <= 6'd0;
            k_ipl    <= {IPL2n, IPL1n, IPL0n};
            k_berr   <= 1'b0;     // the kernel samples the old value here
            q        <= Q_SETTLE;
`ifdef TG68_PREDICT
            pr_rs    <= 1'b1;
`endif
        end
    endtask



    initial begin
        ASn = 1'b1; UDSn = 1'b1; LDSn = 1'b1; eRWn = 1'b1;
        BGn = 1'b1; oRESETn = 1'b1; oEdb = 16'd0; stalled = 1'b0;
        dp_inc = 1'b0;
    end

endmodule

`undef TG_IC_RA
`undef TG_DC_RA
`default_nettype wire
