#!/usr/bin/env python3
"""
golden_compare.py —— 黄金参考比对 + HLS 指标采集 → markdown 报告

两个独立功能，都服务于同一件事：**别再人工翻日志**。

  1. compare  : 拿参考实现（Python/C）的输出与硬件输出逐位比对，
                给出 PASS/FAIL 和**第一个不一致的位置**（不是只说"失败"）
  2. report   : 从 HLS 的 csynth.rpt / 实现报告里抽关键指标，
                生成可对比的 markdown 表（比赛要交的"优化前后对比"就是这个）

【为什么需要】

  - 「比对失败」如果不说清错在哪，等于没说。本工具定位到**首个**不一致的
    下标、期望值、实际值，并给出可能原因的提示。
  - csynth.rpt 有几百行，人肉找 II / Latency / 资源占用又慢又容易漏。
  - 比赛要求提交「优化前后对比（BRAM/LUT/DSP 占用、吞吐率）」——
    本工具的 report 输出直接就是那个表格。

【用法】

    # 比对：硬件输出 vs 参考输出
    python golden_compare.py compare hw_out.bin golden.bin

    # 比对两个形状不同的输出
    python golden_compare.py compare hw_out.bin golden.bin --shape 1920x1080

    # 扫参数空间只比中心区域（图像处理常这样）
    python golden_compare.py compare hw.bin gold.bin --ignore-border 1

    # 采集 HLS 报告
    python golden_compare.py report syn/report/csynth.rpt

    # 采集并写入 baseline，便于后续对比
    python golden_compare.py report csynth.rpt --baseline baseline.json

    # 与 baseline 对比（生成 delta 表）
    python golden_compare.py report csynth.rpt --baseline baseline.json --compare

    # 同时扫多个报告（如 cosim + impl）
    python golden_compare.py report csynth.rpt impl.rpt -o report.md

【退出码】
  compare: 0=一致 / 1=不一致 / 2=输入错误
  report : 0=成功 / 1=未解析到指标
"""

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np

__version__ = "1.0.0"


# =====================================================================
#  比对
# =====================================================================
def load_array(path, shape=None, dtype=np.uint8):
    p = Path(path)
    if not p.is_file():
        raise FileNotFoundError(f"文件不存在: {p}")

    if p.suffix.lower() in (".npy",):
        a = np.load(p)
    elif p.suffix.lower() in (".png", ".jpg", ".jpeg", ".bmp"):
        try:
            from PIL import Image
        except ImportError:
            raise ImportError("读图片需要 Pillow: pip install pillow")
        a = np.array(Image.open(p))
    else:
        a = np.fromfile(p, dtype=dtype)

    if shape:
        h, w = shape
        want = h * w
        if a.size != want and a.ndim == 1:
            raise ValueError(
                f"数据量 {a.size} 与形状 {h}x{w}={want} 不匹配。")
        if a.ndim == 1:
            a = a.reshape(h, w)
    return a


def compare(a, b, ignore_border=0, tol=0):
    """
    逐元素比对。返回 (是否一致, 报告 dict)

    比 np.array_equal 多做的事：
      - 给出**首个**不一致的位置和值
      - 统计不一致元素数量与占比
      - 给出最大偏差
      - 按症状提示可能原因
    """
    if a.shape != b.shape:
        return False, {
            "ok": False,
            "reason": "形状不一致",
            "detail": f"hw={a.shape} golden={b.shape}",
        }

    a = a.astype(np.int64)
    b = b.astype(np.int64)

    # 可选：忽略边界（图像处理常只比有效区）
    if ignore_border > 0:
        k = ignore_border
        a = a[k:-k, k:-k]
        b = b[k:-k, k:-k]

    diff = a - b
    nbad = int(np.count_nonzero(diff))
    total = diff.size

    if nbad == 0:
        return True, {"ok": True, "total": total, "nbad": 0}

    # 首个不一致位置
    idx = np.unravel_index(np.argmax(diff != 0), diff.shape)
    info = {
        "ok": False,
        "total": total,
        "nbad": nbad,
        "ratio": nbad / total,
        "first_bad_index": idx,
        "first_bad_hw": int(a[idx]),
        "first_bad_golden": int(b[idx]),
        "max_abs_diff": int(np.max(np.abs(diff))),
        "mean_abs_diff": float(np.mean(np.abs(diff))),
    }

    # 症状 → 可能原因
    hints = []
    if nbad == total:
        hints.append("全部不一致 → 大概率是数据通路完全没通，或读错了 buffer")
    elif info["ratio"] < 0.02:
        hints.append(f"少量不一致（{info['ratio']:.2%}）→ 典型是边界处理差异、"
                     f"或定点量化舍入不同")
    if info["max_abs_diff"] == 1 and info["ratio"] < 0.1:
        hints.append("偏差恒为 ±1 → 强烈提示定点舍入策略不同（截断 vs 四舍五入）")
    if info["max_abs_diff"] > 128:
        hints.append("偏差很大 → 可能是有符号/无符号解释不同，或字节序问题")

    # ---- 平移检测 ----
    # 用**非环绕**移位比较：只比重叠区。np.roll 会环绕，首尾几拍不匹配，
    # 导致明明整体平移一拍却检测不出来（实测踩过）。
    f1, f2 = a.ravel(), b.ravel()
    for shift in (1, -1, 2, -2):
        if shift > 0:
            ov_a, ov_b = f1[shift:], f2[:-shift]     # a 相对 b 后移
        else:
            k = -shift
            ov_a, ov_b = f1[:-k], f2[k:]             # a 相对 b 前移
        if ov_a.size and np.array_equal(ov_a, ov_b):
            info["shift"] = shift
            hints.append(
                f"**结果 = 参考值整体平移 {shift} 个元素** → 几乎可以确定是"
                f"流水线延迟/对齐差了一拍。检查 TB 采样点是否对齐"
                f"（见 07-verification.md），而不是怀疑算法。")
            break

    info["hints"] = hints
    return False, info


def fmt_compare(info):
    if info["ok"]:
        return f"PASS —— {info['total']} 个元素全部一致"
    lines = [
        f"FAIL —— {info['nbad']} / {info['total']} 不一致 ({info['ratio']:.4%})",
        f"  首个不一致位置: {info['first_bad_index']}",
        f"    硬件值 = {info['first_bad_hw']}",
        f"    参考值 = {info['first_bad_golden']}",
        f"  最大绝对偏差: {info['max_abs_diff']}",
        f"  平均绝对偏差: {info['mean_abs_diff']:.4f}",
    ]
    if info.get("hints"):
        lines.append("  可能原因:")
        lines += [f"    - {h}" for h in info["hints"]]
    return "\n".join(lines)


# =====================================================================
#  HLS 报告解析
# =====================================================================
# 报告里各指标出现的模式。实测基于 Vitis 2025.2 的 csynth.rpt。
_PATTERNS = {
    "target_clock_ns": r"\|\s*Clock\s*\|\s*([\d.]+)\s*\|",
    "estimated_clock_ns": r"\|\s*Target\s*\|\s*([\d.]+)\s*\|.*?\|\s*([\d.]+)\s*\|",
    "latency_min": r"\|\s*Latency \(cycles\)\s*\|.*?\n\s*\|[^\n]*\|\s*(\d+)\|",
    "ii": r"\|\s*Interval\s*\|\s*[^\n]*?\|\s*(\d+)\|",
}

# 资源表：|Total | 3| 1| 903| 1826| 0|
_RES_TOTAL = re.compile(
    r"\|\s*Total\s*\|\s*(\d+)\|\s*(\d+)\|\s*(\d+)\|\s*(\d+)\|\s*(\d+)\|")


def _cells(line):
    """按竖线切表格行，去掉首尾空串"""
    parts = [c.strip() for c in line.split("|")]
    return parts[1:-1] if len(parts) >= 2 else []


def _find_table(lines, header_keywords, start=0):
    """找到含全部关键词的表头行，返回下标（找不到返回 -1）"""
    for i in range(start, len(lines)):
        if all(k in lines[i] for k in header_keywords):
            return i
    return -1


def _iter_rows(lines, header_idx, ncols):
    """
    从表头之后取数据行：跳过分隔线（0 列），返回第一个 ncols 列的行组。

    实测：表格常有"双行表头"（如 Latency 表先 4 列后 7 列），
    以及 0 列的分隔线。这里只认**恰好 ncols 列且首格非空**的行。
    """
    rows = []
    for j in range(header_idx + 1, len(lines)):
        c = _cells(lines[j])
        if not c:
            if rows:
                break
            continue
        if len(c) != ncols:
            if rows:
                break
            continue
        if not c[0]:
            continue
        rows.append(c)
    return rows


def parse_csynth(path):
    """从 csynth.rpt 抽关键指标

    实测格式（Vitis 2025.2）。三个容易踩的点（都实际踩过）：

    1. **时钟表列序**是 Clock | Target | Estimated | Uncertainty。
       取 "Estimated" 是第 2 个数不是第 3 个 —— 取错会算出假 Fmax
       （把 uncertainty 当周期 → Fmax 虚高 2.7 倍）。

    2. **表头关键词会撞车**：Instance 表的表头同时含
       "Latency (cycles)" / "Interval" / "Pipeline"，与顶层 Latency 摘要表
       撞车。必须先定位 Latency 表且**限定在 Timing 段内**。

    3. **achieved II 只有被流水化的循环才有值**，未流水化的是 "-"。
       已流水化的模块组在 Instance 表，其类型为 "loop pipeline stp"，
       此时 Interval 列常为 0（表示"已启动，间隔由循环边界决定"），
       **0 不代表 II=0**，别当过零除或错误处理。
    """
    t = Path(path).read_text(encoding="utf-8", errors="replace")
    lines = t.split("\n")
    out = {"source": str(path)}

    m = re.search(r"Vitis HLS Report for '([^']+)'", t)
    if m:
        out["top"] = m.group(1)

    m = re.search(r"Target device:\s*(\S+)", t)
    if m:
        out["device"] = m.group(1)

    # ---- 时钟 ----
    i = _find_table(lines, ["Clock", "Target", "Estimated"])
    if i >= 0:
        for c in _iter_rows(lines, i, 4):
            if "ns" in c[1]:
                nums = re.findall(r"([\d.]+)", c[1] + " " + c[2])
                if len(nums) >= 2:
                    out["clock_name"] = c[0]
                    out["target_clock_ns"] = float(nums[0])
                    out["estimated_clock_ns"] = float(nums[1])
                    if float(nums[1]) > 0:
                        out["estimated_fmax_mhz"] = round(1000.0 / float(nums[1]), 2)
                break

    # ---- 顶层 Latency 表 ----
    # 先定位 + Latency: 段，避免与后面的 Instance 表撞车
    lat_start = next((i for i, l in enumerate(lines) if l.strip().startswith("+ Latency")), 0)
    i = _find_table(lines, ["Latency (cycles)", "Pipeline", "Type"], start=lat_start)
    if i < 0:
        i = _find_table(lines, ["Latency (cycles)", "Interval", "Pipeline"], start=lat_start)
    if i >= 0:
        rows = _iter_rows(lines, i, 7)
        if rows:
            c = rows[0]
            if c[0].isdigit() and c[1].isdigit():
                out["latency_min"] = int(c[0])
                out["latency_max"] = int(c[1])
                out["interval_min"] = int(c[4])
                out["interval_max"] = int(c[5])

    # ---- 循环级 achieved II ----
    loops = []
    i = _find_table(lines, ["Loop Name", "achieved"])
    if i >= 0:
        for c in _iter_rows(lines, i, 8):
            ach = c[4]
            loops.append({
                "loop": c[0].lstrip("- ").strip(),
                "latency": [int(c[1]), int(c[2])] if c[1].isdigit() and c[2].isdigit() else None,
                "achieved_ii": int(ach) if ach.isdigit() else None,
                "target_ii": int(c[5]) if c[5].isdigit() else None,
                "pipelined": c[7].lower().startswith("yes"),
            })
    if loops:
        out["loops"] = loops
        got = [lp["achieved_ii"] for lp in loops if lp["achieved_ii"] is not None]
        if got:
            out["achieved_ii_best"] = min(got)
        out["n_loops_pipelined"] = sum(1 for lp in loops if lp["pipelined"])

    # ---- 已流水化的模块组（Instance 表，9 列）----
    groups = []
    i = _find_table(lines, ["Instance", "Module", "Type"])
    if i >= 0:
        for c in _iter_rows(lines, i, 9):
            typ = c[8]
            # "no" 表示未流水化；其余（loop pipeline stp 等）都算流水化
            is_pipe = not typ.lower().startswith("no")
            groups.append({
                "instance": c[0],
                "latency": [int(c[2]), int(c[3])] if c[2].isdigit() and c[3].isdigit() else None,
                "interval": [int(c[6]), int(c[7])] if c[6].isdigit() and c[7].isdigit() else None,
                "type": typ,
                "pipelined": is_pipe,
            })
    if groups:
        out["pipelined_groups"] = groups
        out["n_groups_pipelined"] = sum(1 for g in groups if g["pipelined"])

    # ---- 总资源 ----
    totals = _RES_TOTAL.findall(t)
    if totals:
        best = max(totals, key=lambda r: sum(int(x) for x in r))
        out["bram_18k"], out["dsp"], out["ff"], out["lut"], out["uram"] = (
            int(best[0]), int(best[1]), int(best[2]), int(best[3]), int(best[4]))

    return out


def parse_impl(path):
    """从实现报告抽时序（WNS/TNS）"""
    t = Path(path).read_text(encoding="utf-8", errors="replace")
    out = {"source": str(path)}
    for key, pat in (
        ("wns_ns", r"WNS[^\n]*?(-?[\d.]+)"),
        ("tns_ns", r"TNS[^\n]*?(-?[\d.]+)"),
        ("whs_ns", r"WHS[^\n]*?(-?[\d.]+)"),
    ):
        m = re.search(pat, t)
        if m:
            out[key] = float(m.group(1))
    return out


# =====================================================================
#  报告生成
# =====================================================================
_METRIC_ORDER = [
    ("achieved_ii_best", "Achieved II (best)", ""),
    ("latency_min", "Latency min", " cyc"),
    ("latency_max", "Latency max", " cyc"),
    ("estimated_fmax_mhz", "Est. Fmax", " MHz"),
    ("target_clock_ns", "目标时钟", " ns"),
    ("bram_18k", "BRAM_18K", ""),
    ("dsp", "DSP", ""),
    ("ff", "FF", ""),
    ("lut", "LUT", ""),
    ("uram", "URAM", ""),
    ("wns_ns", "WNS", " ns"),
    ("tns_ns", "TNS", " ns"),
]


def fmt_report(new, baseline=None):
    lines = ["# HLS 指标报告", ""]

    if new.get("top"):
        lines.append(f"**顶层函数**: `{new['top']}`")
    lines.append(f"**来源**: `{new.get('source', '?')}`")
    lines.append("")

    if baseline:
        lines.append("## 优化前后对比")
        lines.append("")
        lines.append("| 指标 | 优化前 | 优化后 | Delta | 变化 |")
        lines.append("|---|---|---|---|---|")
        for key, label, unit in _METRIC_ORDER:
            b, n = baseline.get(key), new.get(key)
            if b is None and n is None:
                continue
            b_s = "—" if b is None else f"{b}{unit}"
            n_s = "—" if n is None else f"{n}{unit}"
            if b is not None and n is not None:
                d = n - b
                sign = "+" if d > 0 else ""
                # Fmax 越大越好；II / 延迟 / 资源 越小越好
                better = (key == "estimated_fmax_mhz") == (d > 0)
                arrow = "✅ 改善" if better and d != 0 else ("⚠️ 变差" if d != 0 else "= 持平")
                lines.append(f"| {label} | {b_s} | {n_s} | {sign}{d:.4g} | {arrow} |")
            else:
                lines.append(f"| {label} | {b_s} | {n_s} | — | — |")
        lines.append("")
    else:
        lines.append("## 当前指标")
        lines.append("")
        lines.append("| 指标 | 值 |")
        lines.append("|---|---|")
        for key, label, unit in _METRIC_ORDER:
            if new.get(key) is not None:
                lines.append(f"| {label} | {new[key]}{unit} |")
        lines.append("")

    # ---- 解析空告警 ----
    # ⚠ 实测踩过：把顶层 syn/report/csynth.rpt 喂进来时，
    #   它的布局（`Synthesis Summary Report of ...` + `Performance &
    #   Resource Estimates`）与本解析器期望的
    #   （`Vitis HLS Report for '...'` + `Utilization Estimates`）
    #   完全不同，于是**一个关键词都匹配不到**，
    #   输出一张只有表头的空表 —— 而退出码是 0。
    #   这正是本项目反复强调的"看起来成功、其实什么都没做"。
    #   所以这里显式告警，别让空表被当成"指标全为零"。
    _MEASURED = ("estimated_fmax_mhz", "latency_min", "interval_min",
                 "lut", "dsp", "ff", "bram_18k")
    if not any(new.get(k) is not None for k in _MEASURED) and not new.get("loops"):
        lines.append("## ⚠ 未解析到任何指标")
        lines.append("")
        lines.append("**这个报告可能不是本工具支持的布局。**")
        lines.append("")
        lines.append("本解析器认的是**模块级**报告 "
                     "(`syn/report/<模块>_csynth.rpt`，"
                     "标题为 `Vitis HLS Report for '...'`)。")
        lines.append("")
        lines.append("顶层 `syn/report/csynth.rpt` 是另一种布局"
                     "(`Synthesis Summary Report of ...`)，**本工具不认** —— ")
        lines.append("它是**另一种报告**，不是解析失败，是格式不同。")
        lines.append("顶层报告的指标请直接从该文件的 "
                     "`Performance & Resource Estimates` 表读。")
        lines.append("")

    # 循环级 II 明细
    if new.get("loops"):
        lines.append("## 循环明细")
        lines.append("")
        lines.append("| 循环 | Latency | Achieved II | Target II | 已流水化 |")
        lines.append("|---|---|---|---|---|")
        for lp in new["loops"]:
            lat = lp.get("latency")
            lat_s = f"{lat[0]}~{lat[1]}" if lat else "—"
            ii_s = lp["achieved_ii"] if lp["achieved_ii"] is not None else "—"
            tgt_s = lp.get("target_ii") if lp.get("target_ii") is not None else "—"
            pipes = "✅" if lp.get("pipelined") else "❌"
            lines.append(f"| `{lp['loop']}` | {lat_s} | **{ii_s}** | {tgt_s} | {pipes} |")
        lines.append("")

    # 已流水化的模块组
    if new.get("pipelined_groups"):
        lines.append("## 模块组流水情况")
        lines.append("")
        lines.append("| 实例 | Latency | Interval | 类型 | 已流水化 |")
        lines.append("|---|---|---|---|---|")
        for g in new["pipelined_groups"]:
            lat = g.get("latency")
            lat_s = f"{lat[0]}~{lat[1]}" if lat else "—"
            itv = g.get("interval")
            # ⚠ Interval=0 对 stp 类型表示"流水线已启动，间隔由循环边界决定"，
            #   不是 II=0。按 0 原样显示，不做特殊解释。
            itv_s = f"{itv[0]}~{itv[1]}" if itv else "—"
            mark = "✅" if g.get("pipelined") else "❌"
            lines.append(f"| `{g['instance'][:46]}` | {lat_s} | {itv_s} | "
                         f"{g['type']} | {mark} |")
        lines.append("")

    # 解读提示 —— 只陈述**从数据直接推出的**结论，不做超出证据的推断
    tips = []
    n_pipe_groups = new.get("n_groups_pipelined")
    if n_pipe_groups:
        tips.append(f"有 **{n_pipe_groups}** 个模块组已流水化"
                    f"（类型带 `pipeline` 标记）。这是吞吐的主要来源。")
    if new.get("loops") and new.get("n_loops_pipelined") == 0:
        # 注意：Loop 表的 Pipelined=no 往往是外层循环 —— 不代表整体未流水化
        tips.append("Loop 表里的循环均未标记为 pipelined —— 这通常是**外层**循环。"
                    "整体是否流水化要看上面的「模块组」表，两者不矛盾。")
    if new.get("interval_max") and new.get("latency_max"):
        if new.get("interval_max") >= new["latency_max"]:
            tips.append("顶层 Interval ≈ Latency：各模块基本串行执行，"
                        "若模块间有生产者-消费者关系，可试 `#pragma HLS DATAFLOW` 让它们重叠")
    if new.get("estimated_fmax_mhz") and new.get("target_clock_ns"):
        tgt_mhz = 1000.0 / new["target_clock_ns"]
        margin = new["estimated_fmax_mhz"] / tgt_mhz
        tips.append(f"Est. Fmax {new['estimated_fmax_mhz']} MHz vs 目标 "
                    f"{tgt_mhz:.0f} MHz → 余量 {margin:.2f}×"
                    f"{'（充裕）' if margin > 1.2 else '（偏紧，注意实现后可能降频）'}")
    if new.get("wns_ns") is not None and new["wns_ns"] < 0:
        tips.append(f"WNS = {new['wns_ns']} < 0：时序违例，需要降频或加流水级")
    if tips:
        lines.append("## 解读")
        lines.append("")
        lines += [f"- {t}" for t in tips]
        lines.append("")

    return "\n".join(lines)


# =====================================================================
#  CLI
# =====================================================================
def _parse_shape(s):
    if not s:
        return None
    m = re.match(r"(\d+)\s*[xX×]\s*(\d+)", s)
    if not m:
        raise argparse.ArgumentTypeError(f"形状格式应为 HxW，得到 '{s}'")
    return int(m.group(1)), int(m.group(2))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="黄金参考比对 + HLS 指标采集报告",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"golden_compare {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    # --- compare ---
    cp = sub.add_parser("compare", help="比对硬件输出与参考输出")
    cp.add_argument("hw", help="硬件输出文件")
    cp.add_argument("golden", help="参考输出文件")
    cp.add_argument("--shape", type=_parse_shape, help="形状 HxW（把一维数据 reshape）")
    cp.add_argument("--dtype", default="uint8", help="原始数据 dtype（默认 uint8）")
    cp.add_argument("--ignore-border", type=int, default=0,
                    help="忽略边界 k 像素（图像处理常只比有效区）")
    cp.add_argument("--tol", type=int, default=0, help="容差（默认 0，逐位严格）")

    # --- report ---
    rp = sub.add_parser("report", help="采集 HLS 报告指标")
    rp.add_argument("reports", nargs="+", help="csynth.rpt / impl 报告")
    rp.add_argument("--baseline", help="baseline JSON（写入或对比）")
    rp.add_argument("--compare", action="store_true", help="与 baseline 对比（生成 delta 表）")
    rp.add_argument("-o", "--out", help="输出 markdown 到文件")

    args = ap.parse_args(argv)

    # ---------------- compare ----------------
    if args.cmd == "compare":
        try:
            a = load_array(args.hw, args.shape, np.dtype(args.dtype))
            b = load_array(args.golden, args.shape, np.dtype(args.dtype))
        except (FileNotFoundError, ValueError, ImportError) as e:
            print(f"[错误] {e}", file=sys.stderr)
            return 2

        ok, info = compare(a, b, ignore_border=args.ignore_border)
        print(fmt_compare(info))
        return 0 if ok else 1

    # ---------------- report ----------------
    if args.cmd == "report":
        metrics = {}
        for r in args.reports:
            try:
                if "csynth" in Path(r).name:
                    metrics.update(parse_csynth(r))
                else:
                    metrics.update(parse_impl(r))
            except FileNotFoundError as e:
                print(f"[警告] {e}", file=sys.stderr)

        if not metrics or len(metrics) <= 1:
            print("[错误] 未从报告中解析到任何指标", file=sys.stderr)
            print("       请确认文件是 Vitis HLS 的 csynth.rpt 或实现报告", file=sys.stderr)
            return 1

        baseline = None
        if args.baseline and Path(args.baseline).is_file():
            baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8"))

        md = fmt_report(metrics, baseline if args.compare else None)
        if args.out:
            Path(args.out).write_text(md, encoding="utf-8")
            print(f"[OK] 报告已写入 {args.out}")
        else:
            print(md)

        if args.baseline and not args.compare:
            Path(args.baseline).write_text(
                json.dumps(metrics, indent=2, ensure_ascii=False), encoding="utf-8")
            print(f"[OK] baseline 已写入 {args.baseline}")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
