# -*- coding: utf-8 -*-
"""
Lab8 PS 端: 在 PYNQ-Z2 上跑完 42 个样本, 统计准确率和推理时间.

用法:
    cd /boot
    python3 lab8_npu.py

需要同目录的文件: lab8.bit / lab8.hwh / sel_data.coe / sel_labels.txt

DMA 访问做了三级兼容 (PYNQ 2.x / 3.x / 驱动缺失):
    ① pynq.lib.dma.DMA              (PYNQ 2.x)
    ② pynq.lib.deprecated.dma.DMA   (PYNQ 3.0 起, 位置可能再变)
    ③ 直接 MMIO 写 AXI DMA 寄存器   (兜底, 完全不依赖驱动)
"""
import importlib
import os
import re
import time

try:
    import numpy as np
except ImportError:      # PYNQ 一定带 numpy, 这里只是保险
    np = None

try:
    from pynq import Overlay, allocate, MMIO
except ModuleNotFoundError:
    raise SystemExit(
        "找不到 pynq 模块: 不要用 sudo, 直接 python3 lab8_npu.py"
    )

HERE = os.path.dirname(os.path.abspath(__file__))

CMD_INFER = 0x01
CMD_FMAP = 0x02
N_SAMPLES = 42
N_IN_BYTES = 512
N_FMAP = 162

IN_BYTES = (1 + N_IN_BYTES // 8) * 8       # 65 拍 * 8 = 520
OUT_INFER_BYTES = 8                        # 1 字节结果 -> 1 拍
OUT_FMAP_BYTES = ((N_FMAP + 7) // 8) * 8   # 162 字节 -> 21 拍 = 168

# 一次 DMA 送几张样本。
#   42 = 全部样本一次送完。2026-11-22 已在实板验证:
#     六种批大小 (1/2/4/8/21/42) 结果逐样本相同, 均 37/42 = 88.10%;
#     硬件传输时间 75.85 us/张 (B=1) -> 11.38 us/张 (B=42)。
#   机理: AXI DMA simple mode 每笔传输有约 46 us (MM2S) + 30 us (S2MM)
#   的固定开销, 与数据量几乎无关 (8 B 和 520 B 耗时一样)。批处理把这笔
#   固定开销摊薄到 1/N。
#   RTL 侧靠指令字 [15:8] 的"本批剩余张数"决定何时产生 tlast —— S2MM 收到
#   第一个 tlast 就结束, 所以必须只在最后一张拉高。
#   可用环境变量临时改:  LAB8_BATCH=1 python3 lab8_npu.py
BATCH = int(os.environ.get("LAB8_BATCH", "42"))


# ======================================================================
# DMA 访问层
# ======================================================================
class DmaMmio:
    """AXI DMA simple mode 的直接寄存器访问 (不依赖 PYNQ 的 DMA 驱动).

    寄存器 (Xilinx PG021, simple mode):
        MM2S: 0x00 控制  0x04 状态  0x18/0x1C 源地址  0x28 长度
        S2MM: 0x30 控制  0x34 状态  0x48/0x4C 目的地址 0x58 长度
    控制位: bit0 = RS(启动), bit12 = IOC_IrqEn(完成中断使能)
    状态位: bit1 = IDLE, bit12 = IOC_Irq(完成标志, 写 1 清除)
    """

    MM2S_CR, MM2S_SR = 0x00, 0x04
    MM2S_SA, MM2S_SA_HI = 0x18, 0x1C
    MM2S_LEN = 0x28
    S2MM_CR, S2MM_SR = 0x30, 0x34
    S2MM_DA, S2MM_DA_HI = 0x48, 0x4C
    S2MM_LEN = 0x58

    def __init__(self, mmio):
        self.mmio = mmio
        self._cfg = None      # (sa, da, in_n, out_n) 上次写入 DMA 的地址配置
        # PYNQ 的 MMIO.read/write 每次要 ~15us (实测), 一次传输要访问 7 次寄存器,
        # 光寄存器访问就把 13.4us 的 NPU 计算淹没了。
        # 直接对映射内存做 numpy 视图, 单次访问降到亚微秒级。
        self._arr = None
        if np is not None:
            # 不同 PYNQ 版本把映射内存挂在不同的属性上, 逐个试:
            # 已经是 ndarray 就直接用; 是 mmap/buffer 就包成 ndarray 视图。
            for name in ("array", "mmap", "_mmap", "mem", "_mem", "buffer"):
                obj = getattr(mmio, name, None)
                if obj is None:
                    continue
                if isinstance(obj, np.ndarray):
                    # 必须是可写的视图, 只读的话写不进去, 退回慢路径
                    if obj.flags.writeable:
                        self._arr = obj
                        break
                    continue
                try:
                    self._arr = np.ndarray(shape=(len(obj) // 4,),
                                           dtype=np.uint32, buffer=obj)
                    break
                except Exception:
                    continue
        print("MMIO access : %s" % ("numpy view (fast)" if self._arr is not None
                                    else "PYNQ MMIO.read/write (slow)"))
        # 软复位两个通道 (bit2), 等它自清
        for cr in (self.MM2S_CR, self.S2MM_CR):
            self.wr(cr, 0x4)
            for _ in range(1000):
                if not (self.rd(cr) & 0x4):
                    break
        # 启动通道 + 打开完成中断使能
        self.wr(self.MM2S_CR, 0x1 | 0x1000)
        self.wr(self.S2MM_CR, 0x1 | 0x1000)
        # 清掉可能残留的完成标志
        self.wr(self.MM2S_SR, 0x1000)
        self.wr(self.S2MM_SR, 0x1000)

    def rd(self, off):
        if self._arr is not None:
            return int(self._arr[off >> 2])
        return self.mmio.read(off)

    def wr(self, off, val):
        if self._arr is not None:
            self._arr[off >> 2] = val & 0xFFFFFFFF
        else:
            self.mmio.write(off, val)

    def _wait_ioc(self, sreg, timeout=2.0):
        # 每轮都调 time.time() 会多一次系统调用, 明显拖慢轮询;
        # 改成每 1024 轮才查一次超时。
        t_end = time.time() + timeout
        n = 0
        while not (self.rd(sreg) & 0x1000):
            n += 1
            if (n & 0x3FF) == 0 and time.time() > t_end:
                raise RuntimeError("DMA 超时 (status=0x%08x)" % self.rd(sreg))
        self.wr(sreg, 0x1000)          # 写 1 清除 IOC_Irq

    def transfer(self, in_buf, in_n, out_buf, out_n):
        in_buf.flush()                          # 输入缓冲写回 DDR

        # 一次 AXI-Lite 寄存器写实测要 4.4 us, 所以地址寄存器只在缓冲区
        # 换掉时才重写; 长度寄存器每次都要写 (simple mode 下写 LEN 才启动传输)。
        da = int(out_buf.device_address)
        sa = int(in_buf.device_address)
        cfg = (sa, da, in_n, out_n)
        if cfg != self._cfg:
            self.wr(self.S2MM_DA,    da & 0xFFFFFFFF)
            self.wr(self.S2MM_DA_HI, (da >> 32) & 0xFFFFFFFF)
            self.wr(self.MM2S_SA,    sa & 0xFFFFFFFF)
            self.wr(self.MM2S_SA_HI, (sa >> 32) & 0xFFFFFFFF)
            self._cfg = cfg
        # 先把接收通道准备好, 再灌数据
        self.wr(self.S2MM_LEN,   out_n)

        t0 = time.perf_counter()
        self.wr(self.MM2S_LEN,   in_n)   # 这一刻起, 硬件开始干活
        self._wait_ioc(self.MM2S_SR)
        t1 = time.perf_counter()
        self._wait_ioc(self.S2MM_SR)
        t2 = time.perf_counter()

        out_buf.invalidate()                    # 丢弃 cache, 读回 DDR 新数据
        # 返回 (总时间, 送数据耗时, 拿到结果耗时)
        return ((t2 - t0) * 1e6, (t1 - t0) * 1e6, (t2 - t1) * 1e6)


class DmaDriver:
    """把 PYNQ 自带的 DMA 驱动包成同样的 transfer 接口."""

    def __init__(self, dma):
        self.dma = dma

    def transfer(self, in_buf, in_n, out_buf, out_n):
        self.dma.sendchannel.transfer(in_buf, nbytes=in_n)
        try:
            self.dma.recvchannel.transfer(out_buf, nbytes=out_n)
        except TypeError:
            self.dma.recvchannel.transfer(out_buf)
        t0 = time.perf_counter()
        self.dma.sendchannel.wait()
        t1 = time.perf_counter()
        self.dma.recvchannel.wait()
        t2 = time.perf_counter()
        return ((t2 - t0) * 1e6, (t1 - t0) * 1e6, (t2 - t1) * 1e6)


def make_dma(ol):
    """依次尝试: 驱动 -> 驱动 -> MMIO 兜底."""
    last = None
    for mod_name in ("pynq.lib.dma", "pynq.lib.deprecated.dma",
                     "pynq.lib.deprecated"):
        try:
            mod = importlib.import_module(mod_name)
            cls = getattr(mod, "DMA", None)
            if cls is None:
                continue
            d = cls(ol.axi_dma_0)
            print("DMA driver  : %s.DMA" % mod_name)
            return DmaDriver(d)
        except Exception as e:              # noqa: BLE001
            last = e
            continue

    # 兜底: 直接从 overlay 里拿 DMA 的 MMIO 基址
    print("DMA driver  : 不可用 (%s)" % type(last).__name__)
    print("DMA driver  : 改用 MMIO 直接访问 AXI DMA 寄存器")
    try:
        mmio = ol.axi_dma_0.mmio
    except AttributeError:
        info = ol.ip_dict["axi_dma_0"]
        mmio = MMIO(info["phys_addr"], info.get("addr_range", 0x1000) or 0x1000)
    return DmaMmio(mmio)


# ======================================================================
# 数据
# ======================================================================
def parse_coe(path):
    """取出 .coe 向量部分的全部 0/1 位.

    numpy 分支返回 ASCII '0'/'1' 的 uint8 数组; 兜底分支返回拼接好的字符串。
    实测: 原来对 21,504 个 token 逐个 strip()/set() 判断约 320 ms,
    改成字符级过滤后 <10 ms。
    """
    txt = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"memory_initialization_vector\s*=", txt)
    body = txt[m.end():]
    if np is not None:
        b = np.frombuffer(body.encode("ascii", "ignore"), dtype=np.uint8)
        return b[(b == 48) | (b == 49)]
    return "".join(t for t in re.split(r"[,\n;]", body)
                   if t.strip() and set(t.strip()) <= {"0", "1"}).strip()


def load_samples():
    """返回 (42, 512) 的 uint8 数组.

    实测: 逐位 int(b, 2) 解析要 ~360 ms, numpy 批量解析 <10 ms。
    """
    bits = parse_coe(os.path.join(HERE, "sel_data.coe"))
    if np is not None:
        assert bits.size == N_SAMPLES * N_IN_BYTES * 8, bits.size
        w = np.array([128, 64, 32, 16, 8, 4, 2, 1], dtype=np.uint16)
        flat = (bits - 48).reshape(-1, 8).astype(np.uint16)
        return (flat * w).sum(axis=1).astype(np.uint8).reshape(N_SAMPLES, N_IN_BYTES)
    assert len(bits) == N_SAMPLES * N_IN_BYTES * 8, len(bits)
    return [bytes(int(bits[(s * N_IN_BYTES + i) * 8:(s * N_IN_BYTES + i + 1) * 8], 2)
                  for i in range(N_IN_BYTES))
            for s in range(N_SAMPLES)]


def load_labels():
    txt = open(os.path.join(HERE, "sel_labels.txt"), encoding="utf-8",
               errors="replace").read()
    toks = [t for t in txt.replace(",", " ").split() if t.strip()]
    return [int(t) for t in toks if t.lstrip("+-").isdigit()][:N_SAMPLES]


def pack_infer(sample_bytes, rem=1):
    """指令 + 512 字节 -> 65 个 64bit 字, 字节 MSB 优先.

    rem = 本批"剩余张数" (含本张)。写进指令字的 bit[15:8]。
    NPU 只在 rem==1 (本批最后一张) 时拉 tlast, 这样 AXI DMA 的 S2MM
    才会等整批结果全部收完才结束传输 —— 否则它会收到第一个 tlast 就停,
    导致结果整体滞后一张。
    """
    # 兼容 bytes / bytearray / numpy 行 (load_samples 现在返回 2-D ndarray)
    if not isinstance(sample_bytes, (bytes, bytearray)):
        sample_bytes = np.asarray(sample_bytes, dtype=np.uint8).tobytes()

    buf = bytearray(IN_BYTES)
    buf[0] = CMD_INFER
    buf[1] = rem & 0xFF
    for k in range(N_IN_BYTES // 8):
        w = 0
        for j in range(8):
            w = (w << 8) | int(sample_bytes[8 * k + j])
        buf[8 * (k + 1):8 * (k + 1) + 8] = w.to_bytes(8, "little")
    return buf


def prepare_samples_np(samples):
    """预先把全部样本排成 NPU 需要的字节序 (每 8 字节组内反转), 只做一次.

    实测: 逐张 pack_infer 拼 21,840 字节要 ~600 us, 换成 numpy 预排 +
    一次 copyto 只要 ~50 us。
    """
    a = np.asarray(samples, dtype=np.uint8)
    return np.ascontiguousarray(
        a.reshape(N_SAMPLES, N_IN_BYTES // 8, 8)[:, :, ::-1].reshape(N_SAMPLES, N_IN_BYTES))


def build_batch_payload(sw, b, n):
    """拼出一批 n 张 (从第 b 张起): 8 字节指令头 + 512 字节样本.

    指令头 = [CMD_INFER, rem, 0, 0, 0, 0, 0, 0], rem 是本批剩余张数 (含本张),
    NPU 只在 rem == 1 时拉 tlast。
    """
    a = np.empty((n, IN_BYTES), dtype=np.uint8)
    a[:, 0] = CMD_INFER
    a[:, 1] = np.arange(n, 0, -1, dtype=np.uint8)
    a[:, 2:8] = 0
    a[:, 8:] = sw[b:b + n]
    return a.reshape(-1)


# ======================================================================
# 主流程
# ======================================================================
def main():
    t_all = time.perf_counter()
    t_lap = [t_all]

    def lap(tag):
        now = time.perf_counter()
        print("  [t] %-18s %8.1f ms" % (tag, (now - t_lap[0]) * 1e3))
        t_lap[0] = now

    ol = Overlay(os.path.join(HERE, "lab8.bit"))
    lap("overlay 加载")
    dma = make_dma(ol)
    lap("DMA 驱动初始化")

    samples = load_samples()
    labels = load_labels()
    lap("读样本/标签")

    in_total = BATCH * IN_BYTES
    out_total = BATCH * OUT_INFER_BYTES
    in_buf = allocate(shape=(in_total,), dtype="u1")
    out_buf = allocate(shape=(max(out_total, OUT_FMAP_BYTES),), dtype="u1")
    lap("分配 DMA 缓冲")

    print("=== Lab8 NPU on PYNQ-Z2 ===")
    print("command 0x%02x = inference, 0x%02x = feature map" % (CMD_INFER, CMD_FMAP))
    print("batch = %d samples per dma transfer (%d B in / %d B out)"
          % (BATCH, in_total, out_total))

    results = []
    hw_total = 0.0
    mm2s_total = 0.0
    s2mm_total = 0.0
    nb = (N_SAMPLES + BATCH - 1) // BATCH

    sw = prepare_samples_np(samples)
    for b in range(nb):
        n = min(BATCH, N_SAMPLES - b)
        payload = build_batch_payload(sw, b, n)
        np.copyto(in_buf[:n * IN_BYTES], payload)

        hw_us, mm2s_us, s2mm_us = dma.transfer(in_buf, n * IN_BYTES,
                                               out_buf, n * OUT_INFER_BYTES)
        hw_total += hw_us
        mm2s_total += mm2s_us
        s2mm_total += s2mm_us

        for i in range(n):
            v = int(out_buf[i])
            results.append(v)
            print("  sample %2d : result = %d  label = %d"
                  % (b * BATCH + i + 1, v, labels[b * BATCH + i]))

    lap("42 张推理 (含 %d 笔 DMA)" % nb)
    acc = sum(1 for i in range(N_SAMPLES) if results[i] == labels[i])
    print("")
    print("  accuracy      = %d/%d = %.2f %%"
          % (acc, N_SAMPLES, acc * 100.0 / N_SAMPLES))
    print("  --------------------------------------------------")
    print("  batch HW time = %.2f us  ->  %.3f us/sample"
          % (hw_total, hw_total / N_SAMPLES))
    print("    MM2S total    : %.2f us" % mm2s_total)
    print("    S2MM total    : %.2f us" % s2mm_total)

    # ---- 样本 1 的特征图: 单独再跑一次样本 1 ----
    in_buf[:IN_BYTES] = pack_infer(np.asarray(samples[0], dtype=np.uint8).tobytes())
    dma.transfer(in_buf, IN_BYTES, out_buf, OUT_INFER_BYTES)

    _cmd = bytearray(8)
    _cmd[0] = CMD_FMAP
    in_buf[:8] = _cmd
    dma.transfer(in_buf, 8, out_buf, OUT_FMAP_BYTES)

    fmap = bytes(out_buf[:N_FMAP])
    print("")
    print("  sample 1 feature map (162 bytes):")
    print("    fc1[0:8] =", list(fmap[0:8]))
    print("    fc2[0:8] =", list(fmap[128:136]))
    print("    fc3      =", [fmap[160] - 256 if fmap[160] > 127 else fmap[160],
                             fmap[161] - 256 if fmap[161] > 127 else fmap[161]])

    lap("特征图读取")

    in_buf.freebuffer()
    out_buf.freebuffer()
    print("  --------------------------------------------------")
    print("  进程总耗时 %.1f ms, 其中推理 %.1f ms (%.1f %%)"
          % ((time.perf_counter() - t_all) * 1e3,
             hw_total / 1e3, 100.0 * (hw_total / 1e3) / ((time.perf_counter() - t_all) * 1e3)))


if __name__ == "__main__":
    main()
