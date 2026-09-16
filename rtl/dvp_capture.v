// =====================================================================
//  dvp_capture.v —— OV5640 DVP 采集 → AXI4-Stream
//
//  ─────────────────────────────────────────────────────────────────
//  为什么这个模块用 Verilog 而不是 HLS
//  ─────────────────────────────────────────────────────────────────
//  三件事 HLS 做不好：
//    1. 跨时钟域（PCLK 24 MHz → sysclk 100 MHz）需要显式异步 FIFO
//    2. VSYNC/HREF 的边沿检测与时序违规容忍
//    3. 送 XCLK 给摄像头（MMCM/分频，HLS 表达不了）
//
//  ─────────────────────────────────────────────────────────────────
//  DVP 接口时序（OV5640，RGB565 输出模式）
//  ─────────────────────────────────────────────────────────────────
//  * PCLK 由 OV5640 输出，一个字节一拍
//  * RGB565 下每像素 16 bit / 8 bit 总线 = **2 个字节**（2 拍）
//    - 第 1 拍 = 高字节 {R[4:0], G[5:3]}
//    - 第 2 拍 = 低字节 {G[2:0], B[4:0]}
//    ⚠ 字节序是 **MSB first**，这是 OV5640 的默认行为。
//      若实测发现红蓝互换，把参数 BYTE_SWAP 置 1。
//      不要凭猜改 —— 用一张已知的纯色图（比如对着红纸）验证。
//  * HREF 高 = 一行有效；VSYNC 高（或低，取决于寄存器）为帧边界
//  * 数据在 PCLK 上升沿有效
//
//  ─────────────────────────────────────────────────────────────────
//  输出的 AXI4-Stream
//  ─────────────────────────────────────────────────────────────────
//  * 一拍一个像素（16 bit），不再有"一行 2 拍"的概念
//  * TLAST 每行末尾置位 —— 下游 Video In to AXI4-Stream / VDMA
//    靠它界定行边界，漏了会整帧错位
//  * 行数由 HREF 边沿决定，不靠计数器，所以分辨率变化时无需改代码
//
//  ⚠ 本模块不做帧同步去撕裂，那是 VDMA 的多帧缓存该干的事。
// =====================================================================

`timescale 1ns / 1ps

module dvp_capture #(
    // 一行的最大像素数，用于行内计数器的位宽（不是硬性上限）
    parameter MAX_W      = 1920,
    // FIFO 深度（2^ADDR_W 个 16bit 字）
    parameter FIFO_ADDR_W = 9,
    // 字节序：0 = 先收到的字节是高字节（OV5640 默认）
    //        1 = 先收到的是低字节
    parameter BYTE_SWAP   = 0
) (
    // ---- 摄像头侧（PCLK 域）----
    input  wire        pclk,        // 来自 OV5640 的 PCLK
    input  wire        rst_n,       // 复位需同步到两个域，见下方说明
    input  wire        cam_vsync,   // 帧同步（本模块按高有效处理）
    input  wire        cam_href,    // 行有效
    input  wire [7:0]  cam_data,    // 8bit 数据总线

    // ---- 系统侧（sysclk 域）----
    input  wire        aclk,        // 100 MHz 系统时钟
    output wire [15:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,

    // ---- 状态输出（给 PS 读，用于确认"摄像头到底有没有在出数据"）----
    output reg  [15:0] frame_cnt,   // 收到的帧数
    output reg  [15:0] line_cnt,    // 当前帧的行数（稳定值）
    output reg         stalled,     // FIFO 满导致丢数据

    // ---- 调试用的原始同步信号（打两拍后，仅仿真/ILA 用）----
    output wire        vsync_sync,
    output wire        href_sync
);

    // 复位同步：两个时钟域各用各的复位。
    // ⚠ 生产里应各自做复位同步器；这里为简化只做同源假设，
    //   并在 BD 里由 Processor System Reset 模块统一分发给两个域。
    wire rst_n_pclk = rst_n;
    wire rst_n_aclk = rst_n;

    // ==================================================================
    //  PCLK 域：同步输入信号
    //
    //  cam_vsync / cam_href 与 cam_data 同属 PCLK 域，本不需要同步。
    //  但**给它们打一拍再做边沿检测**是必要的：这样可以先用寄存器
    //  把组合毛刺滤掉，边沿检测才可靠。
    // ==================================================================
    //  ==================================================================
    //  ⚠ 关键：cam_data 必须和 cam_href 一起寄存，不能在后面直接用
    //     原始的 cam_data。
    //
    //     原因：byte_phase 的判定用的是**寄存后**的 href_d0，它比原始
    //     cam_href 晚一拍。如果数据还取原始 cam_data，就等于拿"这一拍
    //     的 href"去配"下一拍的数据"，行首会整体差一个字节
    //     （表现为每个像素都是 {低字节, 下一像素的高字节}）。
    //
    //     把三者（vsync/href/data）在同一级寄存器里采样，它们就永远
    //     属于同一个时间快照，后续全部用寄存后的版本。
    //  ==================================================================
    reg vsync_d0, vsync_d1;
    reg href_d0,  href_d1;
    reg [7:0] data_d0;

    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) begin
            vsync_d0 <= 1'b0;
            vsync_d1 <= 1'b0;
            href_d0  <= 1'b0;
            href_d1  <= 1'b0;
            data_d0  <= 8'd0;
        end else begin
            vsync_d0 <= cam_vsync;
            vsync_d1 <= vsync_d0;
            href_d0  <= cam_href;
            href_d1  <= href_d0;
            data_d0  <= cam_data;
        end
    end

    // 边沿
    wire vsync_rise = vsync_d0 & ~vsync_d1;   // 帧开始
    wire vsync_fall = ~vsync_d0 & vsync_d1;   // 帧结束
    wire href_fall  = ~href_d0  & href_d1;    // 一行结束
    wire href_rise  = href_d0   & ~href_d1;   // 一行开始

    // ==================================================================
    //  PCLK 域：字节拼装
    //
    //  每来两个 HREF 内的有效字节，拼成一个 RGB565 像素推进 FIFO。
    //  byte_phase 用 HREF 的上升沿复位，保证行首一定从"第一字节"开始 ——
    //  否则一旦某行丢了一个字节，之后所有行的红蓝都会整体互换。
    // ==================================================================
    reg        byte_phase;      // 0 = 还没收到高字节, 1 = 已收到，正等低字节
    reg [7:0]  byte_hi;

    // 一个像素拼完的时刻 = 收到**低字节**的那一拍，
    // 即 byte_phase 已经为 1 的时候。
    //
    // ⚠ 两处曾经写错，都由 tb_dvp_capture 的逐位比对抓到：
    //
    //   1. 早期写成 ~byte_phase，方向反了：那样会在每行的
    //      **第一个**字节就触发写入，把 {0, 第一字节} 当成一个像素。
    //
    //   2. 后来改成 byte_phase 但漏了 `& ~href_rise`：行首那一拍
    //      href_rise 与上一行残留的 byte_phase=1 同时为真，
    //      于是用上一行残留的高字节去配本行的首字节，
    //      多出一个幽灵像素（实测多出"行数"个，总数 W*H + H）。
    //
    //   `~href_rise` 的作用：行首那一拍只做相位复位，绝不产出像素。
    wire pix_valid = href_d0 & byte_phase & ~href_rise;

    wire [15:0] pix = BYTE_SWAP ? {data_d0, byte_hi}
                                : {byte_hi, data_d0};

    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) begin
            byte_phase <= 1'b0;
            byte_hi    <= 8'd0;
        end else if (href_d0) begin
            // ⚠ 行首那一拍必须**既复位相位、又把这个字节存成高字节**。
            //   早期版本只复位不存，等于把行首第一个字节吞掉，
            //   之后整行的高字节都取自"下一个字节"，
            //   表现为每个像素都是 {低字节, 下一像素的高字节}。
            //
            //   href_rise 与 !byte_phase 通常同时为真（正常行首）；
            //   只 href_rise 为真则说明上一行有毛刺导致相位失步，
            //   此处一并重新对齐。
            if (href_rise || !byte_phase) begin
                byte_hi    <= data_d0;      // 行首/行内首字节 → 高字节
                byte_phase <= 1'b1;
            end else begin
                byte_phase <= 1'b0;         // 收到低字节，一像素拼完
            end
        end
    end

    // ==================================================================
    //  写 FIFO 的时序：延后一拍，以便给行末像素挂上 TLAST
    //
    //  ⚠ 为什么不能直接写 pix_valid：
    //    DVP 的 HREF 是在**最后一个像素的低字节之后**才拉低的，
    //    所以"这一像素是本行最后一个"这个信息，在写它的那一拍
    //    根本还没有 —— href_fall 要下一拍才出现。
    //
    //    做法：把拼好的像素先寄存一拍，下一拍再用当时看到的
    //    href_fall 决定是否给 TLAST。代价是 1 拍延迟，值得。
    //
    //  ⚠ 这个 1 拍延迟发生在**写入侧**，不要与读侧的 FWFT 关系
    //    （rd_en 当拍出数）混淆 —— 两处是独立的事。
    // ==================================================================
    reg        pix_v_d;
    reg [15:0] pix_d;

    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) begin
            pix_v_d <= 1'b0;
            pix_d   <= 16'd0;
        end else begin
            pix_v_d <= pix_valid;
            pix_d   <= pix;
        end
    end

    wire fifo_full;
    wire fifo_wr = pix_v_d;

    // ==================================================================
    //  跨时钟域：异步 FIFO
    //
    //  ⚠ 这里**必须**用异步 FIFO。PCLK 与 aclk 相位无关，
    //    多比特数据逐位同步会出现"高位新值+低位旧值"的混合态。
    // ==================================================================
    // ---- TLAST 的产生 ----
    // 读侧需要在读出时知道"这一像素是不是本行的最后一个"。
    // 做法：写 FIFO 时把行尾标志作为第 17 位 sideband 一起写进去。
    //
    // 为什么用 sideband 而不是读侧计数器：
    //   读侧计数器要求下游知道分辨率，且一旦上游丢字节就会整帧错位。
    //   sideband 由产生数据的写侧直接标注，分辨率无关，也不怕丢。
    //
    // 代价：FIFO 宽度 16 → 17 位。
    wire        fifo_empty;
    wire [16:0] fifo_dout17;
    wire [16:0] fifo_din17 = {href_fall & pix_v_d, pix_d};
    wire        rd_en17 = ~fifo_empty & m_axis_tready;

    async_fifo #(
        .DATA_W (17),
        .ADDR_W (FIFO_ADDR_W)
    ) u_fifo (
        .wr_clk     (pclk),
        .wr_rst_n   (rst_n_pclk),
        .wr_en      (fifo_wr),
        .wr_data    (fifo_din17),
        .full       (fifo_full),

        .rd_clk     (aclk),
        .rd_rst_n   (rst_n_aclk),
        .rd_en      (rd_en17),
        .rd_data    (fifo_dout17),
        .empty      (fifo_empty),

        .wr_overflow(),
        .rd_underflow()
    );

    // ==================================================================
    //  aclk 域：FIFO → AXI4-Stream
    //
    //  ⚠ 这里的时序关系必须与 async_fifo 的实现对齐，否则整体错一格。
    //
    //  async_fifo 的读出是
    //      assign rd_data = mem[rbin];      // rbin 是寄存器
    //  即"读地址寄存器组合读存储体"，属于 **FWFT**
    //  （first-word-fall-through）：rd_en 拉高的**同一拍**，
    //  rd_data 上就是被读的那个字。
    //
    //  所以 tvalid 必须直接用 rd_en，**不能再打一拍**。
    //  早期版本按"非 FWFT"多打了一拍，结果是：
    //    - 输出整体错位一格，还读到尚未写入的槽位（x 值）
    //    - 每行多吐一个像素（正好一行一个）
    //  这个 bug 由 tb_dvp_capture 的像素逐位比对抓到 ——
    //  只看"有没有数据出来"是发现不了的。
    //
    //  ❗ 如果以后把 async_fifo 改成寄存输出（非 FWFT），
    //    这里必须同步改回打一拍。两处是一体的。
    // ==================================================================
    assign m_axis_tvalid = rd_en17;
    assign m_axis_tdata  = fifo_dout17[15:0];
    assign m_axis_tlast  = fifo_dout17[16];

    // ==================================================================
    //  统计与状态
    // ==================================================================
    // 帧/行计数在 aclk 域统计（给 PS 读，走 AXI-Lite）
    wire any_line  = rd_en17 & fifo_dout17[16];   // 行尾

    // 帧边界脉冲在 pclk 域产生，跨域到 aclk 时只需一位（电平信号
    // 打两拍即可，不存在多比特混合态问题）。
    reg vsync_rise_d0, vsync_rise_d1, vsync_rise_d2;
    always @(posedge aclk or negedge rst_n_aclk) begin
        if (!rst_n_aclk) begin
            vsync_rise_d0 <= 1'b0;
            vsync_rise_d1 <= 1'b0;
            vsync_rise_d2 <= 1'b0;
        end else begin
            vsync_rise_d0 <= vsync_rise;   // 来自 pclk 域的单比特脉冲
            vsync_rise_d1 <= vsync_rise_d0;
            vsync_rise_d2 <= vsync_rise_d1;
        end
    end

    wire frame_edge = vsync_rise_d1 & ~vsync_rise_d2;   // 本域内检边沿

    always @(posedge aclk or negedge rst_n_aclk) begin
        if (!rst_n_aclk) begin
            frame_cnt <= 16'd0;
            line_cnt  <= 16'd0;
            stalled   <= 1'b0;
        end else begin
            if (frame_edge) begin
                frame_cnt <= frame_cnt + 16'd1;
                line_cnt  <= 16'd0;          // 新帧，行计数归零
            end else if (any_line) begin
                line_cnt <= line_cnt + 16'd1;
            end

            if (fifo_full && fifo_wr)
                stalled <= 1'b1;    // 粘滞：发生过丢数据就置位，便于定位
        end
    end

    // ==================================================================
    //  调试输出
    // ==================================================================
    assign vsync_sync = vsync_d0;
    assign href_sync  = href_d0;

endmodule
