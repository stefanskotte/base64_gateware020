#!/usr/bin/env python3
"""Send a program to the harness ROM loader and print what it prints.

    python3 host/run.py build/test.bin [--port /dev/cu.usbmodemXXXX]
                        [--bit build/tg68_harness.bit] [--timeout 120]

--bit loads the bitstream into the FPGA first (openFPGALoader over the
iCELink, volatile: nothing is written to flash). The program is loaded at
and started from $08000000. Exits 0 if the program prints "RESULT: PASS".
No pyserial needed (POSIX termios); on Windows use WSL or adapt the port code.
"""
import argparse, glob, os, select, subprocess, sys, termios, time

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('prog')
ap.add_argument('--port', help='serial port (default: the only /dev/cu.usbmodem* or /dev/ttyACM*)')
ap.add_argument('--bit', help='bitstream to load first with openFPGALoader')
ap.add_argument('--timeout', type=float, default=120)
ap.add_argument('--addr', type=lambda s: int(s, 0), default=0x08000000)
a = ap.parse_args()

def find_port():
    # iCELink serial ports by name; on Linux they are /dev/ttyACM*
    ports = sorted(glob.glob('/dev/cu.usbmodem*') + glob.glob('/dev/ttyACM*'))
    if len(ports) == 1:
        return ports[0]
    sys.exit('several serial ports (%s): pick one with --port' % ', '.join(ports) if ports
             else 'no serial port found')

if a.bit:
    r = subprocess.run(['openFPGALoader', '-c', 'cmsisdap', '--vid', '0x1d50', '--pid', '0x602b', a.bit])
    if r.returncode:
        sys.exit('openFPGALoader failed')
    time.sleep(1.0)        # power-up hold (PWRUP_BIT 25: ~0.4 s) + loader banner

port = a.port or find_port()
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
t = termios.tcgetattr(fd)
t[0] = 0; t[1] = 0; t[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; t[3] = 0
t[4] = t[5] = termios.B115200
t[6][termios.VMIN] = 0; t[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, t)
termios.tcflush(fd, termios.TCIOFLUSH)

data = open(a.prog, 'rb').read()
pkt = b'B64L' + len(data).to_bytes(4, 'big') + a.addr.to_bytes(4, 'big') * 2 \
      + data + (sum(data) & 0xFFFFFFFF).to_bytes(4, 'big')
print('[run] %s: %d bytes -> $%08X on %s (%.1f s at 115200)' % (a.prog, len(data), a.addr, port, len(pkt) / 11520))
# send in chunks, reading back as we go so output is never lost
sent, buf, t0 = 0, b'', time.time()
while sent < len(pkt):
    n = os.write(fd, pkt[sent:sent + 256]) if select.select([], [fd], [], 0.1)[1] else 0
    sent += n
    try:
        buf += os.read(fd, 4096)
    except BlockingIOError:
        pass
sys.stdout.write(buf.decode('latin-1').replace('\r', '')); sys.stdout.flush()
line, ok, deadline = b'', None, time.time() + a.timeout
while time.time() < deadline and ok is None:
    if not select.select([fd], [], [], 0.5)[0]:
        continue
    try:
        chunk = os.read(fd, 4096)
    except BlockingIOError:
        continue
    sys.stdout.write(chunk.decode('latin-1').replace('\r', '')); sys.stdout.flush()
    for c in chunk:
        if c == 10:
            if line.startswith(b'RESULT: PASS'): ok = True
            elif line.startswith(b'RESULT:') or line.startswith(b'ERR'): ok = False
            line = b''
        elif c != 13:
            line += bytes([c])
os.close(fd)
if ok is None:
    print('\n[run] timed out after %.0f s' % a.timeout)
sys.exit(0 if ok else 1)
