#!/usr/bin/env python3
"""
gesture_overlay.py —— 手势识别 PL 流水线的 PYNQ 驱动

在 PYNQ-Z2 的 Jupyter / Python 里运行，加载 bitstream 并驱动整条链：

    OV5640 ─DVP─► dvp_capture ─AXIS─► VDMA S2MM ─► DDR(帧缓存)
                                                        │
                                     AXI DMA MM2S ◄─────┘
                                            │
                                     gesture_preproc ──► 96x96 灰度
                                            │
                                     AXI DMA S2MM ──► DDR(96x96) ──► CNN

=====================================================================
  使用前必须知道的三件事
=====================================================================
1. **地址不硬编码。** 所有基地址从 overlay 的 `ip_dict` 读 ——
   重新综合后地址可能变，硬编码必然出错。

2. **⚠ `ignore_version=True` 可能需要。**
   PYNQ 镜像自带的是某个 Vivado 版本生成的库，与本项目用的
   Vivado 2025.2 不一致时，`Overlay()` 会报版本错误。
   先试不加参数的；报错再加。

3. **⚠ 摄像头还没配。** `sccb_master` 的寄存器表
   （`rtl/ov5640_regs.v`）目前是**占位表**，不会让 OV5640 出图。
   所以本脚本的 `io_pclk` 会一直没有波形 —— 那是预期行为。

=====================================================================
  快速上手
=====================================================================
    from gesture_overlay import GesturePipeline
    g = GesturePipeline()
    g.print_info()          # 先看 IP 认出来没有
    g.setup_dma()           # 配 DMA 缓冲
    g.run_once()            # 跑一帧
    g.show()                # 看结果（Jupyter 里出图）
"""

import time
import numpy as np

try:
    from pynq import Overlay, allocate
    _PYNQ = True
except ImportError:
    # 允许在 PC 上 import 本模块做静态检查（_PYNQ=False 时不加载硬件）
    _PYNQ = False


# =====================================================================
#  与 src_hls/gesture_preproc.h 必须一致的常量
# =====================================================================
IN_WIDTH  = 640
IN_HEIGHT = 480
IN_BYTES  = IN_WIDTH * IN_HEIGHT * 2      # RGB565 = 2 字节/像素

OUT_SIZE  = 96
OUT_PIXELS = OUT_SIZE * OUT_SIZE          # 9216
OUT_BYTES = OUT_PIXELS                    # uint8

# gesture_preproc 的 AXI-Lite 寄存器偏移
# ⚠ 取自 Vitis 生成的官方头文件 xgesture_preproc_hw.h，不是凭记忆
REG_CTRL          = 0x00
REG_GIE           = 0x04   # ⚠ 中断使能，不是状态！
REG_IER           = 0x08
REG_ISR           = 0x0C
REG_WIDTH         = 0x10
REG_HEIGHT        = 0x18
REG_THRESH_MODE   = 0x20
REG_THRESH_OFFSET = 0x28
REG_GAUSS_EN      = 0x30
REG_SOBEL_EN      = 0x38
REG_MORPH_EN      = 0x40
REG_GAIN          = 0x48
REG_ROI_X         = 0x50
REG_ROI_Y         = 0x58
REG_ROI_W         = 0x60
REG_ROI_H         = 0x68

# CTRL 位 —— 取自官方 xgesture_preproc.c
CTRL_AP_START  = 0x01   # bit0
CTRL_AP_DONE   = 0x02   # bit1
CTRL_AP_IDLE   = 0x04   # bit2
CTRL_AP_READY  = 0x08   # bit3

# AXI DMA 的寄存器偏移（PG021 固定布局）
DMA_MM2S_DMACR   = 0x00
DMA_MM2S_DMASR   = 0x04
DMA_MM2S_SRCADDR = 0x18
DMA_MM2S_LENGTH  = 0x28

DMA_S2MM_DMACR   = 0x30
DMA_S2MM_DMASR   = 0x34
DMA_S2MM_DSTADDR = 0x48
DMA_S2MM_LENGTH  = 0x58

DMA_CR_RUNSTOP = 0x0001
DMA_CR_RESET   = 0x0004
DMA_SR_HALTED  = 0x0001
DMA_SR_IDLE    = 0x0002

# 默认算法参数（与驱动一致）
DEFAULT_THRESH_MODE   = 1
DEFAULT_THRESH_OFFSET = -8 & 0xFF   # 有符号转补码
DEFAULT_GAIN          = 256


class GesturePipeline(object):
    """手势识别流水线的 PYNQ 驱动。

    ⚠ 所有基地址从 overlay.ip_dict 读，不硬编码。
    """

    def __init__(self, bitfile=None, ignore_version=False):
        if not _PYNQ:
            raise RuntimeError(
                "pynq 未安装 —— 本模块只能在 PYNQ-Z2 的板载 Python 里运行。\n"
                "在 PC 上做静态检查时用 import 即可，但不要实例化。")

        # 默认按 PYNQ 惯例找同名 .bit / .hwh
        kw = {}
        if ignore_version:
            kw['ignore_version'] = True
        self.ol = Overlay(bitfile, **kw) if bitfile else Overlay(**kw)

        self.ip = {}          # 名字 -> MMIO
        self._find_ips()

        self.in_buf  = None   # 输入帧缓冲（DDR）
        self.out_buf = None   # 输出 96x96 缓冲（DDR）

    # -----------------------------------------------------------------
    def _find_ips(self):
        """从 overlay 里认出需要的 IP。

        ⚠ 不硬编码实例名 —— `.hwh` 里的名字可能与 BD 里的不同
          （BD 里叫 `dma_in`，`.hwh` 里可能是
           `bd_video_i/dma_in` 这种层次路径）。

        ⚠⚠ 匹配逻辑要当心两点：
          1. **运算符优先级**：`A and B or C` 是 `(A and B) or C`，
             不是 `A and (B or C)`。早期写成
                if pat in name and 'dma_' in name or (...)
            结果 `dma_in` 和 `dma_out` 互相误匹配。
          2. **一个模式可能命中多个 IP**，这时要报歧义而不是
             随便取第一个 —— 取错的话表现为"配了 A 结果 B 动了"，
             极难查。
        """
        d = self.ol.ip_dict

        # 每个角色：(名字里的特征, 期望的 IP 类型)
        want = {
            'preproc': ('gesture_preproc', 'gesture_preproc'),
            'dma_in':  ('dma_in',          'axi_dma'),
            'dma_out': ('dma_out',         'axi_dma'),
        }

        for key, (name_pat, type_pat) in want.items():
            hits = []
            for name, info in d.items():
                if name_pat in name and type_pat in str(info.get('type', '')):
                    hits.append(name)

            if len(hits) == 0:
                continue          # 留给下面的报错统一处理
            if len(hits) > 1:
                raise RuntimeError(
                    "IP 匹配有歧义：'%s' 同时命中 %s\n"
                    "  请检查 .hwh 里的实例名，或改用显式指定。"
                    % (name_pat, hits))
            self.ip[key] = self.ol.__getattr__(hits[0])

        missing = [k for k in want if k not in self.ip]
        if missing:
            print("=== overlay 里实际的 IP ===")
            for name, info in sorted(d.items()):
                print("  %-40s type=%s" % (name, info.get('type', '?')))
            raise RuntimeError(
                "overlay 里没找到这些 IP: %s\n"
                "（上面列出了实际有的，对照调整匹配特征）" % missing)

    # -----------------------------------------------------------------
    def print_info(self):
        """打印 overlay 里的 IP 与地址 —— 排查用"""
        print("=== overlay 里的 IP ===")
        for name, info in sorted(self.ol.ip_dict.items()):
            print("  %-40s @ 0x%08X  (%s)" % (
                name, info.get('base_addr', 0), info.get('type', '?')))
        print()
        print("=== 本脚本认到的 ===")
        for k, v in self.ip.items():
            print("  %-10s -> %s" % (k, v))

    # -----------------------------------------------------------------
    def setup_dma(self, in_bytes=IN_BYTES, out_bytes=OUT_BYTES):
        """分配 DMA 缓冲。

        ⚠ 用 pynq.allocate 而不是 numpy 数组 ——
          allocate 出来的 buffer 是 **cache 一致的**，
          不用手动 flush/invalidate。这是 PYNQ 相对裸机的最大便利。
          （裸机 C 驱动里必须手动 Xil_DCacheFlushRange，
            漏了就拿到旧数据，而且不报错。）
        """
        # 输入：614400 字节。pynq 的 allocate 有对齐要求，多分配一点
        self.in_buf  = allocate(shape=(in_bytes,),  dtype=np.uint8)
        self.out_buf = allocate(shape=(out_bytes,), dtype=np.uint8)

        # 输出缓冲清零，便于判断"有没有跑出东西"
        self.out_buf[:] = 0
        self.out_buf.flush()

        print("DMA 缓冲已分配：")
        print("  输入 %d 字节 @ 物理地址 0x%08X" % (in_bytes, self.in_buf.physical_address))
        print("  输出 %d 字节 @ 物理地址 0x%08X" % (out_bytes, self.out_buf.physical_address))

    # -----------------------------------------------------------------
    def config(self, thresh_mode=DEFAULT_THRESH_MODE,
               thresh_offset=DEFAULT_THRESH_OFFSET,
               gauss_en=1, sobel_en=1, morph_en=1,
               gain=DEFAULT_GAIN,
               roi_x=None, roi_y=None, roi_w=320, roi_h=320):
        """配置预处理参数"""
        if roi_x is None: roi_x = (IN_WIDTH  - roi_w) // 2
        if roi_y is None: roi_y = (IN_HEIGHT - roi_h) // 2

        p = self.ip['preproc']
        p.write(REG_WIDTH,  IN_WIDTH)
        p.write(REG_HEIGHT, IN_HEIGHT)
        p.write(REG_THRESH_MODE,   thresh_mode)
        # ⚠ 阈值偏置是有符号的，用 & 0xFF 转成补码写入
        p.write(REG_THRESH_OFFSET, thresh_offset & 0xFF)
        p.write(REG_GAUSS_EN, gauss_en)
        p.write(REG_SOBEL_EN, sobel_en)
        p.write(REG_MORPH_EN, morph_en)
        p.write(REG_GAIN,     gain)
        p.write(REG_ROI_X, roi_x)
        p.write(REG_ROI_Y, roi_y)
        p.write(REG_ROI_W, roi_w)
        p.write(REG_ROI_H, roi_h)

        print("已配置: ROI=(%d,%d) %dx%d, gain=%d, thresh_off=%d" % (
            roi_x, roi_y, roi_w, roi_h, gain,
            thresh_offset if thresh_offset < 128 else thresh_offset - 256))

    # -----------------------------------------------------------------
    def _soft_reset_dma(self, base, sr_off, cr_off, timeout=1.0):
        """软复位一个 DMA 通道"""
        base.write(cr_off, DMA_CR_RESET)
        t0 = time.time()
        while base.read(sr_off) & DMA_SR_HALTED == 0:
            if time.time() - t0 > timeout:
                raise RuntimeError("DMA 复位超时")

    def run_once(self, timeout=5.0):
        """跑一帧：DDR(640x480) -> 96x96 灰度

        ⚠⚠ 顺序不能反：
            1. 先武装 dma_out（S2MM）—— 让它准备好接收
            2. 再启动 dma_in（MM2S）—— 开始供数
            3. 最后 ap_start
          反了的话，预处理输出的第一拍没有接收方，数据会丢。

        ⚠ 与裸机 C 驱动（sw/preproc_driver.c）是同一套顺序 ——
          两边改的时候要同步，否则会出现"主机仿真过了但板上不对"。
        """
        din  = self.ip['dma_in']
        dout = self.ip['dma_out']
        p    = self.ip['preproc']

        # 0. 复位两个 DMA
        self._soft_reset_dma(din,  DMA_MM2S_DMASR, DMA_MM2S_DMACR)
        self._soft_reset_dma(dout, DMA_S2MM_DMASR, DMA_S2MM_DMACR)

        # 1. ⚠ 先武装 S2MM
        dout.write(DMA_S2MM_DSTADDR, self.out_buf.physical_address)
        dout.write(DMA_S2MM_DMACR, DMA_CR_RUNSTOP)
        dout.write(DMA_S2MM_LENGTH, OUT_BYTES)

        # 2. 再启 MM2S
        din.write(DMA_MM2S_SRCADDR, self.in_buf.physical_address)
        din.write(DMA_MM2S_DMACR, DMA_CR_RUNSTOP)
        din.write(DMA_MM2S_LENGTH, IN_BYTES)

        # 3. 最后 ap_start
        c = p.read(REG_CTRL)
        p.write(REG_CTRL, c | CTRL_AP_START)

        # 4. 轮询 ap_done
        #    ⚠ 状态位在 CTRL(0x00)，不是 0x04（那是 GIE）
        t0 = time.time()
        while not (p.read(REG_CTRL) & CTRL_AP_DONE):
            if time.time() - t0 > timeout:
                raise RuntimeError(
                    "等 ap_done 超时。排查：\n"
                    "  1) io_xclk 有没有 24MHz（Clocking Wizard 输出）\n"
                    "  2) io_scl 有没有在跑（SCCB 在工作）\n"
                    "  3) io_pclk 有没有波形（有=摄像头配好了）\n"
                    "  4) 摄像头寄存器表是不是还是占位表")
        dt = time.time() - t0

        # 5. 清 ap_start
        p.write(REG_CTRL, 0)

        # 6. 让 CPU 看到 DMA 写的结果
        #    ⚠ allocate 的 buffer 是 cache 一致的，一般不需要 invalidate，
        #      但显式写一遍无害，且能防"PYNQ 版本差异导致的一致性问题"
        self.out_buf.invalidate()

        print("跑完一帧，耗时 %.3f s" % dt)
        return dt

    # -----------------------------------------------------------------
    def get_result(self):
        """取 96x96 结果（numpy 数组）"""
        if self.out_buf is None:
            raise RuntimeError("先调 setup_dma()")
        return np.array(self.out_buf, dtype=np.uint8).reshape(OUT_SIZE, OUT_SIZE)

    def fill_test_pattern(self):
        """填一张测试图（无摄像头时用来验证数据通路）

        用"左暗右亮 + 居中亮块"的图案 —— 可预测，
        输出全黑或全白时一眼能看出是阈值问题。
        """
        if self.in_buf is None:
            raise RuntimeError("先调 setup_dma()")

        # RGB565: 中灰 = 0x8410
        buf = np.frombuffer(self.in_buf, dtype=np.uint16)

        # numpy 视图：整块填中灰
        buf[:] = 0x8410

        # 居中 320x320 做水平渐变（保证 ROI 内有明暗变化）
        rx = (IN_WIDTH  - 320) // 2
        ry = (IN_HEIGHT - 320) // 2
        for y in range(ry, ry + 320, 4):        # 每 4 行取一行，够快
            row = y * (IN_WIDTH // 2)
            for x in range(rx, rx + 320, 4):
                g = (x - rx) * 255 // 320
                r5, g6, b5 = (g >> 3) & 0x1F, (g >> 2) & 0x3F, (g >> 3) & 0x1F
                buf[row + x // 2] = (r5 << 11) | (g6 << 5) | b5

        self.in_buf.flush()
        print("已填入测试图案（居中 320x320 渐变）")

    def show(self):
        """在 Jupyter 里出图"""
        img = self.get_result()
        import matplotlib.pyplot as plt
        plt.figure(figsize=(4, 4))
        plt.imshow(img, cmap='gray', vmin=0, vmax=255)
        plt.title("96x96 预处理输出")
        plt.axis('off')
        plt.show()
        return img

    def stats(self):
        """不进 Jupyter 也能看的统计"""
        img = self.get_result()
        nz = int((img > 0).sum())
        print("输出统计: min=%d max=%d mean=%.1f 非零=%d/%d" % (
            img.min(), img.max(), img.mean(), nz, OUT_PIXELS))
        return img


# =====================================================================
#  直接运行时：加载 + 自检
# =====================================================================
if __name__ == "__main__":
    print("=" * 69)
    print(" 手势识别流水线 —— PYNQ 自检")
    print("=" * 69)

    g = GesturePipeline()
    g.print_info()
    g.setup_dma()
    g.config()
    g.fill_test_pattern()
    g.run_once()
    g.stats()
    print("\n完成。若在 Jupyter 里，用 g.show() 看图。")
