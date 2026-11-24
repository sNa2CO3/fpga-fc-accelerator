# 基于 FPGA 的全连接神经网络硬件加速器（PYNQ-Z2）

三层全连接网络的硬件加速器：PS 端通过 AXI DMA 把样本送进 PL，PL 内的 NPU 依次完成
FC1(512→128)、FC2(128→32)、FC3(32→2) 三层计算，结果经 AXI-Stream 回传。

- 器件：`xc7z020clg400-1`（PYNQ-Z2，`tul.com.tw:pynq-z2:part0:1.0`）
- 工具：Vivado 2022.1
- 42 张样本，分类准确率 **37/42 = 88.10%**
- 42 张合成**一笔 DMA**，硬件窗口 488 µs，均摊 **11.6 µs/张**

## 目录

```
rtl/        RTL 源码
              fc_top.v            数据流控制（9 状态机、批处理计数、特征图回读）
              fc1.v / fc2.v / fc3.v   三层计算
              mult_array_8.v      64 路 8×8 乘法阵列
              adder_tree.v        加法树
              axis_rd_interface.v AXI-Stream → 异步 FIFO → NPU
              axis_wr_interface.v 异步 FIFO → AXI-Stream（含 tlast）
              fc_out_packer.v     8bit → 64bit 打包
              pl_fc_top.v         顶层
              asy_fifo.v          格雷码异步 FIFO
tb/         tb_pl.v            行为级联合仿真（同频 / 跨时钟域 / 4 包与 12 包连发）
constrs/    lab8.xdc
bd/         design_1.bd       Block Design（PS7 + AXI DMA + SmartConnect + pl_fc_top）
ip/         各 BRAM / 乘法器 IP 的 .xci 与 .mif
scripts/    setup_project.tcl / create_ip.tcl / build_bd.tcl / build_bitstream.tcl
            run_xsim.sh        命令行仿真（xvlog → xvhdl → xelab → xsim）
            run_timing.tcl     时序与资源报告
sw/         板端辅助脚本
              dma_probe.py    DMA 固定开销探针
              bt.py           逐样本验证（按样本计数）
              bench.py        批大小扫描与分层计时
docs/       设计文档 9 篇（入口：docs/README.md），含 3 张可编辑的架构图
output/     lab8.bit / lab8.hwh   已构建的比特流与硬件描述
            lab8_npu.py          板端推理脚本
            sel_data.coe / sel_labels.txt   42 个样本与标签
            上板步骤.txt          上板操作与预期输出
```

## 上板运行

把 `output/` 下的 `lab8.bit`、`lab8.hwh`、`lab8_npu.py`、`sel_data.coe`、`sel_labels.txt`
放到板子的同一目录（如 `/home/xilinx/jupyter_notebooks/lab8`），然后：

```bash
python3 lab8_npu.py        # 不要加 sudo
```

预期输出：

```
accuracy      = 37/42 = 88.10 %
batch HW time = 488 us  ->  11.6 us/sample
  fc1[0:8] = [4, 1, 0, 0, 0, 0, 0, 0]
  fc2[0:8] = [3, 0, 3, 0, 0, 2, 5, 0]
  fc3      = [10, -11]
```

想对比逐张模式：`LAB8_BATCH=1 python3 lab8_npu.py`

## 主要指标

| 项目 | 数值 |
|---|---|
| 准确率 | 37/42 = 88.10 %（与未截位基线一致） |
| PL 三层计算 | 1144 拍 = **9.152 µs** @125 MHz |
| PL 整包（含收发） | 1339 拍 = 10.712 µs |
| 端到端 PS→PL→PS | **11.6 µs/张**（42 张一笔 DMA） |
| DSP48E1 | 64 / 220（29.09 %） |
| Block RAM | 63 / 140（45.00 %） |
| LUT / FF | 12 430（23.36 %）/ 16 331（15.35 %） |
| 时序 | WNS **+0.403 ns** @8 ns，0 失败端点 |
| 片上功耗 | 1.653 W（动态 1.506 + 静态 0.147） |

## 复现构建

```bash
# 1) 建工程与 IP
vivado -mode gui -source scripts/setup_project.tcl
vivado -mode gui -source scripts/create_ip.tcl

# 2) 建 Block Design（必须在 GUI 模式，batch 下 xgui 初始化会失败）
vivado -mode gui -source scripts/build_bd.tcl

# 3) 综合、实现、出比特流
vivado -mode gui -source scripts/build_bitstream.tcl
```

行为级仿真（Git Bash 下用命令行，不走 GUI 的 launch_simulation）：

```bash
bash scripts/run_xsim.sh rtl _work/sim
```

## 设计要点

- **三层共用一套 64 路乘法阵列与加法树**：DSP 从 152 降到 64（−58%），代价是三层分时。
- **8bit 逐层截位**：FC1/2/3 分别右移 10/9/8 位，分类结果与未截位基线完全一致。
- **批处理与 tlast 门控**：指令字 `[15:8]` 携带本批剩余张数，`fc_top` 只在最后一张产生
  `output_data_last`，避免 S2MM 收到第一个 tlast 就结束传输。
  实测每笔 DMA 有约 48 µs(MM2S) + 28 µs(S2MM) 的固定开销，批处理把它摊到 1/42。
- **流水线对齐**：BRAM 3 拍 + 乘法 3 拍 + 加法树 6 拍 = 前段 12 拍，累加/偏置/输出
  控制索引分别对齐第 12/13/15 拍。

## 说明

本仓库只包含 RTL、仿真、脚本、文档与已构建的比特流。
课程报告（docx）与汇报 PPT 因含个人信息未包含在内。

## 许可

课程设计用途。如需引用请注明出处。
