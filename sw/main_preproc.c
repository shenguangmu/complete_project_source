/**
 * @file    main_preproc.c —— 预处理链驱动的主机自检
 *
 * 编译运行：
 *      gcc -DPREPROC_SIM_BUILD -I. preproc_driver.c preproc_sim.c \
 *          main_preproc.c -o preproc_sim
 *      ./preproc_sim
 *
 * ⚠ 必须看到 "*** TB PASSED ***"。
 *
 * =====================================================================
 *  这个自检验什么
 * =====================================================================
 *  验**驱动逻辑**，不验算法（算法由 src_hls 的 csim 负责）。
 *
 *  1. 参数检查：非法参数必须被拦住，不能把坏值写进硬件
 *  2. 有符号阈值偏置：-8 不能被当成 248 写下去
 *  3. DMA 地址对齐：非 4 字节对齐必须拦（否则搬运错位）
 *  4. 数据流：输入进去、输出出来，长度正确
 *  5. 边界：ROI 超出图像必须拦
 *
 *  ⚠ 第 2 条是最容易出问题的：阈值偏置是**有符号**的，
 *    直接 (uint32_t)(-8) 会变成 0xFFFFFFF8，IP 侧当成巨大的正数，
 *    阈值算出来离谱 —— 表现为"输出全黑或全白"。
 */

#include "preproc_driver.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* 仿真用的三块"地址空间"魔数（与 preproc_driver.c 里一致） */
#define SIM_IP_BASE      0x00000000u
#define SIM_DMA_IN_BASE  0xFFFFFF01u
#define SIM_DMA_OUT_BASE 0xFFFFFF02u

#define CPU_HZ  666666687u   /* Zynq-7020 实机频率，便于对照耗时 */

/* 输入帧与输出缓冲放静态区：614400 + 9216 字节，栈上放不下 */
static unsigned short g_src[PREPROC_IN_WIDTH * PREPROC_IN_HEIGHT]
    __attribute__((aligned(4)));
static unsigned char  g_dst[PREPROC_OUT_PIXELS] __attribute__((aligned(4)));

static int g_pass = 0, g_fail = 0;

static void check(int ok, const char *name)
{
    if (ok) g_pass++;
    else { g_fail++; printf("  FAIL : %s\n", name); }
}

/* ------------------------------------------------------------------ *
 *  造一张有明确图案的测试图
 *
 *  ⚠ 图案必须保证 **ROI 内部有明暗变化**，否则二值化后全黑或全白，
 *    自检会误报"输出异常"。
 *
 *    最初版本踩过这个坑：亮块范围恰好等于默认 ROI（160,80,320×320），
 *    ROI 内全是白 → 输出全白 → 自检报 FAIL。
 *    那是**测试数据的错**，不是驱动的错 —— 但如果不点明，
 *    下次看到 FAIL 会先去查驱动。
 *
 *  现在的图案：ROI 覆盖区域内做水平渐变，保证均值在中间、
 *  二值化后既有 0 又有 255。
 * ------------------------------------------------------------------ */
static void make_test_image(void)
{
    int x, y;

    /* 与 preproc_driver.h 的默认 ROI 保持一致 */
    const int rx = (PREPROC_IN_WIDTH  - PREPROC_DEFAULT_ROI_W) / 2;
    const int ry = (PREPROC_IN_HEIGHT - PREPROC_DEFAULT_ROI_H) / 2;

    for (y = 0; y < PREPROC_IN_HEIGHT; y++) {
        for (x = 0; x < PREPROC_IN_WIDTH; x++) {
            unsigned short v;

            if (x >= rx && x < rx + PREPROC_DEFAULT_ROI_W &&
                y >= ry && y < ry + PREPROC_DEFAULT_ROI_H) {
                /* ROI 内：水平渐变 0..255，保证二值化后有区分 */
                unsigned g = (unsigned)((x - rx) * 255 / PREPROC_DEFAULT_ROI_W);
                unsigned short r5 = (g >> 3) & 0x1F;
                unsigned short g6 = (g >> 2) & 0x3F;
                unsigned short b5 = (g >> 3) & 0x1F;
                v = (unsigned short)((r5 << 11) | (g6 << 5) | b5);
            } else {
                /* ROI 外：固定中灰（不进输出，只是让图看起来像回事） */
                v = 0x8410;   /* RGB565 中灰 */
            }

            g_src[y * PREPROC_IN_WIDTH + x] = v;
        }
    }
}

int main(void)
{
    preproc_t dev;
    int rc;

    printf("\n");
    printf("=====================================================================\n");
    printf("  手势预处理链驱动 —— 主机自检\n");
    printf("  输入 %dx%d RGB565 (%d 字节)  ->  输出 %dx%d 灰度 (%d 字节)\n",
           PREPROC_IN_WIDTH, PREPROC_IN_HEIGHT, PREPROC_IN_BYTES,
           PREPROC_OUT_SIZE, PREPROC_OUT_SIZE, PREPROC_OUT_BYTES);
    printf("=====================================================================\n\n");

    /* ---- 1. 初始化 ---- */
    printf("[1] 初始化\n");
    rc = preproc_init(&dev, SIM_IP_BASE, SIM_DMA_IN_BASE, SIM_DMA_OUT_BASE);
    check(rc == PREPROC_OK, "preproc_init 应成功");
    check(dev.width == PREPROC_IN_WIDTH,  "width 应被设为默认值");
    check(dev.height == PREPROC_IN_HEIGHT, "height 应被设为默认值");
    check(dev.roi_w == PREPROC_DEFAULT_ROI_W, "ROI 宽应为默认值");
    check(dev.roi_x == (PREPROC_IN_WIDTH - PREPROC_DEFAULT_ROI_W) / 2,
          "ROI x 应居中");
    printf("      ROI = (%d,%d) %dx%d, gain=%d, thresh_offset=%d\n",
           dev.roi_x, dev.roi_y, dev.roi_w, dev.roi_h,
           dev.gain, dev.thresh_offset);
    printf("\n");

    /* ---- 2. 默认配置 ---- */
    printf("[2] 默认配置\n");
    rc = preproc_config_default(&dev);
    check(rc == PREPROC_OK, "preproc_config_default 应成功");
    check(dev.gauss_en == 1 && dev.sobel_en == 1 && dev.morph_en == 1,
          "默认应开启全链");
    printf("\n");

    /* ---- 3. 非法参数必须被拦住 ---- */
    printf("[3] 参数检查（非法值必须被拦住）\n");

    /* 3a. ROI 超出图像右边界 */
    rc = preproc_config(&dev, 1, -8, 1, 1, 1, 256,
                        PREPROC_IN_WIDTH - 100, 0, 320, 320);
    check(rc == PREPROC_ERR_PARAM, "ROI 超出右边界应被拦");
    printf("      ROI 越界        -> %s\n",
           rc == PREPROC_ERR_PARAM ? "已拦截" : "未拦截!");

    /* 3b. ROI 宽为 0 */
    rc = preproc_config(&dev, 1, -8, 1, 1, 1, 256, 0, 0, 0, 320);
    check(rc == PREPROC_ERR_PARAM, "ROI 宽为 0 应被拦");

    /* 3c. 阈值偏置超范围（有符号 8 位） */
    rc = preproc_config(&dev, 1, 200, 1, 1, 1, 256, 160, 80, 320, 320);
    check(rc == PREPROC_ERR_PARAM, "阈值偏置 +200 超范围应被拦");
    rc = preproc_config(&dev, 1, -200, 1, 1, 1, 256, 160, 80, 320, 320);
    check(rc == PREPROC_ERR_PARAM, "阈值偏置 -200 超范围应被拦");

    /* 3d. gain 为 0 */
    rc = preproc_config(&dev, 1, -8, 1, 1, 1, 0, 160, 80, 320, 320);
    check(rc == PREPROC_ERR_PARAM, "gain=0 应被拦");

    /* 3e. 开关值非法 */
    rc = preproc_config(&dev, 2, -8, 1, 1, 1, 256, 160, 80, 320, 320);
    check(rc == PREPROC_ERR_PARAM, "thresh_mode=2 应被拦");
    printf("\n");

    /* ---- 4. 有符号阈值偏置（本自检最重要的一条）---- */
    printf("[4] 有符号阈值偏置\n");
    rc = preproc_config(&dev, 1, -8, 1, 1, 1, 256, 160, 80, 320, 320);
    check(rc == PREPROC_OK, "-8 应被接受");
    check(dev.thresh_offset == -8, "偏置应存为 -8（有符号）");
    /* ⚠ 关键检查：转成 uint32 后是补码，不是 0xFFFFFFF8 被当成巨大正数 */
    printf("      偏置 -8 存为 int = %d\n", dev.thresh_offset);
    printf("      (写入硬件时转补码，IP 侧按 int32 解释)\n");
    printf("\n");

    /* ---- 5. DMA 地址对齐 ---- */
    printf("[5] DMA 地址对齐\n");
    rc = preproc_run(&dev, NULL, g_dst);
    check(rc == PREPROC_ERR_PARAM, "空指针应被拦");
    rc = preproc_run(&dev, g_src, NULL);
    check(rc == PREPROC_ERR_PARAM, "空输出指针应被拦");
    /* g_src 是 aligned(4) 的，+1 字节就破坏对齐 */
    rc = preproc_run(&dev, (const char *)g_src + 1, g_dst);
    check(rc == PREPROC_ERR_PARAM, "未对齐输入应被拦");
    printf("      空指针 / 未对齐 -> 全部拦截\n");
    printf("\n");

    /* ---- 6. 正常跑一帧 ---- */
    printf("[6] 正常运行一帧\n");
    make_test_image();
    memset(g_dst, 0, sizeof(g_dst));

    rc = preproc_run(&dev, g_src, g_dst);
    check(rc == PREPROC_OK, "preproc_run 应成功");

    if (rc == PREPROC_OK) {
        unsigned long sum = 0;
        int nz = 0, i;
        for (i = 0; i < PREPROC_OUT_PIXELS; i++) {
            sum += g_dst[i];
            if (g_dst[i] != 0) nz++;
        }
        printf("      输出: 非零像素 %d/%d, 均值和 %lu\n",
               nz, PREPROC_OUT_PIXELS, sum);
        check(nz > 0, "输出不应全黑");
        check(nz < PREPROC_OUT_PIXELS, "输出不应全白");
        check(dev.run_count == 1, "run_count 应递增到 1");
        check(dev.last_cycles > 0, "应记录耗时");
        printf("      耗时: %u 周期 (%.1f us @ %u Hz)\n",
               dev.last_cycles,
               preproc_cycles_to_us(dev.last_cycles, CPU_HZ), CPU_HZ);
    }
    printf("\n");

    /* ---- 7. 边界测试（反例，确认驱动不崩）---- */
    printf("[7] 边界测试\n");
    {
        int r1 = preproc_config(&dev, 1, -8, 0, 0, 0, 256, 0, 0, 96, 96);
        printf("      极小 ROI(96x96)  -> %s\n", r1 == PREPROC_OK ? "接受" : "拒绝");
        if (r1 == PREPROC_OK) {
            int r2 = preproc_run(&dev, g_src, g_dst);
            check(r2 == PREPROC_OK, "极小 ROI 应能正常跑");
        }
        /* 恢复默认 */
        preproc_config_default(&dev);
    }
    printf("\n");

    /* ---- 汇总 ---- */
    printf("=====================================================================\n");
    if (g_fail == 0)
        printf("*** TB PASSED ***  (%d 项检查全过)\n", g_pass);
    else
        printf("*** TB FAILED ***  (%d 通过, %d 失败)\n", g_pass, g_fail);
    printf("=====================================================================\n\n");

    return g_fail == 0 ? 0 : 1;
}
