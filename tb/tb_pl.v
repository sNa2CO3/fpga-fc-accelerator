// ===========================================================================
// tb_pl.v —— Lab8 PL 顶层 (pl_fc_top) 仿真
//
// 模拟 DMA 的两条 AXI-Stream 通道:
//   MM2S -> s_axis : 1 个指令字 + 64 个样本字 (tlast 在第 64 个样本字上)
//   m_axis -> S2MM : 收集到 tlast 为止, 按小端字节序展开
//
// 两轮测试:
//   [A] axi 与 fc 同频 (100 MHz), 样本 1  -> 推理 + 特征图
//   [B] axi 100 MHz / fc 150 MHz (跨时钟域), 样本 23 -> 推理 + 特征图
// ===========================================================================
`timescale 1ns / 1ps

module tb_pl;

    localparam N_IN_BYTES = 512;
    localparam N_FMAP     = 162;

    // ---- 时钟 ----
    reg s_axis_aclk = 1'b0;
    reg fc_clk      = 1'b0;
    reg fc_clk_fast = 1'b0;
    reg fc_clk_125  = 1'b0;

    always #5 s_axis_aclk = ~s_axis_aclk;     // 100 MHz
    always #5 fc_clk      = ~fc_clk;          // 100 MHz
    always #3.333 fc_clk_fast = ~fc_clk_fast;// 150 MHz
    always #4 fc_clk_125  = ~fc_clk_125;      // 125 MHz  (板上实际运行频率)

    reg [1:0] fc_period_sel = 2'd0;           // 0->100 MHz, 1->150 MHz, 2->125 MHz
    wire       fc_clk_use = (fc_period_sel == 2'd1) ? fc_clk_fast :
                            (fc_period_sel == 2'd2) ? fc_clk_125  : fc_clk;

    reg rst_n = 1'b0;

    // ---- AXI-Stream 从机 ----
    reg  [63:0] s_tdata  = 64'd0;
    reg  [7:0]  s_tkeep  = 8'hFF;
    reg         s_tlast  = 1'b0;
    reg         s_tvalid = 1'b0;
    wire        s_tready;

    // ---- AXI-Stream 主机 ----
    reg         m_tready = 1'b1;
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tlast;
    wire        m_tvalid;

    wire done_o;

    pl_fc_top u_dut (
        .rst_n         (rst_n),
        .s_axis_aclk   (s_axis_aclk),
        .s_axis_tdata  (s_tdata),
        .s_axis_tkeep  (s_tkeep),
        .s_axis_tlast  (s_tlast),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tready (s_tready),
        .m_axis_tready (m_tready),
        .m_axis_tdata  (m_tdata),
        .m_axis_tkeep  (m_tkeep),
        .m_axis_tlast  (m_tlast),
        .m_axis_tvalid (m_tvalid),
        .fc_clk        (fc_clk_use),
        .done_o        (done_o)
    );

    // ---- 把 NPU 内部的关键信号提到 testbench 顶层, 默认波形就能直接看到 ----
    wire [3:0]  npu_state     = u_dut.u_fc_top.state;
    wire [31:0] cmd_reg       = u_dut.u_fc_top.cmd_reg;
    wire        fc_din_valid  = u_dut.fc_din_valid;
    wire        fc_din_ready  = u_dut.fc_din_ready;
    wire        fc_fifo_empty = u_dut.fc_fifo_empty;
    wire [7:0]  fc_dout       = u_dut.fc_dout;
    wire        fc_dout_vld   = u_dut.fc_dout_vld;
    wire        fc_dout_last  = u_dut.fc_dout_last;
    wire [63:0] pk_dout       = u_dut.pk_dout;
    wire        pk_vld        = u_dut.pk_vld;
    wire        pk_last       = u_dut.pk_last;
    wire [7:0]  fc3_y1        = u_dut.u_fc_top.fc3_hold[7:0];
    wire [7:0]  fc3_y2        = u_dut.u_fc_top.fc3_hold[15:8];

    // ---- 数据 ----
    reg [7:0]  in_bytes [0:N_IN_BYTES-1];
    reg [7:0]  exp_fmap [0:N_FMAP-1];
    reg [7:0]  got_fmap [0:N_FMAP-1];

    integer err_cnt = 0;
    integer nb;
    integer k, j, b;
    reg [63:0] word;
    reg [7:0]  got;

    // =================== AXI-Stream 发送 ==============================
    task push64;
        input [63:0] d;
        input        last;
        begin
            @(posedge s_axis_aclk); #1;
            s_tdata  = d;
            s_tkeep  = 8'hFF;
            s_tlast  = last;
            s_tvalid = 1'b1;
            @(posedge s_axis_aclk);
            while (!s_tready) @(posedge s_axis_aclk);
            #1;
            s_tvalid = 1'b0;
            s_tlast  = 1'b0;
        end
    endtask

    task send_cmd;
        input [7:0] cmd;
        begin
            push64({56'd0, cmd}, 1'b0);
            if (cmd == 8'h01) begin
                for (k = 0; k < 64; k = k + 1) begin
                    word = 64'd0;
                    for (j = 0; j < 8; j = j + 1)
                        word = (word << 8) | {56'd0, in_bytes[8*k + j]};   // MSB 优先, 与 fc_top 一致
                    push64(word, (k == 63));
                end
            end
        end
    endtask

    // =================== AXI-Stream 接收 ==============================
    // 收满 nbytes 个字节（按小端展开），返回实际收到的拍数
    task collect;
        input integer nbytes;
        output integer beats;
        begin
            beats = 0;
            b = 0;
            while (b < nbytes) begin
                @(posedge s_axis_aclk); #1;
                if (m_tvalid) begin
                    if (beats == 0) $display("  [%0t] first m_axis beat", $time);
                    for (j = 0; j < 8; j = j + 1) begin
                        if (b + j < nbytes) got_fmap[b + j] = m_tdata[8*j +: 8];
                    end
                    b = b + 8;
                    beats = beats + 1;
                    if (m_tlast) b = nbytes;      // 收到 tlast 提前结束
                end
            end
            nb = b;
        end
    endtask

    task load_sample;
        input integer which;
        begin
            if (which == 0) begin
                $readmemh("D:/VivadoProject/Lab8/data/sample1_input_bytes.mem",  in_bytes);
                $readmemh("D:/VivadoProject/Lab8/data/sample1_fmap_bytes.mem",  exp_fmap);
            end else begin
                $readmemh("D:/VivadoProject/Lab8/data/sample23_input_bytes.mem", in_bytes);
                $readmemh("D:/VivadoProject/Lab8/data/sample23_fmap_bytes.mem", exp_fmap);
            end
        end
    endtask

    task check_fmap;
        input integer n;
        begin
            for (k = 0; k < n; k = k + 1) begin
                if (got_fmap[k] !== exp_fmap[k]) begin
                    if (err_cnt < 10)
                        $display("   byte[%0d] = %02x, expect %02x", k, got_fmap[k], exp_fmap[k]);
                    err_cnt = err_cnt + 1;
                end
            end
        end
    endtask

    // =================== 满速灌包 ======================================
    reg [63:0] pkt [0:1023];
    reg [7:0]  rem8;          // 本批剩余张数
    localparam NB = 12;       // 大批量测试: 12 个包 = 780 拍 > FIFO 512 深

    task push_burst;
        input integer n;          // 拍数
        integer ii;
        begin
            ii = 0;
            @(posedge s_axis_aclk); #1;
            s_tvalid = 1'b1;
            s_tdata  = pkt[0];
            s_tkeep  = 8'hFF;
            s_tlast  = 1'b0;
            while (ii < n) begin
                @(posedge s_axis_aclk);
                if (s_tready === 1'b1) begin
                    ii = ii + 1;
                    #1;
                    if (ii < n) begin
                        s_tdata = pkt[ii];
                        s_tlast = ((ii % 65) == 64) ? 1'b1 : 1'b0;
                    end
                end else begin
                    #1;
                end
            end
            s_tvalid = 1'b0;
            s_tlast  = 1'b0;
        end
    endtask

    // =================== 监视器: 看每层的起止 =========================
    reg [3:0] prev_state = 4'hf;
    reg       prev_cw    = 1'b0;
    reg       prev_fd    = 1'b0;
    always @(posedge fc_clk_use) begin
        // 指令被锁存的时刻 (cmd_wait 1 -> 0)
        if (prev_cw === 1'b1 && u_dut.u_fc_top.cmd_wait === 1'b0)
            $display("  [%0t] CMD captured = 0x%04x", $time, u_dut.u_fc_top.cmd_reg[15:0]);
        prev_cw = u_dut.u_fc_top.cmd_wait;

        // 状态进入
        if (u_dut.u_fc_top.state !== prev_state) begin
            $display("  [%0t] state %0d -> %0d", $time, prev_state, u_dut.u_fc_top.state);
        end
        prev_state = u_dut.u_fc_top.state;

        // fc1 完成 (done 脉冲)
        if (prev_fd === 1'b0 && u_dut.u_fc_top.fc1_done === 1'b1)
            $display("  [%0t] fc1_done", $time);
        prev_fd = u_dut.u_fc_top.fc1_done;
    end

    // =================== 实测: 指令锁存 -> done_o =====================
    // 直接读 $realtime，不靠"拍数 x 周期"倒推；顺带量出每个状态的驻留时间
    reg        meas_on   = 1'b0;
    reg        prev_done = 1'b0;
    reg        cw_prev   = 1'b0;
    reg [3:0]  st_prev   = 4'hf;
    reg [7:0]  meas_cmd  = 8'h00;
    real       t_start, t_end, t_state;
    integer    cyc_inf, cyc_state;

    always @(posedge fc_clk_use) begin
        #1;                                        // 错开与 DUT 的同一沿竞争
        if (cw_prev === 1'b1 && u_dut.u_fc_top.cmd_wait === 1'b0 && !meas_on) begin
            meas_on   = 1'b1;
            t_start   = $realtime;
            t_state   = $realtime;
            cyc_inf   = 0;
            cyc_state = 0;
            st_prev   = u_dut.u_fc_top.state;
            meas_cmd  = u_dut.u_fc_top.cmd_reg[7:0];
        end else if (meas_on) begin
            cyc_inf   = cyc_inf + 1;
            cyc_state = cyc_state + 1;
            if (u_dut.u_fc_top.state !== st_prev) begin
                $display("    [MEAS] state %0d  %9.3f ns  %4d cyc",
                         st_prev, $realtime - t_state, cyc_state);
                st_prev   = u_dut.u_fc_top.state;
                t_state   = $realtime;
                cyc_state = 0;
            end
            if (prev_done === 1'b0 && done_o === 1'b1) begin
                t_end = $realtime;
                $display("    [MEAS] state %0d  %9.3f ns  %4d cyc",
                         st_prev, t_end - t_state, cyc_state);
                $display("  >>> [MEASURED @ %0d MHz] cmd 0x%02x : cmd->done = %0.3f ns = %0.3f us (%0d cycles)",
                         (fc_period_sel == 2'd2) ? 125 : (fc_period_sel == 2'd1) ? 150 : 100,
                         meas_cmd, t_end - t_start, (t_end - t_start) / 1000.0, cyc_inf);
                meas_on = 1'b0;
            end
        end
        cw_prev   = u_dut.u_fc_top.cmd_wait;
        prev_done = done_o;
    end

    reg [7:0] prev_bl = 8'hff;
    always @(posedge fc_clk_use) begin
        if (u_dut.u_fc_top.batch_left !== prev_bl) begin
            $display("  [%0t] batch_left %0d -> %0d", $time, prev_bl, u_dut.u_fc_top.batch_left);
            prev_bl = u_dut.u_fc_top.batch_left;
        end
    end

    // =================== 输出捕获 (模拟 DMA 边收边存) =================
    reg [7:0] cap_val  [0:255];
    reg       cap_last [0:255];
    integer   cap_n = 0;
    // 直接采 NPU 内部输出 (fc 时钟域), 避开 AXIS/FIFO 的采样时序问题
    always @(posedge fc_clk_use) begin
        if (u_dut.fc_dout_vld && cap_n < 256) begin
            cap_val[cap_n]  <= u_dut.fc_dout;
            cap_last[cap_n] <= u_dut.fc_dout_last;
            cap_n <= cap_n + 1;
        end
    end

    // =================== 主流程 =======================================
    integer beats;
    integer t0, t1;

    initial begin
        rst_n = 1'b0;
        #200;
        rst_n = 1'b1;
        #200;

        // ---------------- [A] 同频, 样本 1 ----------------
        $display("==== [A] same clock : sample 1 ====");
        fc_period_sel = 0;
        load_sample(0);

        $display("  [%0t] begin: push 65 words", $time);
        t0 = $time;
        send_cmd(8'h01);                 // 推理
        $display("  [%0t] 65 words pushed", $time);
        collect(1, beats);
        t1 = $time;
        $display("  [%0t] done", $time);
        $display("  inference: %0d beat(s), result = %0d, %0d ns",
                 beats, got_fmap[0], t1 - t0);
        if (got_fmap[0] !== 8'd0) begin
            $display("   ** result mismatch, expect 0 **");
            err_cnt = err_cnt + 1;
        end

        $display("  [%0t] begin: feature-map command", $time);
        send_cmd(8'h02);                 // 特征图
        $display("  [%0t] command pushed", $time);
        collect(N_FMAP, beats);
        $display("  [%0t] 162 bytes done", $time);
        $display("  feature map: %0d beats, fc1[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d",
                 beats, got_fmap[0], got_fmap[1], got_fmap[2], got_fmap[3],
                 got_fmap[4], got_fmap[5], got_fmap[6], got_fmap[7]);
        check_fmap(N_FMAP);

        // ---------------- [B] 跨时钟域, 样本 23 ----------------
        $display("==== [B] axi 100MHz / fc 150MHz : sample 23 ====");
        fc_period_sel = 1;
        load_sample(1);

        send_cmd(8'h01);
        collect(1, beats);
        $display("  inference: result = %0d (expect 1)", got_fmap[0]);
        if (got_fmap[0] !== 8'd1) begin
            $display("   ** result mismatch, expect 1 **");
            err_cnt = err_cnt + 1;
        end

        send_cmd(8'h02);
        collect(N_FMAP, beats);
        $display("  feature map: %0d beats, fc1[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d",
                 beats, got_fmap[0], got_fmap[1], got_fmap[2], got_fmap[3],
                 got_fmap[4], got_fmap[5], got_fmap[6], got_fmap[7]);
        check_fmap(N_FMAP);

        // =============== [6] 批处理: 连续 4 个包 ===============
        $display("==== [6] batched: 4 packets back-to-back (sample23, expect 1) ====");
        fc_period_sel = 0;
        load_sample(1);
        cap_n = 0;

        // 连续灌 4 个 "指令 + 64 字" 包, 中间不停 (模拟 PS 侧批处理)
        for (k = 0; k < 4; k = k + 1) begin
            rem8 = 8'd4 - k;                            // 剩余张数 4,3,2,1
            push64({48'd0, rem8, 8'h01}, 1'b0);
            for (j = 0; j < 64; j = j + 1) begin
                word = 64'd0;
                for (b = 0; b < 8; b = b + 1)
                    word = (word << 8) | {56'd0, in_bytes[8*j + b]};
                push64(word, (j == 63));
            end
        end

        // 等 4 拍结果全部到齐 (捕获是并行的, 不会漏)
        while (cap_n < 4) @(posedge s_axis_aclk);
        @(posedge s_axis_aclk); #10;
        for (k = 0; k < 4; k = k + 1) begin
            $display("  batch result %0d = %0d (expect 1)  tlast=%b",
                     k, cap_val[k], cap_last[k]);
            if (cap_val[k] !== 8'd1) err_cnt = err_cnt + 1;
            if (cap_last[k] !== (k == 3)) begin
                $display("  ** tlast 位置错: 第 %0d 拍 tlast=%b (应只在第 3 拍为 1)",
                         k, cap_last[k]);
                err_cnt = err_cnt + 1;
            end
        end

        // =============== [7] 大批量: 12 包 (780 拍, 超过 FIFO 512 深) ===============
        $display("==== [7] big burst: %0d packets (sample23, expect 1) ====", NB);
        fc_period_sel = 0;
        load_sample(1);
        cap_n = 0;

        for (k = 0; k < NB; k = k + 1) begin
            rem8 = NB - k;
            pkt[k*65] = {48'd0, rem8, 8'h01};
            for (j = 0; j < 64; j = j + 1) begin
                word = 64'd0;
                for (b = 0; b < 8; b = b + 1)
                    word = (word << 8) | {56'd0, in_bytes[8*j + b]};
                pkt[k*65 + 1 + j] = word;
            end
        end
        push_burst(NB * 65);

        while (cap_n < NB) @(posedge s_axis_aclk);
        @(posedge s_axis_aclk); #10;
        for (k = 0; k < NB; k = k + 1) begin
            if (cap_val[k] !== 8'd1) begin
                $display("  big result %0d = %0d (expect 1)  tlast=%b  ** WRONG",
                         k, cap_val[k], cap_last[k]);
                err_cnt = err_cnt + 1;
            end else if (cap_last[k] !== (k == NB-1)) begin
                $display("  big result %0d = 1  tlast=%b  ** tlast 位置错", k, cap_last[k]);
                err_cnt = err_cnt + 1;
            end
        end
        if (err_cnt == 0) $display("  big burst: all %0d OK", NB);

        // ---------------- 汇总 ----------------
        $display("========================================");
        if (err_cnt == 0)
            $display(" PASS: AXI-Stream 收发 + 2 样本 x (推理+特征图) 全部一致");
        else
            $display(" FAIL: %0d mismatches", err_cnt);
        $display("========================================");
        $finish;
    end

    initial begin
        #400000;                       // 400us 看门狗 (含批处理/满速测试)
        $display("ERROR: timeout");
        $finish;
    end

endmodule
