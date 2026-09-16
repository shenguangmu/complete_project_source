/**
 * @file    gesture_ref.cpp
 * @brief   手势预处理链 —— 软件 golden 参考实现
 *
 * ────────────────────────────────────────────────────────────────────
 *  存在意义
 * ────────────────────────────────────────────────────────────────────
 *  testbench 必须能在**没有 Python、没有 opencv、没有板子**的机器上
 *  独立完成自比对 —— 这是整个项目能往前推的前提。
 *
 *  另有一份等价的 Python 版本在 host/gesture_golden.py，
 *  三方对拍（HLS / C++ golden / Python golden）可以互相定位错误：
 *  单个参考实现出错时，自比对会"一起错"，看起来是通过的。
 *
 * ────────────────────────────────────────────────────────────────────
 *  与 HLS 侧的对齐契约
 * ────────────────────────────────────────────────────────────────────
 *  HLS 的 3x3 阶段是流式的，内部迭代坐标带一个 (−1, −2) 的常数偏移
 *  （3 级列移位寄存器造成）。但它在**输出数组索引**上恰好抵消：
 *
 *      读出第 (x-1) 个值  ⇔  图像列 x-1，窗口覆盖图像列 x-2..x
 *      而它在输出数组里写的正是下标 (Y, X)
 *
 *  于是净效果就是最朴素的标准 3x3 卷积：
 *
 *      **输出 (Y, X) 的窗口 = 图像 (Y-1..Y+1, X-1..X+1)，越界补零**
 *
 *  ⚠ 这条曾经推导错过一次：我把 (−1, −2) 当成了输出坐标的偏移，
 *    于是在流里预先补零边框，导致整幅图错位一行两列。
 *    正确的做法是下游各级自己 zero-feed，流里不做任何预填充。
 *    如果你要改这里，先把上面这段重新推一遍。
 *
 *  ⚠ 直通路径：某一级 enable=0 时，HLS 输出的是"窗口中心即图像
 *    (Y, X) 处的值" —— 也就是**原值直通**，不是带延迟的拷贝。
 *    （早期版本写成带 (1,2) 延迟的拷贝，是同一个推导错误的产物。）
 *
 *  ⚠ 本文件整体被 #ifndef __SYNTHESIS__ 包住，不参与综合。
 */

#include "gesture_preproc.h"
#include "gesture_ref.h"
#include <string.h>

#ifndef __SYNTHESIS__

namespace ref {

const int OW   = GESTURE_OUT_SIZE;
const int OW_H = GESTURE_OUT_SIZE;
const int OPIX = GESTURE_OUT_PIXELS;

/* ================================================================== *
 *  工具
 * ================================================================== */

/** 取 (r, c) 处的像素，越界返回 0（零边框语义）。 */
static inline ap_uint<8> at(const ap_uint<8> *img, int r, int c)
{
    if (r < 0 || r >= OW_H || c < 0 || c >= OW) return (ap_uint<8>)0;
    return img[r * OW + c];
}

/* ================================================================== *
 *  阶段 1：crop_scale
 * ================================================================== */

/** RGB565 → 灰度。先扩位再加权，顺序不能换，否则定标对不上。 */
static ap_uint<8> rgb565_to_gray(ap_uint<16> rgb)
{
    ap_uint<8> r8 = (ap_uint<8>)(ap_uint<5>)rgb.range(15, 11) << 3;
    ap_uint<8> g8 = (ap_uint<8>)(ap_uint<6>)rgb.range(10,  5) << 2;
    ap_uint<8> b8 = (ap_uint<8>)(ap_uint<5>)rgb.range( 4,  0) << 3;

    ap_uint<16> lum = (ap_uint<16>)r8 * GESTURE_Y_R
                    + (ap_uint<16>)g8 * GESTURE_Y_G
                    + (ap_uint<16>)b8 * GESTURE_Y_B;
    return (ap_uint<8>)(lum >> 8);
}

void crop_scale(const ap_uint<16> *src, ap_uint<8> *dst,
                int width, int height,
                int roi_x, int roi_y, int roi_w, int roi_h)
{
    /* 与 HLS 侧一致：步长向上取整，且最小为 1 */
    int step_x = (roi_w + OW - 1) / OW;
    int step_y = (roi_h + OW_H - 1) / OW_H;
    if (step_x < 1) step_x = 1;
    if (step_y < 1) step_y = 1;

    int n_out = 0;
    ap_uint<24> acc = 0;
    int cx = 0, cy = 0;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            const ap_uint<8> gray = rgb565_to_gray(src[y * width + x]);

            const bool in_roi = (x >= roi_x) && (x < roi_x + roi_w) &&
                                (y >= roi_y) && (y < roi_y + roi_h);
            if (!in_roi) continue;

            acc = acc + (ap_uint<24>)gray;
            cx++;
            if (cx == step_x) {
                cx = 0;
                cy++;
                if (cy == step_y) {
                    cy = 0;
                    const ap_uint<24> n = (ap_uint<24>)step_x * (ap_uint<24>)step_y;
                    if (n_out < OPIX) dst[n_out++] = (ap_uint<8>)(acc / n);
                    acc = 0;
                }
            }
        }
    }

    while (n_out < OPIX) dst[n_out++] = 0;
}

/* ================================================================== *
 *  阶段 2：高斯
 *
 *  核 = [1 2 1; 2 4 2; 1 2 1] / 16，除 16 用右移 4 位。
 * ================================================================== */

void gaussian(const ap_uint<8> *src, ap_uint<8> *dst, int enable)
{
    if (!enable) {
        memcpy(dst, src, OPIX * sizeof(ap_uint<8>));   /* 原值直通 */
        return;
    }

    for (int y = 0; y < OW_H; y++) {
        for (int x = 0; x < OW; x++) {
            const ap_uint<8> p00 = at(src, y - 1, x - 1);
            const ap_uint<8> p01 = at(src, y - 1, x    );
            const ap_uint<8> p02 = at(src, y - 1, x + 1);
            const ap_uint<8> p10 = at(src, y    , x - 1);
            const ap_uint<8> p11 = at(src, y    , x    );
            const ap_uint<8> p12 = at(src, y    , x + 1);
            const ap_uint<8> p20 = at(src, y + 1, x - 1);
            const ap_uint<8> p21 = at(src, y + 1, x    );
            const ap_uint<8> p22 = at(src, y + 1, x + 1);

            /* 加权和最大 16*255 = 4080，13 位够 */
            ap_uint<13> g = (ap_uint<13>)p00 + ((ap_uint<13>)p01 << 1) + (ap_uint<13>)p02
                          + ((ap_uint<13>)p10 << 1) + ((ap_uint<13>)p11 << 2) + ((ap_uint<13>)p12 << 1)
                          + (ap_uint<13>)p20 + ((ap_uint<13>)p21 << 1) + (ap_uint<13>)p22;

            dst[y * OW + x] = (ap_uint<8>)(g >> 4);
        }
    }
}

/* ================================================================== *
 *  阶段 3：Sobel
 * ================================================================== */

/** Gx = 左列加权 − 右列加权；Gy = 上行加权 − 下行加权 */
static ap_uint<8> sobel_mag(ap_uint<8> p00, ap_uint<8> p01, ap_uint<8> p02,
                            ap_uint<8> p10, ap_uint<8> p11, ap_uint<8> p12,
                            ap_uint<8> p20, ap_uint<8> p21, ap_uint<8> p22,
                            int gain)
{
    ap_int<11> gx = (ap_int<11>)p00 + (ap_int<11>)p10 * 2 + (ap_int<11>)p20
                  - (ap_int<11>)p02 - (ap_int<11>)p12 * 2 - (ap_int<11>)p22;
    ap_int<11> gy = (ap_int<11>)p00 + (ap_int<11>)p01 * 2 + (ap_int<11>)p02
                  - (ap_int<11>)p20 - (ap_int<11>)p21 * 2 - (ap_int<11>)p22;

    /* 必须写成显式 if —— 三元表达式下 -gx 会进位到 12 位，
     * 与 gx 的 11 位不匹配而触发编译歧义（原工程踩过） */
    ap_int<11> ax = gx, ay = gy;
    if (gx < 0) ax = (ap_int<11>)(-gx);
    if (gy < 0) ay = (ap_int<11>)(-gy);

    ap_uint<12> abs_sum = (ap_uint<12>)ax + (ap_uint<12>)ay;
    ap_int<21>  shifted = ((ap_int<21>)abs_sum * (ap_int<21>)gain) >> 8;

    if (shifted < 0)   shifted = 0;
    if (shifted > 255) shifted = 255;
    return (ap_uint<8>)shifted;
}

void sobel(const ap_uint<8> *src, ap_uint<8> *dst, int gain, int enable)
{
    if (!enable) {
        memcpy(dst, src, OPIX * sizeof(ap_uint<8>));   /* 原值直通 */
        return;
    }

    for (int y = 0; y < OW_H; y++) {
        for (int x = 0; x < OW; x++) {
            dst[y * OW + x] = sobel_mag(
                at(src, y - 1, x - 1), at(src, y - 1, x), at(src, y - 1, x + 1),
                at(src, y    , x - 1), at(src, y    , x), at(src, y    , x + 1),
                at(src, y + 1, x - 1), at(src, y + 1, x), at(src, y + 1, x + 1),
                gain);
        }
    }
}

/* ================================================================== *
 *  阶段 4：自适应阈值
 *
 *  逐像素点运算，不涉及邻域；enable=0 时就是原值。
 * ================================================================== */

void adaptive_thresh(const ap_uint<8> *src, ap_uint<8> *dst,
                     int offset, int enable)
{
    if (!enable) {
        memcpy(dst, src, OPIX * sizeof(ap_uint<8>));
        return;
    }

    ap_uint<32> sum = 0;
    for (int i = 0; i < OPIX; i++) sum = sum + (ap_uint<32>)src[i];

    const int mean = (int)(sum / (ap_uint<32>)OPIX);
    int th = mean + offset;
    if (th < 0)   th = 0;
    if (th > 255) th = 255;

    for (int i = 0; i < OPIX; i++)
        dst[i] = ((int)src[i] > th) ? (ap_uint<8>)255 : (ap_uint<8>)0;
}

/* ================================================================== *
 *  阶段 5：形态学闭运算 = 先膨胀后腐蚀
 * ================================================================== */

void morph_close(const ap_uint<8> *src, ap_uint<8> *dst, int enable)
{
    if (!enable) {
        memcpy(dst, src, OPIX * sizeof(ap_uint<8>));   /* 原值直通 */
        return;
    }

    static ap_uint<8> dil[GESTURE_OUT_PIXELS];
    static ap_uint<8> ero[GESTURE_OUT_PIXELS];

    /* 第一遍：膨胀（3x3 取最大，越界补零） */
    for (int y = 0; y < OW_H; y++)
        for (int x = 0; x < OW; x++) {
            ap_uint<8> mx = 0;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++) {
                    const ap_uint<8> p = at(src, y + dy, x + dx);
                    if (p > mx) mx = p;
                }
            dil[y * OW + x] = mx;
        }

    /* 第二遍：腐蚀（3x3 取最小，越界补零）。
     * 越界补的 0 会被取成最小值 —— 这是腐蚀在边界的标准行为，
     * 也与 HLS 侧环缓冲清空后读到的零一致。 */
    for (int y = 0; y < OW_H; y++)
        for (int x = 0; x < OW; x++) {
            ap_uint<8> mn = 255;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++) {
                    const ap_uint<8> p = at(dil, y + dy, x + dx);
                    if (p < mn) mn = p;
                }
            ero[y * OW + x] = mn;
        }

    memcpy(dst, ero, OPIX * sizeof(ap_uint<8>));
}

/* ================================================================== *
 *  全链参考实现
 * ================================================================== */

void gesture_ref(const ap_uint<16> *src, ap_uint<8> *dst,
                 int width, int height,
                 int thresh_mode, int thresh_offset,
                 int gauss_en, int sobel_en, int morph_en,
                 int gain, int roi_x, int roi_y, int roi_w, int roi_h)
{
    /* 中间缓冲用 static，避免在栈上开 4 × 9216 字节 ——
     * 裸机栈空间有限，栈溢出会让 TB 神秘崩溃。 */
    static ap_uint<8> b0[GESTURE_OUT_PIXELS];
    static ap_uint<8> b1[GESTURE_OUT_PIXELS];
    static ap_uint<8> b2[GESTURE_OUT_PIXELS];
    static ap_uint<8> b3[GESTURE_OUT_PIXELS];

    crop_scale(src, b0, width, height, roi_x, roi_y, roi_w, roi_h);

    gaussian(b0, b1, gauss_en);

    sobel(b1, b2, gain, sobel_en);

    adaptive_thresh(b2, b3, thresh_offset, thresh_mode);

    morph_close(b3, dst, morph_en);
}

} /* namespace ref */

#endif /* !__SYNTHESIS__ */
