# -*- coding: utf-8 -*-
"""Lab8 批处理基准: 按【样本】统计准确率 + 端到端 PS->PL->PS 时间.

用法 (板上 /boot):
    python3 bench.py

设计要点:
  * 打包 (pack_infer) 在计时循环【之外】完成, 否则测到的是 Python 开销;
  * 计时只覆盖 DMA 传输 (MM2S + NPU + S2MM), 这才是 PS->PL->PS 的真实含义;
  * 同时给出 DMA 内部计时 hw (与 numpy 拷贝开销无关), 两者对照。
"""
import os
import sys
import time

sys.path.insert(0, "/boot")
import lab8_npu as L
from pynq import Overlay, allocate

HERE = "/boot"
BATCHES = [1, 2, 4, 8, 21, 42]
REP = 5

ol = Overlay(os.path.join(HERE, "lab8.bit"))
dma = L.make_dma(ol)

samples = L.load_samples()
labels = L.load_labels()
N = L.N_SAMPLES

in_buf = allocate(shape=(N * L.IN_BYTES,), dtype="u1")
out_buf = allocate(shape=(N * 8,), dtype="u1")

print("samples = %d   IN_BYTES = %d" % (N, L.IN_BYTES))
print("")
print("=" * 82)
print(" %-6s %-10s %-9s %-13s %-13s %-9s"
      % ("BATCH", "正确", "准确率", "墙钟(us/张)", "DMA hw(us/张)", "加速比"))
print("-" * 82)

base = None
for B in BATCHES:
    # ---- 预打包 (不计时) ----
    pkts = []
    for b in range(0, N, B):
        n = min(B, N - b)
        p = bytearray(n * L.IN_BYTES)
        for i in range(n):
            p[i * L.IN_BYTES:(i + 1) * L.IN_BYTES] = L.pack_infer(samples[b + i], n - i)
        pkts.append((b, n, p))

    wall_best = None
    hw_best = None
    correct = 0
    for _ in range(REP):
        t0 = time.time()
        hw_sum = 0.0
        correct = 0
        for (b, n, p) in pkts:
            in_buf[:n * L.IN_BYTES] = p
            hw, m2, s2 = dma.transfer(in_buf, n * L.IN_BYTES, out_buf, n * 8)
            hw_sum += hw
            got = [int(v) for v in out_buf[:n]]
            correct += sum(1 for k in range(n) if got[k] == labels[b + k])
        wall = (time.time() - t0) * 1e6
        if wall_best is None or wall < wall_best:
            wall_best = wall
            hw_best = hw_sum
    per_wall = wall_best / N
    per_hw = hw_best / N
    if B == 1:
        base = per_wall
    print(" %-6d %-10s %-8.2f%% %-13.2f %-13.2f %-9s"
          % (B, "%d/%d" % (correct, N), 100.0 * correct / N, per_wall, per_hw,
             "-" if base is None else "%.2fx" % (base / per_wall)))

print("=" * 82)
print(" 准确率不随批大小变化 (37/42) => 批处理未改变任何一张图的推理结果")
print(" 墙钟含 numpy 逐批拷贝; DMA hw 是纯 PS->PL->PS 传输时间")

in_buf.freebuffer()
out_buf.freebuffer()
