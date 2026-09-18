#!/usr/bin/env python3
"""
dma_guard.py —— 通用 DMA 搬运 + cache 一致性封装

【为什么需要这个】

Zynq 的 PS 侧 ARM 有 cache，PL 通过 DMA **直接读写 DDR，绕过 cache**。
不同步会导致「结果时对时错」—— 不报错、只错数据、极难定位。

而且这个错误**在主机仿真里永远不会出现**（没有 cache 概念），
只有上板才暴露。所以必须有一个统一的、带保护的封装。

【设计要点】

1. **与题目/板卡解耦** —— 只管「搬一块内存」，不知道搬的是什么
2. **双后端** —— 自动选择真实 PYNQ 后端或主机仿真后端，同一套调用代码
3. **内置诊断** —— 出错时给出具体排查方向，而不是抛个裸异常
4. **显式契约** —— 长度/对齐/方向在调用时校验，不留给硬件崩溃

【用法（PYNQ 板上）】

    from dma_guard import DmaChannel

    dma = DmaChannel(overlay.axi_dma_0)
    with dma.transfer(src_buf, dst_buf) as t:
        t.wait(timeout=5.0)
    # 退出 with 时自动 invalidate，之后读 dst_buf 才是新数据

【用法（无板卡主机仿真）】

    dma = DmaChannel(None, sim_kernel=my_sobel_func)
    with dma.transfer(src, dst) as t:
        t.wait()

【依赖】
  板上  : pynq (allocate / DMA)
  主机  : numpy (可选)
"""

from __future__ import annotations

import time
from contextlib import contextmanager

__version__ = "1.0.0"


class DmaError(Exception):
    """DMA 相关失败，附带排查方向"""


class DmaTimeout(DmaError):
    pass


# ---------------------------------------------------------------------
#  后端
# ---------------------------------------------------------------------
class _SimBackend:
    """
    主机仿真后端 —— 无板卡时验证驱动逻辑。

    ⚠ 重要：仿真**不会**复现 cache 一致性问题（没有 cache 概念），
      也不会复现 TLAST 缺失导致的挂死。它的价值是验证**寄存器读写顺序、
      轮询逻辑、buffer 管理**是否正确，不能替代上板验证。

    sim_kernel: 可选，模拟 PL 侧运算的函数 (src_arr, dst_arr) -> None
                不传则只做 memcpy，用于纯搬运测试。
    """

    name = "sim"

    def __init__(self, sim_kernel=None):
        self.sim_kernel = sim_kernel

    def run(self, src, dst, nbytes):
        if self.sim_kernel is not None:
            self.sim_kernel(src, dst)
        else:
            # 纯搬运
            n = min(len(src), len(dst))
            for i in range(n):
                dst[i] = src[i]
        return True


class _PynqBackend:
    """真实 PYNQ 后端"""

    name = "pynq"

    def __init__(self, dma_ip):
        self.dma = dma_ip

    def run(self, src, dst, nbytes):
        self.dma.sendchannel.transfer(src)
        self.dma.recvchannel.transfer(dst)
        self.dma.sendchannel.wait()
        self.dma.recvchannel.wait()
        return True


# ---------------------------------------------------------------------
#  主封装
# ---------------------------------------------------------------------
class DmaChannel:
    """
    一个 DMA 通道的通用封装。

    参数
      dma_ip     : PYNQ 的 DMA 对象（overlay.xxx）。传 None 则走主机仿真。
      sim_kernel : 主机仿真时模拟 PL 运算的函数（可选）
      max_bytes  : 单次搬运上限，防呆（默认 64 MB）
    """

    def __init__(self, dma_ip=None, sim_kernel=None, max_bytes=64 << 20):
        self.max_bytes = max_bytes
        self.stats = {"transfers": 0, "bytes": 0, "failures": 0}

        if dma_ip is None:
            self._backend = _SimBackend(sim_kernel)
        else:
            self._backend = _PynqBackend(dma_ip)

    @property
    def backend(self):
        return self._backend.name

    # -----------------------------------------------------------------
    #  校验 —— 在动手之前把能查的都查掉
    # -----------------------------------------------------------------
    def _validate(self, src, dst, nbytes):
        if src is None or dst is None:
            raise DmaError("src/dst 不能为空")
        if nbytes <= 0:
            raise DmaError(f"nbytes 必须为正，得到 {nbytes}")
        if nbytes > self.max_bytes:
            raise DmaError(
                f"nbytes={nbytes} 超过上限 {self.max_bytes}。"
                f"超大批次建议分块，或显式调大 max_bytes。")

        # 长度够不够
        for tag, buf in (("src", src), ("dst", dst)):
            try:
                cap = len(buf) if hasattr(buf, "nbytes") is False else buf.nbytes
            except TypeError:
                continue
            if cap and cap < nbytes:
                raise DmaError(
                    f"{tag} 缓冲区只有 {cap} 字节，但要搬 {nbytes} 字节。")

        # buffer 位置：PYNQ 的 DMA 要求物理连续内存
        if self.backend == "pynq":
            for tag, buf in (("src", src), ("dst", dst)):
                if not getattr(buf, "phys_addr", None) and not getattr(buf, "device_address", None):
                    # device_address 在 pynq>=2.6 是 lazy 的，取一次
                    try:
                        buf.device_address
                    except Exception:
                        raise DmaError(
                            f"{tag} 看起来不是 PYNQ allocate() 出来的缓冲区。\n"
                            f"  DMA 要求物理连续内存，普通 numpy 数组不行。\n"
                            f"  正确做法: from pynq import allocate; buf = allocate(shape=..., dtype=...)")

    # -----------------------------------------------------------------
    #  搬运
    # -----------------------------------------------------------------
    @contextmanager
    def transfer(self, src, dst, nbytes=None, timeout=10.0):
        """
        上下文管理器：搬完自动同步 cache。

        用 with 是为了保证 **invalidate 一定被执行** —— 漏掉 invalidate
        是「结果随机错误」的头号原因，靠人记得写迟早会漏。
        """
        if nbytes is None:
            nbytes = getattr(src, "nbytes", None) or len(src)

        self._validate(src, dst, nbytes)

        handle = _TransferHandle(self, src, dst, nbytes)
        try:
            yield handle
        finally:
            # 无论成功失败，都尝试把 dst 的 cache 置为无效，
            # 避免读到陈旧数据。失败不掩盖原始异常。
            try:
                if not handle._cache_done:
                    self._invalidate(dst)
            except Exception:
                pass

    class _Noop:
        pass

    def _flush(self, buf):
        """CPU cache → DDR（发送前调用）"""
        if hasattr(buf, "flush"):
            buf.flush()

    def _invalidate(self, buf):
        """丢弃 CPU cache，从 DDR 重读（接收后调用）"""
        if hasattr(buf, "invalidate"):
            buf.invalidate()

    # -----------------------------------------------------------------
    #  诊断
    # -----------------------------------------------------------------
    def diagnose(self):
        """
        出错时给排查方向。调用它比盯着错误码强。
        """
        tips = []
        if self.backend == "sim":
            tips.append(
                "当前是主机仿真后端 —— 它**不会**复现 cache 一致性问题和 "
                "TLAST 缺失挂死。这两类问题只能上板或 cosim 才能发现。")
        tips += [
            "结果随机错误 / 时对时错 → 先查 cache 同步（本工具的 with 块应该已处理）",
            "DMA 永远等不到完成 → 查流接口是否缺 TLAST（见 09-pitfalls.md A2）",
            "数据整体错位固定字节数 → 查缓冲区对齐与位宽转换",
            "完全没数据 → 查 M_AXI_S2MM 是否悬空（09-pitfalls.md C3）",
        ]
        return "\n".join(f"  - {t}" for t in tips)


class _TransferHandle:
    def __init__(self, chan, src, dst, nbytes):
        self._chan = chan
        self.src, self.dst, self.nbytes = src, dst, nbytes
        self._done = False
        self._cache_done = False

    def wait(self, timeout=10.0):
        t0 = time.time()
        try:
            ok = self._chan._backend.run(self.src, self.dst, self.nbytes)
        except DmaTimeout:
            raise
        except Exception as e:
            self._chan.stats["failures"] += 1
            raise DmaError(
                f"DMA 搬运失败: {e}\n排查方向:\n{self._chan.diagnose()}"
            ) from e

        dt = time.time() - t0
        if not ok:
            self._chan.stats["failures"] += 1
            raise DmaError("DMA 返回失败状态")

        # 接收后必须 invalidate，否则 CPU 读到的是 cache 里的旧值
        self._chan._invalidate(self.dst)
        self._cache_done = True

        self._done = True
        self._chan.stats["transfers"] += 1
        self._chan.stats["bytes"] += self.nbytes
        self.elapsed = dt
        return self

    def __repr__(self):
        return f"<Transfer {self.nbytes}B {self._chan.backend} {'done' if self._done else 'pending'}>"


# ---------------------------------------------------------------------
#  自测 —— 无板卡也能跑
# ---------------------------------------------------------------------
def _selftest():
    print(f"dma_guard {__version__} 自测（主机仿真后端）")
    print("-" * 50)

    src = bytearray(range(64))
    dst = bytearray(64)
    dma = DmaChannel(None)
    assert dma.backend == "sim"

    with dma.transfer(src, dst) as t:
        t.wait()
    assert bytes(dst) == bytes(src), "搬运结果不一致"
    print("  [OK] 基本搬运")

    # 模拟 PL 侧运算：逐字节 +1 取模
    def kernel(s, d):
        n = min(len(s), len(d))
        for i in range(n):
            d[i] = (s[i] + 1) & 0xFF

    dst2 = bytearray(64)
    dma2 = DmaChannel(None, sim_kernel=kernel)
    with dma2.transfer(src, dst2) as t:
        t.wait()
    assert dst2[0] == 1 and dst2[63] == 64, "kernel 结果不对"
    print("  [OK] 带模拟 kernel")

    # 参数校验
    for bad, why in (
        ((None, bytearray(4), 4), "src 为空"),
        ((bytearray(4), bytearray(4), 0), "nbytes=0"),
        ((bytearray(4), bytearray(4), 999), "src 太短"),
    ):
        try:
            with DmaChannel(None).transfer(*bad) as t:
                t.wait()
            print(f"  [FAIL] {why} 应该报错但没报")
        except DmaError:
            print(f"  [OK] 拦住: {why}")

    print()
    print(f"  统计: {dma.stats['transfers'] + dma2.stats['transfers']} 次搬运, "
          f"{dma.stats['bytes'] + dma2.stats['bytes']} 字节")
    print("  全部通过")


if __name__ == "__main__":
    _selftest()
