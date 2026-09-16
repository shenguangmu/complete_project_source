/**
 * @file    gesture_preproc.h
 * @brief   手势图像预处理链 —— 对外契约（寄存器映射 / 参数 / 共享类型）
 *
 * 本文件被四处共享，改之前先读 docs/架构与接口契约.md：
 *   1. HLS 综合源码      src_hls/gesture_preproc.cpp
 *   2. HLS C 仿真 TB     src_hls/tb_gesture.cpp
 *   3. 各阶段参考实现    src_hls/gesture_ref.cpp
 *   4. PS 端驱动         sw/gesture_driver.h
 *
 * ────────────────────────────────────────────────────────────────────
 *  处理链
 * ────────────────────────────────────────────────────────────────────
 *   RGB565 ─► rgb2gray ─► gaussian ─► sobel ─► adaptive_thresh
 *                           │                      │
 *                           └──── thresh_mode ─────┘   (二选一)
 *                                    │
 *                              morph_close ─► roi_extract ─► 96x96 灰度
 *
 * ────────────────────────────────────────────────────────────────────
 *  与 sobel_hls.h 的关系
 * ────────────────────────────────────────────────────────────────────
 *  sobel_accel 作为**独立 IP** 保留（BD 里仍可单独例化、单独回归），
 *  本文件里的链把它作为一个阶段重新实现了一份，两者数值行为一致。
 */

#ifndef GESTURE_PREPROC_H
#define GESTURE_PREPROC_H

#include <ap_int.h>
#include <hls_stream.h>
#include <ap_axi_sdata.h>

/* ================================================================== *
 *  一、图像规格
 * ================================================================== */

/** 采集分辨率。先按 VGA 640x480@30 走：
 *  RGB565 下 PCLK ≈ 24 MHz，自制转接板稳妥。
 *  改 720p 需重新评估 PCLK（RGB565 约 72 MHz）与转接板走线。 */
#define GESTURE_IN_WIDTH    640
#define GESTURE_IN_HEIGHT   480

/** 输入像素：RGB565，一拍一像素。
 *  DVP 侧"一行 2 拍"的拼装已经在 Verilog 采集模块里做完，
 *  到这里已经是规整的 16bit/像素流。 */
typedef ap_uint<16> rgb565_t;

/** 中间与输出像素 */
typedef ap_uint<8> gray_t;

/** 给 CNN 的输出尺寸（契约冻结，见 docs/架构与接口契约.md §3.1）。
 *  ⚠ 改动这里必须同步通知 CNN 侧。 */
#define GESTURE_OUT_SIZE    96
#define GESTURE_OUT_PIXELS  (GESTURE_OUT_SIZE * GESTURE_OUT_SIZE)

/** 行缓存支持的图像上限 */
#define GESTURE_MAX_WIDTH   1920
#define GESTURE_MAX_HEIGHT  1080

/* ================================================================== *
 *  二、AXI4-Stream 传输类型
 * ================================================================== */

/** 输入流：16bit RGB565。
 *
 *  为什么用 ap_axiu 而不是裸 hls::stream<ap_uint<16>>：
 *  裸类型不生成 TLAST，AXI DMA 的 S2MM 靠 TLAST 界定一次传输的结束，
 *  缺了它 Vivado 会报
 *    "Interface connected to S_AXIS_S2MM does not have TLAST port"
 *  且 DMA 会一直等下去。这个坑现有 sobel 工程已经踩过，
 *  详见 E:\project\README.md §9.6。 */
typedef ap_axiu<16, 0, 0, 0> axis_rgb_t;

/** 输出流：8bit 灰度 */
typedef ap_axiu<8, 0, 0, 0> axis_gray_t;

/* ================================================================== *
 *  三、AXI-Lite 寄存器映射
 *
 *  偏移由 Vitis HLS 的 INTERFACE s_axilite 自动生成，下面的宏是
 *  给驱动和 TB 用的可读对照表。
 *  导出 IP 后请用 drivers/ 下的 _hw.h 或 xparameters.h 复核。
 * ================================================================== */

#define GESTURE_REG_CTRL          0x00  /* bit0=ap_start, bit1=auto_restart */
#define GESTURE_REG_STATUS        0x04  /* bit0=ready,1=done,2=idle,3=continue */
#define GESTURE_REG_WIDTH         0x10  /* 输入宽  (默认 GESTURE_IN_WIDTH)  */
#define GESTURE_REG_HEIGHT        0x18  /* 输入高  (默认 GESTURE_IN_HEIGHT) */
#define GESTURE_REG_THRESH_MODE   0x20  /* 0=不用阈值(灰度直通), 1=自适应阈值 */
#define GESTURE_REG_THRESH_OFFSET 0x28  /* 自适应阈值偏置，有符号，默认 0   */
#define GESTURE_REG_GAUSS_EN      0x30  /* 0=跳过高斯, 1=高斯去噪(默认 1)   */
#define GESTURE_REG_SOBEL_EN      0x38  /* 0=直接阈值灰度, 1=先 Sobel(默认 1)*/
#define GESTURE_REG_MORPH_EN      0x40  /* 0=跳过闭运算, 1=闭运算(默认 1)   */
#define GESTURE_REG_GAIN          0x48  /* Sobel Q8 增益，256 = x1.0        */
#define GESTURE_REG_ROI_X         0x50  /* ROI 左上角 x                     */
#define GESTURE_REG_ROI_Y         0x58  /* ROI 左上角 y                     */
#define GESTURE_REG_ROI_W         0x60  /* ROI 宽（裁剪后缩放至 96x96）     */
#define GESTURE_REG_ROI_H         0x68  /* ROI 高                           */

/* CTRL 位 */
#define GESTURE_CTRL_AP_START      0x01u
#define GESTURE_CTRL_AUTO_RESTART  0x02u

/* STATUS 位 */
#define GESTURE_STATUS_AP_READY    0x01u
#define GESTURE_STATUS_AP_DONE     0x02u
#define GESTURE_STATUS_AP_IDLE     0x04u
#define GESTURE_STATUS_AP_CONTINUE 0x08u

/* ================================================================== *
 *  四、算法参数默认值
 * ================================================================== */

/** RGB565 → 灰度权重（BT.601 的整数近似，仿 Xilinx rgb2ycrcb）。
 *  取 8 位小数精度：0.2568->66, 0.5041->129, 0.0979->25，和 = 220。
 *  结果再右移 8 → 得 0..255。 */
#define GESTURE_Y_R   66
#define GESTURE_Y_G   129
#define GESTURE_Y_B   25

/** Sobel Q8 增益，256 = x1.0 */
#define GESTURE_DEFAULT_GAIN   256

/** 自适应阈值默认偏置（有符号 8 位，单位：灰度级）。
 *  阈值 = 局部均值 + offset，offset 为负表示"低于均值也算前景"，
 *  正值表示"要比均值亮很多才算前景"。 */
#define GESTURE_DEFAULT_THRESH_OFFSET  (-8)

/** 形态学闭运算的核尺寸固定 3x3（结构元全 1） */
#define GESTURE_MORPH_K 1   /* 半径，3x3 = 1 两侧 */

/** ROI 默认值：居中取 320x320（后续缩放至 96x96） */
#define GESTURE_DEFAULT_ROI_W  320
#define GESTURE_DEFAULT_ROI_H  320

/* ================================================================== *
 *  五、各阶段函数声明
 *
 *  均为纯 axilite 参数（无 AXI 接口），方便单独 csim。
 *  顶层 gesture_preproc() 用 DATAFLOW 把它们串起来。
 * ================================================================== */

void rgb2gray(hls::stream<axis_rgb_t>  &src,
              hls::stream<axis_gray_t> &dst,
              int width, int height);

void gaussian_3x3(hls::stream<axis_gray_t> &src,
                  hls::stream<axis_gray_t> &dst,
                  int width, int height);

void sobel_core(hls::stream<axis_gray_t> &src,
                hls::stream<axis_gray_t> &dst,
                int width, int height, int gain);

void adaptive_thresh(hls::stream<axis_gray_t> &src,
                     hls::stream<axis_gray_t> &dst,
                     int width, int height, int offset);

void morph_close(hls::stream<axis_gray_t> &src,
                 hls::stream<axis_gray_t> &dst,
                 int width, int height);

void roi_extract(hls::stream<axis_gray_t> &src,
                 hls::stream<axis_gray_t> &dst,
                 int width, int height,
                 int roi_x, int roi_y, int roi_w, int roi_h);

/* ================================================================== *
 *  六、顶层：接口契约
 * ================================================================== */

/**
 * @brief 手势图像预处理顶层
 *
 * 接口约定（HLS INTERFACE 指令见 gesture_preproc.cpp）：
 *   src  -> AXI4-Stream (16bit RGB565 + TLAST)
 *   dst  -> AXI4-Stream (8bit  灰度  + TLAST)
 *   width/height/thresh_mode/thresh_offset/gauss_en/sobel_en/morph_en/
 *   gain/roi_x/roi_y/roi_w/roi_h -> s_axi_control (AXI4-Lite)
 *
 * ⚠ 输出流的长度恒为 GESTURE_OUT_PIXELS (9216)，与输入分辨率无关；
 *   这是与 CNN 侧的契约，见 docs/架构与接口契约.md §3.1。
 */
void gesture_preproc(hls::stream<axis_rgb_t>  &src,
                     hls::stream<axis_gray_t> &dst,
                     int width,
                     int height,
                     int thresh_mode,
                     int thresh_offset,
                     int gauss_en,
                     int sobel_en,
                     int morph_en,
                     int gain,
                     int roi_x,
                     int roi_y,
                     int roi_w,
                     int roi_h);

#endif /* GESTURE_PREPROC_H */
