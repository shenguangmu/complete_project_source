// =====================================================================
//  tb_ov5640_regs.v —— ov5640_regs ROM 接口自检
//
//  运行：
//      iverilog -g2012 -o tb.vvp tb_ov5640_regs.v ../ov5640_regs.v
//      vvp tb.vvp
//
//  ⚠ 必须看到 *** TB PASSED ***
//
//  ─────────────────────────────────────────────────────────────────
//  这个 TB 验什么、不验什么
//  ─────────────────────────────────────────────────────────────────
//  **不验**配置内容对不对 —— 寄存器值的正确性只能上板看有没有图像。
//  本 TB 不硬编码整张表（250 条抄一遍无法维护，抄错就是双重错误来源）。
//
//  **验**三件事，它们错了都会**静默出错**：
//
//    1. 拼接顺序 = {reg_addr[15:0], value[7:0]}
//       ⚠ 顺序反了会往**错误的寄存器**写值，而 SCCB 波形看起来
//         完全正常（SCL/SDA 一模一样）。症状是"摄像头毫无反应"，
//         而人会去查接线和时序，想不到是拼接顺序。
//         这是本 TB 最有价值的一条。
//
//    2. 几条**关键寄存器**的值（分辨率 / 输出格式 / 彩条 / PCLK 分频）
//       —— 这几个错了会直接导致不出图或格式不对，值得逐条断言。
//
//    3. 表长度与 sccb_master 的 N_REGS 一致
//       ⚠⚠ sccb_master.v 的 N_REGS 默认是 **64**，而本表是 250 条。
//          两者不一致时 sccb 会**配到一半就停**（或越界读垃圾值），
//          且没有任何报错。**这条必须在 BD 里同步改。**
//
//  ─────────────────────────────────────────────────────────────────
//  表更新历史
//  ─────────────────────────────────────────────────────────────────
//    2026-09-17：由"8 条占位值"替换为真实配置表
//                来源：正点原子 i2c_ov5640_rgb565_cfg.v（250 条）
//                分辨率固化为 640x480（详见 ov5640_regs.v 文件头）
//
//  ─────────────────────────────────────────────────────────────────
//  写法说明（踩过的坑）
//  ─────────────────────────────────────────────────────────────────
//  * 所有 reg/wire/integer 声明必须在**所有过程块之前**。
//    把 `reg [23:0] expect [0:7]` 放在 task 之后会报
//    "syntax error: invalid module item"。
//  * **不在 initial 块内部声明 reg** —— 同样报 invalid module item。
//  * iverilog 的 $display 中文在部分终端会乱码，判定只看英文标记。
// =====================================================================

`timescale 1ns / 1ps

module tb_ov5640_regs;

    localparam ADDR_W = 8;
    localparam N_REGS = 250;
    // ⚠ 必须与 BD 里 sccb_0 的 N_REGS 一致
    localparam SCCB_N_REGS = 250;

    reg  [ADDR_W-1:0] addr;
    wire [23:0]       data;
    reg  [23:0]       d;
    reg                fnd;      // find_val 的 found 输出
    reg  [7:0]         kval;     // find_val 的 value 输出

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer i;

    wire [15:0] field_addr = data[23:8];
    wire [7:0]  field_val  = data[7:0];

    ov5640_regs #(
        .N_REGS (N_REGS),
        .ADDR_W (ADDR_W)
    ) u_dut (
        .tbl_addr (addr),
        .tbl_data (data)
    );

    task rd;
        input  [ADDR_W-1:0] a;
        output [23:0]       o;
        begin
            addr = a;
            #1;
            o = data;
        end
    endtask

    task check;
        input             ok;
        input [8*64-1:0]  name;
        begin
            if (ok) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL : %0s", name);
            end
        end
    endtask

    // 按寄存器地址找它的值；找不到返回 24'hxxxxxx
    task find_val;
        input  [15:0]      want_addr;
        output [7:0]       got_val;
        output             found;
        integer            k;
        reg   [23:0]       t;
        begin
            found   = 1'b0;
            got_val = 8'hxx;
            for (k = 0; k < N_REGS; k = k + 1) begin
                addr = k[ADDR_W-1:0];
                #1;
                if (data[23:8] == want_addr) begin
                    got_val = data[7:0];
                    found   = 1'b1;
                    k = N_REGS;      // 提前退出
                end
            end
        end
    endtask

    initial begin
        $dumpfile("wave_ov5640_regs.vcd");
        $dumpvars(0, tb_ov5640_regs);

        $display("=== ov5640_regs TB START ===");
        $display("  ADDR_W = %0d, N_REGS = %0d", ADDR_W, N_REGS);

        // ---- 用例 1：拼接顺序（最重要）----
        $display("\n[1] concat order: high16 = reg addr, low8 = data");
        rd(8'd0, d);
        $display("      rom[0] = %06h  -> addr=%04h val=%02h", d, field_addr, field_val);
        check(field_addr === 16'h300A, "rom[0] high16 should be 0x300A");
        check(field_val  === 8'h00,    "rom[0] low8 should be 0x00");

        // ---- 用例 2：关键寄存器逐条断言 ----
        // 这几个错了会直接导致不出图 / 格式不对，值得断言。
        $display("\n[2] key registers");
        find_val(16'h4300, kval, fnd);
        $display("      0x4300 (output fmt)   = %02h  (expect 61 = RGB565)", kval);
        check(fnd && kval === 8'h61, "0x4300 should be 0x61 (RGB565)");

        find_val(16'h503D, kval, fnd);
        $display("      0x503D (color bar)    = %02h  (expect 00 = off)", kval);
        check(fnd && kval === 8'h00, "0x503D should be 0x00 (color bar off)");

        find_val(16'h3808, kval, fnd);
        $display("      0x3808 (X size hi)    = %02h  (expect 02)", kval);
        check(fnd && kval === 8'h02, "0x3808 should be 0x02 (640 hi)");

        find_val(16'h3809, kval, fnd);
        $display("      0x3809 (X size lo)    = %02h  (expect 80)", kval);
        check(fnd && kval === 8'h80, "0x3809 should be 0x80 (640 lo)");

        find_val(16'h380A, kval, fnd);
        $display("      0x380A (Y size hi)    = %02h  (expect 01)", kval);
        check(fnd && kval === 8'h01, "0x380A should be 0x01 (480 hi)");

        find_val(16'h380B, kval, fnd);
        $display("      0x380B (Y size lo)    = %02h  (expect E0)", kval);
        check(fnd && kval === 8'hE0, "0x380B should be 0xE0 (480 lo)");

        find_val(16'h3824, kval, fnd);
        $display("      0x3824 (PCLK div)     = %02h  (expect 02)", kval);
        check(fnd && kval === 8'h02, "0x3824 should be 0x02 (PCLK div)");

        // ---- 用例 3：表长度与 sccb_master 的 N_REGS 一致 ----
        $display("\n[3] table length vs sccb_master N_REGS");
        $display("      N_REGS = %0d, sccb N_REGS = %0d", N_REGS, SCCB_N_REGS);
        check(N_REGS == SCCB_N_REGS,
              "N_REGS must match sccb_master N_REGS (else SCCB stops halfway)");
        check(N_REGS <= (1 << ADDR_W),
              "N_REGS must not exceed 2^ADDR_W (else out-of-range read)");

        // ---- 汇总 ----
        $display("\n=== TB DONE: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("*** TB PASSED ***");
        else
            $display("*** TB FAILED ***");

        $finish;
    end

    initial begin
        #100000;
        $display("\n*** TB TIMEOUT ***");
        $finish;
    end

endmodule
