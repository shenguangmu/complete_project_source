#!/usr/bin/env python3
"""
dump_frame.py —— 帧数据转储与对拍工具

用在**两个地方**，这正是它的价值：

    1. 板上：把 DDR 里的 96x96 帧 dump 成 .bin，拷到 PC
    2. PC 上：读同一个 .bin，与 Python golden 或 HLS 输出比对、出图

因为两侧用的是**同一份数据文件**，所以能直接回答
"到底是 PL 侧传错了，还是 CNN 侧读错了"。

=====================================================================
  典型用法
=====================================================================
    # 【PC】生成一张测试图 + 跑 golden，产出 .bin
    python dump_frame.py make-test --out test.bin

    # 【板】dump 实际结果（在 PYNQ 的 Jupyter 里调 GesturePipeline）
    #   g.stats(); g.out_buf.tofile("board.bin")

    # 【PC】比对板上结果与 golden
    python dump_frame.py compare board.bin test.bin

    # 【PC】出图（放大 4 倍，便于肉眼看清 96x96）
    python dump_frame.py show board.bin --png out.png

    # 【PC】看统计（判断"全黑/全白"这类明显问题）
    python dump_frame.py stats board.bin

=====================================================================
  [!] 数据格式约定（与 CNN 侧必须一致）
=====================================================================
    裸 .bin，无文件头
    uint8
    96x96
    行优先（row-major）
    共 9216 字节

  没有文件头是**故意的** —— 加了头就要两侧同步解析逻辑，
  而我们要的是"任何工具都能直接读"。
  旁边放个 .txt 记元信息比塞进文件头更灵活。
"""

import argparse
import os
import sys

import numpy as np

OUT_SIZE   = 96
OUT_PIXELS = OUT_SIZE * OUT_SIZE   # 9216


# =====================================================================
#  读 / 写
# =====================================================================

def load_frame(path):
    """读一个帧文件，返回 (96,96) uint8 数组。

    !! 严格校验长度 —— 长度不对时报错而不是"尽力解析"。
      长度错的常见原因：dump 时用了 reshape(96,96) 但 buffer 没截断，
      或者 DMA 写多了/少了字节。
    """
    if not os.path.exists(path):
        raise FileNotFoundError("找不到文件: %s" % path)

    raw = np.fromfile(path, dtype=np.uint8)
    if raw.size != OUT_PIXELS:
        raise ValueError(
            "文件大小不对: %s\n"
            "  实际 %d 字节，期望 %d 字节（96x96 uint8）\n"
            "  多出的部分说明 DMA 写超了，少的说明没写满。"
            % (path, raw.size, OUT_PIXELS))
    return raw.reshape(OUT_SIZE, OUT_SIZE)


def save_frame(img, path):
    """把 (96,96) 数组存成裸 .bin

    !! 用 tofile 而不是 np.save —— 后者会加 .npy 文件头，
      非 Python 工具（含 HLS 的 C 代码）读不了。
    """
    img = np.asarray(img, dtype=np.uint8)
    if img.size != OUT_PIXELS:
        raise ValueError("数组大小不对: %d，期望 %d" % (img.size, OUT_PIXELS))
    img.tofile(path)
    print("已写出 %s (%d 字节)" % (path, img.size))


# =====================================================================
#  统计
# =====================================================================

def describe(img, name=""):
    """打印统计信息 —— 判断"全黑/全白"这类明显问题"""
    nz = int((img > 0).sum())
    tag = (" [%s]" % name) if name else ""
    print("=== 帧统计%s ===" % tag)
    print("  尺寸    : %dx%d (%d 字节)" % (img.shape[1], img.shape[0], img.size))
    print("  最小值  : %d" % img.min())
    print("  最大值  : %d" % img.max())
    print("  均值    : %.2f" % img.mean())
    print("  非零像素: %d / %d (%.1f%%)" % (
        nz, img.size, 100.0 * nz / img.size))

    # 常见异常的直接判据
    if img.max() == 0:
        print("  [!!] 全黑 —— 可能是：阈值太高 / 输入没进来 / DMA 没跑")
    elif img.min() == 255:
        print("  [!!] 全白 —— 可能是：阈值太低 / 输入全亮")
    elif nz == 0 or nz == img.size:
        print("  [!!] 恒定输出 —— 检查阈值与输入是否有变化")
    else:
        print("  [OK] 有明暗变化")

    # 分块统计 —— 能看出"是不是只有一块有内容"（ROI 位置问题）
    print("  分块均值（4x4 网格）:")
    bh, bw = OUT_SIZE // 4, OUT_SIZE // 4
    for r in range(4):
        row = []
        for c in range(4):
            blk = img[r*bh:(r+1)*bh, c*bw:(c+1)*bw]
            row.append("%5.0f" % blk.mean())
        print("     " + " ".join(row))


# =====================================================================
#  比对
# =====================================================================

def compare(a_path, b_path, tol=0):
    """逐像素比对两个帧文件

    tol=0 表示要求逐位一致（PL 与 golden 应当如此）。
    """
    a = load_frame(a_path)
    b = load_frame(b_path)

    if a.shape != b.shape:
        print("FAIL: 尺寸不同 %s vs %s" % (a.shape, b.shape))
        return 1

    diff = np.abs(a.astype(np.int16) - b.astype(np.int16))
    n_bad = int((diff > tol).sum())

    print("=== 比对 ===")
    print("  A: %s" % a_path)
    print("  B: %s" % b_path)
    print("  容差: %d" % tol)
    print()

    if n_bad == 0:
        print("*** 逐位一致 (%d 像素) ***" % a.size)
        return 0

    print("*** 不一致: %d / %d 像素 (%.1f%%) ***" % (
        n_bad, a.size, 100.0 * n_bad / a.size))
    print("  最大差异: %d" % diff.max())
    print("  平均差异: %.2f" % diff.mean())

    # 首个不一致位置
    ys, xs = np.where(diff > tol)
    print("\n  前 5 处差异:")
    for i in range(min(5, len(ys))):
        y, x = int(ys[i]), int(xs[i])
        print("    (y=%2d, x=%2d)  A=%3d  B=%3d  差=%d" % (
            y, x, a[y, x], b[y, x], diff[y, x]))

    # 差异分布 —— 区分"整体偏移"和"局部错误"
    edge = ((ys < 3) | (ys > OUT_SIZE-4) | (xs < 3) | (xs > OUT_SIZE-4)).sum()
    print("\n  差异分布: 边缘 %d, 内部 %d" % (edge, len(ys) - edge))
    if edge > len(ys) * 0.7:
        print("  [!!] 差异集中在边缘 —— 多半是边界/对齐问题，不是算法错")
    else:
        print("  [!!] 差异在内部 —— 多半是算法或数据问题")

    return 1


# =====================================================================
#  出图
# =====================================================================

def show(path, png=None, scale=4, side_by_side=None):
    """出图。96x96 太小，默认放大 4 倍。"""
    from PIL import Image

    img = load_frame(path)
    im = Image.fromarray(img, mode='L')
    if scale > 1:
        im = im.resize((OUT_SIZE*scale, OUT_SIZE*scale), Image.NEAREST)

    if side_by_side:
        other = load_frame(side_by_side)
        im2 = Image.fromarray(other, mode='L')
        if scale > 1:
            im2 = im2.resize((OUT_SIZE*scale, OUT_SIZE*scale), Image.NEAREST)
        # 横向拼接，中间留 10 像素白缝
        W = im.width * 2 + 10
        H = im.height
        canvas = Image.new('L', (W, H), 255)
        canvas.paste(im,  (0, 0))
        canvas.paste(im2, (im.width + 10, 0))
        im = canvas
        print("左: %s   右: %s" % (path, side_by_side))

    if png:
        im.save(png)
        print("已写出 %s" % png)
    else:
        im.show()


# =====================================================================
#  造测试图
# =====================================================================

def make_test(out_path):
    """生成一张可预测的测试帧。

    !! 用"左暗右亮的渐变"而不是随机数 ——
      输出全黑/全白时一眼能看出是阈值问题，
      而随机图出错时分辨不出"是数据错还是本该如此"。

    注意：这是**已经预处理完的 96x96**，
    用来测 CNN 那侧或做对拍基准，不是 640x480 的原图。
    """
    img = np.zeros((OUT_SIZE, OUT_SIZE), dtype=np.uint8)
    # 水平渐变 0..255
    for x in range(OUT_SIZE):
        img[:, x] = x * 255 // (OUT_SIZE - 1)
    # 居中放一个暗方块，制造"明确的前景区域"
    img[32:64, 32:64] = 0

    save_frame(img, out_path)
    describe(img, os.path.basename(out_path))
    return 0


# =====================================================================
#  CLI
# =====================================================================

def main():
    ap = argparse.ArgumentParser(
        description="帧数据转储与对拍工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python dump_frame.py make-test --out test.bin
  python dump_frame.py stats board.bin
  python dump_frame.py compare board.bin test.bin
  python dump_frame.py show board.bin --png out.png
  python dump_frame.py show board.bin --side-by-side golden.bin --png cmp.png
""")

    sub = ap.add_subparsers(dest='cmd', required=True)

    p1 = sub.add_parser('make-test', help='生成一张可预测的测试帧')
    p1.add_argument('--out', required=True, help='输出 .bin 路径')

    p2 = sub.add_parser('stats', help='打印统计信息')
    p2.add_argument('file')

    p3 = sub.add_parser('compare', help='逐像素比对')
    p3.add_argument('a')
    p3.add_argument('b')
    p3.add_argument('--tol', type=int, default=0, help='容差，默认 0（逐位一致）')

    p4 = sub.add_parser('show', help='出图')
    p4.add_argument('file')
    p4.add_argument('--png', help='存成 PNG（不指定则弹窗显示）')
    p4.add_argument('--scale', type=int, default=4, help='放大倍数，默认 4')
    p4.add_argument('--side-by-side', help='与另一个文件并排显示')

    args = ap.parse_args()

    if args.cmd == 'make-test':
        return make_test(args.out)
    elif args.cmd == 'stats':
        describe(load_frame(args.file), os.path.basename(args.file))
        return 0
    elif args.cmd == 'compare':
        return compare(args.a, args.b, args.tol)
    elif args.cmd == 'show':
        show(args.file, args.png, args.scale, args.side_by_side)
        return 0


if __name__ == '__main__':
    sys.exit(main())
