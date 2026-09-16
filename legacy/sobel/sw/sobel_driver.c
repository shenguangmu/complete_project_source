/**
 * @file    sobel_driver.c
 * @brief   Sobel 加速器裸机驱动实现
 *
 * 两种编译模式：
 *
 *   1. 目标模式（默认）—— Zynq PS 裸机
 *      依赖 BSP 提供的 xaxidma / xil_cache / xil_io。
 *      编译: 直接在 Vitis 的 standalone 工程里加入本文件即可。
 *
 *   2. 主机仿真模式 —— 定义 SOBEL_SIM_BUILD
 *      用纯 C 模拟寄存器访问和 DMA 搬运，可在 PC 上跑通驱动逻辑，
 *      验证参数检查、地址运算、时序状态机，无需硬件。
 *      编译: gcc -DSOBEL_SIM_BUILD sobel_driver.c main.c
 *
 * 两种模式共用同一份逻辑，差别只在最底层的几个访问原语。
 */

#include "sobel_driver.h"
#include <string.h>
#include <stdio.h>

/* ================================================================== *
 *  底层访问原语
 * ================================================================== */
#ifdef SOBEL_SIM_BUILD

/* ---------------- 主机仿真：模拟寄存器 + 模拟 DMA ---------------- */

/** 模拟的寄存器文件大小（覆盖到最高的 GAIN 偏移） */
#define SIM_REG_SPACE   0x1000
/** 模拟的 DMA 寄存器空间 */
#define SIM_DMA_SPACE   0x1000

static uint32_t g_sim_regs[SIM_REG_SPACE / 4];
static uint32_t g_sim_dma [SIM_DMA_SPACE / 4];

/** 模拟 DMA 的行为：调用 sobel_run 时，把 src 拷到 dst 并施加 Sobel */
void sim_sobel_execute(const uint8_t *src, uint8_t *dst,
                       uint32_t w, uint32_t h,
                       uint32_t thresh, uint32_t gain);

static inline uint32_t sim_rd(uint32_t *space, uint32_t off)
{
    return space[off >> 2];
}
static inline void sim_wr(uint32_t *space, uint32_t off, uint32_t v)
{
    space[off >> 2] = v;
}

/* 模拟 AXI-Lite 读 */
static uint32_t reg_rd(uint32_t base, uint32_t off)
{
    if (base == 0xFFFFFFFFu) return sim_rd(g_sim_dma, off);
    return sim_rd(g_sim_regs, off);
}
/* 模拟 AXI-Lite 写 */
static void reg_wr(uint32_t base, uint32_t off, uint32_t v)
{
    if (base == 0xFFFFFFFFu) { sim_wr(g_sim_dma, off, v); return; }
    sim_wr(g_sim_regs, off, v);
}

/* 模拟 cache 维护：主机上无需操作，但保留调用点 */
#define CACHE_FLUSH(addr, len)       do { (void)(addr); (void)(len); } while (0)
#define CACHE_INVALIDATE(addr, len)  do { (void)(addr); (void)(len); } while (0)

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

#define CACHE_FLUSH(addr, len)       Xil_DCacheFlushRange((UINTPTR)(addr), (len))
#define CACHE_INVALIDATE(addr, len)  Xil_DCacheInvalidateRange((UINTPTR)(addr), (len))

#endif /* SOBEL_SIM_BUILD */

/* ================================================================== *
 *  内部状态
 * ================================================================== */
typedef struct {
#ifdef SOBEL_SIM_BUILD
    int dummy;                  /* 主机模式无需 DMA 实例 */
#else
    XAxiDma dma;
    int     dma_ready;
#endif
} sobel_priv_t;

static sobel_priv_t g_priv;

/* ================================================================== *
 *  DMA 操作
 * ================================================================== */

/**
 * @brief 启动一次 DDR <-> Sobel IP 的流式搬运
 *
 * 时序很关键：
 *   1. 先启动 S2MM（收），再启动 MM2S（发）
 *      反过来的话，Sobel 可能已经吐数据了而 S2MM 还没准备好，
 *      虽然 AXI-Stream 有反压不会丢数据，但先收后发能少一次停顿。
 *   2. 长度都是 width*height 字节（8-bit 灰度，1 字节/像素）
 */
static int dma_transfer(sobel_t *dev, const uint8_t *src, uint8_t *dst,
                        uint32_t bytes)
{
#ifdef SOBEL_SIM_BUILD
    /* 主机模式：直接调用软件模拟执行 */
    sim_sobel_execute(src, dst, dev->width, dev->height,
                      dev->thresh, dev->gain);
    (void)bytes;
    return SOBEL_OK;
#else
    sobel_priv_t *p = &g_priv;
    uint32_t timeout;

    if (!p->dma_ready) return SOBEL_ERR_DMA_INIT;

    /* ---- 1. 启动接收通道 (S2MM) ---- */
    if (XAxiDma_SimpleTransfer(&p->dma, (UINTPTR)dst, bytes,
                               XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS) {
        return SOBEL_ERR_DMA_RX;
    }

    /* ---- 2. 启动发送通道 (MM2S) ---- */
    if (XAxiDma_SimpleTransfer(&p->dma, (UINTPTR)src, bytes,
                               XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS) {
        return SOBEL_ERR_DMA_TX;
    }

    /* ---- 3. 等两个通道都空 ---- */
    timeout = 10000000u;
    while (XAxiDma_Busy(&p->dma, XAXIDMA_DMA_TO_DEVICE)) {
        if (--timeout == 0) return SOBEL_ERR_TIMEOUT;
    }
    timeout = 10000000u;
    while (XAxiDma_Busy(&p->dma, XAXIDMA_DEVICE_TO_DMA)) {
        if (--timeout == 0) return SOBEL_ERR_TIMEOUT;
    }

    /* ---- 4. 检查两个通道的 DMA 错误位 ----
     * 宏名取自 BSP 的 xaxidma_hw.h：XAXIDMA_ERR_ALL_MASK = 0x770，
     * 覆盖 internal / slave / decode 三类错误（SG 位也含在内，无害）。
     * TX 和 RX 都要查 —— 只查一个会漏掉另一条通路上的从机响应错误。 */
    {
        uint32_t sr_tx = XAxiDma_ReadReg(p->dma.RegBase + XAXIDMA_TX_OFFSET,
                                         XAXIDMA_SR_OFFSET);
        if (sr_tx & XAXIDMA_ERR_ALL_MASK) return SOBEL_ERR_DMA_TX;

        uint32_t sr_rx = XAxiDma_ReadReg(p->dma.RegBase + XAXIDMA_RX_OFFSET,
                                         XAXIDMA_SR_OFFSET);
        if (sr_rx & XAXIDMA_ERR_ALL_MASK) return SOBEL_ERR_DMA_RX;
    }
    return SOBEL_OK;
#endif
}

/* ================================================================== *
 *  API 实现
 * ================================================================== */

int sobel_init(sobel_t *dev, uint32_t ip_base, uint32_t dma_base)
{
    if (!dev) return SOBEL_ERR_PARAM;

    memset(dev, 0, sizeof(*dev));
    dev->ip_base  = ip_base;
    dev->dma_base = dma_base;
    dev->width    = 0;
    dev->height   = 0;
    dev->thresh   = SOBEL_DEFAULT_THRESH;
    dev->gain     = SOBEL_DEFAULT_GAIN;
    dev->priv     = &g_priv;

#ifdef SOBEL_SIM_BUILD
    memset(g_sim_regs, 0, sizeof(g_sim_regs));
    memset(g_sim_dma,  0, sizeof(g_sim_dma));
    /* 模拟上电后 ap_idle=1, ap_ready=1 */
    sim_wr(g_sim_regs, SOBEL_REG_CTRL,
           SOBEL_STATUS_AP_IDLE | SOBEL_STATUS_AP_READY);
    g_priv.dummy = 0;
#else
    {
        /* 用 LookupConfigBaseAddr 而不是 LookupConfig：
         * 前者收"基地址"，后者收"设备 ID"（u32 DeviceId）。
         * 本驱动的 sobel_init() 收的是基地址，所以必须用前者，
         * 否则会把 0x41e00000 当成设备 ID 去查表，必然查不到。 */
        XAxiDma_Config *cfg = XAxiDma_LookupConfigBaseAddr(dma_base);
        if (!cfg) return SOBEL_ERR_DMA_INIT;
        if (XAxiDma_CfgInitialize(&g_priv.dma, cfg) != XST_SUCCESS) {
            return SOBEL_ERR_DMA_INIT;
        }
        /* 关闭中断，本驱动用轮询 */
        XAxiDma_IntrDisable(&g_priv.dma, XAXIDMA_IRQ_ALL_MASK,
                            XAXIDMA_DMA_TO_DEVICE);
        XAxiDma_IntrDisable(&g_priv.dma, XAXIDMA_IRQ_ALL_MASK,
                            XAXIDMA_DEVICE_TO_DMA);
        /* 简单模式必须关闭 SG */
        if (XAxiDma_HasSg(&g_priv.dma)) {
            xil_printf("sobel: 警告 —— DMA 配成了 SG 模式，本驱动只支持简单模式\r\n");
        }
        g_priv.dma_ready = 1;
    }
#endif

    return SOBEL_OK;
}

int sobel_set_size(sobel_t *dev, uint32_t width, uint32_t height)
{
    if (!dev) return SOBEL_ERR_PARAM;
    if (width == 0 || height == 0) return SOBEL_ERR_PARAM;
    if (width > SOBEL_MAX_WIDTH || height > SOBEL_MAX_HEIGHT)
        return SOBEL_ERR_PARAM;

    dev->width  = width;
    dev->height = height;

    reg_wr(dev->ip_base, SOBEL_REG_WIDTH,  width);
    reg_wr(dev->ip_base, SOBEL_REG_HEIGHT, height);
    return SOBEL_OK;
}

void sobel_set_thresh(sobel_t *dev, uint32_t thresh)
{
    if (!dev) return;
    if (thresh > 255u) thresh = 255u;
    dev->thresh = thresh;
    reg_wr(dev->ip_base, SOBEL_REG_THRESH, thresh);
}

void sobel_set_gain(sobel_t *dev, uint32_t gain)
{
    if (!dev) return;
    if (gain > 4095u) gain = 4095u;      /* 12 位上限，避免幅值溢出 */
    dev->gain = gain;
    reg_wr(dev->ip_base, SOBEL_REG_GAIN, gain);
}

uint32_t sobel_read_version(const sobel_t *dev)
{
    if (!dev) return 0;
    /* Vitis HLS 的 s_axilite 接口通常把版本放在最低偏移的保留区，
     * 具体位置以生成的 _hw.h 为准。这里读 0x00 低位做示意。 */
    return 0;
}

/**
 * @brief 打印 IP 的 CTRL 寄存器（状态位就在这里）
 *
 * ⚠ 必须在 sobel_run() 把 CTRL 清零**之前**调用。
 *   run 结尾写 CTRL=0 复位 ap_start，会连只读的
 *   AP_DONE/AP_IDLE/AP_READY 一起读成 0 ——
 *   若在 run 之后调用，会看到全零，误以为 IP 没跑。
 */
void sobel_dump_status(const sobel_t *dev)
{
    if (!dev) return;
    uint32_t st = reg_rd(dev->ip_base, SOBEL_REG_CTRL);

#ifdef SOBEL_SIM_BUILD
    printf("[sobel] CTRL  =0x%08X  ready=%d done=%d idle=%d\n",
           st,
           (st & SOBEL_STATUS_AP_READY) ? 1 : 0,
           (st & SOBEL_STATUS_AP_DONE)  ? 1 : 0,
           (st & SOBEL_STATUS_AP_IDLE)  ? 1 : 0);
#else
    xil_printf("[sobel] CTRL  =0x%08X  ready=%d done=%d idle=%d\r\n",
               st,
               (st & SOBEL_STATUS_AP_READY) ? 1 : 0,
               (st & SOBEL_STATUS_AP_DONE)  ? 1 : 0,
               (st & SOBEL_STATUS_AP_IDLE)  ? 1 : 0);
#endif
}

int sobel_run(sobel_t *dev, const uint8_t *src, uint8_t *dst)
{
    uint32_t bytes;
    uint32_t timeout;
    int rc;

    /* ---- 参数检查 ---- */
    if (!dev || !src || !dst) return SOBEL_ERR_PARAM;
    if (dev->width == 0 || dev->height == 0) return SOBEL_ERR_PARAM;

    bytes = dev->width * dev->height;

    /* 地址必须 4 字节对齐：AXI DMA 在非对齐地址上会报 DMAUnAlign */
    if (((uintptr_t)src & (SOBEL_ALIGN_BYTES - 1)) != 0 ||
        ((uintptr_t)dst & (SOBEL_ALIGN_BYTES - 1)) != 0) {
        return SOBEL_ERR_PARAM;
    }

    /* ---- 1. 把输入图刷出 D-Cache ----
     * 不做这一步 DMA 会读到 DDR 里的旧数据（或读到一半的新数据），
     * 表现为"结果随机错误"，且随 cache 大小/地址变化而变 —— 极难查。 */
    CACHE_FLUSH((void *)src, bytes);
    /* 输出缓冲区也刷一下，避免有脏行在之后被回写、覆盖 DMA 的结果 */
    CACHE_FLUSH(dst, bytes);

    /* ---- 2. 启动 IP ----
     * 先写参数寄存器（已在 set_* 里完成），再置 ap_start */
    dev->last_cycles = 0;
#ifndef SOBEL_SIM_BUILD
    {
        XTime t0, t1;
        XTime_GetTime(&t0);

        reg_wr(dev->ip_base, SOBEL_REG_CTRL, SOBEL_CTRL_AP_START);

        /* ---- 3. DMA 搬运 ---- */
        rc = dma_transfer(dev, src, dst, bytes);

        /* ---- 4. 等 IP 完成 ---- */
        if (rc == SOBEL_OK) {
            timeout = 100000000u;
            while (!(reg_rd(dev->ip_base, SOBEL_REG_CTRL) &
                     SOBEL_STATUS_AP_DONE)) {
                if (--timeout == 0) { rc = SOBEL_ERR_TIMEOUT; break; }
            }
        }

        XTime_GetTime(&t1);
        dev->last_cycles = (uint32_t)(t1 - t0);
    }
#else
    {
        /* 主机模式：直接跑，计一个近似的"周期数"（按像素数估） */
        reg_wr(dev->ip_base, SOBEL_REG_CTRL, SOBEL_CTRL_AP_START);
        rc = dma_transfer(dev, src, dst, bytes);
        /* 模拟 IP 完成 */
        sim_wr(g_sim_regs, SOBEL_REG_CTRL,
               SOBEL_STATUS_AP_DONE | SOBEL_STATUS_AP_READY);
        /* 保守估计：每个像素 1 个周期 + 固定开销 */
        dev->last_cycles = bytes + 64u;
    }
#endif

    if (rc != SOBEL_OK) return rc;

    /* ---- 5. 把结果从 D-Cache 里作废 ----
     * DMA 绕过 cache 写了 DDR，cache 里若还有该地址范围的旧行，
     * CPU 读 dst 会拿到旧值。必须 invalidate。 */
    CACHE_INVALIDATE(dst, bytes);

    /* ---- 6. 清 ap_start，让 IP 回到 idle（下次可重新启动） ----
     * ⚠ 这一写会同时清零只读的 AP_DONE/AP_IDLE/AP_READY：
     *   同一个寄存器，写操作按位覆盖。所以想查看状态必须在
     *   这一步之前 dump（见 sobel_dump_status 的注释）。 */
    reg_wr(dev->ip_base, SOBEL_REG_CTRL, 0);

    dev->run_count++;
    return SOBEL_OK;
}

uint32_t sobel_last_cycles(const sobel_t *dev)
{
    return dev ? dev->last_cycles : 0;
}

double sobel_cycles_to_us(uint32_t cycles, uint32_t cpu_hz)
{
    if (cpu_hz == 0) return 0.0;
    return (double)cycles * 1e6 / (double)cpu_hz;
}
