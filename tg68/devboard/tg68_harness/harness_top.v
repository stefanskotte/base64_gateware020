// harness_top.v -- base64_tg68_top on a bare iCESugar-Pro.
//
// The 85.7 MHz master clock comes from the module's 25 MHz oscillator
// (on the Base64 it comes from the ICS570B). 7M is that divided by 12, as
// on the real board. The 68000 bus goes to mobo.v, a motherboard model,
// instead of the socket. The SDRAM, LEDs and SD pins are the real ones.
// UART on the iCELink: FPGA TX B9, RX A9, 115200 8N1.
//
// Build with -DDEVBOARD (see build.py).
`default_nettype none
module harness_top #(
    parameter integer PWRUP_BIT = 25,
    parameter integer BAUD      = 115_200
)(
    input  wire        clk_25m,
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm,
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire        sdram_cs_n,
    output wire        sd_clk,
    inout  wire        sd_cmd,
    inout  wire [3:0]  sd_d,
    output wire        led_r,       // module LED, active low
    output wire        led_g,
    output wire        led_b
);
    wire clk;
`ifdef SIM
    assign clk = clk_25m;           // the bench supplies 85.7 MHz directly
`else
    pll_86 u_pll (.clkin(clk_25m), .clkout0(clk), .locked());
`endif

    // 7M: 12 master clocks, high for 6 (what the ICS570B pair gives)
    reg [3:0] div = 0;
    reg       clk7 = 1'b0;
    always @(posedge clk) begin
        div <= (div == 4'd11) ? 4'd0 : div + 4'd1;
        if (div == 4'd0) clk7 <= 1'b1;
        if (div == 4'd6) clk7 <= 1'b0;
    end
    wire ce7 = (div == 4'd1);       // just after the 7M rising edge

    // harness reset: hold the board model for a few clocks after config
    reg [3:0] rcnt = 0;
    wire      mb_rst = !rcnt[3];
    always @(posedge clk) if (!rcnt[3]) rcnt <= rcnt + 1'b1;

    wire [23:1] a;
    wire [15:0] d_cpu, d_bus;
    wire        d_oe, as_n, uds_n, lds_n, rw, vma_n, e, bg_n;
    wire [2:0]  fc, ipl_n;
    wire        dtack_n, vpa_n;
    wire        reset_drv_n, halt_drv_n;
    wire        lr, lg, lb;
    wire [3:0]  led_ovr;

    base64_tg68_top #(
        .ENABLE_FASTMEM(1'b1), .ENABLE_SD(1'b0),
        .FORCE_RETRY_MS(0), .COLD_RETRY(1'b0), .PASSIVE_EN(1'b0),
        .PWRUP_BIT(PWRUP_BIT)
    ) dut (
        .clk_7m(clk7), .clk_12x(clk),
        .cpu_a(a), .cpu_d(d_cpu), .cpu_d_oe(d_oe), .cpu_d_in(d_bus),
        .cpu_reset_in(reset_drv_n), .cpu_halt_in(halt_drv_n),
        .cpu_as_n(as_n), .cpu_uds_n(uds_n), .cpu_lds_n(lds_n), .cpu_rw(rw),
        .cpu_fc(fc), .cpu_vma_n(vma_n), .cpu_e(e), .cpu_bg_n(bg_n),
        .cpu_dtack_n(dtack_n), .cpu_vpa_n(vpa_n), .cpu_berr_n(1'b1),
        .cpu_br_n(1'b1), .cpu_bgack_n(1'b1), .cpu_ipl_n(ipl_n),
        .cpu_reset_n(reset_drv_n), .cpu_halt_n(halt_drv_n),
        .cfgin_n(1'b0), .cfgout_n(),
        .cbt_oe_d0_7_n(), .cbt_oe_d8_15_n(), .cbt_oe_ctl_hi_n(),
        .cbt_oe_a8_17_n(), .cbt_oe_a1_7_n(),
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dq(sdram_dq),
        .sdram_dqm(sdram_dqm), .sdram_clk(sdram_clk), .sdram_cke(sdram_cke),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n), .sdram_cs_n(sdram_cs_n),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_d(sd_d),
        .led_r(lr), .led_g(lg), .led_b(lb));

    mobo #(.BAUD(BAUD)) u_mobo (
        .clk(clk), .rst(mb_rst), .ce7(ce7),
        .a(a), .d_cpu(d_cpu), .d_cpu_oe(d_oe), .d_bus(d_bus),
        .as_n(as_n), .uds_n(uds_n), .lds_n(lds_n), .rw(rw), .fc(fc),
        .dtack_n(dtack_n), .vpa_n(vpa_n), .ipl_n(ipl_n),
        .uart_tx(uart_tx), .uart_rx(uart_rx), .led_ovr(led_ovr));

    // The design's LED outputs are active high; the module's LED is active
    // low. Software can take the LED over through $DE000A.
    assign led_r = ~(led_ovr[3] ? led_ovr[0] : lr);
    assign led_g = ~(led_ovr[3] ? led_ovr[1] : lg);
    assign led_b = ~(led_ovr[3] ? led_ovr[2] : lb);
endmodule
