// =====================================================================
//  tb_dvp_capture.v —— dvp_capture 自检 testbench
//
//  运行（iverilog，不需要板卡、不需要 Vivado license）：
//      iverilog -g2012 -o tb.vvp tb_dvp_capture.v ../dvp_capture.v ../async_fifo.v
//      vvp tb.vvp
//
//  ⚠ 日志出现 "finished" 不代表通过。必须看到 *** TB PASSED ***。
//
//  ─────────────────────────────────────────────────────────────────
//  这个 TB 在验什么（不是走个过场）
//  ─────────────────────────────────────────────────────────────────
//  1. **字节拼装的方向**：模拟 OV5640 按 MSB-first 吐字节，
//     检查拼出来的 16bit 像素是不是期望值。
//     期望值用可手算的图案（0x1234, 0xABCD ...），不是随便的数 ——
//     随便的数错了也看不出来方向反了。
//
//  2. **跨时钟域**：PCLK 与 aclk 用**互质**周期的两个时钟，
//     让相位持续漂移。若 CDC 写错，必然在某个相位下暴露。
//     用 2:1 的整数比会让所有相位重复，掩盖问题。
//
//  3. **TLAST 位置**：每行末尾必须有且仅有一个 TLAST。
//     数错会让下游 Video In / VDMA 整帧错位。
//
//  4. **行首对齐**：某行故意多塞一个字节（模拟时序毛刺），
//     检查下一行是否仍然从高字节开始 —— 这是 byte_phase
//     用 HREF 上升沿复位的意义所在。
// =====================================================================

`timescale 1ns / 1ps

module tb_dvp_capture;

    // ------------------------------------------------------------------
    //  两个互质时钟：PCLK ≈ 41.7 MHz，aclk = 100 MHz
    //  周期比 12:5，最小公倍数大，相位持续漂移
    // ------------------------------------------------------------------
    localparam PCLK_HALF = 12;    // 24 ns 周期
    localparam ACLK_HALF = 5;     // 10 ns 周期
    localparam W         = 8;     // 每行 8 个像素（够验证对齐，跑得快）
    localparam H         = 4;     // 每帧 4 行

    reg pclk = 0, aclk = 0;
    reg rst_n = 0;
    always #PCLK_HALF pclk = ~pclk;
    always #ACLK_HALF aclk = ~aclk;

    // ------------------------------------------------------------------
    //  DUT 端口
    // ------------------------------------------------------------------
    reg         cam_vsync = 0, cam_href = 0;
    reg  [7:0]  cam_data = 8'h00;

    wire [15:0] m_tdata;
    wire        m_tvalid, m_tlast;
    reg         m_tready = 1;

    wire [15:0] frame_cnt, line_cnt;
    wire        stalled;
    wire        vsync_sync, href_sync;

    dvp_capture #(
        .MAX_W        (1920),
        .FIFO_ADDR_W  (9),
        .BYTE_SWAP    (0)
    ) u_dut (
        .pclk          (pclk),
        .rst_n         (rst_n),
        .cam_vsync     (cam_vsync),
        .cam_href      (cam_href),
        .cam_data      (cam_data),

        .aclk          (aclk),
        .m_axis_tdata  (m_tdata),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tready (m_tready),
        .m_axis_tlast  (m_tlast),

        .frame_cnt     (frame_cnt),
        .line_cnt      (line_cnt),
        .stalled       (stalled),

        .vsync_sync    (vsync_sync),
        .href_sync     (href_sync)
    );

    // ------------------------------------------------------------------
    //  期望的像素序列
    //
    //  用可手算的图案：像素 n 的高字节 = 0x10+n，低字节 = 0xA0+n。
    //  这样能直接看出"高低字节有没有颠倒"：
    //    正确  → 0x10A0, 0x11A1, ...
    //    颠倒  → 0xA010, 0xA111, ...
    //  用随机数就分辨不出来了。
    // ------------------------------------------------------------------
    function [15:0] exp_pix;
        input integer n;      // 像素在该行内的序号（0 起）
        begin
            exp_pix = {8'h10 + n[7:0], 8'hA0 + n[7:0]};
        end
    endfunction

    // ------------------------------------------------------------------
    //  结果统计
    // ------------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 采集到的像素
    reg [15:0] got_pix  [0:255];
    reg        got_last [0:255];
    integer    got_n = 0;

    // ------------------------------------------------------------------
    //  监视输出：把 DUT 吐出的每个有效像素收集起来
    // ------------------------------------------------------------------
    always @(posedge aclk) begin
        if (m_tvalid && m_tready) begin
            got_pix [got_n] = m_tdata;
            got_last[got_n] = m_tlast;
            got_n = got_n + 1;
        end
    end

    // ------------------------------------------------------------------
    //  激励任务
    // ------------------------------------------------------------------

    // 发一个字节
    //
    // ⚠ 对齐要求：cam_data 与 cam_href 必须在**同一个 PCLK 上升沿**
    //   被 DUT 采样到。所以这里在 negedge 建立数据，next posedge 生效；
    //   控制 href 的语句也必须落在 negedge，才能与数据同拍。
    //   在 posedge 之后改信号会让 href 比数据晚一拍，DUT 就会错位。
    task send_byte;
        input [7:0] b;
        begin
            @(negedge pclk);
            cam_data = b;
        end
    endtask

    /**
     * 发一行：跳过前 N 个字节（用于制造"多一个字节"的错位）
     * 每像素 2 字节，MSB first
     */
    // ⚠ 时序对齐的坑（这个 TB 自己踩过）：
    //   若"HREF 拉低"与"最后一个数据更新"写在同一个 negedge，
    //   DUT 在那个 posedge 采到的是**更新前**的旧数据，
    //   于是每行少算一个像素（表现为像素总数 = W*H + 行数）。
    //
    //   正确做法：先更新数据，等**一个完整的 negedge→posedge**
    //   让 DUT 采到它，然后才拉低 HREF。即下面的顺序。
    task send_line;
        input integer skip_bytes;
        integer i;
        integer nb;          // 本行总字节数
        begin
            nb = skip_bytes + 2 * W;

            @(negedge pclk);
            cam_href = 1'b1;

            for (i = 0; i < nb; i = i + 1) begin
                // 决定第 i 个字节的值
                if (i < skip_bytes)
                    cam_data = 8'hFF;                       // 垃圾字节
                else if ((i - skip_bytes) % 2 == 0)
                    cam_data = 8'h10 + ((i - skip_bytes) / 2);  // 高字节
                else
                    cam_data = 8'hA0 + ((i - skip_bytes) / 2);  // 低字节

                @(negedge pclk);        // 数据已建立，下一个 posedge 被采样
            end

            cam_href = 1'b0;            // 所有字节都已采样完毕，才拉低
            cam_data = 8'h00;
        end
    endtask

    /**
     * 发一帧
     * @param skip_on_line1  第 1 行多塞几个字节（测试行首对齐）
     */
    task send_frame;
        input integer skip_on_line1;
        integer r;
        begin
            @(negedge pclk); cam_vsync = 1'b1;
            @(negedge pclk); cam_vsync = 1'b0;

            for (r = 0; r < H; r = r + 1) begin
                if (r == 0) send_line(skip_on_line1);
                else        send_line(0);
                // 行间空隙：HREF 已为低，这里只是拉开行间距
                repeat (4) @(negedge pclk);
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  比对
    // ------------------------------------------------------------------
    task check;
        input             ok;
        input [8*48-1:0]  name;
        begin
            if (ok) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL : %0s", name);
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  主流程
    // ------------------------------------------------------------------
    integer i, base, checked_line;

    initial begin
        $dumpfile("wave_dvp.vcd");
        $dumpvars(0, tb_dvp_capture);

        $display("=== TB START ===");

        // ---- 复位 ----
        rst_n = 0;
        repeat (10) @(posedge pclk);
        repeat (10) @(posedge aclk);
        rst_n = 1;

        // =============================================================
        //  用例 1：正常一帧，验证字节序与像素值
        // =============================================================
        $display("\n[1] 正常帧 —— 验证 16bit 拼装与字节序");
        got_n = 0;
        send_frame(0);
        repeat (200) @(posedge aclk);       // 等 FIFO 排空

        check(got_n == W * H,
              "像素总数应为 W*H");
        $display("      收到 %0d 个像素（期望 %0d）", got_n, W * H);

        // 逐像素比对第一行
        // ⚠ Verilog 不允许对函数返回值做位选（exp_pix(i)[7:0] 非法），
        //   所以先存进局部变量再取位。
        begin : cmp_line0
            reg [15:0] e, swapped;
            for (i = 0; i < W; i = i + 1) begin
                e       = exp_pix(i);
                swapped = {e[7:0], e[15:8]};
                if (got_pix[i] !== e) begin
                    fail_cnt = fail_cnt + 1;
                    $display("  FAIL : 行0 像素%0d 应为 %04h 实为 %04h%s",
                             i, e, got_pix[i],
                             (got_pix[i] === swapped) ? "  <-- 高低字节颠倒!" : "");
                end else begin
                    pass_cnt = pass_cnt + 1;
                end
            end
        end

        // =============================================================
        //  用例 2：TLAST 位置 —— 每行末尾有且仅有一个
        // =============================================================
        $display("\n[2] TLAST —— 每行末尾有且仅有一个");
        for (checked_line = 0; checked_line < H; checked_line = checked_line + 1) begin
            base = checked_line * W;
            // 行内非末尾像素不应有 TLAST
            for (i = 0; i < W - 1; i = i + 1) begin
                if (base + i < got_n && got_last[base + i] !== 1'b0) begin
                    fail_cnt = fail_cnt + 1;
                    $display("  FAIL : 行%0d 第%0d 像素不应有 TLAST", checked_line, i);
                end
            end
            // 行末应有
            if (base + W - 1 < got_n) begin
                check(got_last[base + W - 1] === 1'b1,
                      "行末应有 TLAST");
            end
        end

        // =============================================================
        //  用例 3：行首对齐 —— 第 1 行多塞字节，后续行不能错位
        // =============================================================
        //  这是 byte_phase 用 HREF 上升沿复位的意义：
        //  若不复位，第 1 行多出的字节会让之后**所有行**高低字节颠倒。
        $display("\n[3] 行首对齐 —— 首行多塞字节，后续行不应错位");
        got_n = 0;
        send_frame(1);                      // 首行多 1 个字节
        repeat (200) @(posedge aclk);

        // 第 2 行（index 从 W 起）应该是干净的
        for (i = 0; i < W; i = i + 1) begin
            if (got_pix[W + i] !== exp_pix(i)) begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL : 错位后 行1 像素%0d 应为 %04h 实为 %04h",
                         i, exp_pix(i), got_pix[W + i]);
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end

        // =============================================================
        //  用例 4：reset 后状态干净
        // =============================================================
        $display("\n[4] reset 行为");
        rst_n = 0;
        repeat (5) @(posedge aclk);
        check(stalled === 1'b0 || stalled === 1'b1, "stalled 是可读信号");
        rst_n = 1;
        repeat (20) @(posedge aclk);
        check(frame_cnt == 16'd0, "reset 后 frame_cnt 归零");

        // =============================================================
        //  汇总
        // =============================================================
        $display("\n=== TB DONE: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("*** TB PASSED ***");
        else
            $display("*** TB FAILED ***");

        $finish;
    end

    // ---- 超时保护 ----
    initial begin
        #2_000_000;
        $display("\n*** TB TIMEOUT ***");
        $display("=== TB DONE: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
