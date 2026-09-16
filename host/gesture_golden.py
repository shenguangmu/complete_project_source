#!/usr/bin/env python3
"""
gesture_golden.py —— 手势预处理链的 Python 参考实现

用途（三方对拍）：
    HLS 实现  ←→  C++ golden (src_hls/gesture_ref.cpp)
        ↘        ↙
          Python golden（本文件）

三者必须逐位一致。任何一方与另外两方不一致，就说明那一方的
语义理解有偏差 —— 这正是三方对拍的价值：单个参考实现出错时，
自比对( HLS vs C++ golden )会"一起错"，看起来是通过的。

⚠ 本文件必须与 src_hls/gesture_ref.cpp 逐位一致。核心契约
（详见 src_hls/README.md）：

    输出 (Y, X) 的 3x3 窗口 = 图像 (Y-1..Y+1, X-1..X+1)，越界补零。

    HLS 的流式实现在内部迭代坐标上带 (−1, −2) 偏移，但在输出
    数组索引上恰好抵消，净效果就是上面这条标准卷积。
    ⚠ 别把它误当成输出坐标的偏移 —— 那会导出一套错的边界模型。

用法：
    # 自检：与 C++ golden 的一致性靠 dump 出的 .bin 比对
    python gesture_golden.py --self-test

    # 对一张输入 .bin（uint16 RGB565, 行列优先）跑全链，输出 .bin
    python gesture_golden.py --input frame.bin --width 640 --height 480 \
                             --out result.bin
"""

import argparse
import sys
import numpy as np

# ======================================================================
# 与 src_hls/gesture_preproc.h 必须保持一致的常量
# ======================================================================

OUT_SIZE = 96
OUT_PIXELS = OUT_SIZE * OUT_SIZE

Y_R = 66
Y_G = 129
Y_B = 25

DEFAULT_GAIN = 256
DEFAULT_THRESH_OFFSET = -8


# ======================================================================
# 阶段 1：crop_scale
# ======================================================================

def rgb565_to_gray(rgb: np.ndarray) -> np.ndarray:
    """RGB565 → 灰度。

    ⚠ 运算顺序必须与 HLS 一致：先扩位（5/6bit 左移成 8bit），
      再加权求和右移 8 位。先加权再移位会得到不同的定标。
    """
    rgb = rgb.astype(np.uint16)
    r5 = (rgb >> 11) & 0x1F
    g6 = (rgb >> 5) & 0x3F
    b5 = rgb & 0x1F

    r8 = (r5 << 3).astype(np.uint16)
    g8 = (g6 << 2).astype(np.uint16)
    b8 = (b5 << 3).astype(np.uint16)

    lum = r8 * Y_R + g8 * Y_G + b8 * Y_B
    return (lum >> 8).astype(np.uint8)


def crop_scale(rgb: np.ndarray, width: int, height: int,
               roi_x: int, roi_y: int, roi_w: int, roi_h: int) -> np.ndarray:
    """ROI 裁剪 + 盒式缩放，输出恒为 96x96。

    整数加法是精确且可交换的，所以块内求和的顺序不影响结果 ——
    但**整数除法必须在求和之后**（不是每步平均），否则与 HLS 不一致。
    """
    step_x = max(1, (roi_w + OUT_SIZE - 1) // OUT_SIZE)
    step_y = max(1, (roi_h + OUT_SIZE - 1) // OUT_SIZE)

    gray = rgb565_to_gray(rgb).reshape(height, width)

    # 裁出 ROI
    roi = gray[roi_y:roi_y + roi_h, roi_x:roi_x + roi_w]

    # 右侧/下侧补零，使尺寸凑成 step 的整数倍
    ph = (-roi_h) % step_y
    pw = (-roi_w) % step_x
    if ph or pw:
        roi = np.pad(roi, ((0, ph), (0, pw)), mode='constant')

    # 盒式平均：reshape 成块，求和后整除
    bh = roi.shape[0] // step_y
    bw = roi.shape[1] // step_x
    blocks = roi[:bh * step_y, :bw * step_x].reshape(bh, step_y, bw, step_x)
    avg = blocks.sum(axis=(1, 3), dtype=np.uint64) // (step_x * step_y)

    out = np.zeros((OUT_SIZE, OUT_SIZE), dtype=np.uint8)
    copy_h = min(bh, OUT_SIZE)
    copy_w = min(bw, OUT_SIZE)
    out[:copy_h, :copy_w] = avg[:copy_h, :copy_w].astype(np.uint8)
    return out


# ======================================================================
# 通用：零边框卷积核辅助
# ======================================================================

def _zero_pad(img: np.ndarray) -> np.ndarray:
    """补一圈零边框，使 out[y][x] 的窗口即为 P[y:y+3, x:x+3]。

    即标准 3x3 卷积的零填充：输出 (Y, X) 的窗口覆盖
    图像 (Y-1..Y+1, X-1..X+1)。
    """
    return np.pad(img.astype(np.int64), ((1, 1), (1, 1)), mode='constant')


def _conv3x3(img: np.ndarray, k: np.ndarray) -> np.ndarray:
    """3x3 相关（不做翻转），零边框，返回 int64 累加结果。

    输出 (y,x) 用窗口 P[y:y+3, x:x+3]，P 带一圈零边框，
    即标准 3x3 卷积的边界处理。
    """
    P = _zero_pad(img)
    h, w = img.shape
    acc = np.zeros((h, w), dtype=np.int64)
    for i in range(3):
        for j in range(3):
            if k[i, j] != 0:
                acc += P[i:i + h, j:j + w] * int(k[i, j])
    return acc


# ======================================================================
# 阶段 2：高斯
# ======================================================================

_gauss_k = np.array([[1, 2, 1],
                     [2, 4, 2],
                     [1, 2, 1]], dtype=np.int64)


def passthrough(img: np.ndarray) -> np.ndarray:
    """直通 = 原值拷贝。

    某级 enable=0 时，HLS 侧输出的是"窗口中心即图像 (Y,X) 处的值"，
    也就是原值本身。实现上 HLS 走的是纯流拷贝（不走窗口路径），
    所以这里直接返回输入即可。

    ⚠ 曾经误以为直通要带 (1,2) 延迟 —— 那是把流式实现的内部
      迭代坐标偏移错当成了输出坐标偏移。正确结论见
      src_hls/gesture_ref.cpp 的文件头说明。
    """
    return img.copy()


def gaussian(img: np.ndarray, enable: int = 1) -> np.ndarray:
    if not enable:
        return passthrough(img)
    g = _conv3x3(img, _gauss_k)
    return (g >> 4).astype(np.uint8)


# ======================================================================
# 阶段 3：Sobel
# ======================================================================

def sobel_mag(img: np.ndarray, gain: int) -> np.ndarray:
    P = _zero_pad(img)
    h, w = img.shape

    def at(dy, dx):
        return P[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]

    # Gx 响应竖直边缘：左列加权 - 右列加权
    gx = at(-1, -1) + 2 * at(0, -1) + at(1, -1) \
       - at(-1,  1) - 2 * at(0,  1) - at(1,  1)
    # Gy 响应水平边缘：上行加权 - 下行加权
    gy = at(-1, -1) + 2 * at(-1, 0) + at(-1, 1) \
       - at( 1, -1) - 2 * at( 1, 0) - at( 1, 1)

    abs_sum = np.abs(gx) + np.abs(gy)
    shifted = (abs_sum * int(gain)) >> 8
    return np.clip(shifted, 0, 255).astype(np.uint8)


def sobel(img: np.ndarray, gain: int, enable: int = 1) -> np.ndarray:
    if not enable:
        return passthrough(img)
    return sobel_mag(img, gain)


# ======================================================================
# 阶段 4：自适应阈值
# ======================================================================

def adaptive_thresh(img: np.ndarray, offset: int, enable: int = 1) -> np.ndarray:
    """均值自适应阈值。

    逐像素点运算，不涉及邻域，所以直通就是原值。
    """
    if not enable:
        return img.copy()

    mean = int(img.astype(np.uint64).sum() // OUT_PIXELS)
    th = min(255, max(0, mean + offset))
    return np.where(img > th, 255, 0).astype(np.uint8)


# ======================================================================
# 阶段 5：形态学闭运算
# ======================================================================

def _dilate(img: np.ndarray) -> np.ndarray:
    """3x3 最大值滤波，零边框。"""
    P = _zero_pad(img)
    h, w = img.shape
    acc = np.zeros((h, w), dtype=np.int64)
    for i in range(3):
        for j in range(3):
            acc = np.maximum(acc, P[i:i + h, j:j + w])
    return acc.astype(np.uint8)


def _erode(img: np.ndarray) -> np.ndarray:
    """3x3 最小值滤波，零边框。

    越界补零 → 0 会被取成最小值，这是腐蚀在边界的标准行为，
    也与 HLS 侧环缓冲清空后的行为一致。
    """
    P = _zero_pad(img)
    h, w = img.shape
    acc = np.full((h, w), 255, dtype=np.int64)
    for i in range(3):
        for j in range(3):
            acc = np.minimum(acc, P[i:i + h, j:j + w])
    return acc.astype(np.uint8)


def morph_close(img: np.ndarray, enable: int = 1) -> np.ndarray:
    """闭运算 = 先膨胀后腐蚀。

    两遍都是标准单级 3x3，中间结果按紧凑表示传递 ——
    与 HLS 的 morph_stage 两遍法一致。
    """
    if not enable:
        return passthrough(img)
    return _erode(_dilate(img))


# ======================================================================
# 全链
# ======================================================================

def gesture_preproc(rgb: np.ndarray, width: int, height: int,
                    roi_x: int, roi_y: int, roi_w: int, roi_h: int,
                    thresh_mode: int = 1,
                    thresh_offset: int = DEFAULT_THRESH_OFFSET,
                    gauss_en: int = 1,
                    sobel_en: int = 1,
                    morph_en: int = 1,
                    gain: int = DEFAULT_GAIN) -> np.ndarray:
    """完整预处理链，返回 96x96 uint8。

    参数顺序与 gesture_preproc() 的 axilite 参数一一对应。
    """
    x = crop_scale(rgb, width, height, roi_x, roi_y, roi_w, roi_h)
    x = gaussian(x, gauss_en)
    x = sobel(x, gain, sobel_en)
    x = adaptive_thresh(x, thresh_offset, thresh_mode)
    x = morph_close(x, morph_en)
    return x


# ======================================================================
# 自检：验证几条关键性质（不依赖 HLS 或 .bin 文件）
# ======================================================================

def self_test() -> int:
    fails = 0

    print("=" * 69)
    print("  Python golden 自检")
    print("=" * 69)
    print()

    # --- 性质 1：灰度转换的手算值 ---
    print("[1] RGB565 灰度转换 —— 与手算预期值对照")
    for v in (0, 64, 128, 255):
        # 构造纯灰 RGB565
        r5 = v >> 3
        g6 = v >> 2
        b5 = v >> 3
        rgb = (r5 << 11) | (g6 << 5) | b5
        got = int(rgb565_to_gray(np.array([[rgb]], dtype=np.uint16))[0, 0])
        r8, g8, b8 = (r5 << 3), (g6 << 2), (b5 << 3)
        expect = (r8 * Y_R + g8 * Y_G + b8 * Y_B) >> 8
        ok = got == expect
        if not ok:
            fails += 1
        print(f"     v={v:3d}  实得={got:3d}  预期={expect:3d}  "
              f"{'OK' if ok else 'FAIL'}")
    print()

    # --- 性质 2：直通必须是原值 ---
    print("[2] 直通语义 —— 必须是原值拷贝")
    a = (np.arange(OUT_PIXELS, dtype=np.uint8)
         .reshape(OUT_SIZE, OUT_SIZE) & 0xFF)
    lamp = passthrough(a)
    same = np.array_equal(lamp, a)
    if not same:
        fails += 1
    print(f"     与输入逐位相同 : {'OK' if same else 'FAIL'}")
    print()

    # --- 性质 3：零边框 → 边界行为可预测 ---
    print("[3] 零边框 —— 全零输入应产生全零输出（各级）")
    z = np.zeros((OUT_SIZE, OUT_SIZE), dtype=np.uint8)
    checks = {
        'gaussian': gaussian(z, 1),
        'sobel   ': sobel(z, 256, 1),
        'morph   ': morph_close(z, 1),
    }
    for name, out in checks.items():
        ok = not out.any()
        if not ok:
            fails += 1
        print(f"     {name} 全零 : {'OK' if ok else 'FAIL'}")
    print()

    # --- 性质 4：闭运算 —— 常数区域的幂等性 ---
    print("[4] 闭运算幂等性 —— 常数图应保持不变")
    c = np.full((OUT_SIZE, OUT_SIZE), 200, dtype=np.uint8)
    out = morph_close(c, 1)
    # 内部区域必须仍是 200；边缘因腐蚀补零会变小
    interior_ok = (out[2:-2, 2:-2] == 200).all()
    if not interior_ok:
        fails += 1
    print(f"     内部区域保持 200 : {'OK' if interior_ok else 'FAIL'}")
    print(f"     (边缘值 {out[0,0]} 变小属预期 —— 腐蚀的零边框所致)")
    print()

    # --- 性质 5：输出尺寸恒定 ---
    print("[5] 输出尺寸恒定 —— 与输入分辨率无关")
    for (w, h) in ((640, 480), (1280, 720), (320, 240)):
        rgb = np.zeros(w * h, dtype=np.uint16)
        out = gesture_preproc(rgb, w, h, (w - 320) // 2, (h - 320) // 2,
                              320, 320)
        ok = out.shape == (OUT_SIZE, OUT_SIZE)
        if not ok:
            fails += 1
        print(f"     输入 {w}x{h} → 输出 {out.shape[1]}x{out.shape[0]} : "
              f"{'OK' if ok else 'FAIL'}")
    print()

    print("=" * 69)
    print(f"  {'全部通过' if fails == 0 else str(fails) + ' 项失败'}")
    print("=" * 69)
    return fails


# ======================================================================
# CLI
# ======================================================================

def main():
    ap = argparse.ArgumentParser(
        description="手势预处理链 Python 参考实现")
    ap.add_argument("--self-test", action="store_true",
                    help="跑不依赖外部文件的自检")
    ap.add_argument("--input", help="输入 .bin（uint16 RGB565，行列优先）")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--out", help="输出 .bin（uint8 96x96）")
    ap.add_argument("--png", help="输出 PNG 便于肉眼查看")
    ap.add_argument("--no-gauss", action="store_true")
    ap.add_argument("--no-sobel", action="store_true")
    ap.add_argument("--no-morph", action="store_true")
    ap.add_argument("--no-thresh", action="store_true")
    ap.add_argument("--gain", type=int, default=DEFAULT_GAIN)
    ap.add_argument("--thresh-offset", type=int, default=DEFAULT_THRESH_OFFSET)
    ap.add_argument("--roi", type=int, nargs=4, metavar=("X", "Y", "W", "H"),
                    help="ROI 位置与尺寸")
    args = ap.parse_args()

    if args.self_test:
        return 1 if self_test() else 0

    if not args.input:
        ap.print_help()
        return 1

    rgb = np.fromfile(args.input, dtype=np.uint16)
    if rgb.size != args.width * args.height:
        print(f"错误：文件有 {rgb.size} 个元素，"
              f"与 {args.width}x{args.height}={args.width*args.height} 不符",
              file=sys.stderr)
        return 1

    if args.roi:
        rx, ry, rw, rh = args.roi
    else:
        rw = rh = min(320, args.width, args.height)
        rx = (args.width - rw) // 2
        ry = (args.height - rh) // 2

    out = gesture_preproc(
        rgb, args.width, args.height, rx, ry, rw, rh,
        thresh_mode=0 if args.no_thresh else 1,
        thresh_offset=args.thresh_offset,
        gauss_en=0 if args.no_gauss else 1,
        sobel_en=0 if args.no_sobel else 1,
        morph_en=0 if args.no_morph else 1,
        gain=args.gain)

    if args.out:
        out.tofile(args.out)
        print(f"已写出 {args.out}  ({out.size} 字节)")

    if args.png:
        from PIL import Image
        Image.fromarray(out, mode='L').resize(
            (OUT_SIZE * 4, OUT_SIZE * 4), Image.NEAREST).save(args.png)
        print(f"已写出 {args.png}")

    if not args.out and not args.png:
        print(f"输出统计: min={out.min()} max={out.max()} "
              f"mean={out.mean():.1f} 非零={int((out > 0).sum())}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
