// ===========================================================================
// adder_tree.v  ——  通用参数化、全流水、有符号加法树
//
// 与 Lab4 那个版本的区别:
//   Lab4 的树把输入按 4:1、8:1 分组, 只在 NUM_INPUTS = 64/128 时可用,
//   而且某一级里串了 7 个加法器(组合深度大、是 Fmax 的瓶颈)。
//   这里改成**平衡二叉树**: 每级只做一次两两相加、每级一个寄存器,
//   对任意 2 的幂的 NUM_INPUTS 都成立, 而且每一级的组合深度都只有 1 个加法器。
//
// 位宽增长:
//   两个 W 位**有符号**数相加, 结果一定能用 W+1 位有符号数表示(不会溢出)。
//   所以经过 k 级之后位宽正好是 DATA_WIDTH + k, 顶层是 DATA_WIDTH + LEVELS。
//   这是**精确**的最坏情况, 不是估算 —— 全程不截位。
//
// 延迟: LEVELS = $clog2(NUM_INPUTS) 拍。
//
// 例化(三层):
//   adder_tree #(.NUM_INPUTS(64), .DATA_WIDTH(16), .SUM_WIDTH(32))  // fc1
//   adder_tree #(.NUM_INPUTS(32), .DATA_WIDTH(40), .SUM_WIDTH(48))  // fc2
//   adder_tree #(.NUM_INPUTS( 8), .DATA_WIDTH(56), .SUM_WIDTH(64))  // fc3
// ===========================================================================
`timescale 1ns / 1ps

module adder_tree #(
    parameter NUM_INPUTS = 64,      // 2 的幂: 8 / 32 / 64
    parameter DATA_WIDTH = 16,      // 单个输入的位宽(乘积位宽)
    parameter SUM_WIDTH  = 32       // 输出位宽, 必须 >= DATA_WIDTH + $clog2(NUM_INPUTS)
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire [NUM_INPUTS*DATA_WIDTH-1:0]  data,   // 车道 0 在最低位 data[DATA_WIDTH-1:0]
    output wire signed [SUM_WIDTH-1:0]       sum_out
);

    // LEVELS 级寄存器; 树节点用**一个扁平数组**存, 用算出来的偏移量区分层级。
    // 第 L 级(L=1..LEVELS)有 NUM_INPUTS>>L 个节点, 起始下标
    //     base(L) = NUM_INPUTS - (NUM_INPUTS >> (L-1))
    // 所有节点共用 WTOP 位宽度 —— 比逐级精确位宽多几个触发器, 但省掉了
    // "generate 里跨层引用信号名"这种容易出错的写法。实测浪费 < 10% 触发器。
    localparam LEVELS = $clog2(NUM_INPUTS);
    localparam WTOP   = DATA_WIDTH + LEVELS;   // 顶层节点的精确位宽

    // 节点总数 = NUM_INPUTS-1 (每级节点数之和), 最后一级只剩 1 个, 下标 NUM_INPUTS-2
    localparam TOPNODE = NUM_INPUTS - 2;
    reg signed [WTOP-1:0] node [0:TOPNODE];

    genvar g, i;

    // --- 第 0 层: 把输入总线拆成 NUM_INPUTS 个字, 并**显式符号扩展** -------
    //     !! data[k*DATA_WIDTH +: DATA_WIDTH] 是**无符号**部分选择,
    //        直接赋给更宽的 signed 线会零扩展, 把负数乘积算错。
    wire signed [WTOP-1:0] lvl0 [0:NUM_INPUTS-1];
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : GEN_L0
            assign lvl0[i] = {{(WTOP-DATA_WIDTH){data[i*DATA_WIDTH + DATA_WIDTH-1]}},
                               data[i*DATA_WIDTH +: DATA_WIDTH]};
        end
    endgenerate

    // --- 各级两两相加 ------------------------------------------------------
    generate
        for (g = 1; g <= LEVELS; g = g + 1) begin : GEN_LVL

            localparam CNT  = NUM_INPUTS >> g;                     // 本级的节点数
            localparam BASE = NUM_INPUTS - (NUM_INPUTS >> (g-1));  // 本级的起始下标

            if (g == 1) begin : G_FIRST
                integer k;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (k = 0; k < CNT; k = k + 1)
                            node[BASE+k] <= {WTOP{1'b0}};
                    end else begin
                        for (k = 0; k < CNT; k = k + 1)
                            node[BASE+k] <= lvl0[2*k] + lvl0[2*k+1];
                    end
                end
            end else begin : G_REST
                localparam PBASE = NUM_INPUTS - (NUM_INPUTS >> (g-2));  // 上一级起始下标
                integer k;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (k = 0; k < CNT; k = k + 1)
                            node[BASE+k] <= {WTOP{1'b0}};
                    end else begin
                        for (k = 0; k < CNT; k = k + 1)
                            node[BASE+k] <= node[PBASE+2*k] + node[PBASE+2*k+1];
                    end
                end
            end

        end
    endgenerate

    // --- 输出: 最后一级正好剩 1 个节点, 符号扩展到 SUM_WIDTH ----------------
    wire signed [WTOP-1:0] top = node[TOPNODE];
    assign sum_out = {{(SUM_WIDTH-WTOP){top[WTOP-1]}}, top};

endmodule
