#!/usr/bin/env python3
"""TG68 dev-board harness: base64_tg68_top on a bare iCESugar-Pro.

    python3 build.py rom          ROM loader -> build/rom.mem
    python3 build.py sw [--sim]   test program -> build/test.bin (--sim: short)
    python3 build.py sim          Verilator: loader + test program, full core
    python3 build.py bit [--seed N] [--seeds N]   bitstream -> build/tg68_harness.bit

Load the bitstream with  openFPGALoader -c cmsisdap --vid 0x1d50 --pid 0x602b
build/tg68_harness.bit  (or copy it to the iCELink drive), then run
host/run.py build/test.bin  to send the program and print its output.

Needs the same tools as ../../scripts/build.py, plus m68k-elf-gcc (or
m68k-linux-gnu-gcc) for the test program. YOSYS / NEXTPNR / ECPPACK override
the tools, as there. Use the pinned versions from ../../scripts/setup_cloud.sh:
newer nextpnr builds (0.11.1-88) abort while packing the TG68 kernel.
"""
import argparse, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TG = os.path.dirname(os.path.dirname(HERE))          # tg68/
OUT = os.path.join(HERE, 'build')
R = lambda *p: os.path.join(TG, 'rtl', *p)

def tool(*names):
    for n in names:
        if shutil.which(n):
            return n
    sys.exit('none of %s on PATH' % ', '.join(names))

def run(cmd, cwd=OUT, **kw):
    print('  $ ' + ' '.join(str(c) for c in cmd[:4]) + (' ...' if len(cmd) > 4 else ''), flush=True)
    r = subprocess.run(cmd, cwd=cwd, **kw)
    if r.returncode:
        sys.exit('%s failed (exit %d)' % (cmd[0], r.returncode))
    return r

def m68k(t):
    return tool('m68k-elf-' + t, 'm68k-linux-gnu-' + t)

def words_mem(data, nwords, path):
    data = data + b'\xff' * (2 * nwords - len(data))
    with open(path, 'w') as f:
        for i in range(nwords):
            f.write('%04x\n' % (data[2 * i] << 8 | data[2 * i + 1]))

def rom():
    run([m68k('as'), '-m68020', '-o', 'loader.o', os.path.join(HERE, 'rom', 'loader.s')])
    run([m68k('ld'), '-Ttext=0', '--oformat=binary', '-o', 'loader.bin', 'loader.o'])
    data = open(os.path.join(OUT, 'loader.bin'), 'rb').read()
    assert len(data) <= 16384, 'loader does not fit the 16 KB ROM'
    words_mem(data, 8192, os.path.join(OUT, 'rom.mem'))
    print('  rom.mem: loader %d bytes' % len(data))

def sw(sim):
    s = os.path.join(HERE, 'sw')
    cflags = ['-m68020', '-O2', '-ffreestanding', '-fno-builtin', '-nostdlib',
              '-fomit-frame-pointer', '-Wall'] + (['-DSIM'] if sim else [])
    run([m68k('gcc')] + cflags + ['-T', os.path.join(s, 'link.ld'), '-o', 'test.elf',
        os.path.join(s, 'crt0.s'), os.path.join(s, 'main.c'), os.path.join(s, 'lib.c'), '-lgcc'])
    run([m68k('objcopy'), '-O', 'binary', 'test.elf', 'test.bin'])
    print('  test.bin: %d bytes' % os.path.getsize(os.path.join(OUT, 'test.bin')))

def sim():
    rom()
    sw(True)
    # the bench feeds the program to the loader through the UART pin
    data = open(os.path.join(OUT, 'test.bin'), 'rb').read()
    pkt = b'B64L' + len(data).to_bytes(4, 'big') + (0x08000000).to_bytes(4, 'big') * 2 \
          + data + (sum(data) & 0xFFFFFFFF).to_bytes(4, 'big')
    with open(os.path.join(OUT, 'uart_in.mem'), 'w') as f:
        f.write('\n'.join('%02x' % b for b in pkt) + '\n')
    with open(os.path.join(OUT, 'uart_in.len'), 'w') as f:
        f.write('%d\n' % len(pkt))
    vl = [tool('verilator'), '--binary', '--timing', '-Wno-fatal', '-Wno-lint', '-Wno-style',
          '-Wno-USEBEFOREDECL', '-O2', '--top-module', 'tb', '-DDEVBOARD', '-DSIM',
          '-DPKT_LEN=%d' % len(pkt), '-DTMAX=%s' % os.environ.get('TMAX', '300ms'), '-o', 'tbh', '--Mdir', 'obj_sim',
          os.path.join(HERE, 'sim', 'tb.sv'), os.path.join(HERE, 'harness_top.v'),
          os.path.join(HERE, 'mobo.v'), R('base64_tg68', 'base64_tg68_top.sv'),
          R('base64_tg68', 'tg68_bus.v'), R('tg68', 'tg68_020_b0.v'),
          os.path.join(TG, 'sim', 'sdram_model_checked.v')] + \
         [R('base64_fx68k', f + '.v') for f in
          ('autoconfig_zii', 'fastmem_zii', 'turbomem_zii', 'sd_subsystem', 'sdcard',
           'sdram_ctrl', 'fifo', 'shifter', 'rx_cpu_buf', 'tx_cpu_buf')]
    for f in ('turbomem.mem', 'sfsd.mem'):
        shutil.copy(R('base64_fx68k', f), OUT)
    run(vl, stdout=open(os.path.join(OUT, 'sim_build.log'), 'w'), stderr=subprocess.STDOUT)
    run([os.path.join(OUT, 'obj_sim', 'tbh')])

def bit(seed, seeds=1):
    rom()
    for f in ('turbomem.mem', 'sfsd.mem'):
        shutil.copy(R('base64_fx68k', f), OUT)
    srcs_v = [os.path.join(HERE, f) for f in ('harness_top.v', 'mobo.v')] + \
             [os.path.join(HERE, '..', 'sdram_test', 'pll_86.v'),
              R('base64_tg68', 'tg68_bus.v'), R('tg68', 'tg68_020_b0.v')] + \
             [R('base64_fx68k', f + '.v') for f in
              ('autoconfig_zii', 'fastmem_zii', 'turbomem_zii', 'sd_subsystem', 'sdcard',
               'sdram_ctrl', 'fifo', 'shifter', 'rx_cpu_buf', 'tx_cpu_buf')]
    # same recipe as scripts/build.py, with DEVBOARD and the harness on top
    script = ['read_verilog -DDEVBOARD -sv ' + R('base64_tg68', 'base64_tg68_top.sv')] + \
             ['read_verilog -DDEVBOARD ' + f for f in srcs_v] + [
        'read_verilog -lib +/ecp5/cells_bb.v',
        'hierarchy -top harness_top',
        # the bridge asks for its pin registers to go in the I/O flip-flops;
        # here they drive mobo.v, not pins, so that cannot be honoured
        'attrmap -remove syn_useioff',
        'setattr -mod -set keep_hierarchy 1 tg68k*',
        'synth_ecp5 -abc9 -top harness_top',
        'setattr -mod -unset keep_hierarchy tg68k*',
        'flatten',
        'opt_clean -purge',
        'delete t:$scopeinfo',
        'attrmap -remove syn_useioff',
        'write_json tg68_harness.json',
        'tee -o utilisation.txt stat']
    open(os.path.join(OUT, 'synth.ys'), 'w').write('\n'.join(script) + '\n')
    run([os.environ.get('YOSYS') or tool('yosys'), '-q', '-l', 'yosys.log', '-s', 'synth.ys'])
    import json
    top = json.load(open(os.path.join(OUT, 'tg68_harness.json')))['modules']['harness_top']
    # sd_cmd (MOSI) and sd_d[3] (chip select) are outputs in SPI mode; with
    # ENABLE_SD=0 they sit at a constant idle level, which is harmless.
    lost = ['%s[%d]' % (p, i) for p, v in top['ports'].items() if v['direction'] == 'inout'
            for i, b in enumerate(v['bits']) if isinstance(b, str)
            and (p, i) not in (('sd_cmd', 0), ('sd_d', 3))]
    if lost:
        sys.exit('ERROR: inout pins tied to constants (tristate lost): ' + ', '.join(lost))
    for seed in range(seed, seed + seeds):
        print('== nextpnr seed %d' % seed, flush=True)
        run([os.environ.get('NEXTPNR') or tool('nextpnr-ecp5'), '--25k', '--package', 'CABGA256', '--speed', '6',
             '--json', 'tg68_harness.json', '--lpf', os.path.join(HERE, 'harness.lpf'),
             '--textcfg', 'tg68_harness.config', '--sdf', 'tg68_harness.sdf',
             '--report', 'report.json', '--timing-allow-fail', '--router', 'router2',
             '--placer', os.environ.get('PLACER', 'static'), '--seed', str(seed),
             '-l', 'nextpnr.log'])
        # the multicycle check, with the harness's extra hierarchy level removed
        r = subprocess.run([sys.executable, os.path.join(TG, 'scripts', 'check_timing.py'),
                            'tg68_harness.sdf', '--strip', 'dut.'], cwd=OUT, capture_output=True, text=True)
        open(os.path.join(OUT, 'timing.txt'), 'w').write(r.stdout + r.stderr)
        print('\n'.join(r.stdout.splitlines()[:6]))
        if r.returncode == 0:
            break
    run([os.environ.get('ECPPACK') or tool('ecppack'), 'tg68_harness.config', 'tg68_harness.bit'])
    print('== done: build/tg68_harness.bit' + ('' if r.returncode == 0 else
          '   (WARNING: check_timing.py did not pass, see build/timing.txt)'))

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('what', choices=('rom', 'sw', 'sim', 'bit'))
ap.add_argument('--sim', action='store_true', help='sw: build the short simulation variant')
ap.add_argument('--seed', type=int, default=5)   # see README: Timing
ap.add_argument('--seeds', type=int, default=1, help='bit: try seeds until check_timing passes')
a = ap.parse_args()
os.makedirs(OUT, exist_ok=True)
{'rom': rom, 'sw': lambda: sw(a.sim), 'sim': sim, 'bit': lambda: bit(a.seed, a.seeds)}[a.what]()
