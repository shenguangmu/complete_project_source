/**
 * @file    preproc_sim.c —— 主机仿真用的朴素预处理实现
 *
 * 用途：给 preproc_driver.c 的 PREPROC_SIM_BUILD 模式提供"硬件行为"。
 *
 * ⚠⚠ 这个文件**只用于主机仿真**，不参与综合、不上板。
 *
 *  它做的事与 src_hls/gesture_preproc.cpp **等价但写法朴素** ——
 *  目的是让驱动侧能验证"数据通路通不通"，而不是替代 HLS 实现。
 *
 *  真正的算法正确性由 src_hls 的 csim 保证（5 组用例逐位比对）。
 *  这里只需要"输入一个样子的图，输出了一个有点像的结果"就够了。
 *
 *  ⚠ 注意它**不追求逐位与 HLS 一致** —— 那是 csim 的事。
 *    如果这里也做一套"精确对齐"的实现，就会有两份需要同步维护的
 *    黄金模型，反而制造不一致的风险。
 */

#include "preproc_driver.h"
#include <string.h>
#include <stdio.h>

/* ================================================================== *
 *  极简 RGB565 → 灰度
 * ================================================================== */
static unsigned char rgb565_to_gray(unsigned short rgb)
{
    unsigned r = (rgb >> 11) & 0x1F;
    unsigned g = (rgb >> 5) & 0x3F;
    unsigned b = rgb & 0x1F;

    r = (r << 3) & 0xFF;
    g = (g << 2) & 0xFF;
    b = (b << 3) & 0xFF;

    /* BT.601 权重 ×256 */
    unsigned lum = (r * 66 + g * 129 + b * 25) >> 8;
    return (unsigned char)(lum > 255 ? 255 : lum);
}

/* ================================================================== *
 *  朴素全链：裁剪缩放 → 灰度 → 阈值二值化
 *
 *  刻意**不做**高斯/Sobel/形态学 —— 那几步是 HLS 的职责，
 *  主机仿真只需要验证驱动能不能把数据搬进去、搬出来。
 * ================================================================== */
void preproc_sim_execute(const void *src, void *dst)
{
    const unsigned short *in = (const unsigned short *)src;
    unsigned char *out = (unsigned char *)dst;

    const int W = PREPROC_IN_WIDTH;
    const int H = PREPROC_IN_HEIGHT;
    const int O = PREPROC_OUT_SIZE;

    /* 默认 ROI 居中 320x320 */
    const int rx = (W - 320) / 2;
    const int ry = (H - 320) / 2;
    const int step = 320 / O;   /* = 3，320/96 向上取整也是 4，这里取整 3 够用 */

    long sum = 0;
    int cnt = 0;
    int x, y;

    /* --- 第一遍：裁剪 + 缩放 --- */
    for (y = 0; y < O; y++) {
        for (x = 0; x < O; x++) {
            int sy = ry + y * (320 / O);
            int sx = rx + x * (320 / O);
            unsigned char v;

            if (sy >= H || sx >= W) { out[y * O + x] = 0; continue; }
            v = rgb565_to_gray(in[sy * W + sx]);
            out[y * O + x] = v;
            sum += v; cnt++;
        }
    }
    (void)step;

    /* --- 第二遍：均值阈值二值化 --- */
    {
        int mean = cnt ? (int)(sum / cnt) : 0;
        int th = mean - 8;   /* 默认偏置 -8 */
        if (th < 0) th = 0;
        for (y = 0; y < O * O; y++)
            out[y] = (out[y] > (unsigned char)th) ? 255 : 0;
    }
}
