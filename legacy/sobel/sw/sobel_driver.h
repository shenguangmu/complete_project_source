/**
 * @file    sobel_driver.h
 * @brief   Sobel 加速器裸机驱动 —— 接口与寄存器定义
 *
 * 运行环境：Zynq-7000 PS 裸机（standalone BSP）
 *
 * 硬件拓扑：
 *
 *     PS (ARM)                       PL
 *   ┌──────────┐   M_AXI_GP0   ┌──────────────┐
 *   │          ├──────────────►│ sobel s_axi  │  ← 寄存器配置
 *   │  Cortex  │               │   _control   │
 *   │   -A9    │               └──────────────┘
 *   │          │   S_AXI_HP0   ┌──────────────┐
 *   │          ├──────────────►│  AXI DMA     │
 *   │   DDR    │◄──────────────┤  MM2S/S2MM   │
 *   └──────────┘               └──────┬───────┘
 *                                     │ AXI4-Stream
 *                              ┌──────▼───────┐
 *                              │  Sobel IP    │
 *                              └──────────────┘
 *
 * ─────────────────────────────────────────────────────────────────────
 *  重要：Cache 一致性
 * ─────────────────────────────────────────────────────────────────────
 *  Zynq 的 AXI DMA 走 S_AXI_HP 口直接访问 DDR，**不经过 CPU 的 L1/L2 缓存**。
 *  所以：
 *
 *    发送前：写进内存的输入图必须 Xil_DCacheFlushRange()，否则 DMA 读到旧数据
 *    接收后：DMA 写入的结果必须 Xil_DCacheInvalidateRange()，否则 CPU 读到
 *            cache 里的旧值（而且是静默的错误结果，最难查）
 *
 *  本驱动已封装这两步，调用者只需保证缓冲区地址 4 字节对齐。
 *  若图省事，也可以在 BSP 里把这两段 DDR 配成 non-cacheable，
 *  但性能会明显下降，不推荐。
 */

#ifndef SOBEL_DRIVER_H
#define SOBEL_DRIVER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================== *
 *  寄存器偏移（与 src_hls/sobel_hls.h 保持一致）
 *
 *  ⚠⚠ 状态位在 CTRL(0x00)，**没有独立的 STATUS 寄存器**。
 *      0x04 是 GIER（全局中断使能），不是状态。
 *
 *      早期版本把 0x04 命名成 SOBEL_REG_STATUS，于是轮询 AP_DONE
 *      永远等不到。之所以一直没暴露：主机仿真自己在 0x04 位置写了
 *      假的状态值，仿真"完美通过"；板卡未到，真机尚未发作。
 *      已记为 fpga-dev skill 的 09-pitfalls.md · D2。
 *
 *  真实布局（取自生成的 xsobel_accel_hw.h，非推测）：
 *      0x00  AP_CTRL  ← 控制 + 状态位都在这里
 *      0x04  GIE      全局中断使能
 *      0x08  IER      通道中断使能
 *      0x0C  ISR      通道中断状态
 *      0x10  参数 0（按 8 字节对齐）
 *
 *  AP_CTRL 的位域：
 *      bit0 = AP_START (RW)
 *      bit1 = AP_DONE  (RO)
 *      bit2 = AP_IDLE  (RO)
 *      bit3 = AP_READY (RO)
 *      bit7 = AUTO_RESTART (RW)
 *
 *  上板前务必用 Vitis 生成的 xparameters.h 复核基地址：
 *      XPAR_SOBEL_ACCEL_0_BASEADDR
 * ================================================================== */
#define SOBEL_REG_CTRL      0x00u   /* 控制 + 状态位都在这个寄存器 */
#define SOBEL_REG_GIE       0x04u   /* 全局中断使能（不是状态！）    */
#define SOBEL_REG_IER       0x08u   /* 通道中断使能                  */
#define SOBEL_REG_ISR       0x0cu   /* 通道中断状态                  */
#define SOBEL_REG_WIDTH     0x10u
#define SOBEL_REG_HEIGHT    0x18u
#define SOBEL_REG_THRESH    0x20u
#define SOBEL_REG_GAIN      0x28u

/* CTRL(0x00) 的位域 */
#define SOBEL_CTRL_AP_START      0x01u   /* bit0 RW */
#define SOBEL_CTRL_AP_DONE       0x02u   /* bit1 RO */
#define SOBEL_CTRL_AP_IDLE       0x04u   /* bit2 RO */
#define SOBEL_CTRL_AP_READY      0x08u   /* bit3 RO */
#define SOBEL_CTRL_AUTO_RESTART  0x80u   /* bit7 RW */

/* 状态位别名 —— ⚠ 一律从 CTRL(0x00) 读，不是从 0x04。
 * 用别名而不是到处写裸宏，是为了让"读哪个寄存器"这件事
 * 只有一处定义，避免再次出现 0x04 的误用。 */
#define SOBEL_STATUS_AP_DONE     SOBEL_CTRL_AP_DONE
#define SOBEL_STATUS_AP_IDLE     SOBEL_CTRL_AP_IDLE
#define SOBEL_STATUS_AP_READY    SOBEL_CTRL_AP_READY

/* ================================================================== *
 *  约束与默认值
 * ================================================================== */
#define SOBEL_MAX_WIDTH       1920u
#define SOBEL_MAX_HEIGHT      1080u
#define SOBEL_DEFAULT_GAIN    256u
#define SOBEL_DEFAULT_THRESH  0u

/** DMA 传输对齐要求：AXI 总线上按 4 字节突发最有效 */
#define SOBEL_ALIGN_BYTES     4u

/* ================================================================== *
 *  返回码
 * ================================================================== */
#define SOBEL_OK              0
#define SOBEL_ERR_PARAM      -1   /* 参数非法（尺寸/对齐/空指针） */
#define SOBEL_ERR_DMA_INIT   -2   /* DMA 初始化失败 */
#define SOBEL_ERR_DMA_TX     -3   /* MM2S（发送）失败 */
#define SOBEL_ERR_DMA_RX     -4   /* S2MM（接收）失败 */
#define SOBEL_ERR_TIMEOUT    -5   /* 等待 IP 完成超时 */

/* ================================================================== *
 *  句柄
 * ================================================================== */
typedef struct {
    uint32_t ip_base;       /* sobel IP 的 AXI-Lite 基地址 */
    uint32_t dma_base;      /* AXI DMA 的基地址 */
    uint32_t width;
    uint32_t height;
    uint32_t thresh;
    uint32_t gain;

    uint32_t last_cycles;   /* 上一次 sobel_run 的耗时（CPU 周期） */
    uint32_t run_count;     /* 累计运行帧数 */

    void    *priv;          /* 内部状态（DMA 实例等），不透明 */
} sobel_t;

/* ================================================================== *
 *  API
 * ================================================================== */

/**
 * @brief 初始化驱动
 *
 * @param dev       句柄
 * @param ip_base   sobel IP 的 AXI-Lite 基地址
 * @param dma_base  AXI DMA 基地址
 * @return SOBEL_OK 或负的错误码
 */
int sobel_init(sobel_t *dev, uint32_t ip_base, uint32_t dma_base);

/** @brief 设置图像尺寸（须 <= SOBEL_MAX_WIDTH/HEIGHT） */
int sobel_set_size(sobel_t *dev, uint32_t width, uint32_t height);

/** @brief 设置阈值（0 = 不二值化，直接输出幅值） */
void sobel_set_thresh(sobel_t *dev, uint32_t thresh);

/** @brief 设置增益，Q8 定点，256 = x1.0 */
void sobel_set_gain(sobel_t *dev, uint32_t gain);

/**
 * @brief 处理一帧：DDR -> DMA -> Sobel -> DMA -> DDR
 *
 * 阻塞直到完成。返回后 src 未被修改，dst 里是边缘图。
 *
 * @param dev   句柄
 * @param src   输入灰度图，宽*高 字节，4 字节对齐
 * @param dst   输出边缘图，宽*高 字节，4 字节对齐
 * @return SOBEL_OK 或负的错误码
 */
int sobel_run(sobel_t *dev, const uint8_t *src, uint8_t *dst);

/** @brief 上一次 sobel_run 的耗时（CPU 周期数，用全局定时器测） */
uint32_t sobel_last_cycles(const sobel_t *dev);

/** @brief 由周期数换算微秒（需传入 CPU 频率，Zynq-7000 通常 666666667） */
double sobel_cycles_to_us(uint32_t cycles, uint32_t cpu_hz);

/** @brief 打印 IP 状态寄存器，调试用 */
void sobel_dump_status(const sobel_t *dev);

/** @brief 读 IP 版本（如果综合时生成了版本寄存器） */
uint32_t sobel_read_version(const sobel_t *dev);

/* ================================================================== *
 *  便捷宏
 * ================================================================== */
#define SOBEL_MAX_BYTES   (SOBEL_MAX_WIDTH * SOBEL_MAX_HEIGHT)

#ifdef __cplusplus
}
#endif

#endif /* SOBEL_DRIVER_H */
