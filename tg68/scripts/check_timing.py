#!/usr/bin/env python3
"""Multicycle-aware timing check for the Base64 TG68 build.

nextpnr only knows single-cycle timing, so it reports the TG68 kernel as
failing 85 MHz. The kernel is a multicycle design (every register is gated by
clkena, and tg68_bus.v guarantees the spacing), so that report is not the
whole truth. This script re-times the routed design from nextpnr's SDF
(--sdf) and applies the budgets the adapter actually provides:

  start               end              budget (master clocks)
  ordinary logic      anything         1
  cpu.k_clkena        anything         1      (it IS the single-cycle part)
  adapter -> kernel   kernel register  min(DIN+1, STEP-1)
                                              (data_in/IPL/berr/nReset)
  kernel register     kernel register  STEP
  kernel register     adapter          SETTLE
  bus outputs and     anything         ASU+1  (address/FC/RW/write data change
  registered address                           only at DECIDE, with AS high, and
  decodes                                      AS falls ADDR_SETUP clocks later)
  config registers    anything         4      (autoconfig base/configured and
                                               maprom bits: written by a CPU
                                               cycle to another slave, static
                                               for thousands of clocks after;
                                               SDRAM init_done: set once)
  anything            k_din (data in)  DATA   (latched DATA_DELAY clocks after
                                               DTACK; every slave holds its read
                                               data from DTACK until AS rises)

Usage: check_timing.py design.sdf [--freq 86] [--step 4 --settle 3 --din 1 --asu 1]
Exit status 0 if every path meets its budget.
"""
import argparse, collections, re, sys

ap = argparse.ArgumentParser()
ap.add_argument('sdf')
ap.add_argument('--freq', type=float, default=86.0)
ap.add_argument('--step', type=int, default=4)
ap.add_argument('--settle', type=int, default=3)
ap.add_argument('--din', type=int, default=1)
ap.add_argument('--data', type=int, default=2, help='tg68_bus DATA_DELAY')
ap.add_argument('--asu', type=int, default=1, help='tg68_bus ADDR_SETUP')
ap.add_argument('--paths', type=int, default=3, help='paths to print per class')
ap.add_argument('--strip', default='', help='hierarchy prefix to remove from every instance name '
                '(the dev-board harness has base64_tg68_top as "dut.")')
args = ap.parse_args()
T = 1e6 / args.freq                      # ps

txt = open(args.sdf).read()

def unesc(s):
    return re.sub(r'\\(.)', r'\1', s)

def dmax(tok):
    # "(a:b:c)" -> c ; "()" -> 0
    m = re.findall(r'\(([-\d.]*):([-\d.]*):([-\d.]*)\)', tok)
    return max([float(x[2]) for x in m if x[2]] or [0.0])

# ---- parse ---------------------------------------------------------------
edges = collections.defaultdict(list)    # node -> [(succ, delay)]
clk2q = {}                               # FF output node -> (inst, delay)
setup = {}                               # endpoint node -> (inst, setup)
clkpin_delay = {}                        # inst -> clock arrival at its CLK

cell_re = re.compile(r'\(CELL\s*\(CELLTYPE\s+"([^"]*)"\)\s*\(INSTANCE\s*([^)]*)\)(.*?)\n  \)\n', re.S)
tok = r'((?:\\.|[^\s()\\])+)'
ic_re = re.compile(r'\(INTERCONNECT\s+' + tok + r'\s+' + tok + r'\s+(\([^)]*\))')
io_re = re.compile(r'\(IOPATH\s+(\((?:posedge|negedge)\s+' + tok + r'\)|' + tok + r')\s+' + tok + r'\s+(\([^)]*\))')
su_re = re.compile(r'\((SETUP|RECOVERY|SETUPHOLD)\s+(?:\((?:posedge|negedge)\s+' + tok + r'\)|' + tok + r')\s+\((?:posedge|negedge)\s+' + tok + r'\)\s+(\([^)]*\))')
CLOCK_PINS = {'CLK', 'CLKA', 'CLKB', 'CLK0', 'CLK1', 'CLK2', 'CLK3', 'SCLK', 'ECLK', 'WCK', 'RCLK', 'WCLK'}

def cells(txt):
    # nextpnr's closing-paren indentation is not consistent, so split on the
    # CELL headers rather than matching blocks.
    for chunk in re.split(r'\n\s*\(CELL\b', txt)[1:]:
        m = re.match(r'\s*\(CELLTYPE\s+"([^"]*)"\)\s*\(INSTANCE\s*((?:\\.|[^)\\])*)\)', chunk)
        if m: yield m.group(1), m.group(2), chunk[m.end():]

def strip(name):
    return name[len(args.strip):] if args.strip and name.startswith(args.strip) else name

for ctype, inst, body in cells(txt):
    inst = strip(unesc(inst.strip()))
    if inst == '':
        for a, b, d in ic_re.findall(body):
            a, b = strip(unesc(a)), strip(unesc(b))
            edges[a].append((b, dmax(d)))
            if b.endswith('/CLK'):
                clkpin_delay[b[:-4]] = dmax(d)
        continue
    for m in io_re.finditer(body):
        full, clkp, inp, outp, d = m.groups()
        outp = unesc(outp)
        if not clkp and unesc(inp) in CLOCK_PINS:
            clkp = unesc(inp)
        if clkp:                          # clock-to-output arc
            node = inst + '/' + outp
            clk2q[node] = (inst, max(clk2q.get(node, (inst, 0))[1], dmax(d)))
        else:
            edges[inst + '/' + unesc(inp)].append((inst + '/' + outp, dmax(d)))
    for kind, pin1, pin2, clkp, d in su_re.findall(body):
        node = inst + '/' + unesc(pin1 or pin2)
        setup[node] = (inst, max(setup.get(node, (inst, 0))[1], dmax(d)))

# ---- classify --------------------------------------------------------------
CLKENA = re.compile(r'(^|\.)(k_clkena|clkena_in)(\[|_|$)')
KIN = re.compile(r'(^|\.)(k_din|data_in|k_ipl|ipl|IPL|k_berr|berr|k_nreset|nReset|nreset)(\[|_|$)')
# ...and the slaves' registered address decodes, which follow the address one
# clock later and are only acted on once AS is low (AS falls 3 clocks after
# the address changes, so they have 3T; 2T is used).
BUSOUT = re.compile(r'^(cpu\.(a_r|fc_r|eRWn|oEdb|eab|FC\d)|core_a|core_fc|core_rw|core_dout|hi_null_r'
                    r'|cpu\.dp_(we|wdata|be)|cpu\.pf_a'
                    # a_r bits that yosys named after the slave port they drive
                    r'|g_\w+\.u_\w+\.(a|a_high|a_low|region)'
                    r'|g_fastmem\.u_fastmem\.(owns_r|cpu_win_r|mr_win_r|saddr_r|saddr)'
                    r'|g_fastmem\.u_turbomem\.rom_win_r|g_sd\.u_sd\.sd_hit_r)(_|\[|$)')
STATIC = re.compile(r'^(g_(fastmem|sd)\.u_\w+\.(maprom_active|maprom_load|configured|addr_match|'
                    r'tm_configured|sd_configured|base|base_sd|tm_base|base_addr\w*|cpu_base\w*)'
                    # the same MapROM bits, named after the adapter's ports
                    r'|cpu\.mr_(active|load)'
                    r'|g_sdram\.u_sdram\.init_done)(_|\[|$)')
# Instruction cache RAM and its registers: ordinary single-cycle logic, but
# listed separately because a cache hit loads k_din one clock after ic_qd,
# so it must NOT get the 2T read-data-latch budget the slaves get.
ICACHE = re.compile(r'^cpu\.(ic_|dc_|g_dcache\.|dp_q|pf_d)')
def start_class(inst):
    if ICACHE.match(inst): return 'I'
    if STATIC.match(inst): return 'S'
    if BUSOUT.match(inst): return 'A'
    if inst.startswith('cpu.') and CLKENA.search(inst): return 'C'
    if inst.startswith('cpu.') and (KIN.search(inst) or KDIN.match(inst)): return 'M'
    if inst.startswith('cpu.core.'):                    return 'K'
    # The adapter's own control registers (sequencer state, timers, flags).
    # Ordinary 1T logic like 'O', but split out because 'O' -> read-data
    # latch has the slaves' 2T data budget, and these registers also steer
    # k_din/ic_wd/dc_wd on single-cycle transitions (CCMP, DDATA, DECIDE).
    # (not the strobe ports: AS/UDS/LDS reach the slaves and the read-data
    # mux like any slave-side logic, and read data is latched 2 clocks
    # after DTACK)
    if inst.startswith('cpu.') and not re.match(r'^cpu\.(ASn|UDSn|LDSn)(_|\[|$)', inst):
        return 'Q'
    return 'O'
# The adapter's read-data register. yosys may name it after the kernel port
# it drives (cpu.core.data_in), but it lives in tg68_bus, not the kernel.
# ic_wd (the cache fill data) is latched from iEdb on the same edge as k_din,
# under the same guarantee, so it is the same kind of endpoint.
KDIN = re.compile(r'^cpu\.(k_din|core\.data_in|ic_wd|dc_wd)(_|\[|$)')
# fastmem_zii's registered window decode. It is read by the CPU adapter (the
# instruction cache, the direct SDRAM path) one clock after the address
# changes, so the path INTO it is single-cycle whatever the address's own
# budget is.
# (saddr_r is NOT here: it is built from the kernel's address, final at
# DECIDE, and held while a request is outstanding, so the controller sees
# it two clocks after it last changed -- a bus-output start, above.)
WINREG = re.compile(r'^g_fastmem\.u_fastmem\.(owns_r|cpu_win_r|mr_win_r|fm_win)(_|\[|$)')
def end_class(inst):
    if KDIN.match(inst): return 'D'
    if WINREG.match(inst): return 'W'
    return 'K' if inst.startswith('cpu.core.') else 'O'

# Adapter -> kernel: data_in and berr change at the data latch, and the
# kernel samples them on the clock after clkena is set: DIN+1. IPL changes
# on a clkena edge (STEP); nReset one clock after one (STEP-1).
M_BUDGET = min(args.din + 1, args.step - 1)
BUDGET = {('O','O'): 1, ('O','K'): 1, ('C','O'): 1, ('C','K'): 1,
          ('M','K'): M_BUDGET, ('M','O'): 1,
          ('K','K'): args.step, ('K','O'): args.settle,
          ('O','D'): args.data, ('C','D'): 1, ('M','D'): 1, ('K','D'): args.settle,
          # the AS pin falls ADDR_SETUP+1 clocks after the address changes
          # (strobe pipeline), and the slaves act on it from then on.
          ('A','O'): args.asu + 1, ('A','K'): args.asu + 1, ('A','D'): args.asu + 1,
          ('S','O'): 4, ('S','K'): 4, ('S','D'): 4,
          ('I','O'): 1, ('I','K'): 1, ('I','D'): 1,
          ('O','W'): 1, ('A','W'): 1, ('C','W'): 1, ('M','W'): 1, ('K','W'): 1,
          ('S','W'): 1, ('I','W'): 1,
          ('Q','O'): 1, ('Q','K'): 1, ('Q','D'): 1, ('Q','W'): 1}

# ---- longest paths, one arrival per start class ------------------------------
indeg = collections.Counter()
nodes = set(edges) | set(clk2q)
for a, succ in edges.items():
    for b, _ in succ:
        indeg[b] += 1; nodes.add(b)
arr = {}                                  # node -> {cls: (time, pred, startinst)}
for node, (inst, d) in clk2q.items():
    c = start_class(inst)
    arr.setdefault(node, {})[c] = (clkpin_delay.get(inst, 0.0) + d, None, inst)
order = collections.deque(n for n in nodes if indeg[n] == 0)
seen = 0
while order:
    n = order.popleft(); seen += 1
    an = arr.get(n)
    for b, d in edges.get(n, ()):
        if an:
            ab = arr.setdefault(b, {})
            for c, (t, _, s) in an.items():
                if c not in ab or t + d > ab[c][0]:
                    ab[c] = (t + d, n, s)
        indeg[b] -= 1
        if indeg[b] == 0: order.append(b)
if seen < len(nodes):
    print('warning: %d nodes in combinational loops were not timed' % (len(nodes) - seen))

# ---- check -----------------------------------------------------------------
worst = collections.defaultdict(list)
for node, (inst, su) in setup.items():
    ec = end_class(inst)
    cap = clkpin_delay.get(inst, 0.0)
    for c, (t, pred, s) in arr.get(node, {}).items():
        budget = BUDGET[(c, ec)] * T
        slack = budget + cap - su - t
        worst[(c, ec)].append((slack, t, node, s))

def trace(node, c):
    out = []
    while node is not None:
        out.append(node)
        node = arr[node][c][1] if node in arr and c in arr[node] else None
    return out[::-1]

names = {'O': 'logic', 'C': 'clkena', 'M': 'adapter->kernel', 'K': 'kernel',
         'D': 'read-data latch', 'A': 'bus outputs', 'S': 'config regs',
         'I': 'icache/direct', 'W': 'window decode', 'Q': 'adapter ctrl'}
fail = False
print('Multicycle timing check at %.2f MHz (T = %.2f ns), STEP=%d SETTLE=%d DIN=%d DATA=%d'
      % (args.freq, T / 1000, args.step, args.settle, args.din, args.data))
print('%-34s %7s %9s %9s %6s' % ('path class', 'budget', 'worst ns', 'slack ns', 'paths'))
for key in sorted(worst, key=lambda k: min(x[0] for x in worst[k])):
    lst = sorted(worst[key])
    s0 = lst[0]
    bad = sum(1 for x in lst if x[0] < 0)
    fail |= bad > 0
    print('%-34s %5dT %9.2f %9.2f %6d%s' % (names[key[0]] + ' -> ' + names[key[1]],
          BUDGET[key], s0[1] / 1000, s0[0] / 1000, len(lst),
          ('   <-- %d FAIL' % bad) if bad else ''))
print()
for key in sorted(worst, key=lambda k: min(x[0] for x in worst[k])):
    for slack, t, node, s in sorted(worst[key])[:args.paths]:
        if slack > 2 * T and key[0] == 'O': continue
        print('[%s -> %s] slack %.2f ns, delay %.2f ns' % (names[key[0]], names[key[1]], slack / 1000, t / 1000))
        p = trace(node, key[0])
        insts = []
        for n in p:
            i = n.rsplit('/', 1)[0]
            if not insts or insts[-1] != i: insts.append(i)
        show = insts if len(insts) <= 8 else insts[:3] + ['... (%d more)' % (len(insts) - 6)] + insts[-3:]
        for i in show: print('      ' + i)
print('RESULT:', 'FAIL' if fail else 'PASS')
sys.exit(1 if fail else 0)
