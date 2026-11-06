#!/bin/sh
# Run the test benches (Linux, needs verilator >= 5 and m68k binutils:
#   apt install verilator binutils-m68k-linux-gnu).
#   sim/run.sh bus       adapter + kernel on a model 68000 bus
#   sim/run.sh top       whole top level on a model motherboard
#   sim/run.sh fastmem   whole top level with fast RAM + SDRAM model
#   sim/run.sh bench copy|read|scatter   fast RAM throughput
#   sim/run.sh bench sd                  SD controller, SPI loopback
# CORE=tg68_020_b0_nobf_smul sim/run.sh bus   tests another core variant
set -e
cd "$(dirname "$0")"
R=../rtl
CORE=${CORE:-tg68_020_b0}
AS="m68k-linux-gnu-as -m68020"; LD="m68k-linux-gnu-ld -Ttext=0"; OC="m68k-linux-gnu-objcopy -O binary"
mem() { python3 -I -c "
d=open('$1','rb').read(); d+=bytes(8192-len(d))
open('$2','w').write('\n'.join('%02x%02x'%(d[i],d[i+1]) for i in range(0,8192,2))+'\n')"; }
VL="verilator --binary --timing -Wno-fatal -Wno-USEBEFOREDECL -Wno-lint -Wno-style -O2 --top-module tb $VLFLAGS"   # VLFLAGS=-DTG68_PREDICT: next-address prediction
SLAVES="$R/base64_fx68k/autoconfig_zii.v $R/base64_fx68k/fastmem_zii.v $R/base64_fx68k/turbomem_zii.v \
 $R/base64_fx68k/sd_subsystem.v $R/base64_fx68k/sdcard.v $R/base64_fx68k/sdram_ctrl.v $R/base64_fx68k/fifo.v \
 $R/base64_fx68k/shifter.v $R/base64_fx68k/rx_cpu_buf.v $R/base64_fx68k/tx_cpu_buf.v"
cp $R/base64_fx68k/turbomem.mem $R/base64_fx68k/sfsd.mem .
case "${1:-bus}" in
bus)
  $AS -o t.o test020.s && $LD -o t.elf t.o 2>/dev/null && $OC t.elf t.bin && mem t.bin rom.mem
  $VL tb_tg68_bus.sv $R/base64_tg68/tg68_bus.v $R/tg68/$CORE.v -o tb_bus > build_bus.log 2>&1
  ./obj_dir/tb_bus ;;
top)
  $AS -o tt.o test_top.s && $LD -o tt.elf tt.o 2>/dev/null && $OC tt.elf tt.bin && mem tt.bin rom_top.mem
  $VL tb_top.sv $R/base64_tg68/base64_tg68_top.sv $R/base64_tg68/tg68_bus.v $R/tg68/$CORE.v $SLAVES -o tb_top > build_top.log 2>&1
  ./obj_dir/tb_top ;;
fastmem)
  $AS --defsym FASTMEM=1 -o tf.o test_top.s && $LD -o tf.elf tf.o 2>/dev/null && $OC tf.elf tf.bin && mem tf.bin rom_top_fm.mem
  $VL -DFASTMEM tb_top.sv sdram_model_checked.v $R/base64_tg68/base64_tg68_top.sv $R/base64_tg68/tg68_bus.v $R/tg68/$CORE.v $SLAVES -o tb_fm > build_fm.log 2>&1
  ./obj_dir/tb_fm ;;
bench)
  # run.sh bench [copy|read|scatter]: fast RAM throughput, timed 2nd pass
  case "${2:-copy}" in
    copy) SRC=test_mem.s; D=-DBENCH_COPY ;; read) SRC=test_rd.s; D= ;; scatter) SRC=test_rnd.s; D= ;;
    sd) SRC=test_sd.s; D=-DSDTEST ;;
  esac
  $AS -o tm.o $SRC && $LD -o tm.elf tm.o 2>/dev/null && $OC tm.elf tm.bin && mem tm.bin rom_mem.mem
  $VL -DFASTMEM -DMEMBENCH $D tb_top.sv sdram_model_checked.v $R/base64_tg68/base64_tg68_top.sv $R/base64_tg68/tg68_bus.v $R/tg68/$CORE.v $SLAVES -o tb_bench > build_bench.log 2>&1
  ./obj_dir/tb_bench | grep -v "^per cycle\|^AS->DTACK" ;;
esac
