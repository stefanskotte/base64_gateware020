#!/usr/bin/env python3
"""Base64 TG68 (68020) bitstream build -- open-source flow, any OS.

    python scripts/build.py [min|fastmem|full] [--seed N] [--seeds N]

  min      CPU + motherboard only (Chip RAM, Kickstart).   Start here.
  fastmem  + SDRAM fast RAM: Zorro II and 16 MB at $08000000
  full     + SD card (sfsd.device)

Needs yosys, nextpnr-ecp5 and ecppack on PATH -- all three are in
oss-cad-suite (https://github.com/YosysHQ/oss-cad-suite-build). Set the
environment variables YOSYS / NEXTPNR / ECPPACK to override.

--seeds N tries placement seeds 1..N and keeps the first that passes the
multicycle timing check (scripts/check_timing.py).

Output: build/<cfg>/base64_tg68_<cfg>.bit, with yosys.log, nextpnr.log,
utilisation.txt and timing.txt alongside it.
"""
import argparse, os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFGS = {'min': (0, 0), 'fastmem': (1, 0), 'full': (1, 1)}

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('cfg', nargs='?', default='min', choices=CFGS)
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--seeds', type=int, default=8, help='try up to this many seeds (stops at the first that passes)')
ap.add_argument('--skip-synth', action='store_true', help='reuse an existing yosys netlist')
ap.add_argument('--predict', action='store_true',
                help='build with TG68_PREDICT (next-address prediction in tg68_bus); output in build/<cfg>_predict')
a = ap.parse_args()

YOSYS = os.environ.get('YOSYS', 'yosys')
NEXTPNR = os.environ.get('NEXTPNR', 'nextpnr-ecp5')
ECPPACK = os.environ.get('ECPPACK', 'ecppack')
fm, sd = CFGS[a.cfg]
name = a.cfg + ('_predict' if a.predict else '')
out = os.path.join(ROOT, 'build', name)
os.makedirs(out, exist_ok=True)
for f in ('turbomem.mem', 'sfsd.mem'):        # $readmemh looks in the cwd
    shutil.copy(os.path.join(ROOT, 'rtl', 'base64_fx68k', f), out)

def run(cmd):
    print('  $ ' + ' '.join(cmd[:3]) + (' ...' if len(cmd) > 3 else ''), flush=True)
    r = subprocess.run(cmd, cwd=out)
    if r.returncode != 0:
        sys.exit('%s failed (exit %d) -- see the log in %s' % (cmd[0], r.returncode, out))

R = lambda *p: os.path.join(ROOT, 'rtl', *p).replace('\\', '/')
srcs_sv = [R('base64_tg68', 'base64_tg68_top.sv')]
core = 'tg68_020_b0.v'
srcs_v = [R('base64_tg68', 'tg68_bus.v'), R('tg68', core)] + \
         [R('base64_fx68k', f + '.v') for f in
          ('autoconfig_zii', 'fastmem_zii', 'turbomem_zii', 'sd_subsystem', 'sdcard',
           'sdram_ctrl', 'fifo', 'shifter', 'rx_cpu_buf', 'tx_cpu_buf')]

if not a.skip_synth:
    print('== yosys  (%s: ENABLE_FASTMEM=%d ENABLE_SD=%d)' % (a.cfg, fm, sd))
    dfl = '-DTG68_PREDICT ' if a.predict else ''
    script = '\n'.join(['read_verilog %s-sv ' % dfl + f for f in srcs_sv] +
                       ['read_verilog %s' % dfl + f for f in srcs_v] + [
        'read_verilog -lib +/ecp5/cells_bb.v',   # BB: the SD card input pins
        'chparam -set ENABLE_FASTMEM %d -set ENABLE_SD %d base64_tg68_top' % (fm, sd),
        # Keep the TG68 kernel and ALU as separate modules through
        # synthesis. Flattened, yosys maps the GHDL netlist to ~18k LUTs and
        # nextpnr cannot route it; kept apart it is ~8k, which is what the
        # vendor tools give. Flatten afterwards, at cell level, for nextpnr.
        'hierarchy -top base64_tg68_top',
        'setattr -mod -set keep_hierarchy 1 tg68k*',
        'synth_ecp5 -abc9 -top base64_tg68_top',
        'setattr -mod -unset keep_hierarchy tg68k*',
        'flatten',
        'opt_clean -purge',
        # yosys >= 0.39 leaves $scopeinfo cells after flatten; older
        # nextpnr builds reject them, newer ones ignore them.
        'delete t:$scopeinfo',
        'write_json base64_tg68.json',
        'tee -o utilisation.txt stat'])
    open(os.path.join(out, 'synth.ys'), 'w').write(script + '\n')
    run([YOSYS, '-q', '-l', 'yosys.log', '-s', 'synth.ys'])

    # A bidirectional pin tied to a constant means a tristate was lost (yosys
    # turns a constant 1'bz into a 0 driver): the FPGA would fight whatever
    # drives that pin. This is how the SD card's MISO went dead in the first
    # TG68 builds. Refuse to go on.
    import json
    top = json.load(open(os.path.join(out, 'base64_tg68.json')))['modules']['base64_tg68_top']
    lost = ['%s[%d]=%s' % (p, i, b) for p, v in top['ports'].items() if v['direction'] == 'inout'
            for i, b in enumerate(v['bits']) if isinstance(b, str)]
    if lost:
        sys.exit('ERROR: inout pins tied to constants (tristate lost): ' + ', '.join(lost))

lpf = os.path.join(ROOT, 'constraints', 'base64_tg68.lpf')
for seed in range(a.seed, a.seed + a.seeds):
    print('== nextpnr  (seed %d)' % seed)
    # --timing-allow-fail: nextpnr cannot be told the TG68 kernel is
    # multicycle and always flags it. check_timing.py is the real check.
    run([NEXTPNR, '--25k', '--package', 'CABGA256', '--speed', '6',
         '--json', 'base64_tg68.json', '--lpf', lpf,
         '--textcfg', 'base64_tg68.config', '--sdf', 'base64_tg68.sdf',
         '--report', 'report.json', '--timing-allow-fail',
         '--router', 'router2',
         # static placer + router2 gave the best results here. The static
         # placer needs nextpnr >= 0.7 (any current oss-cad-suite); set
         # PLACER=heap for an older nextpnr.
         '--placer', os.environ.get('PLACER', 'static'),
         '--seed', str(seed), '-l', 'nextpnr.log'])
    print('== timing check')
    r = subprocess.run([sys.executable, os.path.join(ROOT, 'scripts', 'check_timing.py'),
                        'base64_tg68.sdf'], cwd=out, capture_output=True, text=True)
    open(os.path.join(out, 'timing.txt'), 'w').write(r.stdout)
    print('\n'.join(l for l in r.stdout.splitlines()[:12]))
    if r.returncode == 0 or seed == a.seed + a.seeds - 1:
        break
    print('   timing failed with seed %d, trying the next one' % seed)

print('== ecppack')
# Plain pack, as in Muse Lab's own iCESugar-Pro examples. The Diamond build's
# SYSCONFIG (compressed, dual SPI, 62 MHz MCCLK) was tried here and the FPGA
# does not configure from flash with it -- tested on hardware: LEDs stay off.
# ECPPACK_OPTS="--compress --freq 38.8" gives a faster-loading single-SPI
# image if you want to try it.
bit = 'base64_tg68_%s.bit' % name
run([ECPPACK] + os.environ.get('ECPPACK_OPTS', '').split() + ['base64_tg68.config', bit])
print('== done: %s' % os.path.join(out, bit))
if r.returncode != 0:
    print('WARNING: timing check FAILED on every seed tried -- see timing.txt')
    sys.exit(2)
