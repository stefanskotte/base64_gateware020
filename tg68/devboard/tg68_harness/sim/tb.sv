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
    integer i;
    initial begin
        wait (seen_banner);
        $display("[tb] loader is up at %0t; sending %0d bytes", $time, `PKT_LEN);
        for (i = 0; i < `PKT_LEN; i = i + 1) send(pkt[i]);
        $display("[tb] sent; rx bytes %0d, overruns %0d", n_rxv, n_ovr);
        wait (seen_result);
        repeat (20000) @(posedge clk);
        $display("[tb] unmapped motherboard cycles: %0d", dut.u_mobo.unm_cnt);
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
