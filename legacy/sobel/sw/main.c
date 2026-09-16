/**
 * @file    main.c
 * @brief   Sobel 加速器裸机 demo
 *
 * 做三件事：
 *   1. 造一张测试图（竖直色带 + 方块）
 *   2. 跑一帧 DDR -> DMA -> Sobel -> DMA -> DDR
 *   3. 打印耗时、吞吐、结果校验和，并用 ASCII 把边缘图打出来
 *
 * 编译：
 *   目标(Zynq 裸机)：加入 Vitis standalone 工程，链接 BSP 即可
 *   主机仿真      ：gcc -DSOBEL_SIM_BUILD sobel_driver.c sim_dma.c main.c
 *
 * 上板时需要把下面两个基地址换成 Vitis 里 xparameters.h 的实际值：
 *   XPAR_SOBEL_ACCEL_0_BASEADDR
 *   XPAR_AXI_DMA_0_BASEADDR
 */

#include "sobel_driver.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* ------------------------------------------------------------------ *
 *  地址配置
 * ------------------------------------------------------------------ */
#ifdef SOBEL_SIM_BUILD
  /* 主机仿真：0xFFFFFFFF 是 sim_dma.c 里约定的"模拟 DMA"标识 */
  #define SOBEL_IP_BASE   0x00000000u
  #define SOBEL_DMA_BASE  0xFFFFFFFFu
  #define CPU_HZ          666666687u   /* 与 Zynq-7020 实机一致，便于比较耗时 */
#else
  /* 宏名取自 BSP 生成的 xparameters.h（已核对）：
   *   XPAR_SOBEL_ACCEL_0_BASEADDR          = 0x40000000
   *   XPAR_AXI_DMA_0_BASEADDR              = 0x41e00000
   *   XPAR_CPU_CORE_CLOCK_FREQ_HZ          = 666666687
   * 若换了 BD 或地址分配，这里要跟着改；
   * 直接去 bsp/include/xparameters.h 里搜这几个名字确认。 */
  #include "xparameters.h"
  #define SOBEL_IP_BASE   XPAR_SOBEL_ACCEL_0_BASEADDR
  #define SOBEL_DMA_BASE  XPAR_AXI_DMA_0_BASEADDR
  #define CPU_HZ          (XPAR_CPU_CORE_CLOCK_FREQ_HZ)
#endif

/* ------------------------------------------------------------------ *
 *  测试图与缓冲区
 *
 *  用 static 保证在 DDR 里（栈上开 200KB 会溢出），
 *  且 __attribute__((aligned(4))) 满足 DMA 对齐要求。
 * ------------------------------------------------------------------ */
#define IMG_W   64
#define IMG_H   48

static uint8_t g_src[IMG_W * IMG_H] __attribute__((aligned(4)));
static uint8_t g_dst[IMG_W * IMG_H] __attribute__((aligned(4)));

/** 造一张有明确边缘结构的图：色带 + 居中亮块 */
static void make_test_image(void)
{
    int band = IMG_W / 8;
    for (int y = 0; y < IMG_H; y++) {
        for (int x = 0; x < IMG_W; x++) {
            uint8_t v = (uint8_t)(((x / band) * 32) & 0xFF);
            g_src[y * IMG_W + x] = v;
        }
    }
    /* 居中亮块 —— 会形成一圈闭合强边缘 */
    for (int y = IMG_H / 4; y < IMG_H / 2; y++) {
        for (int x = IMG_W / 3; x < 2 * IMG_W / 3; x++) {
            g_src[y * IMG_W + x] = 255;
        }
    }
}

/** 简单的累加校验和，用来快速判断"跑没跑出东西" */
static uint32_t checksum(const uint8_t *p, size_t n)
{
    uint32_t s = 0;
    for (size_t i = 0; i < n; i++) s += p[i];
    return s;
}

static int count_edges(const uint8_t *p, size_t n)
{
    int c = 0;
    for (size_t i = 0; i < n; i++) if (p[i] > 0) c++;
    return c;
}

/** 把边缘图降采样成 ASCII，方便在串口/终端里肉眼确认 */
static void print_ascii(const uint8_t *img, int w, int h, int step)
{
    const char *ramp = " .:-=+*#%@";
    printf("    +");
    for (int x = 0; x < w / step; x++) printf("-");
    printf("+\n");
    for (int y = 0; y < h; y += step) {
        printf("    |");
        for (int x = 0; x < w; x += step) {
            int v = img[y * w + x];
            int idx = v * 9 / 255;
            if (idx > 9) idx = 9;
            printf("%c", ramp[idx]);
        }
        printf("|\n");
    }
    printf("    +");
    for (int x = 0; x < w / step; x++) printf("-");
    printf("+\n");
}

/* ------------------------------------------------------------------ *
 *  main
 * ------------------------------------------------------------------ */
int main(void)
{
    sobel_t dev;
    int rc;

    printf("\n");
    printf("=====================================================\n");
    printf("  Sobel 边缘检测加速器 —— 驱动 Demo\n");
    printf("  图像 %dx%d (%d 字节)\n", IMG_W, IMG_H, IMG_W * IMG_H);
#ifdef SOBEL_SIM_BUILD
    printf("  模式：主机仿真（非硬件）\n");
#else
    printf("  模式：Zynq 裸机\n");
#endif
    printf("=====================================================\n\n");

    /* ---- 1. 初始化 ---- */
    rc = sobel_init(&dev, SOBEL_IP_BASE, SOBEL_DMA_BASE);
    if (rc != SOBEL_OK) {
        printf("[FAIL] sobel_init 返回 %d\n", rc);
        return 1;
    }
    printf("[ OK ] 初始化完成\n");

    /* ---- 2. 配置 ---- */
    rc = sobel_set_size(&dev, IMG_W, IMG_H);
    if (rc != SOBEL_OK) {
        printf("[FAIL] 设置尺寸失败 (%d)\n", rc);
        return 1;
    }
    sobel_set_thresh(&dev, 0);          /* 不二值化，保留幅值 */
    sobel_set_gain(&dev, SOBEL_DEFAULT_GAIN);
    printf("[ OK ] 配置 %dx%d  thresh=%u  gain=%u\n",
           IMG_W, IMG_H, dev.thresh, dev.gain);

    /* ---- 3. 造图 ---- */
    make_test_image();
    memset(g_dst, 0, sizeof(g_dst));
    printf("[ OK ] 测试图已生成，输入校验和 = 0x%08X\n",
           checksum(g_src, sizeof(g_src)));

    /* ---- 4. 跑一帧 ---- */
    printf("\n>>> 开始处理...\n");
    rc = sobel_run(&dev, g_src, g_dst);
    if (rc != SOBEL_OK) {
        printf("[FAIL] sobel_run 返回 %d\n", rc);
        sobel_dump_status(&dev);
        return 1;
    }

    uint32_t cyc = sobel_last_cycles(&dev);
    double us = sobel_cycles_to_us(cyc, CPU_HZ);
    double px = (double)(IMG_W * IMG_H);
    double mpps = (us > 0.0) ? (px / us) : 0.0;   /* 像素/微秒 = Mpx/s */

    printf("[ OK ] 处理完成\n");
    printf("       耗时      : %u 周期  (%.2f us @ %u Hz)\n", cyc, us, CPU_HZ);
    printf("       吞吐      : %.2f Mpx/s\n", mpps);
    printf("       边缘像素  : %d / %d\n",
           count_edges(g_dst, sizeof(g_dst)), IMG_W * IMG_H);
    printf("       输出校验和: 0x%08X\n", checksum(g_dst, sizeof(g_dst)));

    /* ---- 5. 打印状态寄存器 ---- */
    printf("\n>>> IP 状态\n");
    sobel_dump_status(&dev);

    /* ---- 6. 出个 ASCII 图，肉眼确认边缘形状 ---- */
    printf("\n>>> 边缘图（降采样 %dx 显示）\n", 2);
    print_ascii(g_dst, IMG_W, IMG_H, 2);

    printf("\n>>> 累计运行 %u 帧\n", dev.run_count);

    /* ---- 7. 反例：故意传非法参数，确认驱动会拦住 ---- */
    printf("\n>>> 边界测试\n");
    {
        int r1 = sobel_set_size(&dev, SOBEL_MAX_WIDTH + 1, IMG_H);
        printf("       超大宽度       -> %s (期望 %d)\n",
               (r1 == SOBEL_ERR_PARAM) ? "已拦截" : "未拦截!", SOBEL_ERR_PARAM);

        r1 = sobel_run(&dev, NULL, g_dst);
        printf("       空指针输入     -> %s (期望 %d)\n",
               (r1 == SOBEL_ERR_PARAM) ? "已拦截" : "未拦截!", SOBEL_ERR_PARAM);

        /* 恢复合法尺寸，再做未对齐测试 */
        sobel_set_size(&dev, IMG_W, IMG_H);
        r1 = sobel_run(&dev, g_src + 1, g_dst);
        printf("       未对齐源地址   -> %s (期望 %d)\n",
               (r1 == SOBEL_ERR_PARAM) ? "已拦截" : "未拦截!", SOBEL_ERR_PARAM);
    }

    printf("\n=====================================================\n");
    printf("  Demo 结束\n");
    printf("=====================================================\n\n");
    return 0;
}
