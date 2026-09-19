#!/usr/bin/env python3
"""
test_overlay_offline.py —— gesture_overlay 的**离线**自检（不需要板子）

【为什么有这个文件】

`gesture_overlay.py` 只能在 PYNQ 板上实例化（它要 `pynq.Overlay`）。
但里面**有一部分逻辑与硬件无关**，而且恰恰是**最容易静默出错**的那部分：
把参数写进 AXI-Lite 寄存器时的编码。

2026-09-18 实际发现的一个 bug 就在这里：

    DEFAULT_THRESH_OFFSET = -8 & 0xFF        # ← 8 位补码，错的
    p.write(REG_THRESH_OFFSET, thresh_offset & 0xFF)

AXI-Lite 寄存器是 **32 位**，HLS 侧按 `int` 读。写 0x000000F8 进去，
IP 读回来是 **+248** 而不是 -8 —— 阈值被抬高，**输出全黑**，
而且 `ap_done` 照常置位，**不报任何错**。

同一个坑，C 驱动 `sw/preproc_driver.c` 做对了
（`(uint32_t)(int32_t)v`），而且 `main_preproc.c` 第 4 项专门验它。
**C 侧写对了却少有人注意，Python 侧写错了却没人查。**

所以这里把"与硬件无关的那部分"抽出来，做成能离线跑的回归 ——
**下次谁再写成 `& 0xFF`，这条测试会拦住他。**

【怎么用】

    python host/test_overlay_offline.py

判定：看到 `*** OVERLAY OFFLINE TESTS PASSED ***` 才算过。
退出码 0 = 过，1 = 挂。

⚠ 本文件**不覆盖**真机行为（DMA 搬运、cache 一致性、IP 是否响应等），
  那些只能上板测。见 `docs/board-bringup-guide.md` §5。
"""

import io
import sys
from pathlib import Path

# Windows 控制台的默认编码是 GBK，中文会乱码 —— 显式转 UTF-8
try:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
except Exception:
    pass

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gesture_overlay as g   # noqa: E402

_passed = 0
_failed = 0


def check(cond, msg):
    global _passed, _failed
    if cond:
        _passed += 1
        print("    [ OK ] %s" % msg)
    else:
        _failed += 1
        print("    [FAIL] %s" % msg)


def as_i32_read(v):
    """模拟 IP 侧把 32 位寄存器按有符号 int 解释"""
    return v - 0x100000000 if v > 0x7FFFFFFF else v


def expect_raises(fn, exc, msg):
    global _passed, _failed
    try:
        fn()
    except exc:
        _passed += 1
        print("    [ OK ] %s" % msg)
        return
    except Exception as e:
        _failed += 1
        print("    [FAIL] %s —— 抛了 %s 而不是 %s" % (msg, type(e).__name__, exc.__name__))
        return
    _failed += 1
    print("    [FAIL] %s —— 没有抛异常" % msg)


# =====================================================================
def test_i32_encoding():
    print("\n[1] 32 位补码编码（本文件存在的首要理由）")

    check(g._as_i32(-8) == 0xFFFFFFF8, "-8   → 0xFFFFFFF8")
    check(g._as_i32(-1) == 0xFFFFFFFF, "-1   → 0xFFFFFFFF")
    check(g._as_i32(-128) == 0xFFFFFF80, "-128 → 0xFFFFFF80")
    check(g._as_i32(0) == 0x00000000, "0    → 0x00000000")
    check(g._as_i32(127) == 0x0000007F, "127  → 0x0000007F")

    # 最关键的一条：往返一致
    for v in (-128, -8, -1, 0, 1, 127):
        check(as_i32_read(g._as_i32(v)) == v,
              "写入 %4d → IP 按 int32 读回仍是 %4d" % (v, v))

    # 对照：旧写法必须被证伪，否则说明测试没测到点上
    check(as_i32_read(-8 & 0xFF) == 248,
          "对照：旧的 `-8 & 0xFF` 会让 IP 读成 +248（正是被修掉的 bug）")

    # 防止有人把默认值又改回补码形式
    check(g.DEFAULT_THRESH_OFFSET == -8,
          "DEFAULT_THRESH_OFFSET 保持**有符号** -8（不是 248）")
    check(g.DEFAULT_THRESH_OFFSET <= 127,
          "默认偏置在 [-128,127] 范围内（能被 check_config 接受）")


# =====================================================================
def test_check_config_accepts():
    print("\n[2] check_config —— 合法值")

    c = g.check_config(1, -8, 256, None, None, 320, 320)
    check(c['roi_x'] == 160 and c['roi_y'] == 80,
          "ROI 居中补齐：640x480 里取 320x320 → (%d,%d)" % (c['roi_x'], c['roi_y']))
    check(c['thresh_offset'] == -8, "偏置原样保留 -8")

    c = g.check_config(1, 127, 0, 0, 0, 96, 96)
    check(c['roi_w'] == 96, "极小 ROI 96x96 被接受")
    check(c['gain'] == 0, "gain=0 被接受（不放大）")

    c = g.check_config(0, 0, 256, 0, 0, 640, 480)
    check(c['thresh_mode'] == 0, "灰度直通模式被接受")


# =====================================================================
def test_check_config_rejects():
    print("\n[3] check_config —— 非法值必须被拦住（与 C 驱动对齐）")

    # 这几条与 sw/main_preproc.c 的 [3][5][7] 项一一对应
    expect_raises(lambda: g.check_config(2, -8, 256, None, None, 320, 320),
                  ValueError, "thresh_mode=2 被拦（C 侧同样拦）")

    expect_raises(lambda: g.check_config(1, 128, 256, None, None, 320, 320),
                  ValueError, "偏置 +128 越界被拦")
    expect_raises(lambda: g.check_config(1, -129, 256, None, None, 320, 320),
                  ValueError, "偏置 -129 越界被拦")

    expect_raises(lambda: g.check_config(1, -8, -1, None, None, 320, 320),
                  ValueError, "gain 为负被拦")

    expect_raises(lambda: g.check_config(1, -8, 256, None, None, 0, 320),
                  ValueError, "ROI 宽为 0 被拦")

    # ROI 越界：这是上板最容易犯的错（换了分辨率忘了改 ROI）
    expect_raises(lambda: g.check_config(1, -8, 256, 500, 0, 320, 320),
                  ValueError, "ROI 右边界越界被拦")
    expect_raises(lambda: g.check_config(1, -8, 256, 0, 400, 320, 320),
                  ValueError, "ROI 下边界越界被拦")
    expect_raises(lambda: g.check_config(1, -8, 256, -1, 0, 320, 320),
                  ValueError, "ROI 负坐标被拦")


# =====================================================================
def test_register_map():
    print("\n[4] 寄存器偏移与 CTRL 位（防手滑改错）")

    # ⚠ 这组值与 csynth.rpt 的 S_AXILITE Registers 表逐个核对过
    want = {
        'REG_CTRL': 0x00, 'REG_GIE': 0x04, 'REG_IER': 0x08, 'REG_ISR': 0x0C,
        'REG_WIDTH': 0x10, 'REG_HEIGHT': 0x18,
        'REG_THRESH_MODE': 0x20, 'REG_THRESH_OFFSET': 0x28,
        'REG_GAUSS_EN': 0x30, 'REG_SOBEL_EN': 0x38, 'REG_MORPH_EN': 0x40,
        'REG_GAIN': 0x48,
        'REG_ROI_X': 0x50, 'REG_ROI_Y': 0x58,
        'REG_ROI_W': 0x60, 'REG_ROI_H': 0x68,
    }
    for name, off in want.items():
        check(getattr(g, name) == off, "%s = 0x%02X" % (name, off))

    # 最重要的一条：状态位在 CTRL(0x00)，不在 0x04
    # （0x04 是 GIER —— 这个坑在 legacy/sobel 的 sobel_driver.h 里踩过）
    check(g.REG_GIE == 0x04, "0x04 是 GIE(中断使能)，不是 STATUS")
    check(g.CTRL_AP_START == 0x01, "AP_START = bit0，在 CTRL(0x00)")
    check(g.CTRL_AP_DONE == 0x02, "AP_DONE  = bit1，在 CTRL(0x00)")
    check(g.CTRL_AP_IDLE == 0x04, "AP_IDLE  = bit2，在 CTRL(0x00)")
    check(g.CTRL_AP_READY == 0x08, "AP_READY = bit3，在 CTRL(0x00)")

    # 尺寸契约
    check(g.OUT_SIZE == 96, "输出边长 96")
    check(g.OUT_BYTES == 96 * 96, "输出字节数 9,216（与 gesture_preproc.h 的契约）")
    check(g.IN_BYTES == 640 * 480 * 2, "输入字节数 614,400（RGB565）")


# =====================================================================
def test_dma_offsets():
    print("\n[5] AXI DMA 寄存器偏移（PG021 固定布局）")

    check(g.DMA_MM2S_DMACR == 0x00, "MM2S_DMACR = 0x00")
    check(g.DMA_MM2S_DMASR == 0x04, "MM2S_DMASR = 0x04")
    check(g.DMA_MM2S_SRCADDR == 0x18, "MM2S_SRCADDR = 0x18")
    check(g.DMA_MM2S_LENGTH == 0x28, "MM2S_LENGTH = 0x28")
    check(g.DMA_S2MM_DMACR == 0x30, "S2MM_DMACR = 0x30")
    check(g.DMA_S2MM_DMASR == 0x34, "S2MM_DMASR = 0x34")
    check(g.DMA_S2MM_DSTADDR == 0x48, "S2MM_DSTADDR = 0x48")
    check(g.DMA_S2MM_LENGTH == 0x58, "S2MM_LENGTH = 0x58")

    # ⚠ 与 sw/preproc_driver.c 里的同组宏必须一致 —— 两边不一致会导致
    #   "C 能跑、Python 跑不了"，属最难查的一类
    check(g.DMA_CR_RUNSTOP == 0x00000001, "DMACR.RS = bit0")
    check(g.DMA_CR_RESET == 0x00000004, "DMACR.Reset = bit2")
    check(g.DMA_SR_HALTED == 0x0001, "DMASR.Halted = bit0")
    check(g.DMA_SR_IDLE == 0x0002, "DMASR.Idle = bit1")


# =====================================================================
def main():
    print("=" * 69)
    print("  gesture_overlay 离线自检（不需要板子）")
    print("=" * 69)

    test_i32_encoding()
    test_check_config_accepts()
    test_check_config_rejects()
    test_register_map()
    test_dma_offsets()

    print("\n" + "=" * 69)
    if _failed == 0:
        print("  *** OVERLAY OFFLINE TESTS PASSED ***  (%d 项检查全过)" % _passed)
    else:
        print("  *** OVERLAY OFFLINE TESTS FAILED ***  (%d 通过, %d 失败)"
              % (_passed, _failed))
    print("=" * 69)
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
