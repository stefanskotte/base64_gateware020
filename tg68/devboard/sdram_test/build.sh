#!/bin/sh
# iCESugar-Pro SDRAM soak test: bitstreams and simulation.
#   sh build.sh bit        build/sdram_test_86mhz.bit and build/sdram_test_50mhz.bit
#   sh build.sh bit114     114.3 MHz (x16 evaluation), CL2 and CL3
#   sh build.sh sim        5 passes over a 4K-word window, expect total_errs 0
#   sh build.sh inject     corrupt cells mid-test, expect the test to FAIL them
# Uses the TG68 build's own sdram_ctrl.v and the bench's checked SDRAM model.
set -e
cd "$(dirname "$0")"
R=../../rtl/base64_fx68k
M=../../sim/sdram_model_checked.v
VL="verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-USEBEFOREDECL -O2 --top-module tb"

bit() {  # $1 = 86 | 50 | 114cl2 | 114cl3
    mkdir -p build
    def=""; [ "$1" = 50 ] && def="-DCLK50"
    [ "$1" = 114cl2 ] && def="-DCLK114 -DCAS=2"
    [ "$1" = 114cl3 ] && def="-DCLK114 -DCAS=3"
    yosys -q -l build/yosys_$1.log -p "read_verilog $def top.v sdram_test.v pll_86.v pll_50.v ../tg68_harness/pll_x16.v $R/sdram_ctrl.v; synth_ecp5 -abc9 -top top -json build/top_$1.json"
    # 114 MHz: the tester's own request -> DQ-enable path misses timing; a
    # miss can only add false errors, so a clean run still clears the chip
    taf=""; case "$1" in 114*) taf="--timing-allow-fail" ;; esac
    nextpnr-ecp5 -q $taf -l build/nextpnr_$1.log --25k --package CABGA256 --speed 6 \
        --lpf top.lpf --json build/top_$1.json --textcfg build/top_$1.config
    ecppack build/top_$1.config build/sdram_test_$1mhz.bit
    grep -i 'max frequency' build/nextpnr_$1.log | tail -1
}

case "${1:-bit}" in
bit)    bit 86; bit 50 ;;
bit114) bit 114cl2; bit 114cl3 ;;   # x16 evaluation
sim)    $VL -DAW=12 -DMB=24 -DPASSES=5 -DWSB=4 sim/tb.sv sdram_test.v $R/sdram_ctrl.v $M \
            --Mdir build/obj_sim -o tbsim > build/sim_build.log 2>&1 || { tail build/sim_build.log; exit 1; }
        ./build/obj_sim/tbsim | tail -8 ;;
inject) $VL -DAW=12 -DMB=24 -DPASSES=4 -DWSB=4 -DINJECT sim/tb.sv sdram_test.v $R/sdram_ctrl.v $M \
            --Mdir build/obj_inj -o tbinj > build/inj_build.log 2>&1 || { tail build/inj_build.log; exit 1; }
        ./build/obj_inj/tbinj | tail -12 ;;
*)      echo "usage: sh build.sh bit|sim|inject"; exit 1 ;;
esac
