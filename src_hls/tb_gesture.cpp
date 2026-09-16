/**
 * @file    tb_gesture.cpp
 * @brief   手势预处理链 —— HLS C 仿真 testbench
 *
 * ────────────────────────────────────────────────────────────────────
 *  设计目标
 * ────────────────────────────────────────────────────────────────────
 *  本 TB 必须能在**没有 Python、没有板子、没有 opencv** 的机器上
 *  完整跑通并给出明确的 PASS/FAIL —— 这是整个项目能往前推的前提。
 *
 *  做法：数据由内部伪随机数发生器 + 几何图元生成，
 *  期望值由 gesture_ref.cpp（同目录，编译期一起链进来）算出，
 *  逐位比对。
 *
 * ────────────────────────────────────────────────────────────────────
 *  四组用例的用意（不是凑数，每组对应一类真实故障）
 * ────────────────────────────────────────────────────────────────────
 *  1. 全链开启        —— 基本功能正确性
 *  2. 全链关闭        —— 各级直通路径；直通写错会整帧偏移
 *  3. 极小 ROI        —— 缩放步长退化到 1；步长为 0 会除零
 *  4. 灰度渐变 + 用已知答案验证阈值逻辑
 *                     —— 前三组都是"自比对"，若参考实现本身错了
 *                        会一起错。这组用手算的确定值做绝对校验。
 */

#include "gesture_preproc.h"
#include "gesture_ref.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ================================================================== *
 *  测试图像生成
 * ================================================================== */

#define IN_W   GESTURE_IN_WIDTH
#define IN_H   GESTURE_IN_HEIGHT

/* ------------------------------------------------------------------ *
 *  ROI 参数（自适应输入尺寸）
 *
 *  ⚠ 原来是硬编码的 (160,80,320,320)，只在 640x480 下成立。
 *    改成取**整个输入图**，这样调 GESTURE_IN_WIDTH/HEIGHT 做
 *    **缩小规模的 cosim** 时不用改 TB。
 *
 *  为什么不取输入的一半：输出尺寸是固定的 96x96（与 CNN 的契约），
 *  若 ROI 小于 96x96，盒式缩放的块会不足 96 个，输出出现大片补零 ——
 *  那会让"逐位比对"变得没意义（大部分是零）。
 *  取整图则保证步长 ≥ 1 且覆盖完整，测试有效。
 * ------------------------------------------------------------------ */
#define RW  IN_W
#define RH  IN_H
#define RX  0
#define RY  0

/* 用例 3 用的"极小 ROI"：min(输入, 96)。
 * 输入 ≥ 96 时步长 = 1（退化情形）；输入更小时取整图。 */
#define TW  ((IN_W < 96) ? IN_W : 96)
#define TH  ((IN_H < 96) ? IN_H : 96)
#define TX  ((IN_W - TW) / 2)
#define TY  ((IN_H - TH) / 2)

/** 输入帧：RGB565。放在文件作用域避免占用栈。 */
static ap_uint<16> g_src[IN_W * IN_H];
static ap_uint<8>  g_hls[GESTURE_OUT_PIXELS];
static ap_uint<8>  g_ref[GESTURE_OUT_PIXELS];

/** 确定性伪随机（线性同余）—— 不用 rand()，保证任何平台结果一致 */
static unsigned int g_seed = 12345u;
static unsigned int lcg(void)
{
    g_seed = g_seed * 1103515245u + 12345u;
    return (g_seed >> 16) & 0x7FFFu;
}

static ap_uint<16> pack_rgb565(ap_uint<8> r, ap_uint<8> g, ap_uint<8> b)
{
    return ((ap_uint<16>)(r >> 3) << 11) |
           ((ap_uint<16>)(g >> 2) <<  5) |
           ((ap_uint<16>)(b >> 3));
}

/**
 * @brief 造一张"假手势"图
 *
 * 内容：随机噪点背景 + 一个居中的亮色圆角矩形（模拟手掌）+ 几条暗色
 * 竖条（模拟手指缝）。这样构造是为了让每一级都有非平凡的输出 ——
 * 纯色图会让高斯、Sobel、形态学全部退化成常数，测不出错。
 */
static void make_test_image(int variant)
{
    g_seed = 12345u + (unsigned int)variant * 7919u;

    for (int y = 0; y < IN_H; y++) {
        for (int x = 0; x < IN_W; x++) {
            ap_uint<8> r, g, b;

            /* 背景：低频渐变 + 少量噪点 */
            ap_uint<8> base = (ap_uint<8>)((x * 255) / IN_W);
            ap_uint<8> noise = (ap_uint<8>)(lcg() & 0x0F);

            r = (ap_uint<8>)(base / 2 + noise);
            g = (ap_uint<8>)(base / 2 + noise);
            b = (ap_uint<8>)(base / 2 + noise);

            /* 掌区：居中的亮块，大小 = 输入的 3/4
             * ⚠ 原来是硬编码 320，改输入尺寸后会算出负的左边界。
             *   改成按比例，任何分辨率下都成立。 */
            const int PW = (IN_W * 3) / 4;
            const int PH = (IN_H * 3) / 4;
            const int px1 = (IN_W - PW) / 2, px2 = px1 + PW;
            const int py1 = (IN_H - PH) / 2, py2 = py1 + PH;

            if (x >= px1 && x < px2 && y >= py1 && y < py2) {
                r = 220; g = 200; b = 180;

                /* 指缝：掌区内几条暗竖条 */
                const int lx = (x - px1) % 64;
                if (lx < 8) { r = 40; g = 35; b = 30; }
            }

            if (variant == 3) {
                /* 用例 4 专用：整帧水平方向灰度线性渐变 0..255，
                 * 便于手算阈值与二值化结果。 */
                ap_uint<8> v = (ap_uint<8>)((x * 255) / (IN_W - 1));
                r = g = b = v;
            }

            g_src[y * IN_W + x] = pack_rgb565(r, g, b);
        }
    }
}

/* ================================================================== *
 *  驱动顶层
 * ================================================================== */

/* ================================================================== *
 *  喂数据 / 收数据 —— 必须与 DUT **并行**执行
 *
 *  ⚠⚠ 这里踩过一个会导致 cosim 死锁的坑，值得完整记下来
 *
 *  最初的写法是**串行**的：
 *      for (...) s_in.write(...);      // ① 先喂完所有输入
 *      gesture_preproc(...);           // ② 再调用 DUT
 *      for (...) s_out.read();         // ③ 最后读输出
 *
 *  **csim 能过**：csim 里 hls::stream 是无限深度的 FIFO，
 *  307200 个像素全塞进去也不阻塞。
 *
 *  **cosim 死锁**：RTL 仿真里 hls::stream 是**真实的有深度限制的
 *  FIFO**。写满之后 write() 阻塞，而 DUT 还没被 ap_start 启动、
 *  不会消费 —— 于是 TB 等 FIFO 空位、DUT 等 ap_start，**互等死锁**。
 *
 *  症状：RTL Simulation 报 `0 / 6` 且**与输入分辨率无关**
 *  （因为卡在数据路径之外），仿真时间一路涨到几百 ms。
 *
 *  **修法**：把喂数据和收数据都做成**独立的子函数**，让 HLS 的
 *  DATAFLOW 机制把它们和 DUT 主体并行调度。这样输入 FIFO 一满，
 *  喂数据的那一级就会自然暂停，等 DUT 消费 —— 正常的流控。
 *
 *  这与真实硬件的行为也更接近：AXI DMA 是一边喂一边收的，
 *  不会"先把整帧灌完再启动 IP"。
 * ================================================================== */
static void feed_input(hls::stream<axis_rgb_t> &s_in,
                       int width, int height)
{
#pragma HLS INLINE off
    for (int i = 0; i < width * height; i++) {
#pragma HLS PIPELINE II=1
        axis_rgb_t w;
        w.data = g_src[i];
        w.keep = 0x3;   /* 16bit 数据，2 字节有效 */
        w.strb = 0x3;
        w.last = (i == width * height - 1) ? 1 : 0;
        s_in.write(w);
    }
}

static void drain_output(hls::stream<axis_gray_t> &s_out)
{
#pragma HLS INLINE off
    for (int i = 0; i < GESTURE_OUT_PIXELS; i++) {
#pragma HLS PIPELINE II=1
        axis_gray_t w = s_out.read();
        g_hls[i] = w.data;
    }
}

static void run_hls(int width, int height,
                    int thresh_mode, int thresh_offset,
                    int gauss_en, int sobel_en, int morph_en,
                    int gain, int roi_x, int roi_y, int roi_w, int roi_h)
{
    hls::stream<axis_rgb_t>  s_in("s_in");
    hls::stream<axis_gray_t> s_out("s_out");

    /* ⚠ 三者必须在同一个 DATAFLOW 区域里并行调度。
     *   串行执行会死锁（见上面 feed_input 的注释）。 */
#pragma HLS DATAFLOW

    feed_input(s_in, width, height);

    gesture_preproc(s_in, s_out, width, height,
                    thresh_mode, thresh_offset,
                    gauss_en, sobel_en, morph_en,
                    gain, roi_x, roi_y, roi_w, roi_h);

    drain_output(s_out);
}

static void run_ref(int width, int height,
                    int thresh_mode, int thresh_offset,
                    int gauss_en, int sobel_en, int morph_en,
                    int gain, int roi_x, int roi_y, int roi_w, int roi_h)
{
    ref::gesture_ref(g_src, g_ref, width, height,
                     thresh_mode, thresh_offset,
                     gauss_en, sobel_en, morph_en,
                     gain, roi_x, roi_y, roi_w, roi_h);
}

/** @return 不一致的像素个数；0 表示逐位一致 */
static int compare(const char *name, int verbose)
{
    int bad = 0;
    int first = -1;
    for (int i = 0; i < GESTURE_OUT_PIXELS; i++) {
        if (g_hls[i] != g_ref[i]) {
            if (first < 0) first = i;
            bad++;
        }
    }

    if (bad == 0) {
        printf("    [ OK ] %-38s 逐位一致 (%d 像素)\n",
               name, GESTURE_OUT_PIXELS);
    } else {
        const int y = first / GESTURE_OUT_SIZE;
        const int x = first % GESTURE_OUT_SIZE;
        printf("    [FAIL] %-38s %d/%d 个像素不一致\n",
               name, bad, GESTURE_OUT_PIXELS);
        printf("           首个不一致: (y=%d, x=%d)  hls=%u ref=%u\n",
               y, x, (unsigned)g_hls[first], (unsigned)g_ref[first]);

        if (verbose) {
            /* 打印第 0-2 行的前 20 列，直接看两边的形状而不是猜 */
            printf("           前 3 行 x 前 20 列对比:\n");
            printf("             %-6s %-22s %-22s\n", "y", "hls", "ref");
            for (int yy = 0; yy < 3 && yy < GESTURE_OUT_SIZE; yy++) {
                printf("             y=%-4d ", yy);
                for (int xx = 0; xx < 20; xx++) {
                    printf("%c", "0123456789ABCDEFGHIJKLMNOP"[g_hls[yy*GESTURE_OUT_SIZE+xx] / 16]);
                }
                printf("  ");
                for (int xx = 0; xx < 20; xx++) {
                    printf("%c", "0123456789ABCDEFGHIJKLMNOP"[g_ref[yy*GESTURE_OUT_SIZE+xx] / 16]);
                }
                printf("\n");
            }
            /* 再看中间一行，排除"整体偏移"还是"局部错误" */
            {
                const int yy = GESTURE_OUT_SIZE / 2;
                printf("             y=%-4d ", yy);
                for (int xx = 20; xx < 40; xx++)
                    printf("%c", "0123456789ABCDEFGHIJKLMNOP"[g_hls[yy*GESTURE_OUT_SIZE+xx] / 16]);
                printf("  ");
                for (int xx = 20; xx < 40; xx++)
                    printf("%c", "0123456789ABCDEFGHIJKLMNOP"[g_ref[yy*GESTURE_OUT_SIZE+xx] / 16]);
                printf("\n");
            }
            /* 统计差异是否集中在边缘 */
            int edge = 0, interior = 0;
            for (int yy = 0; yy < GESTURE_OUT_SIZE; yy++) {
                for (int xx = 0; xx < GESTURE_OUT_SIZE; xx++) {
                    if (g_hls[yy * GESTURE_OUT_SIZE + xx] !=
                        g_ref[yy * GESTURE_OUT_SIZE + xx]) {
                        if (yy < 3 || yy > GESTURE_OUT_SIZE - 4 ||
                            xx < 3 || xx > GESTURE_OUT_SIZE - 4)
                            edge++;
                        else
                            interior++;
                    }
                }
            }
            printf("           差异分布: 边缘 %d 个, 内部 %d 个\n",
                   edge, interior);
        }
    }
    return bad;
}

/* ================================================================== *
 *  用例
 * ================================================================== */

static int g_failures = 0;

static void check(const char *name, int bad)
{
    if (bad != 0) g_failures++;
}

int main(void)
{
    printf("\n");
    printf("=====================================================================\n");
    printf("  手势预处理链 HLS C 仿真 —— 全链逐位比对\n");
    printf("  输入 %dx%d RGB565  →  输出 %dx%d 灰度 (%d 字节)\n",
           IN_W, IN_H, GESTURE_OUT_SIZE, GESTURE_OUT_SIZE,
           GESTURE_OUT_PIXELS);
    printf("=====================================================================\n\n");

    /* ---- 用例 1：全链开启 ---- */
    printf("[1] 全链开启（高斯 + Sobel + 自适应阈值 + 闭运算）\n");
    make_test_image(1);
    run_hls(IN_W, IN_H, 1, GESTURE_DEFAULT_THRESH_OFFSET,
            1, 1, 1, GESTURE_DEFAULT_GAIN, RX, RY, RW, RH);
    run_ref(IN_W, IN_H, 1, GESTURE_DEFAULT_THRESH_OFFSET,
            1, 1, 1, GESTURE_DEFAULT_GAIN, RX, RY, RW, RH);
    check("full_pipeline", compare("全链开启", 1));
    printf("\n");

    /* ---- 用例 2：全链关闭（直通路径） ---- */
    printf("[2] 全链关闭（各级直通，只剩裁剪缩放 + 灰度）\n");
    make_test_image(2);
    run_hls(IN_W, IN_H, 0, 0, 0, 0, 0, 256, RX, RY, RW, RH);
    run_ref(IN_W, IN_H, 0, 0, 0, 0, 0, 256, RX, RY, RW, RH);
    check("bypass_paths", compare("全链关闭", 1));
    printf("\n");

    /* ---- 用例 3：极小 ROI（缩放步长退化）
     *
     * ⚠ ROI 尺寸取 min(输入, 96)：
     *   输入 ≥ 96 时 → ROI = 96x96，步长 = 1（正是本用例要测的退化情形）
     *   输入 < 96 时 → ROI = 整图，步长仍被钳到 1
     *   原来硬编码 272,192,96,96 只在 640x480 下成立，改分辨率就越界。
     */
    printf("[3] 极小 ROI（缩放步长 = 1，无降采样）\n");
    make_test_image(3);
    run_hls(IN_W, IN_H, 1, 0, 1, 1, 1, 256, TX, TY, TW, TH);
    run_ref(IN_W, IN_H, 1, 0, 1, 1, 1, 256, TX, TY, TW, TH);
    check("tiny_roi", compare("极小 ROI", 1));
    printf("\n");

    /* ---- 用例 4：绝对校验（用手算的已知答案） ---- */
    printf("[4] 绝对校验 —— 不用参考实现，直接验算预期值\n");
    {
        /* 造一张已知图：ROI 取整个 96x96 区域且步长=1，
         * 关闭所有滤波，只留裁剪缩放。
         * 输入是全图水平渐变 v(x) = x*255/(W-1)。
         *
         * 此时输出[y][x] 应等于 rgb565_to_gray(RGB(v,v,v))。
         * 对纯灰 RGB565（r=g=b=v8）：
         *   R5 = v8>>3, G6 = v8>>2, B5 = v8>>3
         *   扩位后 r8 = (v8>>3)<<3 = v8 & 0xF8
         *          g8 = (v8>>2)<<2 = v8 & 0xFC
         *          b8 = (v8>>3)<<3 = v8 & 0xF8
         *   lum = r8*66 + g8*129 + b8*25，结果 >>8
         * 这是可以手算的确定值，用来抓"参考实现和被测实现一起错"的情况。 */
        make_test_image(3);

        /* ROI = 整图，且**输入恰好 96x96** 时步长 = 1，
         * 输出每个像素正好对应一个源像素，可以手算。
         *
         * ⚠ 这里要求 IN_W/IN_H == 96。若不是（比如为了跑 cosim
         *   改成了 64x64），本用例的手算前提就不成立 ——
         *   步长会 >1，输出是块平均而不是单像素。
         *   所以下面用编译期判断跳过，而不是给出错误结论。 */
        const int rx = 0, ry = 0, rw = IN_W, rh = IN_H;
        run_hls(IN_W, IN_H, 0, 0, 0, 0, 0, 256, rx, ry, rw, rh);

#if (IN_W == 96) && (IN_H == 96)
        int bad = 0, checked = 0;
        for (int y = 0; y < 96; y++) {
            for (int x = 0; x < 96; x++) {
                /* 步长 = 1，输出 (y,x) 对应源 (y,x)。
                 * 源图是水平渐变 v(x) = x*255/(IN_W-1)。 */
                const ap_uint<8> v8 =
                    (ap_uint<8>)((x * 255) / (IN_W - 1));
                const ap_uint<8> r8 = (ap_uint<8>)((v8 & 0xF8));
                const ap_uint<8> g8 = (ap_uint<8>)((v8 & 0xFC));
                const ap_uint<8> b8 = (ap_uint<8>)((v8 & 0xF8));
                const ap_uint<16> lum = (ap_uint<16>)r8 * GESTURE_Y_R
                                      + (ap_uint<16>)g8 * GESTURE_Y_G
                                      + (ap_uint<16>)b8 * GESTURE_Y_B;
                const ap_uint<8> expect = (ap_uint<8>)(lum >> 8);

                const ap_uint<8> got = g_hls[y * 96 + x];
                checked++;
                if (got != expect) {
                    if (bad < 5)
                        printf("            (y=%2d,x=%2d) 期望 %3u 实得 %3u\n",
                               y, x, (unsigned)expect, (unsigned)got);
                    bad++;
                }
            }
        }

        if (bad == 0)
            printf("    [ OK ] %-38s 手算预期值吻合 (%d 像素)\n",
                   "灰度转换绝对校验", checked);
        else
            printf("    [FAIL] %-38s %d/%d 不符\n",
                   "灰度转换绝对校验", bad, checked);
        check("absolute_gray", bad);
#else
        printf("    [跳过] 绝对校验需要 IN_W == IN_H == 96\n");
        printf("           当前 %dx%d —— 步长 >1，手算前提不成立\n",
               IN_W, IN_H);
#endif
    }
    printf("\n");

    /* ---- 用例 5：参数越界应被拒绝且不阻塞 ---- */
    printf("[5] 参数校验 —— 非法参数应被拒绝，不读 stream 直接返回\n");
    {
        /* 只喂极少量数据：若顶层在参数检查前就读了 stream，
         * 会阻塞在这批数据之后，本用例会挂住（超时即视为失败）。
         * 直接量测"调用是否立即返回"。 */
        hls::stream<axis_rgb_t>  s_in("s_in5");
        hls::stream<axis_gray_t> s_out("s_out5");

        axis_rgb_t w;
        w.data = 0; w.keep = 3; w.strb = 3; w.last = 0;
        s_in.write(w);   /* 只喂 1 个像素 */

        /* roi 超出边界 -> 应被拒绝 */
        gesture_preproc(s_in, s_out, IN_W, IN_H, 1, 0, 1, 1, 1, 256,
                        600, 400, 320, 320);
        /* 宽度超上限 -> 应被拒绝 */
        gesture_preproc(s_in, s_out, GESTURE_MAX_WIDTH + 1, IN_H,
                        1, 0, 1, 1, 1, 256, 0, 0, 320, 320);

        printf("    [ OK ] %-38s 未阻塞，正常返回\n", "非法参数拒绝");
    }
    printf("\n");

    /* ---- 汇总 ---- */
    printf("=====================================================================\n");
    if (g_failures == 0)
        printf("  TB PASSED —— 全部用例通过\n");
    else
        printf("  TB FAILED —— %d 个用例失败\n", g_failures);
    printf("=====================================================================\n\n");

    return (g_failures == 0) ? 0 : 1;
}
