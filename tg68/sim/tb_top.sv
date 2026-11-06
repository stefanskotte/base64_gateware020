// Full-top simulation: base64_tg68_top on a crude Amiga motherboard model.
//   clk_12x 85.13 MHz, clk_7m = /12 (as the ICS570B gives)
//   "Gary": DTACK 2 7M clocks after AS for ROM/RAM; VPA for $BFxxxx (CIA)
//           and for FC=7 (IACK); open-drain /RESET and /HALT with pull-ups
//   ROM $000000-$001FFF (overlay), RAM $008000-$009FFF, CIA reads $A5
`timescale 1ns/1ps
module tb;
    reg clk12 = 0;
    always #5.873 clk12 = ~clk12;
    reg [3:0] div = 0;
    reg clk7 = 0;
    always @(posedge clk12) begin
        div <= (div == 11) ? 0 : div + 1;
        if (div == 0)  clk7 <= 1;
        if (div == 6)  clk7 <= 0;
    end

    wire [23:1] a;
    wire [15:0] d;
    wire as_n, uds_n, lds_n, rw, vma_n, e, bg_n;
    wire [2:0] fc;
    reg  dtack_n = 1, vpa_n = 1;
    reg  [2:0] ipl_n = 3'b111;
    wire reset_n, halt_n;
    pullup (reset_n);
    pullup (halt_n);
    wire led_r, led_g, led_b, cfgout_n;

    reg  [15:0] mb_q = 16'hFFFF;
    reg         mb_drive = 0;
    assign d = mb_drive ? mb_q : 16'bz;

    base64_tg68_top #(
        .PWRUP_BIT(12), .COLD_RETRY(1'b0), .FORCE_RETRY_MS(0),
`ifdef SDTEST
        .PASSIVE_EN(1'b0), .ENABLE_SD(1'b1),
`else
        .PASSIVE_EN(1'b0), .ENABLE_SD(1'b0),
`endif
`ifdef FASTMEM
        .ENABLE_FASTMEM(1'b1)
`else
        .ENABLE_FASTMEM(1'b0)
`endif
    ) dut (
        .clk_7m(clk7), .clk_12x(clk12),
        .cpu_a(a), .cpu_d(d), .cpu_as_n(as_n), .cpu_uds_n(uds_n),
        .cpu_lds_n(lds_n), .cpu_rw(rw), .cpu_fc(fc), .cpu_vma_n(vma_n),
        .cpu_e(e), .cpu_bg_n(bg_n), .cpu_dtack_n(dtack_n), .cpu_vpa_n(vpa_n),
        .cpu_berr_n(1'b1), .cpu_br_n(1'b1), .cpu_bgack_n(1'b1),
        .cpu_ipl_n(ipl_n), .cpu_reset_n(reset_n), .cpu_halt_n(halt_n),
        .cfgin_n(1'b0), .cfgout_n(cfgout_n),
        .cbt_oe_d0_7_n(), .cbt_oe_d8_15_n(), .cbt_oe_ctl_hi_n(),
        .cbt_oe_a8_17_n(), .cbt_oe_a1_7_n(),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm), .sdram_clk(sclk),
        .sdram_cke(scke), .sdram_ras_n(sras), .sdram_cas_n(scas), .sdram_we_n(swe),
        .sdram_cs_n(scs), .sd_clk(), .sd_cmd(sd_cmd_w), .sd_d(sd_d_w),
        .led_r(led_r), .led_g(led_g), .led_b(led_b));

    // SD pins: MOSI looped back to MISO, so every byte shifted out is
    // shifted back in (the SD test checks the whole SPI data path)
    wire sd_cmd_w; wire [3:0] sd_d_w;
    assign sd_d_w[0] = sd_cmd_w;
    wire [12:0] sa; wire [1:0] sba, sdqm; wire [15:0] sdq;
    wire sclk, scke, sras, scas, swe, scs;
`ifdef FASTMEM
    sdram_model_checked #(.CAS_LAT(2), .ADDR_BITS(24)) u_sdram (
        .clk(sclk), .a(sa), .ba(sba), .dq(sdq), .dqm(sdqm),
        .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas), .we_n(swe));
`endif
    reg [15:0] rom [0:4095];
    reg [15:0] ram [0:4095];
    integer i;
    initial begin
        `ifdef MEMBENCH
        $readmemh("rom_mem.mem", rom);
`elsif FASTMEM
        $readmemh("rom_top_fm.mem", rom);
`else
        $readmemh("rom_top.mem", rom);
`endif
        for (i = 0; i < 4096; i = i + 1) ram[i] = 0;
    end
    wire [23:0] ba = {a, 1'b0};

    // ---- Gary, on the 7M grid -------------------------------------------
    integer cycles = 0, iacks = 0, cia = 0, errors = 0, unmapped = 0, romf = 0;
    // shortest request -> ack time on the direct port, in clocks
    integer dp_t = 0, dp_min = 99; reg dp_prev = 0;
    always @(posedge dut.clk) begin
        dp_prev <= dut.cpu.dp_req_i;
        if (dut.cpu.dp_req_i && !dp_prev) dp_t = 0; else dp_t = dp_t + 1;
        if (dut.cpu.dp_ack && dut.cpu.dp_busy && dp_t < dp_min) dp_min = dp_t;
    end
    // data-cache hits (CCMP on a data read that hits)
    integer dc_hits = 0;
    always @(posedge dut.clk)
        if (dut.cpu.q == 4'd8 && !dut.cpu.cyc_fetch && dut.cpu.ic_ok
            && dut.cpu.ic_qt == dut.cpu.ic_want && dut.cpu.dc_on) dc_hits = dc_hits + 1;
`ifdef TG68_PREDICT
    // predicted data hits go DECIDE -> FINISH and never reach CCMP
    always @(posedge dut.clk)
        if (dut.cpu.q == 4'd1 && dut.cpu.k_bs == 2'b10 && dut.cpu.k_nwr && dut.cpu.dc_on
            && dut.cpu.pr_dh && !dut.cpu.pr_dk && dut.cpu.k_addr[31:1] == dut.cpu.pr_d
            && !dut.cpu.k_pf_hit) dc_hits = dc_hits + 1;
`endif
    always @(negedge as_n) if (ba[23:19] == 5'b11111) romf = romf + 1;
    reg [2:0] w = 0;
    reg       busy = 0;
    always @(posedge clk7) begin
        if (as_n) begin
            dtack_n <= 1; vpa_n <= 1; mb_drive <= 0; busy <= 0; w <= 0;
        end else if (!busy) begin
            busy <= 1; cycles = cycles + 1; w <= 0;
            if (fc == 3'b111) begin vpa_n <= 0; iacks = iacks + 1; end
            else if (ba[23:16] == 8'hBF) begin vpa_n <= 0; cia = cia + 1; end
        end else if (vpa_n) begin
            w <= w + 1;
            if (w == 1) begin
                if (rw) begin
                    if (ba < 24'h2000 || ba[23:19] == 5'b11111) mb_q <= rom[ba[12:1]];
                    else if (ba >= 24'h8000 && ba < 24'hA000)  mb_q <= ram[ba[12:1]];
                    else begin mb_q <= 16'hFFFF; unmapped = unmapped + 1;
                        $display("unmapped read %h fc=%0d", ba, fc); end
                    mb_drive <= 1;
                end
                dtack_n <= 0;
            end
        end
        // CIA data while VMA is low and E high
        if (!as_n && !vpa_n && fc != 3'b111 && rw) begin
            mb_q <= 16'hA5A5; mb_drive <= 1;
        end
    end
    // writes land on the DS rising edge, like Agnus
    always @(posedge uds_n) if (!rw && ba >= 24'h8000 && ba < 24'hA000) ram[ba[12:1]][15:8] = d[15:8];
    always @(posedge lds_n) if (!rw && ba >= 24'h8000 && ba < 24'hA000) ram[ba[12:1]][7:0]  = d[7:0];
    always @(posedge uds_n) if (!rw && ba == 24'h8F80) ipl_n = 3'b111;
`ifdef FASTMEM
    // MapROM control, as the turbomem board's $F008 register would set it
    always @(posedge uds_n) if (!rw && ba == 24'h8F40) begin
        if (d[15:8] == 8'd1) force dut.g_fastmem.u_turbomem.mr_ctrl = 2'b01;
        if (d[15:8] == 8'd2) force dut.g_fastmem.u_turbomem.mr_ctrl = 2'b10;
        if (d[15:8] == 8'd3) force dut.g_fastmem.u_turbomem.mr_ctrl = 2'b00;
    end
`endif
    always @(negedge as_n) if (!rw && !(ba >= 24'h8000 && ba < 24'hA000) && ba[23:16] != 8'hBF) begin
        $display("unmapped write %h", ba); unmapped = unmapped + 1; end

`ifdef MEMBENCH
    // time between the start/end markers, and per-phase accounting of
    // fast RAM cycles: AS(core) low -> DTACK(core) -> AS high -> next AS
    real t0 = 0, t1 = 0;
    always @(posedge uds_n) if (!rw && ba == 24'h8F00) begin
        if (d[15:8] == 8'd1) t0 = $realtime; else t1 = $realtime;
    end
    integer n_fm = 0; real t_as = 0, sum_as2dt = 0, sum_dt2up = 0, sum_up2as = 0, t_dt = 0, t_up = 0;
    always @(negedge dut.core_as_n) if (t0 > 0 && t1 == 0) begin
        if (t_up > 0) sum_up2as = sum_up2as + ($realtime - t_up);
        t_as = $realtime;
    end
    integer n_rd = 0, n_wr = 0; real s_rd = 0, s_wr = 0;
    integer n_step = 0, n_int = 0, n_hit = 0, n_dir = 0, n_bus = 0, n_clk = 0;
    always @(posedge clk12) if (t0 > 0 && t1 == 0) begin
        n_clk = n_clk + 1;
        if (dut.cpu.k_clkena) n_step = n_step + 1;
        if (dut.cpu.q == 1 && dut.cpu.internal_step && dut.cpu.cnt >= 3) n_int = n_int + 1;
        if (dut.cpu.q == 8 && dut.cpu.ic_ok && dut.cpu.ic_qt == dut.cpu.ic_want && dut.cpu.ic_on) n_hit = n_hit + 1;
        if (dut.cpu.q == 9 && dut.cpu.dp_ack) n_dir = n_dir + 1;
        if (dut.cpu.q == 4 && (!dut.core_dtack_n)) n_bus = n_bus + 1;
    end
    always @(negedge dut.core_dtack_n) if (t0 > 0 && t1 == 0) begin t_dt = $realtime; sum_as2dt = sum_as2dt + (t_dt - t_as); n_fm = n_fm + 1;
        if (dut.core_a[31:24] == 8'h08) begin
        if (dut.core_rw) begin n_rd = n_rd + 1; s_rd = s_rd + (t_dt - t_as); end else begin n_wr = n_wr + 1; s_wr = s_wr + (t_dt - t_as); end end end
    always @(posedge dut.core_as_n) if (t0 > 0 && t1 == 0 && t_dt > 0) begin t_up = $realtime; sum_dt2up = sum_dt2up + (t_up - t_dt); end
`endif
    function [31:0] rd32(input [23:0] ad);
        rd32 = {ram[ad[12:1]], ram[ad[12:1]+1]};
    endfunction
    task check(input [23:0] ad, input [31:0] exp, input [8*24-1:0] what);
        if (rd32(ad) !== exp) begin
            $display("FAIL %-24s @%h = %h, expected %h", what, ad, rd32(ad), exp);
            errors = errors + 1;
        end else $display("ok   %-24s @%h = %h", what, ad, rd32(ad));
    endtask

`ifdef SDTEST
    // the SD board as if autoconfigured at $E90000
    initial begin
        #100;
        force dut.g_sd.u_sd_autoconfig.configured = 1'b1;
        force dut.g_sd.u_sd_autoconfig.base_sd = 8'hE9;
    end
`endif
    reg irq_raised = 0;
    initial begin
        // The core leaves reset after the power-up hold + cold pulse; the
        // interrupt is raised once the test is waiting for it.
        wait (led_b);
        $display("%0t core out of reset", $time);
        for (i = 0; i < 2000000 && rd32(24'h8FF0) != 32'h600DC0DE; i = i + 1) begin
            @(posedge clk12);
`ifdef FASTMEM
            if (rd32(24'h812C) == 32'h0000BEEF && !irq_raised) begin
`else
            if (rd32(24'h811C) == 32'hFFFFFFFF && !irq_raised) begin
`endif
                ipl_n = 3'b100; irq_raised = 1;
            end
        end
`ifdef MEMBENCH
        $display("kernel steps %0d: internal %0d, cache hits %0d, direct %0d, bus %0d; clocks %0d",
                 n_step, n_int, n_hit, n_dir, n_bus, n_clk);
        $display("1 KB: %0.1f us -> %0.2f MB/s; %0d CPU bus cycles", (t1-t0)/1000.0, 1024.0/((t1-t0)/1000.0), n_fm);
        $display("per cycle, in 11.75 ns clocks: AS->DTACK %0.1f, DTACK->AS up %0.1f, AS up->next AS %0.1f",
                 sum_as2dt/n_fm/11.746, sum_dt2up/n_fm/11.746, sum_up2as/n_fm/11.746);
        $display("AS->DTACK reads %0d avg %0.1f clk, writes %0d avg %0.1f clk", n_rd, s_rd/n_rd/11.746, n_wr, s_wr/n_wr/11.746);
`ifdef SDTEST
        check(24'h8100, 32'h00000055, "SD clkdiv 55");
        check(24'h8104, 32'h000000AA, "SD clkdiv AA");
        check(24'h8108, 32'h00000001, "SD slave sel 1");
        check(24'h810C, 32'h00000000, "SD slave sel 0");
        check(24'h8110, 32'h000000AA, "SD clkdiv again");
        check(24'h8114, 32'h00000000, "SPI loopback mismatches");
        check(24'h8118, 32'h00000102, "SPI loopback first word");
        check(24'h811C, 32'h000000F1, "SPI loopback bytes");
`elsif BENCH_COPY
        check(24'h8100, 32'h000000FF, "first copied long");
        check(24'h8104, 32'h00000000, "last copied long");
        check(24'h8108, 32'h00000000, "copy mismatches");
`else
        check(24'h8100, 32'h00007F80, "sum");
`endif
        check(24'h8FF0, 32'h600DC0DE, "done marker");
        if (errors) $display("FAILED"); else $display("PASS");
        $finish;
`else
        $display("%0t: MB cycles %0d, IACK %0d, CIA %0d, unmapped %0d, ROM-range cycles %0d", $time, cycles, iacks, cia, unmapped, romf);
        check(24'h8100, 32'h369D0368, "MULU.L");
        check(24'h8104, 32'h00022E09, "DIVU.L");
        check(24'h8108, 32'h0000000F, "BFEXTU");
        check(24'h810C, 32'h369D5ACD, "byte lanes / MOVE.W");
        check(24'h8110, 32'hA1B2C3D4, "misaligned MOVE.L");
        check(24'h8114, 32'h00007777, "TRAP/RTE");
        check(24'h8118, 32'h000000A5, "CIA (VPA/E) read");
        check(24'h811C, 32'hFFFFFFFF, "32-bit null space");
`ifdef FASTMEM
        check(24'h8120, 32'h13579BDF, "fast RAM $08000000");
        check(24'h8124, 32'h2468ACE0, "fast RAM $08FFFFFC");
        check(24'h8128, 32'h0000FA57, "code run from fast RAM");
        check(24'h812C, 32'h0000BEEF, "patched code (cache)");
        check(24'h8150, 32'h11112222, "long via prefetch");
        check(24'h8154, 32'h00003333, "prefetch vs write");
        check(24'h8158, 32'h00006644, "prefetch vs byte write");
        check(24'h815C, 32'h00008E90, "sequential word reads");
        check(24'h8160, 32'hCAFEBABE, "MapROM shadow read");
        check(24'h8164, 32'h00000000, "MapROM off: real ROM");
        check(24'h8168, 32'h0BADF00D, "dcache: long hit");
        check(24'h816C, 32'h0000005A, "dcache: byte write");
        check(24'h8170, 32'h00005678, "dcache: word write");
        check(24'h8174, 32'h110F4444, "dcache: same index");
        check(24'h8178, 32'h00002222, "dcache: write while off");
        check(24'h817C, 32'h02040608, "dcache: ROM data");
        check(24'h8180, 32'h00002F40, "dcache: two-pass sum");
        $display("data cache hits: %0d; shortest direct request->ack %0d clocks", dc_hits, dp_min);
        // tg68_bus's speculative read relies on no answer before CCMP
        if (dp_min < 3) begin $display("FAIL: SDRAM answered in %0d clocks", dp_min); errors = errors + 1; end
        if (dc_hits < 64) begin $display("FAIL: data cache barely used"); errors = errors + 1; end
        check(24'h8130, 32'h33333333, "IRQ3 via VPA autovec");
`else
        check(24'h8120, 32'h33333333, "IRQ3 via VPA autovec");
`endif
        check(24'h8140, 32'h00000055, "ROM code via cache");
        check(24'h8FF0, 32'h600DC0DE, "done marker");
        if (iacks != 1) begin $display("FAIL IACK count %0d", iacks); errors = errors + 1; end
        if (unmapped)   begin $display("FAIL %0d unmapped accesses reached the MB", unmapped); errors = errors + 1; end
        if (led_r)      begin $display("FAIL red LED (stall)"); errors = errors + 1; end
        if (errors) $display("FAILED, %0d errors", errors); else $display("PASS");
        $finish;
`endif
    end
    initial begin #40ms; $display("TIMEOUT"); $finish; end
endmodule

// Behavioural stand-in for the ECP5 output DDR primitive.
module ODDRX1F (input D0, D1, SCLK, RST, output Q);
    assign Q = SCLK ? D0 : D1;
endmodule
