// =====================================================================
//  sccb_master.v —— SCCB(I2C 兼容) 主控，用于配置 OV5640
//
//  ─────────────────────────────────────────────────────────────────
//  ⚠ OV5640 用 **16 位寄存器地址**，事务是 4 字节不是 3 字节
//  ─────────────────────────────────────────────────────────────────
//  常见教程里的 SCCB 写是 3 字节（设备地址 + 8 位寄存器地址 + 数据），
//  那是给 OV7670 / OV7725 这类老传感器的。OV5640 的寄存器地址是
//  16 位（0x3035、0x503D 这种），正确的事务是：
//
//      设备地址(W) → ACK → 地址高字节 → ACK → 地址低字节 → ACK → 数据 → ACK
//
//  早期版本按 3 字节实现，仿真能跑完、但真机上摄像头一个寄存器都配不上
//  （表现为完全没有图像）。这个错误由 tb_sccb_master.v 的从机模型抓到。
//
//  SUB_ADDR_BYTES 参数保留可配，接别的传感器时改它即可。
//
//  ─────────────────────────────────────────────────────────────────
//  SCCB 与标准 I2C 的关系
//  ─────────────────────────────────────────────────────────────────
//  * 电气与位时序一致：START / STOP / 8bit + ACK
//  * SCCB 规范里 ACK 是"don't care"，OV5640 实际会拉低，本模块按
//    I2C 的规则检查；若某些模组不拉低，把 CHK_ACK 置 0 跳过检查
//  * 本模块只实现"写"方向（配置摄像头不需要读）
//
//  ─────────────────────────────────────────────────────────────────
//  时钟
//  ─────────────────────────────────────────────────────────────────
//  SCL 由 clk 分频：分频系数 = clk_freq / (2 * sccb_freq)
//    100 MHz / (2 * 100 kHz) = 500
//  OV5640 手册上限 400 kHz，100 kHz 有充足余量（也降低转接板走线风险）。
// =====================================================================

`timescale 1ns / 1ps

module sccb_master #(
    // 分频系数：clk_freq / (2 * sccb_freq)
    parameter CLK_DIV       = 500,
    // 7bit 设备地址（OV5640 写地址 0x78 → 7bit 是 0x3C）
    parameter DEV_ADDR      = 7'h3C,
    // 子地址字节数。OV5640 = 2（16 位寄存器地址）
    parameter SUB_ADDR_BYTES = 2,
    // 配置表深度
    parameter N_REGS        = 64,
    // 是否检查从机 ACK
    parameter CHK_ACK       = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    // 配置表：每项 {子地址[15:0], 数据[7:0]} = 24 位
    output reg  [7:0]  tbl_addr,
    input  wire [23:0] tbl_data,

    // SCCB 物理接口（开漏，需外部上拉）
    output reg         scl,
    output reg         sda_oe,      // 1 = 驱动 sda_o
    output reg         sda_o,
    input  wire        sda_i,

    // 状态
    output reg         cfg_done,
    output reg         cfg_error,   // 某次事务没收到 ACK
    output reg  [7:0]  done_cnt
);

    // 一次事务的总字节数 = 1(设备地址) + SUB_ADDR_BYTES + 1(数据)
    localparam N_BYTES = 1 + SUB_ADDR_BYTES + 1;
    localparam SR_W    = 8 + 8 * SUB_ADDR_BYTES + 8;   // 移位寄存器位宽

    // ------------------------------------------------------------------
    //  分频时基
    // ------------------------------------------------------------------
    reg [15:0] div_cnt;
    wire       tick = (div_cnt == CLK_DIV[15:0] - 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div_cnt <= 16'd0;
        else if (tick) div_cnt <= 16'd0;
        else div_cnt <= div_cnt + 16'd1;
    end

    // ------------------------------------------------------------------
    //  状态机
    //
    //  每个 SCL 位周期用 2 个 tick：
    //    前半段（scl_phase=0）：SCL 拉低，此时更新 SDA
    //    后半段（scl_phase=1）：SCL 拉高，数据被从机采样
    // ------------------------------------------------------------------
    localparam S_IDLE  = 3'd0,
               S_START = 3'd1,
               S_BITS  = 3'd2,
               S_ACK   = 3'd3,
               S_STOP  = 3'd4,
               S_NEXT  = 3'd5,
               S_DONE  = 3'd6;

    reg [2:0]  state;
    reg [2:0]  byte_idx;     // 当前是第几个字节 0..N_BYTES-1
    reg [2:0]  bit_idx;      // 字节内第几位 7..0
    reg [SR_W-1:0] sr;       // 待发数据
    reg        scl_phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            scl       <= 1'b1;
            sda_oe    <= 1'b0;
            sda_o     <= 1'b1;
            byte_idx  <= 3'd0;
            bit_idx   <= 3'd0;
            sr        <= {SR_W{1'b0}};
            tbl_addr  <= 8'd0;
            cfg_done  <= 1'b0;
            cfg_error <= 1'b0;
            done_cnt  <= 8'd0;
            scl_phase <= 1'b0;
        end else begin
            case (state)

            // ---- 空闲：等分频，装载下一个事务 ----
            S_IDLE: begin
                scl      <= 1'b1;
                sda_oe   <= 1'b1;
                sda_o    <= 1'b1;
                cfg_done <= 1'b0;
                if (tick) begin
                    if (tbl_addr >= N_REGS[7:0]) begin
                        state <= S_DONE;
                    end else begin
                        /* 拼出待发位串：{设备地址[6:0], 0(W), 子地址, 数据}
                         * ⚠ 顺序不能错：设备地址在最前，数据在最后。 */
                        sr       <= {DEV_ADDR, 1'b0, tbl_data};
                        byte_idx <= 3'd0;
                        bit_idx  <= 3'd7;
                        scl_phase <= 1'b0;
                        state    <= S_START;
                    end
                end
            end

            // ---- START：SCL 保持高，SDA 由 1→0 ----
            S_START: begin
                scl <= 1'b1;
                if (tick) begin
                    if (!scl_phase) begin
                        sda_oe    <= 1'b1;
                        sda_o     <= 1'b0;
                        scl_phase <= 1'b1;
                    end else begin
                        scl_phase <= 1'b0;
                        state     <= S_BITS;
                    end
                end
            end

            // ---- 发 8 位：SCL 低电平期间更新 SDA ----
            //
            //  ⚠ 移位、位计数、状态跳转必须在**同一个 tick 的同一拍**
            //    里决定，否则会在字节边界处多跳一拍、少发一位。
            //
            //    早期版本的 bug 正是这样：在"最后一位"那一拍同时写了
            //    `scl_phase <= 0` 和 `bit_idx <= 0`，而 state 是**下一拍**
            //    才变成 S_ACK 的；等到进 S_BITS 重新开始发下一字节时，
            //    sr 已经被多移了一位。表现是主机只发出 24 位（3 字节）
            //    而 OV5640 需要 32 位（4 字节），摄像头完全收不到正确数据。
            //    由 tb_probe 数 SCL 上升沿（48 个，应为 72）定位到。
            S_BITS: begin
                if (tick) begin
                    if (!scl_phase) begin
                        scl       <= 1'b0;
                        sda_oe    <= 1'b1;
                        sda_o     <= sr[SR_W-1];        // MSB first
                        scl_phase <= 1'b1;
                    end else begin
                        scl       <= 1'b1;
                        sr        <= {sr[SR_W-2:0], 1'b0};
                        scl_phase <= 1'b0;

                        // 本拍发出的就是最后一位 => 直接转去收 ACK，
                        // 且不再动 bit_idx（它下次进 S_BITS 时才重置）
                        if (bit_idx == 3'd0) begin
                            bit_idx <= 3'd7;
                            state   <= S_ACK;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                        end
                    end
                end
            end

            // ---- 收 ACK：释放 SDA，SCL 高电平时采样 ----
            S_ACK: begin
                if (tick) begin
                    if (!scl_phase) begin
                        scl       <= 1'b0;
                        sda_oe    <= 1'b0;      // 释放总线
                        scl_phase <= 1'b1;
                    end else begin
                        scl <= 1'b1;
                        if (CHK_ACK != 0 && sda_i != 1'b0)
                            cfg_error <= 1'b1;  // 从机没拉低 = NACK
                        scl_phase <= 1'b0;
                        bit_idx   <= 3'd7;

                        if (byte_idx == N_BYTES[2:0] - 3'd1)
                            state <= S_STOP;
                        else begin
                            byte_idx <= byte_idx + 3'd1;
                            state    <= S_BITS;
                        end
                    end
                end
            end

            // ---- STOP：SCL 保持高，SDA 由 0→1 ----
            S_STOP: begin
                if (tick) begin
                    if (!scl_phase) begin
                        sda_oe    <= 1'b1;
                        sda_o     <= 1'b0;
                        scl       <= 1'b1;
                        scl_phase <= 1'b1;
                    end else begin
                        sda_o     <= 1'b1;
                        scl_phase <= 1'b0;
                        state     <= S_NEXT;
                    end
                end
            end

            // ---- 下一项 ----
            S_NEXT: begin
                if (tick) begin
                    tbl_addr <= tbl_addr + 8'd1;
                    done_cnt <= done_cnt + 8'd1;
                    state    <= S_IDLE;
                end
            end

            // ---- 全部配完：释放总线 ----
            S_DONE: begin
                scl      <= 1'b1;
                sda_oe   <= 1'b0;
                cfg_done <= 1'b1;
                state    <= S_DONE;
            end

            default: state <= S_IDLE;

            endcase
        end
    end

endmodule
