// iCESugar-Pro SDRAM soak test: 25 MHz -> PLL -> ~86 MHz, Base64's sdram_ctrl.
`default_nettype none
module top (
    input  wire        clk_25m,       // P6
    output wire        uart_tx,       // B9 -> iCELink CDC
    input  wire        uart_rx,       // A9 (unused)
    output wire        led_r, led_g, led_b,   // active low
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm,
    output wire        sdram_clk, sdram_cke, sdram_cs_n,
    output wire        sdram_ras_n, sdram_cas_n, sdram_we_n
);
`ifdef CLK50
    localparam integer HZ = 50_000_000;
    wire clk, locked;
    pll_50 u_pll (.clkin(clk_25m), .clkout0(clk), .locked(locked));
`else
    localparam integer HZ = 85_714_286;
    wire clk, locked;
    pll_86 u_pll (.clkin(clk_25m), .clkout0(clk), .locked(locked));
`endif
    reg [3:0] rst_sh = 4'hF;
    always @(posedge clk) rst_sh <= {rst_sh[2:0], ~locked};
    wire rst = rst_sh[3];

    wire req, we, ack, ready; wire [23:0] addr; wire [15:0] wdata, rdata; wire [1:0] be;
    wire r_on, g_on, b_on, sclk_int;
    sdram_test #(.CLK_HZ(HZ)) u_test (
        .clk(clk), .rst(rst), .uart_tx(uart_tx),
        .led_r_on(r_on), .led_g_on(g_on), .led_b_on(b_on),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .byte_en(be),
        .ack(ack), .rdata(rdata), .ready(ready));
    sdram_ctrl #(.CLK_HZ(HZ), .CAS_LAT(2)) u_sdram (
        .clk(clk), .reset(rst), .req(req), .we(we), .wr_valid(1'b1),
        .addr(addr), .wdata(wdata), .byte_en(be), .ack(ack), .ack_early(),
        .rdata_live(), .rdata(rdata), .ready(ready),
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dq(sdram_dq),
        .sdram_dqm(sdram_dqm), .sdram_clk(sclk_int), .sdram_cke(sdram_cke),
        .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n));
    // same as base64_tg68_top: clock out through an ODDR, D0/D1 = 0/1
    ODDRX1F u_sclk (.D0(1'b0), .D1(1'b1), .SCLK(clk), .RST(1'b0), .Q(sdram_clk));
    assign led_r = ~r_on; assign led_g = ~g_on; assign led_b = ~b_on;
endmodule
