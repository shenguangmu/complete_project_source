#!/usr/bin/env python3
"""
bringup_check.py —— 板到当天的**分步验证脚本**（在 PYNQ 板上跑）

【这个脚本解决什么问题】

`docs/board-bringup-guide.md` §5 把验证分成 10 步，每步判定标准都写清楚了，
但**代码是逐段贴在文档里的**。板子到的那天，边读文档边拼代码是最容易出错的
时候 —— 尤其是：

  · 顺序（先 S2MM 再 MM2S 再 ap_start，反了就丢数据）
  · 位宽（有符号参数必须按 32 位补码写，见 host/gesture_overlay.py 头部）
  · cache（填完输入要 flush）

本脚本把 §5 里**不需要摄像头**的两步（②③）做成可直接跑的：
    ② DDR 与 buffer 基本自检
    ③ 只跑预处理链

**摄像头相关的 ④~⑧ 需要示波器/逻辑分析仪，本脚本不做** ——
它只负责把"摄像头之外的变量"全部钉死。这样摄像头一插上，
出问题就只剩摄像头一条线。

【怎么用】

    # 把整个仓库拷到板上（或至少 host/ 目录）
    python3 bringup_check.py                 # 跑全部（②③）
    python3 bringup_check.py --step 2        # 只跑 DDR 自检
    python3 bringup_check.py --step 3        # 只跑预处理链
    python3 bringup_check.py --json r.json   # 把耗时落盘（报告要用）

    # 指定 overlay（默认按 PYNQ 惯例找同名 .bit/.hwh）
    python3 bringup_check.py --bit /path/to/gesture_system.bit

【判定】

每步打印 [ OK ] / [FAIL]，最后打印汇总。
看到 `*** BRINGUP CHECK PASSED ***` 才算这一步真的过了。

⚠ 步骤 ③ 通过 = **数据通路（DDR→DMA→IP→DMA→DDR）是好的**，
  不代表算法结果对。算法正确性由 csim/上板对拍负责，
  见 docs/board-bringup-guide.md §5.5。
"""

import argparse
import io
import json
import sys
import time
from pathlib import Path

# ⚠ Windows 控制台默认 GBK，打印 ⚠ / → 这类字符会 UnicodeEncodeError 崩掉。
#   在 PYNQ（Linux，UTF-8）上本来没问题，但本脚本也可能在 PC 上被误跑
#   （做语法检查或看帮助），所以这里统一包一层。
#   用 errors='replace' 而不是 'strict' —— 宁可显示成 ?，也不要崩在半路。
try:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8',
                                  errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8',
                                  errors='replace')
except Exception:
    pass

sys.path.insert(0, str(Path(__file__).resolve().parent))

_passed = 0
_failed = 0


def _c(ok, msg):
    global _passed, _failed
    if ok:
        _passed += 1
        print("    [ OK ] %s" % msg)
    else:
        _failed += 1
        print("    [FAIL] %s" % msg)
    return ok


# =====================================================================
def step2_ddr():
    """② DDR 与 buffer 基本自检 —— 不需要摄像头，不需要 overlay

    ⚠ 这一步失败 = PS DDR 配置有问题，**后面所有步骤都不必做**。
      对应 board-bringup-guide.md §5.1 / §1.4。
    """
    print("\n" + "=" * 69)
    print("  ② DDR 与 buffer 基本自检")
    print("=" * 69)

    try:
        from pynq import allocate
    except ImportError:
        # ⚠ 这里必须让 _failed 动 —— 不能只 print。
        #   否则末尾会打出 "PASSED"，造成"显示了 FAIL 却报通过"的假成功。
        #   （这个 bug 在本脚本第一版里真实存在过，被 --step 2 的试跑抓到。）
        print("    [FAIL] 连 pynq 都 import 不了 —— 你确定在板上跑？")
        return _fail()


def _fail():
    """记一次失败并返回 False（给不在 _c() 调用链上的早退用）"""
    global _failed
    _failed += 1
    return False

    import numpy as np

    buf = allocate(shape=(9216,), dtype=np.uint8)
    buf[:] = np.arange(9216, dtype=np.uint8)
    buf.flush()                      # ⚠ 别省，见 gesture_overlay.py 的说明

    ok = True
    ok &= _c(np.array_equal(buf, np.arange(9216, dtype=np.uint8)),
             "写入 9216 字节后读回一致")
    ok &= _c(buf.physical_address != 0,
             "物理地址非 0：0x%08X" % buf.physical_address)
    ok &= _c(buf.physical_address % 4 == 0,
             "物理地址 4 字节对齐（DMA 要求）")

    # 大 buffer：614400 字节 = 一帧 RGB565。这是真正常用的那个尺寸
    big = allocate(shape=(640 * 480 * 2,), dtype=np.uint8)
    ok &= _c(big.physical_address != 0,
             "614400 字节 buffer 分配成功 @ 0x%08X" % big.physical_address)

    del buf, big
    print("    判定：以上全过 → DDR 没问题，可以往 ③ 走")
    print("    失败 → 回 board-bringup-guide.md §1.4（DDR 参数）")
    return ok


# =====================================================================
def step3_pipeline(bitfile=None):
    """③ 只跑预处理链 —— 不碰摄像头

    这是**当前最该先做的事**：把摄像头这个最大的不确定性排除在外。
    对应 board-bringup-guide.md §5.2。
    """
    print("\n" + "=" * 69)
    print("  ③ 只跑预处理链（不碰摄像头）")
    print("=" * 69)

    try:
        from gesture_overlay import GesturePipeline
    except ImportError as e:
        print("    [FAIL] import gesture_overlay 失败：%s" % e)
        return False

    ok = True

    # ---- 3a. 加载 overlay + 认 IP ----
    print("\n  [3a] 加载 overlay 并认 IP")
    try:
        gp = GesturePipeline(bitfile) if bitfile else GesturePipeline()
    except Exception as e:
        print("    [FAIL] overlay 加载/认 IP 失败：%s" % e)
        print("       → 若报『没找到这些 IP』，对照上面列出的实际 IP 名调整匹配")
        print("       → 若报『歧义』，说明 dma_in/dma_out 名字互相命中")
        return False

    gp.print_info()
    ok &= _c(True, "overlay 加载成功，三个 IP 都认到了")
    ok &= _c(len(gp.ip) == 3,
             "认到 3 个 IP：preproc / dma_in / dma_out（实得 %d）" % len(gp.ip))

    # ---- 3b. 分配 DMA 缓冲 ----
    print("\n  [3b] 分配 DMA 缓冲")
    gp.setup_dma()

    # ---- 3c. 配置 + 回读断言 ----
    print("\n  [3c] 配置预处理参数（含回读断言）")
    try:
        gp.config(thresh_mode=1, thresh_offset=-8, gain=256,
                  gauss_en=1, sobel_en=1, morph_en=1, roi_w=320, roi_h=320)
        ok &= _c(True, "配置写入成功，且 thresh_offset 回读 == -8")
    except Exception as e:
        ok &= _c(False, "配置失败：%s" % e)
        print("       ⚠ 若回读是 248 而不是 -8，说明有符号补码位宽写错了")
        return False

    # ---- 3d. 填测试图并跑一帧 ----
    print("\n  [3d] 填测试图案并跑一帧")
    gp.fill_test_pattern()

    try:
        dt = gp.run_once(timeout=10.0)
        ok &= _c(True, "跑完一帧，耗时 %.3f s" % dt)
    except Exception as e:
        ok &= _c(False, "run_once 失败：%s" % e)
        print("\n    ⚠ 注意：这一步**不需要摄像头**也能完成。")
        print("      若卡在等 ap_done超时，按下面顺序查：")
        print("        1) overlay 是不是加载对了版本（.hwh 与 .bit 要配套）")
        print("        2) ip_dict 里的地址与 hwh 一致吗（print_info 已打印）")
        print("        3) dma_in/dma_out 有没有认反（认反了会死锁）")
        return False

    # ---- 3e. 检查输出不是常量 ----
    print("\n  [3e] 检查输出（关键：不能是常量）")
    import numpy as np
    out = gp.get_result()
    nz = int(np.count_nonzero(out))
    total = out.size

    # ⚠ 只检查"非平凡"，不检查"算得对" ——
    #   算得对要靠 csim 与上板对拍（board-bringup-guide.md §5.5）。
    #   这里能确认的是：**数据真的流过整条链了**。
    ok &= _c(nz > 0, "输出不全黑（非零 %d/%d）" % (nz, total))
    ok &= _c(nz < total, "输出不全白（非零 %d/%d）" % (nz, total))
    ok &= _c(out.shape == (96, 96), "输出形状是 96x96（实得 %s）" % (out.shape,))

    if nz == 0:
        print("\n    ⚠ 全黑。常见原因（按出现频率）：")
        print("      · thresh_offset 写错位宽 → 阈值被抬到 255（见 [3c] 的回读）")
        print("      · 输入 buffer 没 flush → DMA 搬的是旧数据")
        print("      · 测试图 ROI 区域是纯色 → 阈值后无边缘")
    elif nz == total:
        print("\n    ⚠ 全白。常见原因：")
        print("      · thresh_offset 是很大的负数")
        print("      · 输入全亮 → 均值阈值失效")

    return ok


# =====================================================================
def main():
    ap = argparse.ArgumentParser(
        description="板到当天的分步验证（不需要摄像头）")
    ap.add_argument("--step", type=int, choices=[2, 3],
                    help="只跑某一步；省略则跑全部")
    ap.add_argument("--bit", metavar="PATH",
                    help="overlay 的 .bit 路径（默认按 PYNQ 惯例找同名文件）")
    ap.add_argument("--json", metavar="PATH", help="把结果写成 JSON（报告用）")
    args = ap.parse_args()

    print("=" * 69)
    print("  上板分步验证 —— ②③ 不需要摄像头")
    print("=" * 69)
    print("  ⚠ 摄像头相关的 ④~⑧ 需要示波器/逻辑分析仪，本脚本不做。")
    print("     先把 ②③ 做掉，摄像头插上后就只剩一条线要查。")

    t0 = time.time()
    results = {}

    if args.step in (None, 2):
        results['step2_ddr'] = step2_ddr()
        # ② 挂了就别做 ③ —— 后面所有现象都会被污染
        if not results['step2_ddr'] and args.step is None:
            print("\n    ⚠ ② 未通过，跳过 ③（board-bringup-guide §5：每一步失败就停下）")

    if args.step == 3 or (args.step is None and results.get('step2_ddr')):
        results['step3_pipeline'] = step3_pipeline(args.bit)

    elapsed = time.time() - t0

    print("\n" + "=" * 69)
    if _failed == 0:
        print("  *** BRINGUP CHECK PASSED ***  (%d 项检查全过, %.1f s)"
              % (_passed, elapsed))
        print("  ②③ 过了 = 数据通路是好的，摄像头可接。")
        print("  下一步：board-bringup-guide.md §5.3（摄像头逐级排查，需仪器）")
    else:
        print("  *** BRINGUP CHECK FAILED ***  (%d 通过, %d 失败, %.1f s)"
              % (_passed, _failed, elapsed))
    print("=" * 69)

    if args.json:
        Path(args.json).write_text(
            json.dumps({'results': results, 'passed': _passed,
                        'failed': _failed, 'seconds': elapsed},
                       indent=2, ensure_ascii=False), encoding='utf-8')
        print("\n  结果已写入: %s" % args.json)

    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
