#!/usr/bin/env python3
"""Convert a raw image to an Android sparse image (img2simg without libsparse).

  raw2simg.py RAW OUT [--block 4096]

Zero blocks become DONT_CARE chunks: fastboot skips them, and a freshly
created filesystem never reads blocks outside its own metadata.
"""
import argparse, os, struct, sys

MAGIC = 0xed26ff3a
RAW, DONT_CARE = 0xcac1, 0xcac3
MAX_CHUNK = 4096  # blocks; 16 MiB at 4 KiB, bounds memory use


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('raw')
    ap.add_argument('out')
    ap.add_argument('--block', type=int, default=4096)
    a = ap.parse_args()
    bs = a.block
    size = os.path.getsize(a.raw)
    if size % bs:
        sys.exit(f'{a.raw}: size is not a multiple of {bs}')
    nblocks = size // bs

    chunks = 0
    zero_run = 0
    raw_buf = bytearray()
    zero = bytes(bs)

    with open(a.raw, 'rb') as src, open(a.out, 'wb') as out:
        out.write(b'\0' * 28)  # header patched once total_chunks is known

        def flush_raw():
            nonlocal chunks
            if raw_buf:
                n = len(raw_buf) // bs
                out.write(struct.pack('<HHII', RAW, 0, n, 12 + n * bs))
                out.write(raw_buf)
                raw_buf.clear()
                chunks += 1

        def flush_zero():
            nonlocal chunks, zero_run
            while zero_run:
                n = min(zero_run, MAX_CHUNK)
                out.write(struct.pack('<HHII', DONT_CARE, 0, n, 12))
                chunks += 1
                zero_run -= n

        step = (8 << 20) // bs
        done = 0
        while done < nblocks:
            window = src.read(min(step, nblocks - done) * bs)
            if len(window) != min(step, nblocks - done) * bs:
                sys.exit(f'{a.raw}: unexpected EOF')
            for i in range(0, len(window), bs):
                block = window[i:i + bs]
                if block == zero:
                    flush_raw()
                    zero_run += 1
                else:
                    flush_zero()
                    raw_buf += block
                    if len(raw_buf) >= MAX_CHUNK * bs:
                        flush_raw()
            done += len(window) // bs
        flush_raw()
        flush_zero()

        out.seek(0)
        out.write(struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, bs,
                              nblocks, chunks, 0))
    print(f'{a.out}: {nblocks} blocks, {chunks} chunks')


if __name__ == '__main__':
    main()
