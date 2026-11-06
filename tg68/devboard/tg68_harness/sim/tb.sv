// tb.sv -- harness_top in simulation: the real core, bridge, fast RAM and
// mobo.v, with the checked SDRAM model on the SDRAM pins. The bench plays
// host/run.py: it sends build/uart_in.mem (B64L packet with the test
// program) to the ROM loader over the UART pin, prints everything the
// program sends back, and stops after the "RESULT:" line.
`timescale 1ns/1ps
`ifndef TMAX
`define TMAX 300ms
`endif
module tb;
    localparam integer BAUD = 1_000_000;      // fast UART for simulation
`ifdef X16
    localparam integer DIV  = 114_285_714 / BAUD;
    localparam         X16  = 1'b1;
    reg clk = 0;
    always #4.375 clk = ~clk;                 // 114.3 MHz (16 x 7.14 MHz)
`else
    localparam integer DIV  = 85_714_286 / BAUD;
    localparam         X16  = 1'b0;
    reg clk = 0;
    always #5.833 clk = ~clk;                 // 85.7 MHz (12 x 7.14 MHz)
`endif

    wire tx; reg rx = 1;
    wire [12:0] sa; wire [1:0] sba, sdqm; wire [15:0] sdq;
    wire sclk, scke, sras, scas, swe, scs;
    wire lr, lg, lb;
    wire sd_cmd; wire [3:0] sd_d;

`ifndef IC_AW
`define IC_AW 12
`endif
`ifndef DCACHE
`define DCACHE 1
`endif
    harness_top #(.PWRUP_BIT(12), .BAUD(BAUD), .X16(X16), .IC_AW(`IC_AW), .DCACHE(`DCACHE)) dut (
        .clk_25m(clk), .uart_tx(tx), .uart_rx(rx),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm),
        .sdram_clk(sclk), .sdram_cke(scke), .sdram_ras_n(sras),
        .sdram_cas_n(scas), .sdram_we_n(swe), .sdram_cs_n(scs),
        .sd_clk(), .sd_cmd(sd_cmd), .sd_d(sd_d),
        .led_r(lr), .led_g(lg), .led_b(lb));

    sdram_model_checked #(.CAS_LAT(2), .ADDR_BITS(24)) u_sdram (
        .clk(sclk), .a(sa), .ba(sba), .dq(sdq), .dqm(sdqm),
        .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas), .we_n(swe));

    // ---- host -> loader ----------------------------------------------------
    reg [7:0] pkt [0:`PKT_LEN-1];
    initial $readmemh("uart_in.mem", pkt);
    task send(input [7:0] b);
        integer k;
        rx = 0; repeat (DIV) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin rx = b[k]; repeat (DIV) @(posedge clk); end
        rx = 1; repeat (DIV * 2) @(posedge clk);
    endtask

    // ---- loader/program -> host ---------------------------------------------
    reg [8*80-1:0] line = 0;
    integer col = 0;
    reg seen_banner = 0, seen_result = 0, passed = 0;
    integer k2; reg [7:0] c;
    always begin
        @(negedge tx);
        repeat (DIV / 2) @(posedge clk);
        for (k2 = 0; k2 < 8; k2 = k2 + 1) begin repeat (DIV) @(posedge clk); c[k2] = tx; end
        repeat (DIV) @(posedge clk);
        if (c == 8'h0A) begin
            if (line[8*80-1 -: 8*17] == "B64 TG68 harness ") seen_banner = 1;
            if (line[8*80-1 -: 8*12] == "RESULT: PASS") passed = 1;
            if (line[8*80-1 -: 8*7]  == "RESULT:") seen_result = 1;
            line = 0; col = 0;
        end else if (c != 8'h0D) begin
            if (col < 80) line[8*80-1 - 8*col -: 8] = c;
            col = col + 1;
        end
        $write("%c", c);
        $fflush;
    end

    // receive-path counters, printed at the end
    integer n_rxv = 0, n_ovr = 0; reg pv = 0, po = 0;
    always @(posedge clk) begin
        pv <= dut.u_mobo.rx_valid; po <= dut.u_mobo.rx_ovr;
        if (dut.u_mobo.rx_valid && !pv) n_rxv = n_rxv + 1;
        if (dut.u_mobo.rx_ovr && !po) n_ovr = n_ovr + 1;
    end

`ifdef STATS
    // ---- cache-access statistics per benchmark (marker in mobo $DE0014) ----
    // For each cache lookup: hit or miss, fetch or data, and whether its
    // address is the previous same-kind access + 2 ("sequential"). Savings:
    //   next-address prediction: 2 clocks (CLOOK+CCMP) per sequential hit
    //   two-word entries (Glen): 2 clocks per sequential hit on the second
    //     (odd) word of an aligned longword
    localparam integer NB = 8;
    integer st_clk [0:NB-1], st_step [0:NB-1], st_pf [0:NB-1];
    integer st_lk [0:NB-1][0:1], st_hit [0:NB-1][0:1], st_seq [0:NB-1][0:1], st_odd [0:NB-1][0:1];
    integer st_dir [0:NB-1], st_bus [0:NB-1];
    reg [3:0]  q_p = 0;
    reg [30:0] ka_p = 0; reg knwr_p = 1, kint_p = 0;
    reg [30:0] last_a [0:1];
    reg        cur_seq = 0, cur_odd = 0; integer cur_t = 0;
    integer bi, bj;
    initial begin
        for (bi = 0; bi < NB; bi = bi + 1) begin
            st_clk[bi] = 0; st_step[bi] = 0; st_pf[bi] = 0; st_dir[bi] = 0; st_bus[bi] = 0;
            for (bj = 0; bj < 2; bj = bj + 1) begin
                st_lk[bi][bj] = 0; st_hit[bi][bj] = 0; st_seq[bi][bj] = 0; st_odd[bi][bj] = 0;
            end
        end
        last_a[0] = 0; last_a[1] = 0;
    end
    wire [3:0] q_n = dut.dut.cpu.q;
    integer m;
    always @(posedge clk) begin
        m = dut.u_mobo.mark;
        if (m >= NB) m = 0;
        st_clk[m] = st_clk[m] + 1;
        if (dut.dut.cpu.k_clkena) st_step[m] = st_step[m] + 1;
        // a lookup starts: DECIDE -> CLOOK (a_r/cyc_fetch are the new values)
        if (q_p == 4'd1 && q_n == 4'd7) begin
            cur_t   = dut.dut.cpu.cyc_fetch ? 0 : 1;
            cur_seq = (dut.dut.cpu.a_r[31:1] == last_a[cur_t] + 1);
            cur_odd = cur_seq && dut.dut.cpu.a_r[1];
            last_a[cur_t] = dut.dut.cpu.a_r[31:1];
            st_lk[m][cur_t] = st_lk[m][cur_t] + 1;
        end
        // prefetch-buffer hit on the direct path: DECIDE -> FINISH, a read
        if (q_p == 4'd1 && q_n == 4'd6 && knwr_p && !kint_p) begin
            st_pf[m] = st_pf[m] + 1; last_a[1] = ka_p;
        end
        if (q_p == 4'd1 && q_n == 4'd9) begin st_dir[m] = st_dir[m] + 1; if (knwr_p) last_a[1] = ka_p; end
        if (q_p == 4'd1 && q_n == 4'd2) st_bus[m] = st_bus[m] + 1;
        // the tag compare
        if (q_n == 4'd8 && dut.dut.cpu.ic_ok && dut.dut.cpu.ic_qt == dut.dut.cpu.ic_want
            && (cur_t == 0 ? dut.dut.cpu.ic_on : dut.dut.cpu.dc_on)) begin
            st_hit[m][cur_t] = st_hit[m][cur_t] + 1;
            if (cur_seq) st_seq[m][cur_t] = st_seq[m][cur_t] + 1;
            if (cur_odd) st_odd[m][cur_t] = st_odd[m][cur_t] + 1;
            cur_seq = 0; cur_odd = 0;
        end
        q_p <= q_n; ka_p <= dut.dut.cpu.k_addr[31:1];
        knwr_p <= dut.dut.cpu.k_nwr; kint_p <= dut.dut.cpu.internal_step;
    end
    task stats;
        integer b, sp, sg;
        $display("[stats] bench clocks steps | fetch: lookups hits seq odd | data: lookups hits seq odd | pf direct bus | save%%: predict glen");
        for (b = 1; b < NB; b = b + 1) if (st_clk[b] > 0) begin
            sp = 2 * (st_seq[b][0] + st_seq[b][1]);
            sg = 2 * (st_odd[b][0] + st_odd[b][1]);
            $display("[stats] %0d %0d %0d | %0d %0d %0d %0d | %0d %0d %0d %0d | %0d %0d %0d | %0.1f %0.1f",
                     b, st_clk[b], st_step[b], st_lk[b][0], st_hit[b][0], st_seq[b][0], st_odd[b][0],
                     st_lk[b][1], st_hit[b][1], st_seq[b][1], st_odd[b][1], st_pf[b], st_dir[b], st_bus[b],
                     100.0 * sp / st_clk[b], 100.0 * sg / st_clk[b]);
        end
    endtask
`endif
    integer i;
    initial begin
        wait (seen_banner);
        $display("[tb] loader is up at %0t; sending %0d bytes", $time, `PKT_LEN);
        for (i = 0; i < `PKT_LEN; i = i + 1) send(pkt[i]);
        $display("[tb] sent; rx bytes %0d, overruns %0d", n_rxv, n_ovr);
        wait (seen_result);
        repeat (20000) @(posedge clk);
        $display("[tb] unmapped motherboard cycles: %0d", dut.u_mobo.unm_cnt);
`ifdef STATS
        stats;
`endif
        // lr is the module pin, active low: high = red LED off
        if (passed && lr) $display("SIM PASS"); else $display("SIM FAIL");
        $finish;
    end
    initial begin #`TMAX; $display("[tb] TIMEOUT: rx bytes %0d, overruns %0d", n_rxv, n_ovr); $finish; end
endmodule

// behavioural ECP5 output DDR (as in tg68/sim/tb_top.sv)
module ODDRX1F (input D0, D1, SCLK, RST, output Q);
    assign Q = SCLK ? D0 : D1;
endmodule
