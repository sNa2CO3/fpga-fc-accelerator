# -*- coding: utf-8 -*-
"""
Lab8 DMA 吞吐探针 —— 判断 51 us 的 MM2S 是"固定开销"还是"吞吐不足"

用法 (板上, 和 lab8.bit 同目录):
    python3 dma_probe.py

原理:
    测两次 MM2S
      A) 8   字节 (特征图指令, NPU 不重算)
      B) 520 字节 (一次完整推理的指令 + 样本)
    如果  A ≈ B  -> 固定开销主导 (每笔传输都要几十 us 的启动/寻址延迟)
                    => 批处理 (一次传多张) 才是正解
    如果  A << B  -> 吞吐不足
                    => 要改 DMA/HP 口配置 (burst size、HP0 频率等)

    由 (B-A) 还能反推真实吞吐:
        吞吐 = (520-8) bytes / (tB - tA)
"""
import os
import sys

from pynq import Overlay, allocate

import lab8_npu as L          # 复用 DmaMmio / make_dma

HERE = os.path.dirname(os.path.abspath(__file__))
N_REP = 20


def measure(dma, in_buf, out_buf, nbytes_in, nbytes_out):
    """重复 N_REP 次, 返回 (MM2S 平均, S2MM 平均) 单位 us."""
    m2 = s2 = 0.0
    for _ in range(N_REP):
        hw, a, b = dma.transfer(in_buf, nbytes_in, out_buf, nbytes_out)
        m2 += a
        s2 += b
    return m2 / N_REP, s2 / N_REP


def main():
    ol = Overlay(os.path.join(HERE, "lab8.bit"))
    dma = L.make_dma(ol)

    in_buf = allocate(shape=(L.IN_BYTES,), dtype="u1")
    out_buf = allocate(shape=(L.OUT_FMAP_BYTES,), dtype="u1")

    # ---- A) 8 字节: 只发特征图指令 ----
    cmd = bytearray(L.IN_BYTES)
    cmd[0] = L.CMD_FMAP
    in_buf[:] = cmd
    a_m2, a_s2 = measure(dma, in_buf, out_buf, 8, L.OUT_FMAP_BYTES)

    # ---- B) 520 字节: 一次完整推理 ----
    payload = bytearray(L.IN_BYTES)
    payload[0] = L.CMD_INFER
    in_buf[:] = payload
    b_m2, b_s2 = measure(dma, in_buf, out_buf, L.IN_BYTES, L.OUT_INFER_BYTES)

    print("")
    print("================ DMA probe (%d reps) ================" % N_REP)
    print("  A)   8 B  : MM2S %8.2f us   S2MM %8.2f us" % (a_m2, a_s2))
    print("  B) 520 B  : MM2S %8.2f us   S2MM %8.2f us" % (b_m2, b_s2))
    print("  --------------------------------------------------")
    print("  MM2S 差值 (520-8 字节) = %.2f us" % (b_m2 - a_m2))
    if b_m2 > a_m2 + 1e-6:
        thr = (L.IN_BYTES - 8) / ((b_m2 - a_m2) * 1e-6) / 1e6
        print("  推算吞吐           = %.2f MB/s" % thr)
    print("  --------------------------------------------------")
    if abs(b_m2 - a_m2) < 0.2 * b_m2:
        print("  结论: MM2S 以【固定开销】为主 (8B 和 520B 差不多)")
        print("        -> 批处理 (一次传多张) 最有效")
    else:
        print("  结论: MM2S 受【吞吐】限制 (520B 明显更久)")
        print("        -> 要查 DMA burst / HP0 频率 / 互联位宽")
    print("=====================================================")

    in_buf.freebuffer()
    out_buf.freebuffer()


if __name__ == "__main__":
    main()
