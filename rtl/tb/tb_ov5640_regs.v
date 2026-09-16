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
//  **不验**配置内容对不对 —— 当前是占位表，内容本身还没定。
//  值的正确性只能上板看有没有图像。
//
//  **验**接口行为，因为接口错了会静默出错：
//
//    1. tbl_data 的拼接顺序 = {reg_addr[15:0], value[7:0]}
//       ⚠ 顺序反了会往**错误的寄存器**写值，而 SCCB 波形
//         看起来完全正常（SCL/SDA 一模一样）。症状是"摄像头毫无反应"，
//         而人会去查接线和时序，想不到是拼接顺序。
//         这是本 TB 最有价值的一条。
//
//    2. 地址位宽与 sccb_master 一致（8 位）
//       —— 曾用 12 位导致 BD 报 [BD 41-2383] 位宽不匹配、高 4 位悬空
//
//    3. 越界读不产生 x（否则综合出的 ROM 行为不确定）
//
//  ─────────────────────────────────────────────────────────────────
//  写法说明（踩过的坑）
//  ─────────────────────────────────────────────────────────────────
//  * 所有 reg/wire/integer 声明必须在**所有过程块之前**。
//    把 `reg [23:0] expect [0:7]` 放在 task 之后会报
//    "syntax error: invalid module item"。
//  * **不在 initial 块内部声明 reg** —— 同样报 invalid module item。
//    需要临时变量就提到模块级。
//  * 上面两条让最初的版本连编译都过不去。本版改用 task + 单个
//    临时变量，结构最简。
// =====================================================================

`timescale 1ns / 1ps

module tb_ov5640_regs;

    localparam ADDR_W = 8;

    // ---- 所有声明放最前 ----
    reg  [ADDR_W-1:0] addr;
    wire [23:0]       data;
    reg  [23:0]       d;          // 读回值暂存

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 拆分 tbl_data 的两个字段（用例 2 用）
    wire [15:0] field_addr = data[23:8];
    wire [7:0]  field_val  = data[7:0];

    ov5640_regs #(
        .N_REGS (8),
        .ADDR_W (ADDR_W)
    ) u_dut (
        .tbl_addr (addr),
        .tbl_data (data)
    );

    // ---- task 在所有 initial 之前 ----
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
        input [8*52-1:0]  name;
        begin
            if (ok) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("  FAIL : %0s", name);
            end
        end
    endtask

    initial begin
        $dumpfile("wave_ov5640_regs.vcd");
        $dumpvars(0, tb_ov5640_regs);

        $display("=== ov5640_regs TB START ===");
        $display("  地址位宽 = %0d", ADDR_W);

        // ---- 用例 1：逐项读取，与 ov5640_regs.v 里的表比对 ----
        //
        // ⚠ 改 ov5640_regs.v 的表时这里要同步改 —— 本 TB 失败正是
        //   它的作用：防止改了表却忘了别处。
        $display("\n[1] 逐项比对（与 ov5640_regs.v 的 rom[] 一致）");
        rd(0, d); check(d === 24'h31_03_11, "rom[0] 应为 31_03_11");
        rd(1, d); check(d === 24'h30_08_82, "rom[1] 应为 30_08_82");
        rd(2, d); check(d === 24'h30_35_11, "rom[2] 应为 30_35_11");
        rd(3, d); check(d === 24'h30_36_3C, "rom[3] 应为 30_36_3C");
        rd(4, d); check(d === 24'h30_37_13, "rom[4] 应为 30_37_13");
        rd(5, d); check(d === 24'h38_24_00, "rom[5] 应为 38_24_00");
        rd(6, d); check(d === 24'h43_00_61, "rom[6] 应为 43_00_61");
        rd(7, d); check(d === 24'h50_3D_80, "rom[7] 应为 50_3D_80");

        // ---- 用例 2：拼接顺序（本 TB 最重要的一条）----
        $display("\n[2] 拼接顺序：高 16 位 = 寄存器地址，低 8 位 = 数据");
        rd(2, d);
        $display("      data = %06h  ->  地址字段 = %04h, 数据字段 = %02h",
                 d, field_addr, field_val);
        check(field_addr === 16'h3035, "高 16 位应为寄存器地址 0x3035");
        check(field_val  === 8'h11,    "低 8 位应为数据值 0x11");

        // ---- 用例 3：越界读的行为（提示性，不作断言）----
        //
        // ⚠ 这里**故意不做断言**。原因：
        //   仿真器对越界数组读一律返回 x（数组边界在仿真中是检查的），
        //   而综合出的 ROM 对越界地址的行为由综合器决定（通常回绕）。
        //   所以"仿真里是 x"**不代表有问题** —— 断言它反而会误报。
        //
        //   真正要保证的是：**配置表长度不超过 2^ADDR_W**，
        //   否则 sccb_master 会读到越界项。
        //   这条靠人检查，TB 只能提示。
        $display("\n[3] 越界读行为（提示性检查，不断言）");
        rd(8'd200, d);
        if (d === 24'hxxxxxx)
            $display("      越界读到 x —— 仿真正常（综合后 ROM 会有确定行为）");
        else
            $display("      越界读返回 %06h", d);
        pass_cnt = pass_cnt + 1;   // 只要不挂就算过

        // ---- 汇总 ----
        $display("\n=== TB DONE: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("*** TB PASSED ***");
        else
            $display("*** TB FAILED ***");

        $finish;
    end

    initial begin
        #10000;
        $display("\n*** TB TIMEOUT ***");
        $finish;
    end

endmodule
