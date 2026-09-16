// =====================================================================
//  async_fifo.v —— 异步 FIFO（跨时钟域数据搬运）
//
//  ─────────────────────────────────────────────────────────────────
//  为什么必须有它
//  ─────────────────────────────────────────────────────────────────
//  OV5640 的像素数据由 PCLK 打出（24 MHz，来自 PL 送给摄像头的
//  XCLK），而下游 AXI4-Stream / VDMA 跑在系统时钟域（100 MHz）。
//  这是两个**完全独立**的时钟，相位关系不确定。
//
//  多比特数据**绝对不能**逐位打两拍同步 —— 各位的传播延迟不同，
//  同一拍上可能出现"高位已是新值、低位还是旧值"的混合态，
//  得到的数据既不是旧值也不是新值。这类错误在仿真里通常看不出来
//  （仿真中所有位同时跳变），只在真实硅片上随机出现。
//
//  正确做法就是本模块：用**格雷码指针**跨域。格雷码的相邻值只差
//  一位，即使采样时刻落在跳变沿上，读到的要么是旧值要么是新值，
//  不会出现混合态。
//
//  ─────────────────────────────────────────────────────────────────
//  实现要点
//  ─────────────────────────────────────────────────────────────────
//  * 写指针 wbin/wgray 在写时钟域，读指针 rbin/rgray 在读时钟域
//  * 跨域只传格雷码：wgray → 读域打两拍；rgray → 写域打两拍
//  * 空满判断用**扩展一位**的指针（多出的最高位区分"绕了一圈"）
//    - 满：写域看到的 wgray == {~rgray_sync[MSB:MSB-1], rgray_sync[..0]}
//    - 空：读域看到的 rgray == wgray_sync
//
//  ⚠ 这里不做 FWFT（first-word-fall-through）：读出有一拍延迟。
//    下游 dvp_capture 的状态机按"rd_en 拉高下一拍出数据"来用。
// =====================================================================

`timescale 1ns / 1ps

module async_fifo #(
    parameter DATA_W = 16,      // 数据位宽
    parameter ADDR_W = 9        // 地址位宽（深度 = 2**ADDR_W）
) (
    // ---- 写侧（PCLK 域）----
    input  wire              wr_clk,
    input  wire              wr_rst_n,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,

    // ---- 读侧（sysclk 域）----
    input  wire              rd_clk,
    input  wire              rd_rst_n,
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty,

    // ---- 状态指示（调试用，非必需）----
    output wire              wr_overflow,   // 满时仍写 → 数据丢失
    output wire              rd_underflow   // 空时仍读 → 数据无效
);

    localparam DEPTH = (1 << ADDR_W);

    // ------------------------------------------------------------------
    //  存储体
    // ------------------------------------------------------------------
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ------------------------------------------------------------------
    //  写域指针
    // ------------------------------------------------------------------
    reg  [ADDR_W:0] wbin, wgray;
    reg  [ADDR_W:0] wq2_rgray;      // 读指针同步到写域（两级）
    reg  [ADDR_W:0] rgray_sync1_w, rgray_sync2_w;

    wire [ADDR_W:0] wbin_next  = wbin + {{ADDR_W{1'b0}}, wr_en & ~full};
    wire [ADDR_W:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

    // 满：写域看到的读指针（格雷）与"下一个写指针"的格雷序列相邻
    wire full_val = (wgray_next ==
                     {~rgray_sync2_w[ADDR_W:ADDR_W-1], rgray_sync2_w[ADDR_W-2:0]});

    assign full = full_val;

    // ------------------------------------------------------------------
    //  读域指针
    // ------------------------------------------------------------------
    reg  [ADDR_W:0] rbin, rgray;
    reg  [ADDR_W:0] wgray_sync1_r, wgray_sync2_r;

    wire [ADDR_W:0] rbin_next  = rbin + {{ADDR_W{1'b0}}, rd_en & ~empty};
    wire [ADDR_W:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    // 空：读域看到的写指针与当前读指针相同
    wire empty_val = (rgray == wgray_sync2_r);

    assign empty = empty_val;

    // ------------------------------------------------------------------
    //  存储体写入（写域）
    // ------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_en & ~full)
            mem[wbin[ADDR_W-1:0]] <= wr_data;
    end

    // ------------------------------------------------------------------
    //  读指针同步到写域
    // ------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rgray_sync1_w <= {ADDR_W+1{1'b0}};
            rgray_sync2_w <= {ADDR_W+1{1'b0}};
        end else begin
            rgray_sync1_w <= rgray;
            rgray_sync2_w <= rgray_sync1_w;
        end
    end

    // ------------------------------------------------------------------
    //  写指针本体 + 写指针同步到读域
    // ------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin  <= {ADDR_W+1{1'b0}};
            wgray <= {ADDR_W+1{1'b0}};
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wgray_sync1_r <= {ADDR_W+1{1'b0}};
            wgray_sync2_r <= {ADDR_W+1{1'b0}};
        end else begin
            wgray_sync1_r <= wgray;
            wgray_sync2_r <= wgray_sync1_r;
        end
    end

    // ------------------------------------------------------------------
    //  读指针本体
    // ------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin  <= {ADDR_W+1{1'b0}};
            rgray <= {ADDR_W+1{1'b0}};
        end else begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
        end
    end

    // ------------------------------------------------------------------
    //  读数据（有寄存，读出一拍延迟）
    // ------------------------------------------------------------------
    assign rd_data = mem[rbin[ADDR_W-1:0]];

    // ------------------------------------------------------------------
    //  错误指示
    // ------------------------------------------------------------------
    assign wr_overflow  = wr_en &  full;
    assign rd_underflow = rd_en &  empty;

endmodule
