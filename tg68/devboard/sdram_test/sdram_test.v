// sdram_test.v -- full-chip SDRAM soak test for the iCESugar-Pro module.
//
// Uses the Base64 TG68 build's own sdram_ctrl.v (open-row controller, CL2,
// DQ sampled straight off the pins, clock out through ODDRX1F 0/1) at the
// same ~86 MHz, so a pass here means the memory AND the controller as the
// 68020 build uses them are good on this module.
//
// Passes cycle through four pattern types over all 16M words (32 MB):
//   0  addr-hash ^ seed, written as TWO BYTE WRITES (exercises DQM lanes)
//   1  ~(addr-hash ^ seed), word writes
//   2  checkerboard AAAA/5555 alternating per word, inverting per pass
//   3  32-bit LFSR stream (seeded per pass), replayed on read
// The addr-hash gives every address a different value from any address that
// differs in one bit, so stuck/shorted address lines and aliasing show up.
// Before the first pass: walking 1s/0s on the data bus at word 0.
//
// UART (115200 8N1, iCELink CDC): banner, one line per error (max 16 per
// pass, test pauses while printing), one summary line per pass:
//   P0003 T2 E00000000 B0000 OK
//   (pass, type, error count this pass, OR of all failing data bits)
// LEDs (active low on the module): green toggles per pass, red latches on
// any error, blue = test running.
`ifndef WSB
`define WSB 23   // startup wait: 2^23 clocks (~0.1 s); the sim sets a small value
`endif
`default_nettype none
module sdram_test #(
    parameter integer CLK_HZ = 85_714_286,
    parameter integer BAUD   = 115_200,
    parameter integer AW     = 24          // words tested: 2^AW (24 = 32 MB)
)(
    input  wire        clk,
    input  wire        rst,
    output wire        uart_tx,
    output reg         led_r_on,
    output reg         led_g_on,
    output reg         led_b_on,
    // sdram_ctrl user port
    output reg         req,
    output reg         we,
    output reg  [23:0] addr,
    output reg  [15:0] wdata,
    output reg  [1:0]  byte_en,
    input  wire        ack,
    input  wire [15:0] rdata,
    input  wire        ready
);
    // ------------------------------------------------------------------ UART
    localparam integer DIV = CLK_HZ / BAUD;
    reg [15:0] u_cnt = 0;
    reg [9:0]  u_sh  = 10'h3FF;
    reg [3:0]  u_bits = 0;
    wire       u_busy = (u_bits != 0);
    reg        u_go;
    reg [7:0]  u_byte;
    assign uart_tx = u_sh[0];
    always @(posedge clk) begin
        if (u_go && !u_busy) begin
            u_sh <= {1'b1, u_byte, 1'b0}; u_bits <= 4'd10; u_cnt <= DIV - 1;
        end else if (u_busy) begin
            if (u_cnt == 0) begin
                u_cnt <= DIV - 1; u_sh <= {1'b1, u_sh[9:1]}; u_bits <= u_bits - 1'b1;
            end else u_cnt <= u_cnt - 1'b1;
        end
    end

    function [7:0] hex(input [3:0] n);
        hex = (n < 10) ? 8'd48 + n : 8'd55 + n;
    endfunction

    // ------------------------------------------------------------- patterns
    reg [15:0] pass;
    reg [1:0]  ptype;
    reg [15:0] seed;
    reg [31:0] lfsr;
    function [15:0] ahash(input [23:0] a, input [15:0] s);
        ahash = a[15:0] ^ {a[23:16], a[23:16]} ^ s;
    endfunction
    wire [31:0] lfsr_nx = {lfsr[30:0], 1'b0} ^ (lfsr[31] ? 32'h04C11DB7 : 32'h0);
    function [15:0] pat(input [1:0] t, input [23:0] a, input [15:0] s, input [31:0] l, input [15:0] p);
        case (t)
            2'd0: pat = ahash(a, s);
            2'd1: pat = ~ahash(a, s);
            2'd2: pat = (a[0] ^ p[2]) ? 16'hAAAA : 16'h5555;
            default: pat = l[31:16] ^ l[15:0];
        endcase
    endfunction

    // ----------------------------------------------------------- sequencer
    localparam S_WAIT = 0, S_BANNER = 1, S_WALK_W = 2, S_WALK_WA = 3,
               S_WALK_R = 4, S_WALK_RA = 5, S_PSTART = 6, S_WR = 7, S_WRA = 8,
               S_RD = 9, S_RDA = 10, S_ERR = 11, S_SUM = 12, S_PEND = 13;
    reg [3:0]  st, ret;
    reg [5:0]  walk;               // 0..31: walking 1s then walking 0s; 32 = done
    reg        lane;               // type 0 writes: 0 = upper byte, 1 = lower
    reg [15:0] exp_d;
    reg [31:0] errs, total_errs;
    reg [15:0] badbits;
    reg [4:0]  shown;
    reg [23:0] e_addr;
    reg [15:0] e_exp, e_got;
    reg [5:0]  ci;                 // character index while printing
    reg        pwait;
    reg [23:0] ws_cnt;
    localparam [23:0] LAST = (1 << AW) - 1;

    wire [15:0] walk_pat = walk[4] ? ~(16'h1 << walk[3:0]) : (16'h1 << walk[3:0]);
    wire [31:0] lfsr0 = {pass, ~pass} | 32'h1;
    wire [15:0] cur_pat = pat(ptype, addr, seed, lfsr, pass);
    wire        mism = (rdata != exp_d);

    reg [7:0] ch;
    reg       ch_end;
    always @* begin
        ch = 8'd32; ch_end = 1'b0;
        case (st)
        S_BANNER: case (ci)
            0: ch="\r"; 1: ch="\n"; 2: ch="S"; 3: ch="D"; 4: ch="R"; 5: ch="A"; 6: ch="M";
            7: ch=" "; 8: ch="t"; 9: ch="e"; 10: ch="s"; 11: ch="t"; 12: ch=" "; 13: ch="2";
            14: ch="^"; 15: ch=hex(AW / 10); 16: ch=hex(AW % 10); 17: ch=" "; 18: ch="w";
            19: ch="o"; 20: ch="r"; 21: ch="d"; 22: ch="s"; 23: ch="\r"; 24: ch="\n";
            default: ch_end = 1'b1; endcase
        S_ERR: case (ci)
            0: ch="E"; 1: ch=" ";
            2: ch=hex(e_addr[23:20]); 3: ch=hex(e_addr[19:16]); 4: ch=hex(e_addr[15:12]);
            5: ch=hex(e_addr[11:8]);  6: ch=hex(e_addr[7:4]);   7: ch=hex(e_addr[3:0]);
            8: ch=" "; 9: ch="w"; 10: ch=hex(e_exp[15:12]); 11: ch=hex(e_exp[11:8]);
            12: ch=hex(e_exp[7:4]); 13: ch=hex(e_exp[3:0]); 14: ch=" "; 15: ch="r";
            16: ch=hex(e_got[15:12]); 17: ch=hex(e_got[11:8]); 18: ch=hex(e_got[7:4]);
            19: ch=hex(e_got[3:0]); 20: ch=" ";
            21: ch=(walk != 6'd32) ? "W" : "T"; 22: ch=(walk != 6'd32) ? "K" : hex({2'b0, ptype});
            23: ch="\r"; 24: ch="\n";
            default: ch_end = 1'b1; endcase
        S_SUM: case (ci)
            0: ch="P"; 1: ch=hex(pass[15:12]); 2: ch=hex(pass[11:8]); 3: ch=hex(pass[7:4]);
            4: ch=hex(pass[3:0]); 5: ch=" "; 6: ch="T"; 7: ch=hex({2'b0, ptype}); 8: ch=" ";
            9: ch="E"; 10: ch=hex(errs[31:28]); 11: ch=hex(errs[27:24]); 12: ch=hex(errs[23:20]);
            13: ch=hex(errs[19:16]); 14: ch=hex(errs[15:12]); 15: ch=hex(errs[11:8]);
            16: ch=hex(errs[7:4]); 17: ch=hex(errs[3:0]); 18: ch=" "; 19: ch="B";
            20: ch=hex(badbits[15:12]); 21: ch=hex(badbits[11:8]); 22: ch=hex(badbits[7:4]);
            23: ch=hex(badbits[3:0]); 24: ch=" ";
            25: ch=(total_errs == 0) ? "O" : "F"; 26: ch=(total_errs == 0) ? "K" : "A";
            27: ch=(total_errs == 0) ? " " : "I"; 28: ch=(total_errs == 0) ? " " : "L";
            29: ch="\r"; 30: ch="\n";
            default: ch_end = 1'b1; endcase
        default: ;
        endcase
    end

    always @(posedge clk) begin
        u_go <= 1'b0;
        if (rst) begin
            st <= S_WAIT; ret <= S_WALK_W; req <= 0; we <= 0; addr <= 0; wdata <= 0;
            byte_en <= 2'b11; pass <= 0; ptype <= 0; seed <= 16'h1D0F; lfsr <= 32'h1;
            errs <= 0; total_errs <= 0; badbits <= 0; shown <= 0; walk <= 0;
            led_r_on <= 0; led_g_on <= 0; led_b_on <= 0; ci <= 0; ws_cnt <= 0;
            pwait <= 0; lane <= 0; exp_d <= 0;
        end else case (st)
        S_WAIT: begin
            ws_cnt <= ws_cnt + 1'b1;
            if (ready && ws_cnt[`WSB]) begin st <= S_BANNER; ci <= 0; ret <= S_WALK_W; end
        end
        S_BANNER, S_ERR, S_SUM: begin          // print current text, then go to ret
            if (pwait) begin
                if (!u_busy && !u_go) pwait <= 1'b0;
            end else if (ch_end) begin
                ci <= 0; st <= (st == S_SUM) ? S_PEND : ret;
            end else begin
                u_byte <= ch; u_go <= 1'b1; ci <= ci + 1'b1; pwait <= 1'b1;
            end
        end
        // ---- walking 1s / 0s on the data bus, word 0
        S_WALK_W: begin
            led_b_on <= 1'b1;
            if (walk == 6'd32) st <= S_PSTART;
            else begin
                addr <= 0; we <= 1; wdata <= walk_pat; byte_en <= 2'b11; exp_d <= walk_pat;
                req <= 1; st <= S_WALK_WA;
            end
        end
        S_WALK_WA: if (ack) begin req <= 0; st <= S_WALK_R; end
        S_WALK_R:  begin we <= 0; req <= 1; st <= S_WALK_RA; end
        S_WALK_RA: if (ack) begin
            req <= 0;
            if (mism) begin
                errs <= errs + 1; total_errs <= total_errs + 1;
                badbits <= badbits | (rdata ^ exp_d); led_r_on <= 1;
                e_addr <= 0; e_exp <= exp_d; e_got <= rdata;
                st <= S_ERR; ret <= S_WALK_W; ci <= 0;
            end else st <= S_WALK_W;
            walk <= walk + 1'b1;
        end
        // ---- full-chip sweeps
        S_PSTART: begin addr <= 0; lane <= 0; lfsr <= lfsr0; st <= S_WR; end
        S_WR: begin
            we <= 1; req <= 1; wdata <= cur_pat; st <= S_WRA;
            byte_en <= (ptype == 2'd0) ? (lane ? 2'b01 : 2'b10) : 2'b11;
        end
        S_WRA: if (ack) begin
            req <= 0;
            if (ptype == 2'd0 && !lane) begin lane <= 1'b1; st <= S_WR; end
            else begin
                lane <= 1'b0; lfsr <= lfsr_nx;
                if (addr == LAST) begin addr <= 0; lfsr <= lfsr0; st <= S_RD; end
                else begin addr <= addr + 1'b1; st <= S_WR; end
            end
        end
        S_RD: begin we <= 0; req <= 1; exp_d <= cur_pat; st <= S_RDA; end
        S_RDA: if (ack) begin
            req <= 0; lfsr <= lfsr_nx; addr <= addr + 1'b1;
            if (mism) begin
                errs <= errs + 1; total_errs <= total_errs + 1;
                badbits <= badbits | (rdata ^ exp_d); led_r_on <= 1;
            end
            if (mism && shown != 5'd16) begin
                shown <= shown + 1'b1;
                e_addr <= addr; e_exp <= exp_d; e_got <= rdata;
                st <= S_ERR; ci <= 0;
                ret <= (addr == LAST) ? S_SUM : S_RD;
            end else if (addr == LAST) begin st <= S_SUM; ci <= 0; ret <= S_PEND; end
            else st <= S_RD;
            if (addr == LAST && mism && shown != 5'd16) ret <= S_SUM;
        end
        S_PEND: begin
            pass <= pass + 1'b1; ptype <= ptype + 1'b1; led_g_on <= ~led_g_on;
            seed <= {seed[14:0], seed[15] ^ seed[13] ^ seed[12] ^ seed[10]} ^ pass;
            errs <= 0; badbits <= 0; shown <= 0;
            st <= S_PSTART;
        end
        default: st <= S_WAIT;
        endcase
    end
endmodule
