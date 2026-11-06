// mobo.v -- a synthesizable stand-in for the Amiga motherboard, so the
// complete base64_tg68_top (bridge, 7M grid, fast RAM, caches) can run on a
// bare iCESugar-Pro. Built from tb_top.sv's "Gary".
//
// Memory map, as the CPU sees it on the 68000 bus:
//   $000000-$00FFFF  ROM while OVL=1 (after reset), else Chip RAM
//   $000000-$007FFF  Chip RAM (32 KB, once OVL is cleared)
//   $BFxxxx          "CIA": VPA/E cycle, reads $A5A5
//   $DE0000-$DE001F  harness registers (below)
//   $F80000-$FFFFFF  ROM (16 KB, mirrored)
//   IACK (FC=7)      VPA, so the bridge autovectors
//   anything else    DTACK, reads $FFFF, counted as "unmapped"
//
// Registers: word writes take the low byte, byte writes the strobed one.
//   $DE0000 W  UART TX byte          R  bit0 TX busy, bit1 RX valid
//   $DE0002 R  UART RX: bit15 valid, bit14 overrun, [7:0] byte; read clears
//   $DE0004 R  microsecond counter [31:16] (latches the low half)
//   $DE0006 R  microsecond counter [15:0] (as latched)
//   $DE0008 W  IPL level to raise (0 = none)
//   $DE000A W  bit0 = OVL (1 after reset), bit1..3 = LED r/g/b override
//   $DE000C R  count of unmapped motherboard cycles
//   $DE000E R  last unmapped address [23:16]
//   $DE0010 R  last unmapped address [15:0]
//   $DE0012 R  harness id $B64D
// Read data and DTACK follow tb_top's timing: DTACK two 7M clocks after AS.
`default_nettype none
module mobo #(
    parameter integer CLK_HZ  = 85_714_286,
    parameter integer BAUD    = 115_200,
    parameter integer ROM_AW  = 13,       // words: 8K x 16 = 16 KB
    parameter integer RAM_AW  = 14,       // words: 16K x 16 = 32 KB
    parameter         ROM_INIT = "rom.mem"
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce7,         // one clock per 7M period
    // 68000 bus from base64_tg68_top
    input  wire [23:1] a,
    input  wire [15:0] d_cpu,       // bridge's data, valid when d_cpu_oe
    input  wire        d_cpu_oe,
    output wire [15:0] d_bus,       // resolved bus, back to the bridge
    input  wire        as_n, uds_n, lds_n, rw,
    input  wire [2:0]  fc,
    output reg         dtack_n,
    output reg         vpa_n,
    output wire [2:0]  ipl_n,
    // serial
    output wire        uart_tx,
    input  wire        uart_rx,
    output reg  [3:0]  led_ovr      // {enable, b, g, r}
);
    wire [23:0] ba = {a, 1'b0};

    // ---- memories --------------------------------------------------------
    reg [15:0] rom [0:(1<<ROM_AW)-1];
    reg [15:0] ram [0:(1<<RAM_AW)-1];
    initial $readmemh(ROM_INIT, rom);
    reg [15:0] rom_q, ram_q;
    reg        ovl = 1'b1;
    always @(posedge clk) rom_q <= rom[ba[ROM_AW:1]];
    always @(posedge clk) ram_q <= ram[ba[RAM_AW:1]];

    wire sel_rom = (ovl && ba[23:16] == 8'h00) || ba[23:19] == 5'b11111;
    wire sel_ram = !ovl && ba[23:RAM_AW+1] == 0;
    wire sel_reg = ba[23:8] == 16'hDE00;
    wire sel_cia = ba[23:16] == 8'hBF;

    // ---- data bus resolution: the bridge, else the board, else pull-ups --
    reg  [15:0] mb_q = 16'hFFFF;
    reg         mb_drive = 1'b0;
    assign d_bus = d_cpu_oe ? d_cpu : (mb_drive ? mb_q : 16'hFFFF);

    // ---- UART ------------------------------------------------------------
    localparam integer DIV = CLK_HZ / BAUD;
    reg  [15:0] tx_cnt = 0;
    reg  [9:0]  tx_sh  = 10'h3FF;
    reg  [3:0]  tx_n   = 0;
    wire        tx_busy = tx_n != 0;
    assign uart_tx = tx_sh[0];
    reg         tx_go = 1'b0;
    reg  [7:0]  tx_byte = 0;
    always @(posedge clk) begin
        if (tx_go && !tx_busy) begin
            tx_sh <= {1'b1, tx_byte, 1'b0}; tx_n <= 10; tx_cnt <= DIV - 1;
        end else if (tx_busy) begin
            if (tx_cnt == 0) begin
                tx_sh <= {1'b1, tx_sh[9:1]}; tx_n <= tx_n - 1; tx_cnt <= DIV - 1;
            end else tx_cnt <= tx_cnt - 1;
        end
    end
    reg [2:0]  rx_s = 3'b111;
    reg [15:0] rx_cnt = 0;
    reg [3:0]  rx_n = 0;
    reg [7:0]  rx_sh = 0;
    reg [7:0]  rx_byte = 0;
    reg        rx_valid = 1'b0, rx_ovr = 1'b0;
    reg        rx_clr = 1'b0;
    always @(posedge clk) begin
        rx_s <= {rx_s[1:0], uart_rx};
        if (rx_clr) begin rx_valid <= 1'b0; rx_ovr <= 1'b0; end
        if (rx_n == 0) begin
            if (!rx_s[2]) begin rx_n <= 10; rx_cnt <= DIV / 2; end
        end else if (rx_cnt == 0) begin
            rx_cnt <= DIV - 1; rx_n <= rx_n - 1;
            if (rx_n == 10) begin if (rx_s[2]) rx_n <= 0; end      // false start
            else if (rx_n >= 2) rx_sh <= {rx_s[2], rx_sh[7:1]};
            else begin                                            // stop bit
                rx_n <= 0;
                if (rx_valid && !rx_clr) rx_ovr <= 1'b1;
                rx_byte <= rx_sh; rx_valid <= 1'b1;
            end
        end else rx_cnt <= rx_cnt - 1;
    end

    // ---- microsecond counter: 7 / 600 of a clock = 1 us at 85.714 MHz ----
    reg [9:0]  us_acc = 0;
    reg [31:0] us = 0;
    reg [15:0] us_lo_l = 0;
    always @(posedge clk)
        if (us_acc >= 10'd593) begin us_acc <= us_acc + 10'd7 - 10'd600; us <= us + 1; end
        else us_acc <= us_acc + 10'd7;

    // ---- interrupts ------------------------------------------------------
    reg [2:0] ipl_lvl = 3'd0;
    assign ipl_n = ~ipl_lvl;

    // ---- unmapped-cycle accounting ---------------------------------------
    reg [15:0] unm_cnt = 0;
    reg [23:0] unm_addr = 0;

    // ---- register read mux -----------------------------------------------
    reg [15:0] reg_q;
    always @(*) begin
        case (ba[4:1])
        4'd0: reg_q = {14'd0, rx_valid, tx_busy};
        4'd1: reg_q = {rx_valid, rx_ovr, 6'd0, rx_byte};
        4'd2: reg_q = us[31:16];
        4'd3: reg_q = us_lo_l;
        4'd5: reg_q = {12'd0, led_ovr[2:0], ovl};
        4'd6: reg_q = unm_cnt;
        4'd7: reg_q = {8'd0, unm_addr[23:16]};
        4'd8: reg_q = unm_addr[15:0];
        4'd9: reg_q = 16'hB64D;
        default: reg_q = 16'h0000;
        endcase
    end

    // ---- "Gary": cycle timing on the 7M grid -----------------------------
    reg [2:0]  w = 0;
    reg        busy = 1'b0;
    reg        is_wr = 1'b0, wr_done = 1'b0;
    reg [15:0] wd = 0;
    reg [23:0] ca = 0;               // cycle address, latched at the start
    wire c_ram = !ovl && ca[23:RAM_AW+1] == 0;
    wire c_reg = ca[23:8] == 16'hDE00;
    wire lo    = wl;                 // word or odd-byte write: low byte
    reg        wu = 0, wl = 0;
    always @(posedge clk) begin
        tx_go  <= 1'b0;
        rx_clr <= 1'b0;
        // write data and strobes, captured while the bridge drives them
        if (!as_n && !rw && d_cpu_oe) wd <= d_cpu;
        if (!as_n && !rw) begin wu <= wu | !uds_n; wl <= wl | !lds_n; end
        if (rst) begin
            dtack_n <= 1'b1; vpa_n <= 1'b1; mb_drive <= 1'b0; busy <= 1'b0;
            ovl <= 1'b1; ipl_lvl <= 0; led_ovr <= 0; wu <= 0; wl <= 0;
        end else if (as_n) begin
            // end of cycle: commit a write (data is complete by now)
            if (busy && is_wr && !wr_done) begin
                if (c_ram) begin
                    if (wu) ram[ca[RAM_AW:1]][15:8] <= wd[15:8];
                    if (wl) ram[ca[RAM_AW:1]][7:0]  <= wd[7:0];
                end
                if (c_reg) case (ca[4:1])
                    4'd0: begin tx_byte <= lo ? wd[7:0] : wd[15:8]; tx_go <= 1'b1; end
                    4'd4: ipl_lvl <= lo ? wd[2:0] : wd[10:8];
                    4'd5: begin ovl <= lo ? wd[0] : wd[8];
                                led_ovr <= lo ? {wd[3:1] != 0, wd[3:1]} : {wd[11:9] != 0, wd[11:9]}; end
                    default: ;
                endcase
            end
            dtack_n <= 1'b1; vpa_n <= 1'b1; mb_drive <= 1'b0; busy <= 1'b0; w <= 0;
            wr_done <= 1'b0; wu <= 0; wl <= 0;
        end else if (ce7) begin
            if (!busy) begin
                busy <= 1'b1; w <= 0; is_wr <= !rw; ca <= ba;
                if (fc == 3'b111 || sel_cia) vpa_n <= 1'b0;
            end else if (vpa_n) begin
                w <= w + 1'b1;
                if (w == 1) begin
                    if (rw) begin
                        if (sel_rom)      mb_q <= rom_q;
                        else if (sel_ram) mb_q <= ram_q;
                        else if (sel_reg) begin
                            mb_q <= reg_q;
                            // clear only the byte this read returned: a byte landing in this
                            // very clock was not in reg_q and must survive
                            if (ba[4:1] == 4'd1) rx_clr <= rx_valid;
                            if (ba[4:1] == 4'd2) us_lo_l <= us[15:0];
                        end else begin
                            mb_q <= 16'hFFFF; unm_cnt <= unm_cnt + 1'b1; unm_addr <= ba;
                        end
                        mb_drive <= 1'b1;
                    end else if (!(sel_ram || sel_reg)) begin
                        unm_cnt <= unm_cnt + 1'b1; unm_addr <= ba;
                    end
                    dtack_n <= 1'b0;
                end
            end
            // CIA read data while VPA is low (the bridge times the E cycle)
            if (!vpa_n && fc != 3'b111 && rw) begin mb_q <= 16'hA5A5; mb_drive <= 1'b1; end
        end
    end
endmodule
