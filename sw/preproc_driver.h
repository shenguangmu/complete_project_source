/**
 * @file    preproc_driver.h
 * @brief   手势预处理链 PS 侧驱动 —— 接口与寄存器定义
 *
 * =====================================================================
 *  这个驱动控制什么
 * =====================================================================
 *  BD（bd_video）里的 CNN 通路：
 *
 *      DDR(640x480 RGB565)          ← VDMA 写的帧缓存
 *            │  dma_in (MM2S)
 *            ▼
 *      gesture_preproc (HLS) ──► 96x96 uint8
 *            │  dma_out (S2MM)
 *            ▼
 *      DDR(96x96) ──► 本驱动读出来 / 给 CNN 用
 *
 *  与 sobel_driver 的关系：那个是给原 Sobel 通路（bd_sobel）用的，
 *  **两者互不影响**，可以同时存在。
 *
 * =====================================================================
 *  ⚠ 寄存器偏移的来源（不凭记忆写）
 * =====================================================================
 *  下面所有偏移取自 **Vitis HLS 生成的官方驱动**：
 *      gesture_comp/solution1/impl/ip/drivers/
 *          gesture_preproc_v1_0/src/xgesture_preproc_hw.h
 *
 *  ⚠ 并且从官方 xgesture_preproc.c 里确认了控制位：
 *        Start()  写 CTRL 的 bit0=1，同时保留 bit7(auto_restart)
 *        IsDone() 读 **CTRL(0x00)** 的 bit1
 *        IsIdle() 读 **CTRL(0x00)** 的 bit2
 *        IsReady()读 **CTRL(0x00)** 的 bit3
 *
 *  ⚠⚠ **状态位在 CTRL(0x00)，不在什么 "STATUS 寄存器"。**
 *      0x04 是 GIE（全局中断使能）。本项目在 sobel_driver 上踩过
 *      这个坑（见 fpga-dev skill 09-pitfalls D2）：
 *      驱动轮询 0x04 永远等不到 AP_DONE，而主机仿真自己造了个假
 *      STATUS 值所以看起来是通的 —— 上板才炸。
 *      本驱动从一开始就用正确的位置。
 */

#ifndef PREPROC_DRIVER_H
#define PREPROC_DRIVER_H

#include <stdint.h>
#include <stddef.h>

/* ================================================================== *
 *  1. gesture_preproc 的 AXI-Lite 寄存器
 *
 *  偏移取自官方驱动 xgesture_preproc_hw.h（见文件头说明）
 *  参数按 8 字节对齐：0x10, 0x18, 0x20, ...
 * ================================================================== */
#define PREPROC_REG_CTRL          0x00u  /* 控制 + 状态位都在这 */
#define PREPROC_REG_GIE           0x04u  /* 全局中断使能（不是状态！） */
#define PREPROC_REG_IER           0x08u  /* 通道中断使能 */
#define PREPROC_REG_ISR           0x0Cu  /* 通道中断状态 */
#define PREPROC_REG_WIDTH         0x10u
#define PREPROC_REG_HEIGHT        0x18u
#define PREPROC_REG_THRESH_MODE   0x20u
#define PREPROC_REG_THRESH_OFFSET 0x28u
#define PREPROC_REG_GAUSS_EN      0x30u
#define PREPROC_REG_SOBEL_EN      0x38u
#define PREPROC_REG_MORPH_EN      0x40u
#define PREPROC_REG_GAIN          0x48u
#define PREPROC_REG_ROI_X         0x50u
#define PREPROC_REG_ROI_Y         0x58u
#define PREPROC_REG_ROI_W         0x60u
#define PREPROC_REG_ROI_H         0x68u

/* CTRL(0x00) 的位 —— 取自官方 xgesture_preproc.c */
#define PREPROC_CTRL_AP_START      0x01u  /* bit0 RW */
#define PREPROC_CTRL_AP_DONE       0x02u  /* bit1 RO */
#define PREPROC_CTRL_AP_IDLE       0x04u  /* bit2 RO */
#define PREPROC_CTRL_AP_READY      0x08u  /* bit3 RO */
#define PREPROC_CTRL_AUTO_RESTART  0x80u  /* bit7 RW */

/* ================================================================== *
 *  2. 尺寸常量（必须与 src_hls/gesture_preproc.h 一致）
 * ================================================================== */

/** 输入帧（与 VDMA 帧缓存一致） */
#define PREPROC_IN_WIDTH      640
#define PREPROC_IN_HEIGHT     480
/** 输入每像素字节数：RGB565 = 2 */
#define PREPROC_IN_BPP        2
/** 输入帧字节数：614400 */
#define PREPROC_IN_BYTES      (PREPROC_IN_WIDTH * PREPROC_IN_HEIGHT * PREPROC_IN_BPP)

/** ⚠ 输出尺寸是与 CNN 侧的契约，改这里必须同步通知 CNN 那侧 */
#define PREPROC_OUT_SIZE      96
/** 输出像素数：9216 */
#define PREPROC_OUT_PIXELS    (PREPROC_OUT_SIZE * PREPROC_OUT_SIZE)
/** 输出字节数：9216（uint8 灰度） */
#define PREPROC_OUT_BYTES     PREPROC_OUT_PIXELS

/* ================================================================== *
 *  3. 算法参数默认值（与 src_hls/gesture_preproc.h 一致）
 * ================================================================== */
#define PREPROC_DEFAULT_THRESH_MODE    1
#define PREPROC_DEFAULT_THRESH_OFFSET  (-8)
#define PREPROC_DEFAULT_GAIN           256
/** ROI 默认居中 320x320 */
#define PREPROC_DEFAULT_ROI_W          320
#define PREPROC_DEFAULT_ROI_H          320

/* ================================================================== *
 *  4. 错误码
 * ================================================================== */
#define PREPROC_OK              0
#define PREPROC_ERR_PARAM      (-1)   /* 参数非法 */
#define PREPROC_ERR_TIMEOUT    (-2)   /* 等 ap_done 超时 */
#define PREPROC_ERR_DMA        (-3)   /* DMA 出错 */
#define PREPROC_ERR_NOTIDLE    (-4)   /* IP 不在 idle 状态 */

/* ================================================================== *
 *  5. 设备结构
 * ================================================================== */

typedef struct {
    uint32_t ip_base;        /* gesture_preproc 的 AXI-Lite 基地址 */
    uint32_t dma_in_base;    /* 输入 DMA（MM2S）基地址 */
    uint32_t dma_out_base;   /* 输出 DMA（S2MM）基地址 */

    /* 当前配置（供 dump / 复用） */
    int      width, height;
    int      thresh_mode, thresh_offset;
    int      gauss_en, sobel_en, morph_en;
    int      gain;
    int      roi_x, roi_y, roi_w, roi_h;

    /* 统计 */
    uint32_t run_count;      /* 累计处理帧数 */
    uint32_t last_cycles;    /* 上一帧耗时（周期） */
} preproc_t;

/* ================================================================== *
 *  6. 驱动 API
 * ================================================================== */

/**
 * @brief 初始化
 *
 * 只记录基地址并做基本检查，不碰硬件寄存器 ——
 * 真正的配置在 preproc_run() 里做（每帧都要重设，因为 IP 不是
 * auto_restart 模式）。
 *
 * @param dev         设备结构
 * @param ip_base     XPAR_GESTURE_PREPROC_0_BASEADDR
 * @param dma_in_base 输入 DMA 基地址
 * @param dma_out_base输出 DMA 基地址
 */
int preproc_init(preproc_t *dev,
                 uint32_t ip_base,
                 uint32_t dma_in_base,
                 uint32_t dma_out_base);

/**
 * @brief 设置完整参数（含各阶段开关与 ROI）
 *
 * 参数存在 dev 里，preproc_run() 时写进硬件。
 * ⚠ 不做参数合法性检查到硬件层面 —— 非法值由 preproc_run() 拦住。
 */
int preproc_config(preproc_t *dev,
                   int thresh_mode, int thresh_offset,
                   int gauss_en, int sobel_en, int morph_en,
                   int gain,
                   int roi_x, int roi_y, int roi_w, int roi_h);

/**
 * @brief 用默认参数配置（居中 ROI、全链开启）
 */
int preproc_config_default(preproc_t *dev);

/**
 * @brief 处理一帧：DDR(640x480 RGB565) → DDR(96x96 灰度)
 *
 * ⚠⚠ 执行顺序不能反：
 *      1. 先武装 dma_out（S2MM）—— 让它准备好接收
 *      2. 再启动 dma_in（MM2S）—— 开始供数
 *      3. 最后 ap_start
 *      4. 轮询 ap_done
 *
 *    如果先启 dma_in，预处理输出的第一拍数据**没有接收方**
 *    （S2MM 还没武装），那部分数据会丢 —— 表现为输出图像开头
 *    缺几行，或者 S2MM 报 DMA 错误。
 *
 * @param dev 设备
 * @param src DDR 里的输入帧（640x480 RGB565，614400 字节，4 字节对齐）
 * @param dst DDR 里的输出缓冲（96x96 uint8，9216 字节，4 字节对齐）
 */
int preproc_run(preproc_t *dev, const void *src, void *dst);

/**
 * @brief 打印 IP 的 CTRL 寄存器状态
 *
 * ⚠ 必须在 preproc_run() 把 CTRL 清零**之前**调用。
 *    run 结尾写 CTRL=0 复位 ap_start，会连只读的
 *    AP_DONE/AP_IDLE/AP_READY 一起读成 0 ——
 *    之后调用会看到全零，误以为 IP 没跑。
 *    （与 sobel_driver 里同样的问题，见其注释。）
 */
void preproc_dump_status(const preproc_t *dev);

/**
 * @brief 上一帧耗时
 */
uint32_t preproc_last_cycles(const preproc_t *dev);

/**
 * @brief 周期数 → 微秒
 */
double preproc_cycles_to_us(uint32_t cycles, uint32_t cpu_hz);

#endif /* PREPROC_DRIVER_H */
