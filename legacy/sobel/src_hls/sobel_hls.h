/**
 * @file    sobel_hls.h
 * @brief   Sobel 边缘检测加速器 —— 常量与寄存器定义
 *
 * 本文件被三处共享：
 *   1. HLS 综合源码 (sobel_hls.cpp)
 *   2. HLS C 仿真 testbench (tb_sobel.cpp)
 *   3. PS 端裸机驱动 (../sw/sobel_driver.h 通过 SOBEL_REG_* 宏引用)
 *
 * 改这里之前，先读 README.md 的「接口与寄存器」一节。
 */

#ifndef SOBEL_HLS_H
#define SOBEL_HLS_H

#include <ap_int.h>
#include <hls_stream.h>
#include <ap_axi_sdata.h>

/* ------------------------------------------------------------------ *
 *  AXI4-Stream 传输类型
 *
 *  用 ap_axiu<8,0,0,0>（= hls::axis<ap_uint<8>>）而不是裸的
 *  hls::stream<ap_uint<8>>，因为**裸类型不会生成 TLAST**：
 *
 *    hls::stream<ap_uint<8>>  →  只有 TDATA / TVALID / TREADY
 *    hls::stream<ap_axiu<8>>  →  多出 TLAST / TKEEP / TSTRB
 *
 *  AXI DMA 的 S2MM 通道靠 TLAST 判定"一次传输到此结束"，缺了它
 *  Vivado 会报 CRITICAL WARNING，DMA 也无法确定收包边界。
 *  用这个类型后，TLAST 由 sobel_accel() 显式置位（见 .cpp）。
 * ------------------------------------------------------------------ */
typedef ap_axiu<8, 0, 0, 0> axis_word_t;

/* ------------------------------------------------------------------ *
 *  图像规格
 * ------------------------------------------------------------------ */

/** 支持的最大图像宽度（像素）。行缓存按此宽度静态分配。
 *  1920 对应 1080p；XC7Z020 的 BRAM 足以放下 3 行。
 *  如果只做小图，可下调以减少资源占用。 */
#define SOBEL_MAX_WIDTH   1920

/** 支持的最大图像高度。仅用于边界检查，不参与存储分配。 */
#define SOBEL_MAX_HEIGHT  1080

/* ------------------------------------------------------------------ *
 *  AXI-Lite 寄存器映射
 *
 *  注意：真正的偏移由 Vitis HLS 的 INTERFACE s_axilite 自动生成，
 *  下面的宏是为了让驱动和 testbench 能有一份可读的对照表。
 *  导出 IP 后请用 sobel_accel/hls/impl/ip/drivers/ 下的 _hw.h 复核，
 *  或在 Vitis 里打开 xparameters.h 查看 XPAR_*_S_AXI_CONTROL_*_ADDR。
 * ------------------------------------------------------------------ */

#define SOBEL_REG_CTRL      0x00  /* bit0=ap_start, bit1=auto_restart */
#define SOBEL_REG_STATUS    0x04  /* bit0=ap_ready, 1=ap_done, 2=ap_idle, 3=ap_continue */
#define SOBEL_REG_WIDTH     0x10  /* 图像宽度 */
#define SOBEL_REG_HEIGHT    0x18  /* 图像高度 */
#define SOBEL_REG_THRESH    0x20  /* 阈值 0-255 */
#define SOBEL_REG_GAIN      0x28  /* Q8 增益，256 = x1.0 */

/* CTRL 位定义 */
#define SOBEL_CTRL_AP_START      0x01u
#define SOBEL_CTRL_AUTO_RESTART  0x02u

/* STATUS 位定义 */
#define SOBEL_STATUS_AP_READY    0x01u
#define SOBEL_STATUS_AP_DONE     0x02u
#define SOBEL_STATUS_AP_IDLE     0x04u
#define SOBEL_STATUS_AP_CONTINUE 0x08u

/* ------------------------------------------------------------------ *
 *  算法参数默认值
 * ------------------------------------------------------------------ */

/** 增益默认 256，即 Q8 定点下的 x1.0。 */
#define SOBEL_DEFAULT_GAIN   256

/** 阈值默认 0，即不做二值化，直接输出幅值。 */
#define SOBEL_DEFAULT_THRESH 0

/** 幅值上限：|Gx|+|Gy| 最大 4*255 = 1020，取饱和到 255。 */
#define SOBEL_MAG_MAX        255

/* ------------------------------------------------------------------ *
 *  顶层函数声明
 *
 *  接口约定（HLS INTERFACE 指令见 sobel_hls.cpp）：
 *    src  -> AXI4-Stream (8-bit + TLAST)，C 类型是 hls::stream
 *    dst  -> AXI4-Stream (8-bit + TLAST)
 *    width / height / thresh / gain -> s_axi_control (AXI4-Lite)
 *
 *  ⚠️ 为什么必须是 hls::stream 而不是裸指针 ap_uint<8>*：
 *     裸指针映射成 axis 后**只有 TDATA**，没有 TLAST。
 *     而 AXI DMA 的 S2MM 通道靠 TLAST 界定一次传输的结束，
 *     缺了它 Vivado 会报 CRITICAL WARNING
 *       "Interface connected to S_AXIS_S2MM does not have TLAST port"
 *     并且 DMA 无法知道何时收完，推理上会一直等下去。
 *     用 hls::stream 则 HLS 自动补出 TVALID/TREADY/TLAST/TKEEP/TSTRB。
 * ------------------------------------------------------------------ */

void sobel_accel(hls::stream<axis_word_t> &src,
                 hls::stream<axis_word_t> &dst,
                 int width,
                 int height,
                 int thresh,
                 int gain);

#endif /* SOBEL_HLS_H */
