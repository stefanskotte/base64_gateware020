#!/usr/bin/env python3
"""Copy one file onto a DAPLink MSD drive by writing raw FAT16 sectors.

Bypasses the macOS FSKit msdos driver (which fragments/delays writes so the
DAPLink bootloader aborts). Writes: file data (contiguous clusters, in order)
-> FAT chain (all FAT copies) -> root directory entry, each with fsync.

usage: sudo python3 rawcopy_fat16.py /dev/rdisk7 file.hex [--dry-run]
Unmount first:  diskutil unmount /Volumes/MAINTENANCE
"""
import os, struct, sys

def main():
    dev, src = sys.argv[1], sys.argv[2]
    dry = '--dry-run' in sys.argv
    data = open(src, 'rb').read()
    fd = os.open(dev, os.O_RDWR if not dry else os.O_RDONLY)

    def rd(lba, n=1):
        return os.pread(fd, n * bps, lba * bps)

    global bps
    bps = 512
    bs = os.pread(fd, 512, 0)
    bps, spc, rsv, nfat, nroot, tot16 = struct.unpack_from('<HBHBHH', bs, 11)
    spf, = struct.unpack_from('<H', bs, 22)
    tot32, = struct.unpack_from('<I', bs, 32)
    tot = tot16 or tot32
    root_lba = rsv + nfat * spf
    root_secs = (nroot * 32 + bps - 1) // bps
    data_lba = root_lba + root_secs
    nclus = (tot - data_lba) // spc
    cbytes = spc * bps
    print(f'bps={bps} spc={spc} rsv={rsv} nfat={nfat} spf={spf} nroot={nroot} '
          f'tot={tot} clusters={nclus}')
    assert bs[510:512] == b'\x55\xaa', 'no boot signature'
    assert 4085 <= nclus < 65525, 'not FAT16'

    fat = bytearray(rd(rsv, spf))
    need = (len(data) + cbytes - 1) // cbytes
    # find contiguous free run, start well past existing files
    start, run = None, 0
    for c in range(2, nclus + 2):
        if struct.unpack_from('<H', fat, c * 2)[0] == 0:
            run += 1
            if run == need:
                start = c - need + 1
                break
        else:
            run = 0
    assert start, 'no free run'

    root = bytearray(rd(root_lba, root_secs))
    slot = None
    for i in range(nroot):
        b = root[i * 32]
        if b in (0x00, 0xE5):
            slot = i
            break
    assert slot is not None, 'root full'
    print(f'file {len(data)} B -> {need} clusters from {start}, dir slot {slot}')
    if dry:
        return

    # 1. data, in order, sector-aligned
    buf = data + b'\x00' * (need * cbytes - len(data))
    lba0 = data_lba + (start - 2) * spc
    step = 32 * bps
    for off in range(0, len(buf), step):
        os.pwrite(fd, buf[off:off + step], lba0 * bps + off)
    os.fsync(fd)
    # 2. FAT chain
    for k in range(need):
        c = start + k
        struct.pack_into('<H', fat, c * 2, 0xFFFF if k == need - 1 else c + 1)
    for f in range(nfat):
        os.pwrite(fd, bytes(fat), (rsv + f * spf) * bps)
    os.fsync(fd)
    # 3. directory entry
    ent = bytearray(32)
    ent[0:11] = b'FIRMWAREHEX'
    ent[11] = 0x20
    struct.pack_into('<H', ent, 26, start)
    struct.pack_into('<I', ent, 28, len(data))
    root[slot * 32:slot * 32 + 32] = ent
    sec = slot * 32 // bps
    os.pwrite(fd, bytes(root[sec * bps:(sec + 1) * bps]), (root_lba + sec) * bps)
    os.fsync(fd)
    os.close(fd)
    print('written; wait ~15 s for the device to reboot')

main()
