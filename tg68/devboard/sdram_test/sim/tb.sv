`timescale 1ns/1ps
module tb;
    reg clk = 0; always #5.833 clk = ~clk;
    reg rst = 1; initial #200 rst = 0;
    wire req, we, ack, ready; wire [23:0] addr; wire [15:0] wdata, rdata; wire [1:0] be;
    wire tx, r, g, b;
    wire [12:0] sa; wire [1:0] sba, sdqm; wire [15:0] sdq; wire scke, scs, sras, scas, swe, sclk;
    sdram_test #(.CLK_HZ(85_714_286), .BAUD(10_000_000), .AW(`AW)) u_test (
        .clk(clk), .rst(rst), .uart_tx(tx), .led_r_on(r), .led_g_on(g), .led_b_on(b),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .byte_en(be),
        .ack(ack), .rdata(rdata), .ready(ready));
    sdram_ctrl #(.CLK_HZ(85_714_286), .CAS_LAT(2), .T_INIT_US(2)) u_sdram (
        .clk(clk), .reset(rst), .req(req), .we(we), .wr_valid(1'b1),
        .addr(addr), .wdata(wdata), .byte_en(be), .ack(ack), .ack_early(),
        .rdata_live(), .rdata(rdata), .ready(ready),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm), .sdram_clk(sclk),
        .sdram_cke(scke), .sdram_cs_n(scs), .sdram_ras_n(sras), .sdram_cas_n(scas), .sdram_we_n(swe));
    sdram_model_checked #(.CAS_LAT(2), .ADDR_BITS(`MB)) u_mem (
        .clk(~clk),   // ODDRX1F D0=0/D1=1: chip clock rises at our falling edge
        .a(sa), .ba(sba), .dq(sdq), .dqm(sdqm),
        .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas), .we_n(swe));
`ifdef INJECT
    // corrupt two cells between the write and read sweeps of pass 2 (and
    // stick DQ7 low for one read in pass 3): the test must report them
    initial begin
        wait (u_test.pass == 2 && u_test.st == 9);
        u_mem.mem[5]   = u_mem.mem[5]   ^ 16'h0080;
        u_mem.mem[300] = u_mem.mem[300] ^ 16'h4000;
        wait (u_test.pass == 3 && u_test.st == 9 && u_test.addr == 77);
        force rdata = u_sdram.rdata & 16'hFF7F; @(posedge clk); @(posedge clk); @(posedge clk); release rdata;
    end
`endif
    // UART decoder (10 Mbaud in sim)
    localparam integer BIT = 9; // clocks per bit = 85.7M/10M ~ 8
    integer k; reg [7:0] c;
    always begin
        @(negedge tx);
        repeat (u_test.DIV/2) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin repeat (u_test.DIV) @(posedge clk); c[k] = tx; end
        repeat (u_test.DIV) @(posedge clk);
        $write("%c", c);
    end
    initial begin
        wait (u_test.pass == `PASSES);
        repeat (2000) @(posedge clk);
        $display("\nSIM DONE: passes %0d total_errs %0d", u_test.pass, u_test.total_errs);
        $finish;
    end
endmodule
