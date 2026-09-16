#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_vectors.py —— 生成测试图与 golden 向量，供 HLS C 仿真使用

输出到 sim/vectors/ 下，每种测试图两个文件:

    <name>_in.txt     输入灰度图
    <name>_gold.txt   golden 边缘图（由 host/sobel_ref.py 算出）

文件格式（纯文本，C 端用 fscanf 读，简单可靠）:
    第 1 行:  <width> <height>
    其后:     height*width 个整数，每行一个，取值 0..255

为什么用文本而不是二进制:
    方便肉眼 diff、方便 git 追踪、跨平台无字节序问题。
    代价是文件大一点 —— 测试图最大 64x64，无所谓。

用法:
    python sim/gen_vectors.py            # 默认 gain=256, thresh=0
    python sim/gen_vectors.py --thresh 64
"""

import argparse
import os
import sys

# 让脚本能从项目根或 sim/ 目录下运行
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_ROOT, "host"))

from sobel_ref import TEST_IMAGES, sobel_numpy  # noqa: E402


def write_image(path, img):
    """按约定格式写一张 8-bit 灰度图"""
    h, w = img.shape
    with open(path, "w", encoding="ascii") as f:
        f.write(f"{w} {h}\n")
        for row in img:
            for v in row:
                f.write(f"{int(v)}\n")


def main():
    ap = argparse.ArgumentParser(description="生成 Sobel 测试向量")
    ap.add_argument("--thresh", type=int, default=0,
                    help="阈值，0 表示不二值化（默认）")
    ap.add_argument("--gain", type=int, default=256,
                    help="Q8 增益，256 = x1.0（默认）")
    ap.add_argument("--outdir", default=os.path.join(_ROOT, "sim", "vectors"),
                    help="输出目录")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    print(f"输出目录 : {args.outdir}")
    print(f"参数     : thresh={args.thresh}  gain={args.gain}")
    print("-" * 58)

    manifest = []
    for name, (fn, w, h) in TEST_IMAGES.items():
        img = fn(w, h)
        gold = sobel_numpy(img, thresh=args.thresh, gain=args.gain)

        in_path = os.path.join(args.outdir, f"{name}_in.txt")
        gd_path = os.path.join(args.outdir, f"{name}_gold.txt")
        write_image(in_path, img)
        write_image(gd_path, gold)

        n_edge = int((gold > 0).sum())
        manifest.append((name, w, h, n_edge))
        print(f"{name:12s} {w:>4d}x{h:<4d}  边缘像素 {n_edge:>5d} / {w*h}")

    # 写一份清单，testbench 可以按行遍历（C 端文件名硬编码亦可）
    mani_path = os.path.join(args.outdir, "manifest.txt")
    with open(mani_path, "w", encoding="ascii") as f:
        f.write(f"# thresh={args.thresh} gain={args.gain}\n")
        f.write(f"# name width height edge_pixels\n")
        for name, w, h, n in manifest:
            f.write(f"{name} {w} {h} {n}\n")

    print("-" * 58)
    print(f"共 {len(manifest)} 组向量，清单: {mani_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
