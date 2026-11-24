// ===========================================================================
// fc_top.v —— Lab7 网络数据流控制 (FC_top)
//
// 接口命名与课件第 13 / 19 页一致:
//   输入侧: din[63:0] / din_valid / din_ready / fifo_empty
//   输出侧: output_data[7:0] / output_data_vld / fifo_wren / outfifo_full
//   状态  : done_o, 内部 state[3:0] / cmd_reg[31:0] / data_count
//
// 与 FIFO 的连接方式(课件第 13 页):
//   in_fifo.rd_en   <- din_ready      (控制单元要数据)
//   in_fifo.dout    -> din
//   in_fifo.valid   -> din_valid      (读使能后一拍)
//   in_fifo.empty   -> fifo_empty
//   out_fifo.wr_en  <- fifo_wren      (有效且不满时才真正写)
//   out_fifo.din    <- output_data
//   out_fifo.full   -> outfifo_full
//
// 状态机 (9 状态, 编码与课件参考波形一致):
//   推理  : idle → command → data_receive → FC1 → FC2 → FC3 → FC3_out → idle
//   特征图: command → FC1_out(128B) → FC2_out(32B) → FC3_out(2B) → idle
//
// 指令字 (64bit 的 din, 只用低 8 位):
//   0x01 = 推理, 随后 64 个 64bit 字 = 512 字节样本
//   0x02 = 特征图, 不重新推理, 回读上一次的结果
// ===========================================================================
`timescale 1ns / 1ps

module fc_top #(
    parameter SH1 = 10,
    parameter SH2 = 9,
    parameter SH3 = 8
) (
    input  wire        clk_i,
    input  wire        rst_n,

    // ---- 输入 FIFO 侧 ----
    input  wire [63:0] din,
    input  wire        din_valid,
    output reg         din_ready,
    input  wire        fifo_empty,

    // ---- 输出 FIFO 侧 ----
    output reg  [7:0]  output_data,
    output reg         output_data_vld,
    output reg         output_data_last,   // Lab8: 与最后一字节同时有效
    output wire        fifo_wren,
    input  wire        outfifo_full,

    // ---- 状态 ----
    output reg         done_o
);

    // ======================= 状态定义 ==================================
    localparam S_IDLE     = 4'd0;
    localparam S_COMMAND  = 4'd1;
    localparam S_DATA_RCV = 4'd2;
    localparam S_FC1      = 4'd3;
    localparam S_FC2      = 4'd4;
    localparam S_FC3      = 4'd5;
    localparam S_FC1_OUT  = 4'd6;
    localparam S_FC2_OUT  = 4'd7;
    localparam S_FC3_OUT  = 4'd8;

    localparam CMD_INFER = 8'h01;
    localparam CMD_FMAP  = 8'h02;

    reg [3:0]  state;

    // ---- 指令 ----
    reg        cmd_wait;        // 已发读请求, 等 din_valid
    reg [31:0] cmd_reg;
    reg        mode_fmap;

    // ---- 样本接收 ----
    reg        w_wait;
    reg [3:0]  data_count;      // 一行 16 个字
    reg [1:0]  row_cnt;         // 4 行
    reg [1023:0] row_buf;
    wire [1023:0] row_full = {row_buf[959:0], din};
    reg        row_we;
    reg [1:0]  row_addr;
    reg [1023:0] row_data;

    // ---- 三层控制 ----
    reg        fc1_start, fc2_start, fc3_start;
    wire       fc1_done, fc2_done, fc3_done;

    reg [15:0] fc3_hold;        // {ch1, ch0}

    // ---- 特征图读出 ----
    reg [7:0]  fm_t;
    reg [7:0]  byte_cnt;
    reg [511:0] fm_buf0, fm_buf1;
    reg [1:0]  fc3_ph;

    wire [0:0] fm_row = (fm_t != 8'd0) ? 1'b1 : 1'b0;

    // 推理结果: y1 > y2 -> 0(正常), 否则 1(异常)
    wire result_bit = ($signed(fc3_hold[7:0]) > $signed(fc3_hold[15:8])) ? 1'b0 : 1'b1;

    // ===================================================================
    // 输出通道: output_data_vld 表示 output_data 上有一个待取走的字节,
    //           fifo_wren = 有效 且 输出 FIFO 未满 (真正写进 FIFO)
    // ===================================================================
    assign fifo_wren = output_data_vld & ~outfifo_full;
    wire out_ready = ~output_data_vld | fifo_wren;

    reg [7:0] byte_sel;
    reg       byte_en;
    reg       byte_last;

    // ---- 批处理: 指令字 [15:8] = 本批"剩余张数" (逐包递减) ----
    //   只有剩余为 1 (即本批最后一张) 时, 才在输出上拉 tlast,
    //   这样 AXI DMA 的 S2MM 才会等到整批结果都收完才结束传输。
    //   PS 侧: 第 i 个包 (0 起) 的指令字填 N-i。
    reg [7:0] batch_left;

    always @(*) begin
        byte_sel  = 8'h00;
        byte_en   = 1'b0;
        byte_last = 1'b0;
        case (state)
            S_FC3_OUT: begin
                if (fc3_ph == 2'd0) begin
                    byte_sel  = mode_fmap ? fc3_hold[7:0] : {7'd0, result_bit};
                    byte_en   = 1'b1;
                    // 推理模式只有 1 字节; 且只有本批最后一张才拉 tlast
                    byte_last = ~mode_fmap & (batch_left == 8'd1);
                end else if (fc3_ph == 2'd1) begin
                    byte_sel  = fc3_hold[15:8];
                    byte_en   = 1'b1;
                    byte_last = 1'b1;              // 特征图模式的第 2 字节
                end
            end
            S_FC1_OUT: if (fm_t >= 8'd5) begin
                byte_sel = (byte_cnt < 8'd64) ? fm_buf0[8*byte_cnt[5:0] +: 8]
                                              : fm_buf1[8*byte_cnt[5:0] +: 8];
                byte_en  = 1'b1;
            end
            S_FC2_OUT: if (fm_t >= 8'd4) begin
                byte_sel = fm_buf0[8*byte_cnt[4:0] +: 8];
                byte_en  = 1'b1;
            end
            default: ;
        endcase
    end

    wire out_fire = byte_en & out_ready;

    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            output_data      <= 8'd0;
            output_data_vld  <= 1'b0;
            output_data_last <= 1'b0;
            // 注意: batch_left 的复位必须在下面 FSM 那个 always 块里,
            //       不能写在这里 —— 同一个 reg 被两个 always 块驱动会综合成
            //       multi-driven net (Synth 8-6859/8-6858), 最高位被常量顶掉。
        end else begin
            if (fifo_wren) output_data_vld <= 1'b0;
            if (out_fire) begin
                output_data      <= byte_sel;
                output_data_vld  <= 1'b1;
                output_data_last <= byte_last;
            end
        end
    end

    // ===================================================================
    // 第一层
    // ===================================================================
    wire [7:0]    fc1_in_addr;
    wire [1023:0] fc1_in_dout;
    wire [8:0]    fc1_w_addr;
    wire [1023:0] fc1_w_dout;
    wire [6:0]    fc1_b_addr;
    wire [7:0]    fc1_b_dout;
    wire [511:0]  fc1_mul_d1, fc1_mul_d2;

    wire          fc1_out_we_pack;
    wire [511:0]  fc1_out_dina_pack;
    wire [0:0]    fc1_out_addra_pack;
    wire [511:0]  fc1_out_dout;

    wire          fc1_output_wren_o;
    wire [7:0]    fc1_output_data_o;
    wire [6:0]    fc1_output_addr_o;

    wire          fc2_output_wren_o;
    wire [7:0]    fc2_output_data_o;
    wire [4:0]    fc2_output_addr_o;

    wire signed [31:0] tree_sum;

    fc1 #(.CUT_W(8), .SH1(SH1)) u_fc1 (
        .clk_i             (clk_i),
        .rst_n_i           (rst_n),
        .start_i           (fc1_start),
        .done_o            (fc1_done),
        .sample_i          (6'd0),
        .input_data_addr_o (fc1_in_addr),
        .input_data_i      (fc1_in_dout),
        .weight_addr_o     (fc1_w_addr),
        .weight_i          (fc1_w_dout),
        .bias_addr_o       (fc1_b_addr),
        .bias_i            (fc1_b_dout),
        .fc_output_wren_o  (fc1_output_wren_o),
        .fc_output_data_o  (fc1_output_data_o),
        .fc_output_addr_o  (fc1_output_addr_o),
        .mul_data1_o       (fc1_mul_d1),
        .mul_data2_o       (fc1_mul_d2),
        .sum_i             (tree_sum),
        .out_ram_we        (fc1_out_we_pack),
        .out_ram_dina      (fc1_out_dina_pack),
        .out_ram_addra     (fc1_out_addra_pack)
    );

    // ===================================================================
    // 第二层
    // ===================================================================
    wire [0:0]   fc2_in_addr;
    wire [511:0] fc2_in_dout;
    wire [5:0]   fc2_w_addr;
    wire [511:0] fc2_w_dout;
    wire [4:0]   fc2_b_addr;
    wire [7:0]   fc2_b_dout;
    wire [511:0] fc2_mul_d1, fc2_mul_d2;

    wire         fc2_out_we_pack;
    wire [511:0] fc2_out_dina_pack;
    wire [511:0] fc2_out_dout;

    fc2 #(.CUT_W(8), .SH2(SH2)) u_fc2 (
        .clk_i             (clk_i),
        .rst_n_i           (rst_n),
        .start_i           (fc2_start),
        .done_o            (fc2_done),
        .input_data_addr_o (fc2_in_addr),
        .input_data_i      (fc2_in_dout),
        .weight_addr_o     (fc2_w_addr),
        .weight_i          (fc2_w_dout),
        .bias_addr_o       (fc2_b_addr),
        .bias_i            (fc2_b_dout),
        .fc_output_wren_o  (fc2_output_wren_o),
        .fc_output_data_o  (fc2_output_data_o),
        .fc_output_addr_o  (fc2_output_addr_o),
        .mul_data1_o       (fc2_mul_d1),
        .mul_data2_o       (fc2_mul_d2),
        .sum_i             (tree_sum),
        .out_ram_we        (fc2_out_we_pack),
        .out_ram_dina      (fc2_out_dina_pack),
        .out_ram_addra     ()
    );

    // ===================================================================
    // 第三层
    // ===================================================================
    wire [0:0]  fc3_in_addr;
    wire [511:0] fc3_in_dout;
    wire [0:0]  fc3_w_addr;
    wire [511:0] fc3_w_dout;
    wire [511:0] fc3_mul_d1, fc3_mul_d2;

    wire        fc3_output_wren_o;
    wire [7:0]  fc3_output_data_o;
    wire [0:0]  fc3_output_addr_o;

    fc3 #(.CUT_W(8), .SH3(SH3)) u_fc3 (
        .clk_i             (clk_i),
        .rst_n_i           (rst_n),
        .start_i           (fc3_start),
        .done_o            (fc3_done),
        .input_data_addr_o (fc3_in_addr),
        .input_data_i      (fc3_in_dout),
        .weight_addr_o     (fc3_w_addr),
        .weight_i          (fc3_w_dout),
        .fc_output_wren_o  (fc3_output_wren_o),
        .fc_output_data_o  (fc3_output_data_o),
        .fc_output_addr_o  (fc3_output_addr_o),
        .mul_data1_o       (fc3_mul_d1),
        .mul_data2_o       (fc3_mul_d2),
        .sum_i             (tree_sum)
    );

    // fc3 只有 2 个输出通道, 不进 BRAM, 锁在寄存器里供特征图模式回读
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) fc3_hold <= 16'd0;
        else if (fc3_output_wren_o)
            fc3_hold[fc3_output_addr_o*8 +: 8] <= fc3_output_data_o;
    end

    // ===================================================================
    // 共用的乘法器阵列 + 加法树
    // ===================================================================
    wire [511:0] mul_d1 = (state == S_FC1) ? fc1_mul_d1 :
                          (state == S_FC2) ? fc2_mul_d1 : fc3_mul_d1;
    wire [511:0] mul_d2 = (state == S_FC1) ? fc1_mul_d2 :
                          (state == S_FC2) ? fc2_mul_d2 : fc3_mul_d2;

    wire [1023:0] mul_result;

    mult_array_8 u_mul_array (
        .clk(clk_i), .rst_n(rst_n),
        .data1(mul_d1), .data2(mul_d2), .result(mul_result)
    );

    adder_tree #(
        .NUM_INPUTS(64),
        .DATA_WIDTH(16),
        .SUM_WIDTH(32)
    ) u_adder_tree (
        .clk(clk_i),
        .rst_n(rst_n),
        .data(mul_result),
        .sum_out(tree_sum)
    );

    // ===================================================================
    // 层间 RAM 的地址/写使能 (生产者 / 消费者 / 特征图读出, 三选一)
    // ===================================================================
    wire [0:0]  fc_output_ram_addr = (state == S_FC1)     ? fc1_out_addra_pack :
                                     (state == S_FC1_OUT) ? fm_row :
                                                            fc2_in_addr;
    wire        fc1_out_wea        = (state == S_FC1) ? fc1_out_we_pack : 1'b0;

    wire [0:0]  fc2_output_ram_addr = (state == S_FC2)     ? 1'b0 :
                                      (state == S_FC2_OUT) ? 1'b0 :
                                                             fc3_in_addr;
    wire        fc2_out_wea         = (state == S_FC2) ? fc2_out_we_pack : 1'b0;

    // ===================================================================
    // 主状态机
    // ===================================================================
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            din_ready   <= 1'b0;
            done_o      <= 1'b0;
            cmd_wait    <= 1'b0;
            cmd_reg     <= 32'd0;
            mode_fmap   <= 1'b0;
            w_wait      <= 1'b0;
            data_count  <= 4'd0;
            row_cnt     <= 2'd0;
            row_buf     <= 1024'd0;
            row_we      <= 1'b0;
            row_addr    <= 2'd0;
            row_data    <= 1024'd0;
            fc1_start   <= 1'b0;
            fc2_start   <= 1'b0;
            fc3_start   <= 1'b0;
            fm_t        <= 8'd0;
            byte_cnt    <= 8'd0;
            fm_buf0     <= 512'd0;
            fm_buf1     <= 512'd0;
            fc3_ph      <= 2'd0;
            batch_left  <= 8'd1;
        end else begin
            din_ready <= 1'b0;
            done_o    <= 1'b0;
            row_we    <= 1'b0;
            fc1_start <= 1'b0;
            fc2_start <= 1'b0;
            fc3_start <= 1'b0;

            case (state)

            // ---------------------------------------------------------
            S_IDLE: begin
                if (!fifo_empty) begin
                    din_ready <= 1'b1;
                    cmd_wait  <= 1'b1;
                    state     <= S_COMMAND;
                end
            end

            // ---------------------------------------------------------
            S_COMMAND: begin
                if (cmd_wait) begin
                    if (din_valid) begin
                        cmd_reg  <= din[31:0];
                        cmd_wait <= 1'b0;
                    end
                end else begin
                    if (cmd_reg[7:0] == CMD_INFER) begin
                        mode_fmap  <= 1'b0;
                        // 本批剩余张数: 0 当作 1 (兼容旧脚本)
                        batch_left <= (cmd_reg[15:8] == 8'd0) ? 8'd1
                                                             : cmd_reg[15:8];
                        data_count <= 4'd0;
                        row_cnt    <= 2'd0;
                        row_buf    <= 1024'd0;
                        w_wait     <= 1'b0;
                        state      <= S_DATA_RCV;
                    end else if (cmd_reg[7:0] == CMD_FMAP) begin
                        mode_fmap  <= 1'b1;
                        fm_t       <= 8'd0;
                        byte_cnt   <= 8'd0;
                        fc3_ph     <= 2'd0;
                        state      <= S_FC1_OUT;
                    end else begin
                        state  <= S_IDLE;
                        done_o <= 1'b1;
                    end
                end
            end

            // ---------------------------------------------------------
            // 收 64 个 64bit 字 = 512 字节; 每 16 个字拼成一行 1024bit
            S_DATA_RCV: begin
                if (w_wait) begin
                    if (din_valid) begin
                        w_wait  <= 1'b0;
                        row_buf <= row_full;
                        if (data_count == 4'd15) begin
                            data_count <= 4'd0;
                            row_we     <= 1'b1;
                            row_addr   <= row_cnt;
                            row_data   <= row_full;
                            if (row_cnt == 2'd3) begin
                                state     <= S_FC1;
                                fc1_start <= 1'b1;
                            end else begin
                                row_cnt <= row_cnt + 1'b1;
                            end
                        end else begin
                            data_count <= data_count + 1'b1;
                        end
                    end
                end else if (!fifo_empty) begin
                    din_ready <= 1'b1;
                    w_wait    <= 1'b1;
                end
            end

            // ---------------------------------------------------------
            S_FC1: if (fc1_done) begin fc2_start <= 1'b1; state <= S_FC2; end
            S_FC2: if (fc2_done) begin fc3_start <= 1'b1; state <= S_FC3; end
            S_FC3: if (fc3_done) begin fc3_ph <= 2'd0; state <= S_FC3_OUT; end

            // ---------------------------------------------------------
            // 推理: 1 字节结果; 特征图: 2 字节 (y1, y2)
            S_FC3_OUT: begin
                if (fc3_ph == 2'd2) begin
                    state  <= S_IDLE;
                    done_o <= 1'b1;
                end else if (out_fire) begin
                    // 推理模式只发 1 字节, 发完直接跳到"结束"相位
                    fc3_ph <= (fc3_ph == 2'd0 && !mode_fmap) ? 2'd2
                                                            : (fc3_ph + 1'b1);
                    // 一张推理完成 -> 剩余张数减 1 (特征图模式不涉及)
                    if (!mode_fmap && batch_left > 8'd1)
                        batch_left <= batch_left - 1'b1;
                end
            end

            // ---------------------------------------------------------
            // FC1 特征图: 2 行 x 64 字节 = 128 字节
            S_FC1_OUT: begin
                if (fm_t < 8'd5) begin
                    fm_t <= fm_t + 1'b1;
                    if (fm_t == 8'd3) fm_buf0 <= fc1_out_dout;
                    if (fm_t == 8'd4) fm_buf1 <= fc1_out_dout;
                end else if (out_fire) begin
                    if (byte_cnt == 8'd127) begin
                        byte_cnt <= 8'd0;
                        fm_t     <= 8'd0;
                        state    <= S_FC2_OUT;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end
            end

            // ---------------------------------------------------------
            // FC2 特征图: 1 行 x 32 字节
            S_FC2_OUT: begin
                if (fm_t < 8'd3) begin
                    fm_t <= fm_t + 1'b1;
                end else if (fm_t == 8'd3) begin
                    fm_buf0 <= fc2_out_dout;
                    fm_t    <= fm_t + 1'b1;
                end else if (out_fire) begin
                    if (byte_cnt == 8'd31) begin
                        byte_cnt <= 8'd0;
                        fm_t     <= 8'd0;
                        fc3_ph   <= 2'd0;
                        state    <= S_FC3_OUT;
                    end else begin
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end
            end

            // ---------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end

    // ===================================================================
    // 8 个 BRAM
    // ===================================================================
    fc_input_ram u_fc_input_ram (
        .clka(clk_i), .rsta(~rst_n),
        .wea(row_we),
        .addra(row_we ? row_addr : fc1_in_addr[1:0]),
        .dina(row_data), .douta(fc1_in_dout)
    );

    fc1_weight_ram u_fc1_weight_ram (
        .clka(clk_i), .rsta(~rst_n), .wea(1'b0),
        .addra(fc1_w_addr), .dina(1024'd0), .douta(fc1_w_dout)
    );

    fc1_bias_ram u_fc1_bias_ram (
        .clka(clk_i), .rsta(~rst_n), .wea(1'b0),
        .addra(fc1_b_addr), .dina(8'd0), .douta(fc1_b_dout)
    );

    fc1_out_ram u_fc1_out_ram (
        .clka(clk_i), .rsta(~rst_n), .wea(fc1_out_wea),
        .addra(fc_output_ram_addr), .dina(fc1_out_dina_pack), .douta(fc1_out_dout)
    );
    assign fc2_in_dout = fc1_out_dout;

    fc2_weight_ram u_fc2_weight_ram (
        .clka(clk_i), .rsta(~rst_n), .wea(1'b0),
        .addra(fc2_w_addr), .dina(512'd0), .douta(fc2_w_dout)
    );

    fc2_bias_ram u_fc2_bias_ram (
        .clka(clk_i), .rsta(~rst_n), .wea(1'b0),
        .addra(fc2_b_addr), .dina(8'd0), .douta(fc2_b_dout)
    );

    fc2_out_ram u_fc2_out_ram (
        .clka(clk_i), .rsta(~rst_n), .wea(fc2_out_wea),
        .addra(fc2_output_ram_addr), .dina(fc2_out_dina_pack), .douta(fc2_out_dout)
    );
    assign fc3_in_dout = fc2_out_dout;

    fc3_weight_ram u_fc3_weight_ram (
        .clka(clk_i), .rsta(~rst_n), .wea(1'b0),
        .addra(fc3_w_addr), .dina(512'd0), .douta(fc3_w_dout)
    );

endmodule
