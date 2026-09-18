#!/usr/bin/env python3
"""
ip_contract.py —— 从 .hwh / component.xml 提取 IP 接口契约

【为什么需要这个工具】

一个真实 Block Design 导出的 .hwh 文件实测 **307 KB ≈ 77,000 tokens**。
直接读进 LLM 上下文会瞬间吃掉整个窗口，且 88% 是重复的描述文本。

本工具把原始文件压成**紧凑 JSON 契约**（通常 < 3 KB），只保留决策需要的
信息：寄存器偏移、位域、地址范围、接口清单。描述字段默认丢弃，需要时
用 --with-desc 单独取。

**核心约定：原始 .hwh 永远不要直接 Read，一律通过本工具。**

【用法】

    # 看有哪些 IP、各自占多少寄存器
    python ip_contract.py board.hwh

    # 完整契约（JSON）
    python ip_contract.py board.hwh --json out.json

    # 只看某个 IP
    python ip_contract.py board.hwh --ip sobel_accel_0

    # 只要 C 宏（可直接粘进驱动头文件）
    python ip_contract.py board.hwh --ip sobel_accel_0 --format c

    # 生成 Python register_map 属性名对照
    python ip_contract.py board.hwh --ip sobel_accel_0 --format py

【支持的输入】
  - .hwh            : Vivado Block Design 硬件交接文件（推荐，信息最全）
  - component.xml   : HLS 导出 IP 的组件描述（只有单 IP，无地址分配）

【退出码】
  0 成功 / 1 输入错误 / 2 解析失败
"""

import argparse
import json
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

__version__ = "1.0.0"

# 描述类字段在压缩时默认丢弃 —— 它们占了 .hwh 体积的绝大部分
_DROP_PROPS = {"DESCRIPTION", "DISPLAY_NAME", "TOOL_COMMAND", "XML_FILE"}


# ---------------------------------------------------------------------
#  解析
# ---------------------------------------------------------------------
def _props(node):
    """把 <PROPERTY NAME= VALUE=> 子节点收成 dict"""
    out = {}
    for p in node.findall("PROPERTY"):
        name = p.get("NAME")
        if name:
            out[name] = p.get("VALUE", "")
    return out


def _text(node, tag):
    el = node.find(tag)
    return (el.text or "").strip() if el is not None and el.text else ""


def parse_hwh(path, keep_desc=False):
    """
    解析 .hwh，返回 {instance: contract}

    contract = {
        "vlnv": str, "modtype": str,
        "addr_blocks": {name: {"access":..., "range":...}},
        "registers":   {name: {"offset":int, "size":int, "access":str,
                               "reset":str, "fields":{name:{offset,width,access}}}},
        "memory_ranges": [{base, high, ...}],
        "interfaces":  [name, ...],
    }
    """
    tree = ET.parse(path)
    root = tree.getroot()
    out = {}

    for mod in root.iter("MODULE"):
        inst = mod.get("INSTANCE")
        if not inst:
            continue

        c = {
            "vlnv": mod.get("VLNV", ""),
            "modtype": mod.get("MODTYPE", ""),
            "addr_blocks": {},
            "registers": {},
            "memory_ranges": [],
            "interfaces": [],
        }

        # --- 地址块 + 寄存器 ---
        for ab in mod.iter("ADDRESSBLOCK"):
            ab_name = ab.get("NAME", "Reg")
            c["addr_blocks"][ab_name] = {
                "access": ab.get("ACCESS", ""),
                "range": ab.get("RANGE", ""),
                "usage": ab.get("USAGE", ""),
            }
            for reg in ab.iter("REGISTER"):
                rp = _props(reg)
                rname = reg.get("NAME")
                if not rname:
                    continue
                entry = {
                    "offset": int(rp.get("ADDRESS_OFFSET", "0"), 16)
                    if rp.get("ADDRESS_OFFSET", "").startswith("0x")
                    else int(rp.get("ADDRESS_OFFSET", "0") or 0),
                    "size": int(rp.get("SIZE", "32") or 32),
                    "access": rp.get("ACCESS", ""),
                    "reset": rp.get("RESET_VALUE", ""),
                    "fields": {},
                }
                if keep_desc and rp.get("DESCRIPTION"):
                    entry["desc"] = rp["DESCRIPTION"]
                for fld in reg.iter("FIELD"):
                    fp = _props(fld)
                    fname = fld.get("NAME")
                    if not fname:
                        continue
                    f_entry = {
                        "offset": int(fp.get("ADDRESS_OFFSET", "0") or 0),
                        "width": int(fp.get("BIT_WIDTH", "1") or 1),
                        "access": fp.get("ACCESS", ""),
                    }
                    if keep_desc and fp.get("DESCRIPTION"):
                        f_entry["desc"] = fp["DESCRIPTION"][:120]
                    entry["fields"][fname] = f_entry
                c["registers"][rname] = entry

        # --- 内存映射范围（PS 侧地址） ---
        for mr in mod.iter("MEMRANGE"):
            mp = _props(mr)
            c["memory_ranges"].append({
                "base": mp.get("BASEVALUE", mr.get("BASEVALUE", "")),
                "high": mp.get("HIGHVALUE", mr.get("HIGHVALUE", "")),
                "inst": mp.get("INSTANCE", ""),
            })

        # --- 总线接口 ---
        for bi in mod.iter("BUSINTERFACE"):
            n = bi.get("NAME")
            if n:
                c["interfaces"].append(n)

        out[inst] = c

    return out


def parse_component_xml(path, keep_desc=False):
    """
    解析 HLS 导出的 component.xml —— 只有单个 IP，没有地址分配。
    寄存器来自 memoryMaps，接口来自 busInterfaces。
    """
    tree = ET.parse(path)
    root = tree.getroot()

    name = _text(root, "component/name") or root.get("name", "unknown")
    out = {
        name: {
            "vlnv": f"{root.get('vendor','')}:{root.get('library','')}:"
                    f"{root.get('name','')}:{root.get('version','')}".strip(":"),
            "modtype": "hls_ip",
            "addr_blocks": {},
            "registers": {},
            "memory_ranges": [],
            "interfaces": [],
        }
    }
    c = out[name]

    for bi in root.iter("busInterfaces"):
        for b in bi.findall("busInterface"):
            n = b.get("name")
            if n:
                c["interfaces"].append(n)

    for mm in root.iter("memoryMap"):
        ab_name = mm.get("name", "Reg")
        c["addr_blocks"][ab_name] = {"access": "read-write", "range": "", "usage": "register"}
        for blk in mm.iter("addressBlock"):
            c["addr_blocks"][ab_name]["range"] = blk.get("range", "")
            for reg in blk.iter("register"):
                rname = _text(reg, "name")
                off = _text(reg, "addressOffset")
                if not rname:
                    continue
                entry = {
                    "offset": int(off, 16) if off.startswith("0x") else int(off or 0),
                    "size": int(_text(reg, "size") or 32),
                    "access": _text(reg, "access") or "read-write",
                    "reset": "",
                    "fields": {},
                }
                if keep_desc:
                    d = _text(reg, "description")
                    if d:
                        entry["desc"] = d
                for fld in reg.iter("field"):
                    fname = _text(fld, "name")
                    if not fname:
                        continue
                    entry["fields"][fname] = {
                        "offset": int(_text(fld, "bitOffset") or 0),
                        "width": int(_text(fld, "bitWidth") or 1),
                        "access": _text(fld, "access"),
                    }
                c["registers"][rname] = entry

    return out


# ---------------------------------------------------------------------
#  输出格式
# ---------------------------------------------------------------------
def fmt_summary(contracts):
    """人类可读的摘要 —— 只给全局视图，不展开寄存器"""
    lines = []
    lines.append(f"{'INSTANCE':<26} {'MODTYPE':<22} {'REGS':>5} {'ADDR BLOCKS':<16} IFACES")
    lines.append("-" * 88)
    for inst, c in sorted(contracts.items()):
        if not c["registers"] and not c["interfaces"]:
            continue
        lines.append(
            f"{inst:<26} {c.get('modtype',''):<22} "
            f"{len(c['registers']):>5} {len(c['addr_blocks']):<16} "
            f"{len(c['interfaces'])}"
        )
    return "\n".join(lines)


def fmt_registers(inst, c):
    """单个 IP 的寄存器表"""
    lines = [f"# {inst}  ({c.get('vlnv')})", ""]
    if not c["registers"]:
        lines.append("  (无寄存器信息)")
        return "\n".join(lines)

    # 按偏移排序 —— 顺序稳定，便于 diff
    regs = sorted(c["registers"].items(), key=lambda kv: kv[1]["offset"])
    lines.append(f"  {'OFFSET':<8} {'NAME':<28} {'SIZE':>4} {'ACCESS':<12} RESET")
    lines.append("  " + "-" * 70)
    for name, r in regs:
        lines.append(f"  0x{r['offset']:<6X} {name:<28} {r['size']:>4} "
                     f"{r['access']:<12} {r['reset']}")
        for fname, f in sorted(r["fields"].items(), key=lambda kv: kv[1]["offset"]):
            lines.append(f"            └ {fname:<22} bit[{f['offset']}"
                         f"+{f['width']}] {f['access']}")
    return "\n".join(lines)


def fmt_c(inst, c, prefix=None):
    """生成 C 宏 —— 可直接粘进驱动头文件

    ⚠ 大小写约定：HLS 生成的标量参数寄存器在 .hwh 里是**小写**
    （如 `width`），但 HLS 自己导出的 C 驱动头文件里是**大写**
    （`SOBEL_REG_WIDTH`）。这里统一转大写，保证与官方驱动对得上。

    例外：`GIER` / `IP_IER` / `IP_ISR` 本身就是全大写，转大写无影响。
    """
    pfx = (prefix or inst).upper().replace("-", "_")
    lines = [
        f"/* 由 ip_contract.py 从硬件描述文件生成 —— 不要手改 */",
        f"/* 源: {c.get('vlnv','')} */",
        f"#ifndef {pfx}_HW_H",
        f"#define {pfx}_HW_H",
        "",
    ]
    for name, r in sorted(c["registers"].items(), key=lambda kv: kv[1]["offset"]):
        lines.append(f"#define {pfx}_REG_{name.upper():<24} 0x{r['offset']:02X}u")
    if any(r["fields"] for r in c["registers"].values()):
        lines.append("")
        for name, r in sorted(c["registers"].items(), key=lambda kv: kv[1]["offset"]):
            for fname, f in sorted(r["fields"].items(), key=lambda kv: kv[1]["offset"]):
                mask = ((1 << f["width"]) - 1) << f["offset"]
                lines.append(f"#define {pfx}_{name.upper()}_{fname}_MASK  0x{mask:08X}u")
                lines.append(f"#define {pfx}_{name.upper()}_{fname}_SHIFT {f['offset']}u")
    lines += ["", f"#endif /* {pfx}_HW_H */"]
    return "\n".join(lines)


def fmt_py(inst, c):
    """生成 PYNQ register_map 属性名对照 —— 避免手写偏移"""
    lines = [
        "from pynq import DefaultIP",
        "",
        "",
        f"class {_camel(inst)}(DefaultIP):",
        '    """由 ip_contract.py 生成，基于硬件描述文件。',
        "",
        "    字段名与 .hwh 一致，可直接用 register_map.<name> 访问。",
        '    """',
        "    bindto = ['%s']" % c.get("vlnv", ""),
        "",
        "    # 寄存器偏移（调试用；正常访问走 register_map）",
    ]
    for name, r in sorted(c["registers"].items(), key=lambda kv: kv[1]["offset"]):
        lines.append(f"    REG_{name} = 0x{r['offset']:02X}")
    lines.append("")
    lines.append("    # PYNQ 会自动从 .hwh 生成 register_map 属性，名字如下：")
    for name in sorted(c["registers"]):
        lines.append(f"    #   ip.register_map.{_snake(name)}")
    return "\n".join(lines)


def _snake(s):
    s = re.sub(r"[^0-9A-Za-z]+", "_", s)
    return re.sub(r"(?<!^)(?=[A-Z])", "_", s).lower().strip("_")


def _camel(s):
    return "".join(p.capitalize() for p in re.split(r"[^0-9A-Za-z]+", s) if p)


# ---------------------------------------------------------------------
#  CLI
# ---------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="从 .hwh / component.xml 提取 IP 接口契约（压缩 50× 以上）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("【用法】")[1].split("【支持")[0] if "【用法】" in __doc__ else "",
    )
    ap.add_argument("input", help=".hwh 或 component.xml")
    ap.add_argument("--ip", help="只看某个 IP 实例")
    ap.add_argument("--json", metavar="PATH", help="输出完整契约 JSON 到文件")
    ap.add_argument("--format", choices=["summary", "table", "c", "py"], default="summary",
                    help="summary=全局概览 / table=寄存器表(需 --ip) / c=C宏 / py=PYNQ类")
    ap.add_argument("--prefix", help="C 宏前缀（默认用实例名）")
    ap.add_argument("--with-desc", action="store_true",
                    help="保留描述字段（体积会大涨，默认丢弃）")
    ap.add_argument("--version", action="version", version=f"ip_contract {__version__}")

    args = ap.parse_args(argv)

    p = Path(args.input)
    if not p.is_file():
        print(f"[错误] 文件不存在: {p}", file=sys.stderr)
        return 1

    try:
        if p.suffix.lower() == ".hwh":
            contracts = parse_hwh(p, keep_desc=args.with_desc)
        elif p.name.endswith(".xml"):
            contracts = parse_component_xml(p, keep_desc=args.with_desc)
        else:
            print(f"[错误] 不支持的文件类型: {p.suffix}（支持 .hwh / .xml）", file=sys.stderr)
            return 1
    except ET.ParseError as e:
        print(f"[错误] XML 解析失败: {e}", file=sys.stderr)
        return 2

    if not contracts:
        print("[警告] 未解析到任何 IP 实例", file=sys.stderr)
        return 2

    # 落盘完整契约
    if args.json:
        Path(args.json).write_text(
            json.dumps(contracts, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"[OK] 契约已写入 {args.json}")

    # 终端输出
    if args.ip:
        if args.ip not in contracts:
            cand = ", ".join(sorted(contracts))
            print(f"[错误] 找不到 IP '{args.ip}'。可用: {cand}", file=sys.stderr)
            return 1
        c = contracts[args.ip]
        if args.format == "c":
            print(fmt_c(args.ip, c, args.prefix))
        elif args.format == "py":
            print(fmt_py(args.ip, c))
        else:
            print(fmt_registers(args.ip, c))
    else:
        print(fmt_summary(contracts))
        print()
        print(f"共 {len(contracts)} 个 IP 实例。用 --ip <名字> 看寄存器详情。")
        print("提示：这些 IP 的原始 .hwh 可能有几十万字节，不要直接读。")

    return 0


if __name__ == "__main__":
    sys.exit(main())
