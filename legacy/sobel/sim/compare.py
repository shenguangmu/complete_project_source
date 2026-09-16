#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
compare.py —— 比对 HLS 仿真输出与 Python golden，输出差异报告

HLS C 仿真本身已经做了逐像素比对。本脚本补充两件事：

  1. 更友好的报告 —— 差异定位、分布、是否呈"整体偏移"形态
  2. 图像化输出 —— 并排导出 PNG，直观确认边缘形状一致

用法:
    # 只跑自检（向量 vs golden，验证参考模型自身）
    python sim/compare.py

    # 比对一份外部输出（HLS csim 导出的或板上回传的）
    python sim/compare.py --out path/to/output.txt --gold sim/vectors/shapes_gold.txt

    # 指定尺寸（输出文件不带尺寸头时）
    python sim/compare.py --out out.txt --gold gold.txt --size 64x64 --raw
"""

import argparse
import os
import sys
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_ROOT, "host"))

from sobel_ref import TEST_IMAGES, sobel_numpy  # noqa: E402


def load_image(path, raw=False, size=None):
    """
    读图。
    raw=True 时文件只含像素值，尺寸由 size 参数给出；
    否则第一行是 "宽 高"。
    """
    if raw:
        with open(path) as f:
            vals = [int(x) for x in f.read().split()]
        if size is None:
            raise ValueError("--raw 模式必须提供 --size")
        w, h = size
        if len(vals) < w * h:
            raise ValueError(f"数据不足: 需要 {w*h} 个，只有 {len(vals)} 个")
        return np.array(vals[:w * h], dtype=np.uint8).reshape(h, w)

    with open(path) as f:
        w, h = (int(x) for x in f.readline().split())
        vals = [int(x) for x in f.read().split()]
    if len(vals) < w * h:
        raise ValueError(f"数据不足: 需要 {w*h} 个，只有 {len(vals)} 个")
    return np.array(vals[:w * h], dtype=np.uint8).reshape(h, w)


def psnr(a, b):
    """峰值信噪比。完全一致返回 inf"""
    a = a.astype(np.float64)
    b = b.astype(np.float64)
    mse = np.mean((a - b) ** 2)
    if mse == 0:
        return float("inf")
    return 10.0 * np.log10(255.0 ** 2 / mse)


def analyze_diff(got, exp, name=""):
    """分析差异模式，返回 (是否一致, 报告字符串)"""
    if got.shape != exp.shape:
        return False, f"尺寸不符: got={got.shape} exp={exp.shape}"

    diff = got.astype(np.int32) - exp.astype(np.int32)
    n_bad = int(np.count_nonzero(diff))
    total = diff.size

    if n_bad == 0:
        return True, f"完全一致 ({total} 像素)"

    lines = []
    lines.append(f"差异像素 {n_bad}/{total} ({100.0*n_bad/total:.2f}%)")
    lines.append(f"最大绝对误差 {int(np.abs(diff).max())}")
    lines.append(f"PSNR {psnr(got, exp):.2f} dB")

    # 判定差异形态，帮助定位原因
    ys, xs = np.nonzero(diff)
    lines.append(f"差异范围: x∈[{xs.min()},{xs.max()}]  y∈[{ys.min()},{ys.max()}]")

    h, w = diff.shape
    on_border = np.count_nonzero(
        (ys == 0) | (ys == h - 1) | (xs == 0) | (xs == w - 1))
    if on_border == n_bad:
        lines.append("形态: 全部落在图像边界 → 边界补零策略不一致")
    elif on_border > n_bad * 0.8:
        lines.append("形态: 集中在边界 → 疑似边界处理 off-by-one")
    else:
        lines.append("形态: 遍布内部 → 疑似算法规约不同（移位/饱和/增益）")

    # 前几个差异点
    lines.append("前 8 个差异点:")
    for i in range(min(8, n_bad)):
        y, x = int(ys[i]), int(xs[i])
        lines.append(f"  ({x},{y}) exp={int(exp[y,x])} got={int(got[y,x])} "
                     f"差={int(diff[y,x])}")

    return False, "\n".join(lines)


def render_side_by_side(src, exp, got, path):
    """把原图/golden/硬件输出并排成一张 PNG"""
    try:
        from PIL import Image
    except ImportError:
        return False, "未安装 Pillow，跳过图像输出（pip install pillow）"

    def to_img(a):
        return Image.fromarray(a, mode="L").convert("RGB")

    imgs = []
    if src is not None:
        imgs.append(to_img(src))
    imgs.append(to_img(exp))
    imgs.append(to_img(got))

    gap = 8
    W = sum(i.width for i in imgs) + gap * (len(imgs) - 1)
    H = max(i.height for i in imgs)
    canvas = Image.new("RGB", (W, H), (40, 40, 40))

    x = 0
    for i in imgs:
        canvas.paste(i, (x, 0))
        x += i.width + gap

    canvas = canvas.resize((W * 4, H * 4), Image.NEAREST)
    canvas.save(path)
    return True, path


def main():
    ap = argparse.ArgumentParser(description="Sobel 输出比对工具")
    ap.add_argument("--out",  help="待测输出文件")
    ap.add_argument("--gold", help="golden 文件")
    ap.add_argument("--src",  help="原始输入图（可选，仅用于拼图）")
    ap.add_argument("--raw",  action="store_true",
                    help="输出文件无尺寸头，纯像素值")
    ap.add_argument("--size", help="--raw 时指定尺寸，形如 64x64")
    ap.add_argument("--png",  default="diff_report.png", help="拼图输出路径")
    ap.add_argument("--no-png", action="store_true", help="不输出 PNG")
    args = ap.parse_args()

    # ---- 模式一：无参数 → 跑参考模型自检 ----
    if not args.out:
        print("=" * 60)
        print("  参考模型自检：向量化实现 vs 逐像素实现")
        print("=" * 60)
        all_ok = True
        for name, (fn, w, h) in TEST_IMAGES.items():
            img = fn(w, h)
            a = sobel_numpy(img)
            # 逐像素实现较慢，大图抽样即可
            from sobel_ref import sobel_pixelwise
            if img.size <= 4096:
                b = sobel_pixelwise(img)
                same = np.array_equal(a, b)
                all_ok &= same
                print(f"  {name:12s} {w:>3d}x{h:<3d}  {'一致' if same else '不一致!'}")
        print("=" * 60)
        print("  " + ("全部一致" if all_ok else "存在不一致，请检查 sobel_ref.py"))
        return 0 if all_ok else 1

    # ---- 模式二：比对两份文件 ----
    if not args.gold:
        print("错误: 指定了 --out 就必须同时指定 --gold")
        return 2

    size = None
    if args.size:
        w, h = args.size.lower().split("x")
        size = (int(w), int(h))

    got = load_image(args.out, raw=args.raw, size=size)
    exp = load_image(args.gold)

    print("=" * 60)
    print(f"  待测: {args.out}  {got.shape[1]}x{got.shape[0]}")
    print(f"  基准: {args.gold}  {exp.shape[1]}x{exp.shape[0]}")
    print("=" * 60)

    ok, report = analyze_diff(got, exp)
    print(report)

    if not args.no_png:
        src = None
        if args.src:
            src = load_image(args.src, raw=args.raw, size=size)
        made, msg = render_side_by_side(src, exp, got, args.png)
        print(f"\n拼图: {msg}" if made else f"\n{msg}")

    print("=" * 60)
    print("  PASS" if ok else "  FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
