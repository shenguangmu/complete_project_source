#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sobel_ref.py —— Sobel 边缘检测的 Python golden 参考模型

这份实现必须与 src_hls/sobel_hls.cpp 里的 sobel_calc() **逐位一致**。
任何一处改动都要同步另一处，否则 HLS C 仿真会失败。

固定点约定（Q8）:
    gain = 256 表示 x1.0
    mag  = (|Gx| + |Gy|) * gain >> 8
    out  = min(mag, 255)
    若 mag > thresh 则直接输出 255（二值化）

用法:
    from sobel_ref import sobel_numpy, sobel_pixelwise
"""

import numpy as np


def sobel_numpy(img, thresh=0, gain=256):
    """
    向量化实现，用于生成 golden 向量。

    参数
    ----
    img    : (H, W) uint8 灰度图
    thresh : 阈值，超出则输出 255
    gain   : Q8 增益，256 = x1.0

    返回
    ----
    (H, W) uint8 边缘图
    """
    img = np.asarray(img, dtype=np.int64)
    h, w = img.shape

    # 四周补零，得到 (H+2, W+2)
    pad = np.zeros((h + 2, w + 2), dtype=np.int64)
    pad[1:h + 1, 1:w + 1] = img

    # 3x3 邻域视图，左上角对齐到每个输出像素
    p00 = pad[0:h,   0:w  ]   # 左上
    p01 = pad[0:h,   1:w+1]   # 上
    p02 = pad[0:h,   2:w+2]   # 右上
    p10 = pad[1:h+1, 0:w  ]   # 左
    p11 = pad[1:h+1, 1:w+1]   # 中
    p12 = pad[1:h+1, 2:w+2]   # 右
    p20 = pad[2:h+2, 0:w  ]   # 左下
    p21 = pad[2:h+2, 1:w+1]   # 下
    p22 = pad[2:h+2, 2:w+2]   # 右下

    # Sobel 卷积核
    gx = (p00 + 2 * p10 + p20) - (p02 + 2 * p12 + p22)
    gy = (p00 + 2 * p01 + p02) - (p20 + 2 * p21 + p22)

    mag = (np.abs(gx) + np.abs(gy)) * gain
    # 算术右移，与 C 的 >> 在非负数上等价。mag 恒 >= 0，无需处理补码
    mag = mag >> 8

    # 阈值：超过则满量程
    mag = np.where(mag > thresh, 255, mag)
    # 饱和
    mag = np.clip(mag, 0, 255)
    return mag.astype(np.uint8)


def sobel_pixelwise(img, thresh=0, gain=256):
    """
    逐像素的朴素实现，不依赖任何向量化技巧。

    存在的意义是做**独立性校验**：如果 sobel_numpy 的切片写错了，
    两个实现在随机图上会对不上。测试里会拿它俩互相比对。
    """
    img = np.asarray(img, dtype=np.int64)
    h, w = img.shape
    out = np.zeros((h, w), dtype=np.uint8)

    def px(y, x):
        """越界返回 0（补零边界）"""
        if y < 0 or y >= h or x < 0 or x >= w:
            return 0
        return int(img[y, x])

    for y in range(h):
        for x in range(w):
            p00 = px(y - 1, x - 1); p01 = px(y - 1, x); p02 = px(y - 1, x + 1)
            p10 = px(y,     x - 1); p11 = px(y,     x); p12 = px(y,     x + 1)
            p20 = px(y + 1, x - 1); p21 = px(y + 1, x); p22 = px(y + 1, x + 1)

            gx = (p00 + 2 * p10 + p20) - (p02 + 2 * p12 + p22)
            gy = (p00 + 2 * p01 + p02) - (p20 + 2 * p21 + p22)

            mag = (abs(gx) + abs(gy)) * gain
            mag >>= 8

            if mag > thresh:
                mag = 255
            mag = max(0, min(255, mag))
            out[y, x] = mag

    return out


# ----------------------------------------------------------------------
#  测试图生成
# ----------------------------------------------------------------------

def make_gradient(w=32, h=32):
    """水平渐变。每列 +8，Sobel 响应恒为 8*4 = 32（内部区域）。"""
    row = (np.arange(w) * 8 % 256).astype(np.uint8)
    return np.tile(row, (h, 1))


def make_checkerboard(w=32, h=32, block=4):
    """棋盘格。检验边界处理与强边缘响应。"""
    yy, xx = np.mgrid[0:h, 0:w]
    c = (((yy // block) + (xx // block)) % 2).astype(np.uint8) * 255
    return c


def make_shapes(w=64, h=64):
    """几何图形：矩形 + 对角线，肉眼可辨的边缘结构。"""
    img = np.zeros((h, w), dtype=np.uint8)
    img[8:24, 8:24] = 200                 # 亮矩形
    img[36:56, 36:60] = 128               # 灰矩形
    for i in range(min(w, h)):            # 对角线
        if 0 <= i < h and (w - 1 - i) >= 0:
            img[i, w - 1 - i] = 255
    return img


def make_ramp_edges(w=64, h=64):
    """阶梯灰阶：竖直方向若干条不同亮度的色带。"""
    img = np.zeros((h, w), dtype=np.uint8)
    band = w // 8
    for i in range(8):
        img[:, i * band:(i + 1) * band] = (i * 32) % 256
    return img


def make_noise(w=32, h=32, seed=12345):
    """伪随机噪声。用固定 seed 保证可复现，检验一般情形。"""
    rng = np.random.RandomState(seed)
    return rng.randint(0, 256, size=(h, w), dtype=np.uint8)


# 供 gen_vectors.py 遍历
TEST_IMAGES = {
    "gradient":     (make_gradient,     32, 32),
    "checker":      (make_checkerboard, 32, 32),
    "shapes":       (make_shapes,       64, 64),
    "ramp":         (make_ramp_edges,   64, 64),
    "noise":        (make_noise,        32, 32),
    "odd":          (make_shapes,       37, 41),   # 奇数尺寸，查边界 off-by-one
}


if __name__ == "__main__":
    # 自检：向量化实现 vs 逐像素实现，必须完全一致
    import sys
    rng = np.random.RandomState(7)
    ok = True
    for name, (fn, w, h) in TEST_IMAGES.items():
        img = fn(w, h)
        a = sobel_numpy(img)
        b = sobel_pixelwise(img) if img.size <= 4096 else a
        same = np.array_equal(a, b)
        ok &= same
        print(f"{name:12s} {w}x{h:<4d} vectorized==naive: {same}")
    print("SELF-CHECK", "PASSED" if ok else "FAILED")
    sys.exit(0 if ok else 1)
