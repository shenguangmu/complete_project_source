/**
 * @file    gesture_ref.h
 * @brief   软件 golden 参考实现的声明（仅供 csim，不参与综合）
 *
 * 各阶段签名做了简化：宽高固定为 GESTURE_OUT_SIZE（因为 crop_scale
 * 之后整条链都跑在 96x96 上），enable 直接对应 HLS 侧的开关参数。
 * 这样声明与实现一一对应，也少一处可以写错的地方。
 */

#ifndef GESTURE_REF_H
#define GESTURE_REF_H

#include "gesture_preproc.h"

#ifndef __SYNTHESIS__

namespace ref {

/** ROI 裁剪 + 盒式缩放，输出恒为 GESTURE_OUT_PIXELS 字节 */
void crop_scale(const ap_uint<16> *src, ap_uint<8> *dst,
                int width, int height,
                int roi_x, int roi_y, int roi_w, int roi_h);

/** 3x3 高斯。enable=0 时按 (1,2) 延迟直通，见 .cpp 文件头第 3 条 */
void gaussian(const ap_uint<8> *src, ap_uint<8> *dst, int enable);

/** Sobel |Gx|+|Gy| 带 Q8 增益。enable=0 时按 (1,2) 延迟直通 */
void sobel(const ap_uint<8> *src, ap_uint<8> *dst, int gain, int enable);

/** 均值自适应阈值。点运算，无延迟；enable=0 时原值直通 */
void adaptive_thresh(const ap_uint<8> *src, ap_uint<8> *dst,
                     int offset, int enable);

/** 3x3 闭运算。enable=0 时按 (1,2) 延迟直通 */
void morph_close(const ap_uint<8> *src, ap_uint<8> *dst, int enable);

/**
 * @brief 全链参考实现
 *
 * 参数与 gesture_preproc() 的 axilite 参数一一对应（去掉宽高，
 * 因为参考实现固定跑在输出尺寸上）。
 */
void gesture_ref(const ap_uint<16> *src, ap_uint<8> *dst,
                 int width, int height,
                 int thresh_mode, int thresh_offset,
                 int gauss_en, int sobel_en, int morph_en,
                 int gain, int roi_x, int roi_y, int roi_w, int roi_h);

} /* namespace ref */

#endif /* !__SYNTHESIS__ */

#endif /* GESTURE_REF_H */
