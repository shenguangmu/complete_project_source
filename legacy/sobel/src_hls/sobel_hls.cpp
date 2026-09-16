/**
 * @file    sobel_hls.cpp
 * @brief   Sobel 边缘检测 —— 行缓存 / 3x3 窗口生成 / 梯度计算 / AXI 接口
 *
 * 数据通路：
 *
 *   s_axis_video ─► 3 行 BRAM 行缓存 ─► 3x3 窗口 ─► Sobel ─► 阈值/饱和 ─► m_axis_video
 *                                            ▲
 *                                  s_axi_control (width/height/thresh/gain)
 *
 * ────────────────────────────────────────────────────────────────────
 *  为什么输出有 (1 行 + 2 列) 的延迟
 * ────────────────────────────────────────────────────────────────────
 *  流式 Sobel 在读到 (y, x) 时，手上只有第 y 行到第 x 列的数据，
 *  既拿不到"下一行"也拿不到"右边一列"。所以本设计的输出必然是滞后的：
 *
 *    在读取 (y, x) 的那个周期，计算的是 (y-1, x-2) 处的边缘强度。
 *
 *  延迟是常数，不影响结果正确性，只是输出流整体后移。
 *
 * ────────────────────────────────────────────────────────────────────
 *  行缓存结构
 * ────────────────────────────────────────────────────────────────────
 *  3 个 BRAM 行缓存按 (y % 3) 轮转角色：
 *
 *    第 y 行处理时：  lb[y%3]        ← 写入第 y 行
 *                    lb[(y+2)%3]    → 读出第 y-1 行
 *                    lb[(y+1)%3]    → 读出第 y-2 行
 *
 *  每行缓存读/写地址都是 x，所以"列"天然对齐。
 *  每个行缓存后面挂一条 3 级移位寄存器，把顺序读出的单列
 *  攒成 [x, x-1, x-2] 三列，正好凑齐窗口的一行。
 *
 *  图像四周补零：靠"把循环多跑一圈、越界位置输入 0"实现，
 *  流水线内没有数据相关的分支。
 */

#include "sobel_hls.h"

/* ================================================================== *
 *  3x3 窗口
 * ================================================================== */
struct window3x3 {
    ap_uint<8> p00, p01, p02;   /* 上一行   左/中/右 */
    ap_uint<8> p10, p11, p12;   /* 当前行   左/中/右 */
    ap_uint<8> p20, p21, p22;   /* 下一行   左/中/右 */
};

/* ================================================================== *
 *  Sobel 梯度
 * ================================================================== */

/**
 * @brief 由 3x3 窗口计算 Sobel 幅值
 *
 *   Gx = (p00 + 2*p10 + p20) - (p02 + 2*p12 + p22)   水平梯度（响应竖直边缘）
 *   Gy = (p00 + 2*p01 + p02) - (p20 + 2*p21 + p22)   垂直梯度（响应水平边缘）
 *   mag = (|Gx| + |Gy|) * gain >> 8                  Q8 增益
 *   超过 thresh 则置满量程，最后饱和到 0..255
 *
 * 用 |Gx|+|Gy|（L1 范数）而非 sqrt(Gx^2+Gy^2)（L2）：
 *   免开方、纯整数、可与 Python golden 模型逐位对齐；
 *   幅值比真实梯度模约大 8%，做边缘检测足够。
 */
static ap_uint<8> sobel_calc(const struct window3x3 &w, int gain, int thresh)
{

#pragma HLS INLINE

    /* 累加用 11 位：单项最大 4*255 = 1020，差值范围 ±1020 */
    ap_int<11> gx = (ap_int<11>)w.p00 + (ap_int<11>)w.p10 * 2 + (ap_int<11>)w.p20
                  - (ap_int<11>)w.p02 - (ap_int<11>)w.p12 * 2 - (ap_int<11>)w.p22;

    ap_int<11> gy = (ap_int<11>)w.p00 + (ap_int<11>)w.p01 * 2 + (ap_int<11>)w.p02
                  - (ap_int<11>)w.p20 - (ap_int<11>)w.p21 * 2 - (ap_int<11>)w.p22;

    /* 取绝对值。写成显式的 if 而不是 (gx<0)?-gx:gx —— 后者在 ap_int 下
     * 因为 -gx 会进位到 12 位而与 gx 的 11 位不匹配，触发编译歧义。 */
    ap_int<11> ax = gx;
    ap_int<11> ay = gy;
    if (gx < 0) ax = (ap_int<11>)(-gx);
    if (gy < 0) ay = (ap_int<11>)(-gy);

    /* 幅值 = |Gx| + |Gy|，恒 <= 2040，用 12 位承接不会溢出 */
    ap_uint<12> abs_sum = (ap_uint<12>)ax + (ap_uint<12>)ay;

    /* 增益 Q8：gain = 256 表示 x1.0。2040 * 256 = 522240，20 位够用 */
    ap_int<21> mag     = (ap_int<21>)abs_sum * (ap_int<21>)gain;
    ap_int<21> shifted = mag >> 8;

    /* 阈值：超过则置满量程（直接得到二值化边缘图） */
    if (shifted > (ap_int<21>)thresh)
        shifted = (ap_int<21>)SOBEL_MAG_MAX;

    /* 饱和 */
    if (shifted < 0)
        shifted = 0;
    if (shifted > (ap_int<21>)SOBEL_MAG_MAX)
        shifted = (ap_int<21>)SOBEL_MAG_MAX;

    return (ap_uint<8>)shifted;
}

/* ================================================================== *
 *  C 仿真专用的软件参考实现
 *
 *  这段代码不参与综合（用 #ifndef __SYNTHESIS__ 屏蔽），
 *  唯一用途是让 testbench 在没有 Python 环境时也能自比对。
 *  它必须与 sobel_calc() 的数值行为完全一致。
 * ================================================================== */
#ifndef __SYNTHESIS__
void sobel_ref_sw(const ap_uint<8> *src, ap_uint<8> *dst,
                  int width, int height, int thresh, int gain)
{
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            struct window3x3 w;
            /* 越界补零 */
            const int ys[3] = { y - 1, y, y + 1 };
            const int xs[3] = { x - 1, x, x + 1 };
            ap_uint<8> p[3][3];
            for (int i = 0; i < 3; i++) {
                for (int j = 0; j < 3; j++) {
                    int yy = ys[i], xx = xs[j];
                    if (yy < 0 || yy >= height || xx < 0 || xx >= width)
                        p[i][j] = 0;
                    else
                        p[i][j] = src[yy * width + xx];
                }
            }
            w.p00 = p[0][0]; w.p01 = p[0][1]; w.p02 = p[0][2];
            w.p10 = p[1][0]; w.p11 = p[1][1]; w.p12 = p[1][2];
            w.p20 = p[2][0]; w.p21 = p[2][1]; w.p22 = p[2][2];

            dst[y * width + x] = sobel_calc(w, gain, thresh);
        }
    }
}
#endif

/* ================================================================== *
 *  顶层函数
 * ================================================================== */

void sobel_accel(hls::stream<axis_word_t> &src,
                 hls::stream<axis_word_t> &dst,
                 int width,
                 int height,
                 int thresh,
                 int gain)
{
    /* ---- 接口映射 ----
     * 注意：Vitis HLS 2025.2 的 axis 指令**不接受 bundle 参数**
     * （写 bundle=xxx 会被判为 unexpected pragma parameter，
     *   整条指令被忽略，端口退化成 ap_none 单根线）。
     * 所以这里只用 mode=axis，bundle 名由工具按端口名自动生成。
     *
     * 用 hls::stream 做端口类型，HLS 会自动补出
     * TVALID / TREADY / TDATA / TLAST / TKEEP / TSTRB ——
     * TLAST 是 AXI DMA 的 S2MM 界定传输结束所必需的。 */

#pragma HLS INTERFACE mode=axis     port=src

#pragma HLS INTERFACE mode=axis     port=dst

#pragma HLS INTERFACE mode=s_axilite port=width  bundle=control

#pragma HLS INTERFACE mode=s_axilite port=height bundle=control

#pragma HLS INTERFACE mode=s_axilite port=thresh bundle=control

#pragma HLS INTERFACE mode=s_axilite port=gain   bundle=control

#pragma HLS INTERFACE mode=s_axilite port=return bundle=control

    /* ---- 行缓存：3 行 x (MAX_WIDTH+2) x 8bit，映射到 BRAM ---- *
     * 多出的 2 列用于右侧补零时的安全写入（x 最大到 width+1）。   */
    static ap_uint<8> lb[3][SOBEL_MAX_WIDTH + 2];

#pragma HLS BIND_STORAGE    variable=lb type=RAM_2P impl=BRAM

#pragma HLS ARRAY_PARTITION variable=lb dim=1 complete

    /* ---- 每行缓存后的 3 级列移位寄存器 ---- */
    ap_uint<8> sr_cur[3];   /* 当前行   cols [x, x-1, x-2] */
    ap_uint<8> sr_p1[3];    /* 上一行   cols [x, x-1, x-2] */
    ap_uint<8> sr_p2[3];    /* 上上行   cols [x, x-1, x-2] */

#pragma HLS ARRAY_PARTITION variable=sr_cur complete

#pragma HLS ARRAY_PARTITION variable=sr_p1  complete

#pragma HLS ARRAY_PARTITION variable=sr_p2  complete

    /* ---- 参数合法性：超出行缓存容量的图直接拒绝，避免越界 ---- */
    if (width  > SOBEL_MAX_WIDTH  || width  <= 0 ||
        height > SOBEL_MAX_HEIGHT || height <= 0) {
        return;
    }

    /* ---- 清空列移位寄存器 ---- */
    for (int i = 0; i < 3; i++) {

#pragma HLS UNROLL
        sr_cur[i] = 0;
        sr_p1[i]  = 0;
        sr_p2[i]  = 0;
    }

    /* ---- 清空行缓存 ----
     * 必须清：否则上一帧残留的数据会被读成"上一行/上上行"，
     * 污染本帧最上面两行。代价约 3*(W+2) 个周期，相对整帧可忽略。 */
    for (int i = 0; i < 3; i++) {
        for (int c = 0; c < width + 2; c++) {

#pragma HLS PIPELINE II=1
            lb[i][c] = 0;
        }
    }

    /* ---- 主循环 ----
     *
     * 行 y 从 0 跑到 height（含），共 height+1 次；
     * 列 x 从 0 跑到 width+1（含），共 width+2 次。
     *
     * 多跑的这一圈就是"补零边界"：越界位置输入 0，
     * 于是四周自动获得一圈零，无需任何数据相关分支。
     *
     * 迭代 (y, x) 读入的是概念坐标 (行 y, 列 x-1)：
     *   x = 0        → 列 -1（左补零）
     *   x = 1..width → 列 0..width-1（真实像素）
     *   x = width+1  → 列 width（右补零）
     *
     * 输出：迭代 (y, x) 产出概念坐标 (行 y-1, 列 x-2) 的结果，
     *      故 y >= 1 且 x >= 2 时写回。
     */
    for (int y = 0; y <= height; y++) {

        /* 按 y%3 轮转三个行缓存的角色（循环不变量，每行算一次） */
        const int wi  = y % 3;              /* 写：第 y 行     */
        const int r1i = (y + 2) % 3;        /* 读：第 y-1 行   */
        const int r2i = (y + 1) % 3;        /* 读：第 y-2 行   */

        for (int x = 0; x <= width + 1; x++) {

#pragma HLS PIPELINE II=1

            /* ---- 1. 取输入像素，越界补零 ----
             * 真实像素从 stream 读；补零位置不读，直接给 0。
             * stream 为空时 read() 会阻塞 —— 这正是 axis 的反压行为。 */
            ap_uint<8> p;
            if (y < height && x >= 1 && x <= width) {
                axis_word_t w_in = src.read();
                p = w_in.data;
            } else {
                p = 0;
            }

            /* ---- 2. 读两个历史行 + 写当前行 ----
             * wi / r1i / r2i 互不相同，同周期读写不冲突。 */
            ap_uint<8> v1 = lb[r1i][x];     /* 第 y-1 行，列 x-1 */
            ap_uint<8> v2 = lb[r2i][x];     /* 第 y-2 行，列 x-1 */
            lb[wi][x] = p;                  /* 第 y   行，列 x-1 */

            /* ---- 3. 推入列移位寄存器 ---- */
            sr_cur[2] = sr_cur[1]; sr_cur[1] = sr_cur[0]; sr_cur[0] = p;
            sr_p1 [2] = sr_p1 [1]; sr_p1 [1] = sr_p1 [0]; sr_p1 [0] = v1;
            sr_p2 [2] = sr_p2 [1]; sr_p2 [1] = sr_p2 [0]; sr_p2 [0] = v2;

            /* ---- 4. 组装 3x3 窗口 ----
             * 移位后 sr_*[0]=列 x-1, [1]=列 x-2, [2]=列 x-3。
             * 窗口以 (行 y-1, 列 x-2) 为中心：
             *   左 = x-3, 中 = x-2, 右 = x-1  —— 正好对应 [2],[1],[0] */
            struct window3x3 win;

#pragma HLS ARRAY_PARTITION variable=win complete
            win.p00 = sr_p2 [2]; win.p01 = sr_p2 [1]; win.p02 = sr_p2 [0];
            win.p10 = sr_p1 [2]; win.p11 = sr_p1 [1]; win.p12 = sr_p1 [0];
            win.p20 = sr_cur[2]; win.p21 = sr_cur[1]; win.p22 = sr_cur[0];

            /* ---- 5. Sobel ---- */
            ap_uint<8> edge = sobel_calc(win, gain, thresh);

            /* ---- 6. 写回 ----
             * 有效输出共 width*height 个像素，写满即止。
             *
             * TLAST 必须显式置位：AXI DMA 的 S2MM 靠它判定
             * "一次传输到此结束"。最后一个像素是 (y=height, x=width+1)，
             * 恰好是整个循环的最后一拍。 */
            if (y >= 1 && x >= 2) {
                axis_word_t w_out;
                w_out.data = edge;
                w_out.keep = 1;      /* 1 字节有效（8-bit 数据） */
                w_out.strb = 1;
                w_out.last = ((y == height) && (x == width + 1)) ? 1 : 0;
                dst.write(w_out);
            }
        }
    }
}
