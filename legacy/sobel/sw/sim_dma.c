/**
 * @file    sim_dma.c
 * @brief   主机仿真用的"模拟 DMA + 模拟 Sobel"
 *
 * 仅当定义 SOBEL_SIM_BUILD 时参与编译。
 *
 * 作用：在 PC 上跑 sw/main.c 时，sobel_driver.c 里的 dma_transfer()
 * 会调用 sim_sobel_execute()。本文件实现它 —— 用一段纯 C 的
 * Sobel 计算冒充硬件，从而验证：
 *   - 驱动层的参数检查、地址运算、对齐断言
 *   - 数据在"源缓冲 -> 目标缓冲"之间的搬运动作确实存在
 *   - 上层 API 的调用顺序
 *
 * 注意：这里算出来的值**不是**被验证的对象 —— 算法正确性由
 * src_hls/tb_sobel.cpp 和 sim/compare.py 负责。本文件只是让
 * 驱动流程能端到端跑起来。
 */

#include <stdint.h>
#include <string.h>

/* 与 sobel_driver.c 里的声明保持一致 */
void sim_sobel_execute(const uint8_t *src, uint8_t *dst,
                       uint32_t w, uint32_t h,
                       uint32_t thresh, uint32_t gain);

static inline int px(const uint8_t *img, int w, int h, int y, int x)
{
    if (y < 0 || y >= h || x < 0 || x >= w) return 0;   /* 边界补零 */
    return img[y * w + x];
}

void sim_sobel_execute(const uint8_t *src, uint8_t *dst,
                       uint32_t w, uint32_t h,
                       uint32_t thresh, uint32_t gain)
{
    const int W = (int)w;
    const int H = (int)h;

    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            int p00 = px(src, W, H, y - 1, x - 1);
            int p01 = px(src, W, H, y - 1, x    );
            int p02 = px(src, W, H, y - 1, x + 1);
            int p10 = px(src, W, H, y    , x - 1);
            int p11 = px(src, W, H, y    , x    );
            int p12 = px(src, W, H, y    , x + 1);
            int p20 = px(src, W, H, y + 1, x - 1);
            int p21 = px(src, W, H, y + 1, x    );
            int p22 = px(src, W, H, y + 1, x + 1);

            int gx = (p00 + 2 * p10 + p20) - (p02 + 2 * p12 + p22);
            int gy = (p00 + 2 * p01 + p02) - (p20 + 2 * p21 + p22);

            int ax = (gx < 0) ? -gx : gx;
            int ay = (gy < 0) ? -gy : gy;

            long mag = (long)(ax + ay) * (long)gain;
            mag >>= 8;

            if (mag > (long)thresh) mag = 255;
            if (mag < 0)   mag = 0;
            if (mag > 255) mag = 255;

            dst[y * W + x] = (uint8_t)mag;
        }
    }
}
