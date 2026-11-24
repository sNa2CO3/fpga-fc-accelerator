# -*- coding: utf-8 -*-
"""批大小对照实验: python3 bt.py <N>"""
import sys
sys.path.insert(0, "/boot")
import lab8_npu as L
from pynq import Overlay, allocate

B = int(sys.argv[1]) if len(sys.argv) > 1 else 1
ol = Overlay("/boot/lab8.bit")
dma = L.make_dma(ol)
samples = L.load_samples()
labels = L.load_labels()

in_buf = allocate(shape=(B * L.IN_BYTES,), dtype="u1")
out_buf = allocate(shape=(max(B * 8, L.OUT_FMAP_BYTES),), dtype="u1")

print("=== BATCH = %d ===" % B)
bad = 0
for b in range(0, L.N_SAMPLES, B):
    grp = samples[b:b + B]
    n = len(grp)
    payload = bytearray(n * L.IN_BYTES)
    for i in range(n):
        payload[i * L.IN_BYTES:(i + 1) * L.IN_BYTES] = L.pack_infer(grp[i], n - i)
    in_buf[:n * L.IN_BYTES] = payload
    hw, m2, s2 = dma.transfer(in_buf, n * L.IN_BYTES, out_buf, n * 8)
    got = [int(v) for v in out_buf[:n]]
    exp = labels[b:b + n]
    ok = got == exp
    if not ok:
        bad += 1
    print("  %2d..%2d  got=%s exp=%s %s  hw=%.1f m2=%.1f s2=%.1f"
          % (b + 1, b + n, got, exp, "OK " if ok else "BAD", hw, m2, s2))
print("=> %d/%d batches correct" % (L.N_SAMPLES // B + (1 if L.N_SAMPLES % B else 0) - bad,
                                     L.N_SAMPLES // B + (1 if L.N_SAMPLES % B else 0)))
in_buf.freebuffer(); out_buf.freebuffer()
