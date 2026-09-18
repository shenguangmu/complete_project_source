#!/usr/bin/env python3
"""
bench_ps_baseline.py ---- PS 侧（CPU）基线：同一预处理链的软件耗时

【这个脚本回答什么问题】

赛题 §3.3.4 要求"给出与基线的对比"。本脚本产出**基线那一半**：
把与 PL 侧**完全相同的算法**（`gesture_golden.py`，已与 C++ golden 逐位一致）
在 CPU 上跑，测单帧耗时。

    ┌─ PL 侧：gesture_preproc（HLS），实测见 vivado/build-report.md
    └─ PS 侧：本脚本

[!] **这是"PS 侧"基线，不是"纯 CPU 基线"的二选一** ----
本项目 PS 就是 Cortex-A9，所以这个数直接对应"如果不用 PL 加速会怎样"。

【怎么用】

    python host/bench_ps_baseline.py                    # 合成随机图，跑默认帧数
    python host/bench_ps_baseline.py --frames 50
    python host/bench_ps_baseline.py --json bench.json  # 落盘，供报告引用

【[!] 计量口径 ---- 别把数字用错】

  * 这里测的是 **CPU 墙钟时间**，不含 DDR 搬运。
    PL 侧的对应量是 **HLS 报告的 latency**，同样不含 DMA 搬运。
    两者口径一致，可比。
  * PL 侧的 **吞吐**还受 DMA 与 DDR 带宽限制，会低于纯计算延迟。
    所以本脚本给出的是**算法计算量的对比**，不是端到端帧率的对比。
  * 结果依赖运行机器。**报告里必须写明 CPU 型号**，
    否则数字不可复现（赛题 §3.3.4 明确要求"数据真实完整"）。
"""

import argparse
import json
import platform
import sys
import time
from pathlib import Path

import numpy as np

# 复用已验证的 golden 实现 ---- 不另写一套，避免语义偏差
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gesture_golden import gesture_preproc, OUT_SIZE, OUT_PIXELS   # noqa: E402


def make_test_frame(width: int, height: int, seed: int = 12345) -> np.ndarray:
    """合成一帧 RGB565 测试图。

    [!] 用固定种子 ---- 否则每次跑的数据不同，耗时不稳、结果不可复现。
    内容不追求"像照片"，只要不是纯色（纯色会让某些分支走极端路径）。
    """
    rng = np.random.default_rng(seed)
    # RGB565：高 5 位 R、中 6 位 G、低 5 位 B
    r = rng.integers(0, 32, size=(height, width), dtype=np.uint16)
    g = rng.integers(0, 64, size=(height, width), dtype=np.uint16)
    b = rng.integers(0, 32, size=(height, width), dtype=np.uint16)
    return ((r << 11) | (g << 5) | b).astype(np.uint16)


def bench(width: int, height: int, frames: int, warmup: int,
          roi_w: int, roi_h: int) -> dict:
    """跑 frames 次，返回统计量（毫秒/帧）。"""
    rgb = make_test_frame(width, height)
    rx = (width - roi_w) // 2
    ry = (height - roi_h) // 2

    def one() -> np.ndarray:
        return gesture_preproc(rgb, width, height, rx, ry, roi_w, roi_h)

    # 预热：让 numpy 完成首次分配、CPU 升频
    for _ in range(warmup):
        one()

    ts = []
    for _ in range(frames):
        t0 = time.perf_counter()
        out = one()
        ts.append((time.perf_counter() - t0) * 1e3)   # ms

    ts = np.asarray(ts)
    return {
        "frames": frames,
        "warmup": warmup,
        "ms_mean": float(ts.mean()),
        "ms_median": float(np.median(ts)),
        "ms_min": float(ts.min()),
        "ms_max": float(ts.max()),
        "ms_std": float(ts.std()),
        "fps_from_mean": float(1000.0 / ts.mean()),
        "out_sum": int(out.sum()),          # 校验用：确认真的算出了东西
        "out_shape": list(out.shape),
    }


def main() -> int:
    ap = argparse.ArgumentParser(
        description="预处理链纯软件耗时（主机参考值，非 PS 基线）")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--frames", type=int, default=30,
                    help="计时帧数（默认 30）")
    ap.add_argument("--warmup", type=int, default=3,
                    help="预热帧数（默认 3，不计入统计）")
    ap.add_argument("--roi", type=int, nargs=4, metavar=("X", "Y", "W", "H"),
                    help="ROI 位置与尺寸；省略则取居中的 320x320")
    ap.add_argument("--json", metavar="PATH",
                    help="把结果写成 JSON（供报告引用）")
    args = ap.parse_args()

    if args.roi:
        _, _, roi_w, roi_h = args.roi
    else:
        roi_w = roi_h = min(320, args.width, args.height)

    print("=" * 69)
    print("  预处理链纯软件耗时（主机参考值，非 PS 基线）")
    print("=" * 69)
    print()
    print(f"  输入        : {args.width}x{args.height} RGB565")
    print(f"  ROI         : {roi_w}x{roi_h}（居中）")
    print(f"  输出        : {OUT_SIZE}x{OUT_SIZE} uint8 = {OUT_PIXELS} 字节")
    print(f"  CPU         : {platform.processor() or platform.machine()}")
    print(f"  Python      : {platform.python_version()}")
    print(f"  numpy       : {np.__version__}")
    print(f"  计时        : {args.frames} 帧 + {args.warmup} 帧预热")
    print()

    res = bench(args.width, args.height, args.frames, args.warmup,
                roi_w, roi_h)

    # 健全性检查：确认真的算出了非平凡结果（不是全 0 也不是全 255）
    s, n = res["out_sum"], OUT_PIXELS
    if s == 0 or s == 255 * n:
        print(f"  [!] 输出是常量（sum={s}/{255*n}）---- "
              f"测试图或参数可能有问题，这个耗时不代表真实负载")
    else:
        print(f"  输出校验    : sum={s}（均值 {s/n:.1f}/255，非平凡 [OK]）")
    print()

    print(f"  中位数      : {res['ms_median']:8.3f} ms/帧")
    print(f"  平均值      : {res['ms_mean']:8.3f} ms/帧  (±{res['ms_std']:.3f})")
    print(f"  最小 / 最大 : {res['ms_min']:.3f} / {res['ms_max']:.3f} ms")
    print(f"  对应帧率    : {res['fps_from_mean']:8.2f} fps（按平均值）")
    print()

    print("=" * 69)
    print("  [!] 口径说明（写报告时必须一起给出，否则数字会被误读）")
    print("=" * 69)
    print("  - 这是**主机 CPU** 的耗时，**不代表 PYNQ-Z2 的 Cortex-A9**。")
    print("    两者差着代际，直接当 PS 基线会被挑。")
    print("  - 报告里要的是**板到后在 PYNQ 上跑出来的**数（本脚本可直接拷过去用）。")
    print("  - 不含 DDR 搬运；PL 侧对应量是 HLS 的 latency，同样不含搬移。")
    print("  - 任何 CPU 数字都必须写明型号，否则不可复现。")

    if args.json:
        out = {
            "kind": "host_cpu_reference",
            "input": f"{args.width}x{args.height}",
            "roi": f"{roi_w}x{roi_h}",
            "output_bytes": OUT_PIXELS,
            "cpu": platform.processor() or platform.machine(),
            "python": platform.python_version(),
            "numpy": np.__version__,
            **res,
        }
        Path(args.json).write_text(
            json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\n  结果已写入: {args.json}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
