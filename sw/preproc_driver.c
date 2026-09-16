/**
 * @file    preproc_driver.c
 * @brief   手势预处理链 PS 侧驱动实现
 *
 * 两种编译模式（与 sobel_driver.c 同一套约定）：
 *
 *   1. 目标模式（默认）—— Zynq PS 裸机
 *      依赖 BSP 的 xaxidma / xil_cache / xil_io
 *
 *   2. 主机仿真模式 —— 定义 PREPROC_SIM_BUILD
 *      用纯 C 模拟寄存器访问与 DMA 搬运，可在 PC 上验证
 *      执行顺序、参数检查、超时逻辑，无需硬件
 *      编译: gcc -DPREPROC_SIM_BUILD preproc_driver.c main_preproc.c
 *
 * ⚠ 两种模式共用同一份控制流 —— 差别只在最底层几个访问原语。
 *   这很重要：如果主机仿真自己另写一套逻辑，它验证的就是假的
 *   （sobel_driver 上踩过这个坑，见 fpga-dev skill 09-pitfalls D2）。
 */

#include "preproc_driver.h"
#include <string.h>
#include <stdio.h>

/* ================================================================== *
 *  底层访问原语
 * ================================================================== */
#ifdef PREPROC_SIM_BUILD

/* ---------------- 主机仿真 ---------------- */

#define SIM_REG_SPACE   0x1000
#define SIM_DMA_SPACE   0x1000

/** 三个地址空间：IP 寄存器、输入 DMA、输出 DMA */
static uint32_t g_sim_ip [SIM_REG_SPACE / 4];
static uint32_t g_sim_din[SIM_DMA_SPACE / 4];
static uint32_t g_sim_dout[SIM_DMA_SPACE / 4];

/* 模拟 DMA 的地址寄存器：记下 src/dst/len，供 sim 执行用 */
static const void *g_sim_src;
static void       *g_sim_dst;
static uint32_t    g_sim_len_in;
static uint32_t    g_sim_len_out;

/** 主机仿真时由主程序提供：真正做一次预处理（可用朴素 C 实现） */
extern void preproc_sim_execute(const void *src, void *dst);

/* 模拟 AXI-Lite 空间选择：用基地址的魔数区分 */
#define BASE_IS_DMA_IN(b)   ((b) == 0xFFFFFF01u)
#define BASE_IS_DMA_OUT(b)  ((b) == 0xFFFFFF02u)

static uint32_t reg_rd(uint32_t base, uint32_t off)
{
    if (BASE_IS_DMA_IN(base))  return g_sim_din [off >> 2];
    if (BASE_IS_DMA_OUT(base)) return g_sim_dout[off >> 2];
    return g_sim_ip[off >> 2];
}

static void reg_wr(uint32_t base, uint32_t off, uint32_t v)
{
    if (BASE_IS_DMA_IN(base))  { g_sim_din [off >> 2] = v; return; }
    if (BASE_IS_DMA_OUT(base)) { g_sim_dout[off >> 2] = v; return; }
    g_sim_ip[off >> 2] = v;
}

/* cache 维护点在主机上无操作，但保留调用位置 */
#define CACHE_FLUSH(a, l)      do { (void)(a); (void)(l); } while (0)
#define CACHE_INVALIDATE(a, l) do { (void)(a); (void)(l); } while (0)

/* ================================================================== *
 *  AXI DMA 的寄存器偏移（Xilinx axi_dma 的固定布局）
 *
 *  ⚠ 这几个偏移来自 PG021（AXI DMA 手册），不是我们自己的 IP。
 *    MM2S 与 S2MM 各有一套，偏移固定。
 * ================================================================== */
#define DMA_MM2S_CTRL      0x00u   /* bit0=RS(运行), bit2=Reset, bit12=IOC_IrqEn */
#define DMA_MM2S_STATUS    0x04u   /* bit1=Idle, bit0=Halted */
#define DMA_MM2S_SRCADDR   0x18u
#define DMA_MM2S_LENGTH    0x28u

#define DMA_S2MM_CTRL      0x30u
#define DMA_S2MM_STATUS    0x34u
#define DMA_S2MM_DSTADDR   0x48u
#define DMA_S2MM_LENGTH    0x58u

#define DMA_CTRL_RS        0x00000001u  /* Run/Stop */
#define DMA_CTRL_RESET     0x00000004u  /* Soft reset */
#define DMA_CTRL_IOC_IRQEN 0x00001000u  /* 完成中断使能 */
#define DMA_STATUS_HALTED  0x00000001u
#define DMA_STATUS_IDLE    0x00000002u

#else /* ---------------------- 真实 Zynq 目标 ---------------------- */

#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xaxidma.h"
#include "xtime_l.h"

static uint32_t reg_rd(uint32_t base, uint32_t off)
{
    return Xil_In32(base + off);
}
static void reg_wr(uint32_t base, uint32_t off, uint32_t v)
{
    Xil_Out32(base + off, v);
}

/* ⚠ DMA 绕过 cache 直接读写 DDR，必须手动维护一致性。
 *  这是 Zynq 上最容易踩的坑之一（原工程 README §5 有详细记录）。 */
#define CACHE_FLUSH(a, l)      Xil_DCacheFlushRange((UINTPTR)(a), (l))
#define CACHE_INVALIDATE(a, l) Xil_DCacheInvalidateRange((UINTPTR)(a), (l))

/* XTime 计时（CPU 周期） */
static XTime g_t0, g_t1;

#endif

/* ================================================================== *
 *  公共：参数检查
 * ================================================================== */

/**
 * @brief 检查地址与长度是否满足 DMA 要求
 *
 * ⚠ DMA 要求 4 字节对齐。不对齐不会报错，而是**搬运错位** ——
 *   表现为输出图像整体偏移，很难往回查到是地址对齐问题。
 */
static int check_dma_args(const void *src, void *dst)
{
    if (src == NULL || dst == NULL) return PREPROC_ERR_PARAM;
    if (((uintptr_t)src & 3u) != 0) return PREPROC_ERR_PARAM;
    if (((uintptr_t)dst & 3u) != 0) return PREPROC_ERR_PARAM;
    return PREPROC_OK;
}

/** ROI 是否落在图像内 */
static int check_roi(const preproc_t *dev)
{
    if (dev->roi_w <= 0 || dev->roi_h <= 0) return 0;
    if (dev->roi_x < 0 || dev->roi_y < 0) return 0;
    if (dev->roi_x + dev->roi_w > dev->width) return 0;
    if (dev->roi_y + dev->roi_h > dev->height) return 0;
    return 1;
}

/* ================================================================== *
 *  API 实现
 * ================================================================== */

int preproc_init(preproc_t *dev,
                 uint32_t ip_base,
                 uint32_t dma_in_base,
                 uint32_t dma_out_base)
{
    if (dev == NULL) return PREPROC_ERR_PARAM;

    memset(dev, 0, sizeof(*dev));
    dev->ip_base      = ip_base;
    dev->dma_in_base  = dma_in_base;
    dev->dma_out_base = dma_out_base;

    /* 默认参数 */
    dev->width  = PREPROC_IN_WIDTH;
    dev->height = PREPROC_IN_HEIGHT;
    dev->thresh_mode   = PREPROC_DEFAULT_THRESH_MODE;
    dev->thresh_offset = PREPROC_DEFAULT_THRESH_OFFSET;
    dev->gauss_en = 1;
    dev->sobel_en = 1;
    dev->morph_en = 1;
    dev->gain     = PREPROC_DEFAULT_GAIN;

    /* ROI 居中 */
    dev->roi_w = PREPROC_DEFAULT_ROI_W;
    dev->roi_h = PREPROC_DEFAULT_ROI_H;
    dev->roi_x = (dev->width  - dev->roi_w) / 2;
    dev->roi_y = (dev->height - dev->roi_h) / 2;

#ifdef PREPROC_SIM_BUILD
    memset(g_sim_ip,   0, sizeof(g_sim_ip));
    memset(g_sim_din,  0, sizeof(g_sim_din));
    memset(g_sim_dout, 0, sizeof(g_sim_dout));
    g_sim_src = NULL; g_sim_dst = NULL;
    g_sim_len_in = 0; g_sim_len_out = 0;
#endif

    return PREPROC_OK;
}

int preproc_config(preproc_t *dev,
                   int thresh_mode, int thresh_offset,
                   int gauss_en, int sobel_en, int morph_en,
                   int gain,
                   int roi_x, int roi_y, int roi_w, int roi_h)
{
    if (dev == NULL) return PREPROC_ERR_PARAM;

    /* ⚠ 阈值偏置是有符号的，范围 -128..127 */
    if (thresh_offset < -128 || thresh_offset > 127) return PREPROC_ERR_PARAM;
    if (gain < 1 || gain > 65536) return PREPROC_ERR_PARAM;
    if (thresh_mode < 0 || thresh_mode > 1) return PREPROC_ERR_PARAM;
    if (gauss_en < 0 || gauss_en > 1) return PREPROC_ERR_PARAM;
    if (sobel_en < 0 || sobel_en > 1) return PREPROC_ERR_PARAM;
    if (morph_en < 0 || morph_en > 1) return PREPROC_ERR_PARAM;

    dev->thresh_mode   = thresh_mode;
    dev->thresh_offset = thresh_offset;
    dev->gauss_en = gauss_en;
    dev->sobel_en = sobel_en;
    dev->morph_en = morph_en;
    dev->gain     = gain;
    dev->roi_x = roi_x; dev->roi_y = roi_y;
    dev->roi_w = roi_w; dev->roi_h = roi_h;

    if (!check_roi(dev)) return PREPROC_ERR_PARAM;

    return PREPROC_OK;
}

int preproc_config_default(preproc_t *dev)
{
    if (dev == NULL) return PREPROC_ERR_PARAM;
    return preproc_config(dev,
                          PREPROC_DEFAULT_THRESH_MODE,
                          PREPROC_DEFAULT_THRESH_OFFSET,
                          1, 1, 1,
                          PREPROC_DEFAULT_GAIN,
                          (dev->width  - PREPROC_DEFAULT_ROI_W) / 2,
                          (dev->height - PREPROC_DEFAULT_ROI_H) / 2,
                          PREPROC_DEFAULT_ROI_W,
                          PREPROC_DEFAULT_ROI_H);
}

int preproc_run(preproc_t *dev, const void *src, void *dst)
{
    uint32_t timeout;
    int rc;

    if (dev == NULL) return PREPROC_ERR_PARAM;

    rc = check_dma_args(src, dst);
    if (rc != PREPROC_OK) return rc;
    if (!check_roi(dev)) return PREPROC_ERR_PARAM;

#ifdef PREPROC_SIM_BUILD
    /* --- 主机仿真：不需要真实硬件，直接跑朴素实现 --- */
    (void)timeout;
    preproc_sim_execute(src, dst);
    dev->last_cycles = PREPROC_IN_BYTES / 8u + 200u;  /* 粗略估计 */
    dev->run_count++;
    return PREPROC_OK;
#else
    /* ==============================================================
     *  真实 Zynq 流程
     *
     *  ⚠⚠ 顺序不能反：先武装 S2MM，再启动 MM2S，最后 ap_start。
     *     详见 preproc_driver.h 里 preproc_run 的说明。
     * ============================================================== */

    /* ---- 1. 复位两个 DMA 通道 ---- */
    reg_wr(dev->dma_in_base,  DMA_MM2S_CTRL, DMA_CTRL_RESET);
    reg_wr(dev->dma_out_base, DMA_S2MM_CTRL, DMA_CTRL_RESET);
    /* 等复位完成（Halted 位被清） */
    timeout = 1000000u;
    while ((reg_rd(dev->dma_in_base, DMA_MM2S_STATUS) & DMA_STATUS_HALTED) == 0) {
        if (--timeout == 0) return PREPROC_ERR_DMA;
    }
    timeout = 1000000u;
    while ((reg_rd(dev->dma_out_base, DMA_S2MM_STATUS) & DMA_STATUS_HALTED) == 0) {
        if (--timeout == 0) return PREPROC_ERR_DMA;
    }

    /* ---- 2. 清 cache：让 IP/DMA 看到最新的输入数据 ---- */
    CACHE_FLUSH(src, PREPROC_IN_BYTES);

    /* ---- 3. 【先】武装 dma_out（S2MM）---- */
    reg_wr(dev->dma_out_base, DMA_S2MM_DSTADDR, (uint32_t)(uintptr_t)dst);
    reg_wr(dev->dma_out_base, DMA_S2MM_CTRL, DMA_CTRL_RS | DMA_CTRL_IOC_IRQEN);
    reg_wr(dev->dma_out_base, DMA_S2MM_LENGTH, PREPROC_OUT_BYTES);

    /* ---- 4. 【再】启动 dma_in（MM2S）---- */
    reg_wr(dev->dma_in_base, DMA_MM2S_SRCADDR, (uint32_t)(uintptr_t)src);
    reg_wr(dev->dma_in_base, DMA_MM2S_CTRL, DMA_CTRL_RS | DMA_CTRL_IOC_IRQEN);
    reg_wr(dev->dma_in_base, DMA_MM2S_LENGTH, PREPROC_IN_BYTES);

    /* ---- 5. 配置 IP 参数 ---- */
    reg_wr(dev->ip_base, PREPROC_REG_WIDTH,  (uint32_t)dev->width);
    reg_wr(dev->ip_base, PREPROC_REG_HEIGHT, (uint32_t)dev->height);
    reg_wr(dev->ip_base, PREPROC_REG_THRESH_MODE,   (uint32_t)dev->thresh_mode);
    /* ⚠ 阈值偏置有符号：转成补码再写，否则 -8 会被当成 248 */
    reg_wr(dev->ip_base, PREPROC_REG_THRESH_OFFSET,
           (uint32_t)(int32_t)dev->thresh_offset);
    reg_wr(dev->ip_base, PREPROC_REG_GAUSS_EN, (uint32_t)dev->gauss_en);
    reg_wr(dev->ip_base, PREPROC_REG_SOBEL_EN, (uint32_t)dev->sobel_en);
    reg_wr(dev->ip_base, PREPROC_REG_MORPH_EN, (uint32_t)dev->morph_en);
    reg_wr(dev->ip_base, PREPROC_REG_GAIN,     (uint32_t)dev->gain);
    reg_wr(dev->ip_base, PREPROC_REG_ROI_X,    (uint32_t)dev->roi_x);
    reg_wr(dev->ip_base, PREPROC_REG_ROI_Y,    (uint32_t)dev->roi_y);
    reg_wr(dev->ip_base, PREPROC_REG_ROI_W,    (uint32_t)dev->roi_w);
    reg_wr(dev->ip_base, PREPROC_REG_ROI_H,    (uint32_t)dev->roi_h);

    /* ---- 6. 【最后】ap_start ---- */
    XTime_GetTime(&g_t0);
    /* ⚠ 保留 bit7(auto_restart)，只置 bit0 —— 与官方驱动的 Start() 一致。
     *   直接写 1 会把 auto_restart 清掉（我们本来也不要它，但保持写法
     *   一致便于对照官方驱动）。 */
    {
        uint32_t c = reg_rd(dev->ip_base, PREPROC_REG_CTRL);
        reg_wr(dev->ip_base, PREPROC_REG_CTRL,
               (c & PREPROC_CTRL_AUTO_RESTART) | PREPROC_CTRL_AP_START);
    }

    /* ---- 7. 轮询 ap_done ---- */
    /*  ⚠ 状态位在 CTRL(0x00)，不是 0x04！见头文件说明。 */
    timeout = 100000000u;
    while ((reg_rd(dev->ip_base, PREPROC_REG_CTRL) & PREPROC_CTRL_AP_DONE) == 0) {
        if (--timeout == 0) {
            return PREPROC_ERR_TIMEOUT;
        }
    }
    XTime_GetTime(&g_t1);

    /* ---- 8. invalidate 输出：DMA 绕过了 cache，CPU 直接读会拿到旧值 ---- */
    CACHE_INVALIDATE(dst, PREPROC_OUT_BYTES);

    /* ---- 9. 清 ap_start 让 IP 回 idle ---- */
    reg_wr(dev->ip_base, PREPROC_REG_CTRL, 0);

    dev->last_cycles = (uint32_t)(g_t1 - g_t0);
    dev->run_count++;
    return PREPROC_OK;
#endif
}

void preproc_dump_status(const preproc_t *dev)
{
    if (dev == NULL) return;
    {
        uint32_t st = reg_rd(dev->ip_base, PREPROC_REG_CTRL);
#ifdef PREPROC_SIM_BUILD
        printf("[preproc] CTRL=0x%08X  ready=%d done=%d idle=%d\n",
               st,
               (st & PREPROC_CTRL_AP_READY) ? 1 : 0,
               (st & PREPROC_CTRL_AP_DONE)  ? 1 : 0,
               (st & PREPROC_CTRL_AP_IDLE)  ? 1 : 0);
#else
        xil_printf("[preproc] CTRL=0x%08X  ready=%d done=%d idle=%d\r\n",
                   st,
                   (st & PREPROC_CTRL_AP_READY) ? 1 : 0,
                   (st & PREPROC_CTRL_AP_DONE)  ? 1 : 0,
                   (st & PREPROC_CTRL_AP_IDLE)  ? 1 : 0);
#endif
    }
}

uint32_t preproc_last_cycles(const preproc_t *dev)
{
    return dev ? dev->last_cycles : 0;
}

double preproc_cycles_to_us(uint32_t cycles, uint32_t cpu_hz)
{
    if (cpu_hz == 0) return 0.0;
    return (double)cycles * 1e6 / (double)cpu_hz;
}
