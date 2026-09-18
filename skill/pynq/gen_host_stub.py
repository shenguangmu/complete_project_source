#!/usr/bin/env python3
"""
gen_host_stub.py —— 从接口契约生成主机侧调用代码 / 测试骨架

【解决什么问题】

从「硬件做好了」到「主机侧能调它」之间，要手写三份高度重复的代码：

  1. PYNQ 的 Python 驱动类（寄存器名、位域掩码、AXI-Lite 访问）
  2. 裸机的 C 头文件 + 轮询逻辑（偏移、AP_START/AP_DONE 时序）
  3. 测试骨架（把测试向量喂进去、跟黄金值比对）

这三份代码的**信息源头是同一个** —— 硬件的接口契约。手写就是把它抄三遍，
抄错一个偏移就是几小时的调试。本工具读一次契约，生成三份。

【用法】

    # 先提取契约
    python ip_contract.py board.hwh --ip my_accel_0 --json contract.json

    # 生成 PYNQ Python 驱动类
    python gen_host_stub.py contract.json --ip my_accel_0 --lang py -o driver.py

    # 生成裸机 C 驱动骨架
    python gen_host_stub.py contract.json --ip my_accel_0 --lang c -o driver.h

    # 生成测试骨架（含黄金比对）
    python gen_host_stub.py contract.json --ip my_accel_0 --lang tb -o tb_accel.py

    # 一次生成三种
    python gen_host_stub.py contract.json --ip my_accel_0 --lang all -o out/

【设计原则】

  - **不改契约里没有的东西** —— 生成的代码只基于硬件描述，不猜业务语义
  - **生成的骨架必须能跑** —— 参数校验、状态轮询、cache 同步都写好
  - **留 TODO 标记** —— 凡是需要人填的地方（如算法参数含义）显式标出
  - **与 dma_guard 配套** —— 生成的 Python 代码默认用 dma_guard 管 DMA
"""

import argparse
import json
import sys
from pathlib import Path

__version__ = "1.0.0"


def _snake(s):
    import re
    s = re.sub(r"[^0-9A-Za-z]+", "_", s)
    return re.sub(r"(?<!^)(?=[A-Z])", "_", s).lower().strip("_")


def _camel(s):
    import re
    return "".join(p.capitalize() for p in re.split(r"[^0-9A-Za-z]+", s) if p)


def _cls(inst):
    """实例名 → Python 类名"""
    base = _camel(inst)
    if base and base[0].isdigit():
        base = "Ip" + base
    return base


# ---------------------------------------------------------------------
#  分类寄存器 —— 决定生成什么代码
# ---------------------------------------------------------------------
def _classify(regs):
    """
    把寄存器分成几类：
      ctrl   : 控制/状态寄存器（含 AP_START / AP_DONE 等位域）
      scalar : 标量参数（可写、无位域、32 位满宽）
      other  : 其余（中断使能等）

    依据：位域名 + 权限。不猜业务含义。
    """
    ctrl, scalar, other = {}, {}, {}
    for name, r in regs.items():
        fields = r.get("fields", {})
        fnames = {f.upper() for f in fields}
        if {"AP_START"} & fnames or {"AP_DONE"} & fnames or {"AP_IDLE"} & fnames:
            ctrl[name] = r
        elif (r.get("access", "").startswith("write")
              and not fields
              or (len(fields) == 1 and list(fields)[0].lower() in name.lower())):
            scalar[name] = r
        else:
            other[name] = r
    return ctrl, scalar, other


# ---------------------------------------------------------------------
#  Python（PYNQ）
# ---------------------------------------------------------------------
def gen_py(inst, c, pkg=None):
    ctrl, scalar, other = _classify(c["registers"])
    cls = _cls(inst)

    L = [
        f'"""',
        f'{cls} —— 由 gen_host_stub.py 从硬件接口契约生成。',
        f'',
        f'源 VLNV: {c.get("vlnv","")}',
        f'',
        f'⚠ 生成后请勿手改偏移 —— 改了硬件要重新生成。',
        f'业务参数的含义（如 width 到底是像素还是字节）需要你补。',
        f'"""',
        f'',
        f'from pynq import DefaultIP',
        f'',
        f'',
        f'class {cls}(DefaultIP):',
        f'    """{inst} 的主机侧驱动"""',
        f'',
    ]
    if c.get("vlnv"):
        L.append(f'    bindto = ["{c["vlnv"]}"]')
        L.append('')

    # --- 寄存器偏移（常量，便于调试时对照） ---
    L.append('    # ---- 寄存器偏移（来自硬件描述，勿手改）----')
    for name, r in sorted(c["registers"].items(), key=lambda kv: kv[1]["offset"]):
        L.append(f'    REG_{name.upper()} = 0x{r["offset"]:02X}')
    L.append('')

    # --- 位域掩码 ---
    if ctrl:
        L.append('    # ---- 控制位域掩码 ----')
        for name, r in ctrl.items():
            for fn, f in r.get("fields", {}).items():
                if fn.upper().startswith("RESERVED"):
                    continue
                mask = ((1 << f["width"]) - 1) << f["offset"]
                L.append(f'    {name.upper()}_{fn.upper()} = 0x{mask:08X}  '
                         f'# bit[{f["offset"]}+{f["width"]}] {f["access"]}')
        L.append('')

    # --- 属性访问：把标量参数包成 property ---
    if scalar:
        L.append('    # ---- 标量参数（写寄存器）----')
        for name in scalar:
            pyname = _snake(name)
            L.append('    @property')
            L.append(f'    def {pyname}(self):')
            L.append(f'        return self.register_map.{name}')
            L.append('')
            L.append(f'    @{pyname}.setter')
            L.append(f'    def {pyname}(self, v):')
            L.append(f'        self.register_map.{name} = v')
            L.append('')

    # --- 启动 / 等待 ---
    ctrl_name = next(iter(ctrl), None) if ctrl else None
    if ctrl_name:
        cn = next(iter(ctrl))
        fields = {k.upper(): v for k, v in ctrl[cn].get("fields", {}).items()}
        start_b = fields.get("AP_START")
        done_b = fields.get("AP_DONE")
        idle_b = fields.get("AP_IDLE")

        L.append('    # ---- 启动与等待 ----')
        if start_b:
            m = 1 << start_b["offset"]
            L.append('    def start(self):')
            L.append(f'        """置 AP_START（bit{start_b["offset"]}）"""')
            L.append(f'        self.register_map.{cn} |= 0x{m:08X}')
            L.append('')
        if done_b:
            m = 1 << done_b["offset"]
            L.append('    def wait_done(self, timeout=5.0):')
            L.append(f'        """轮询 AP_DONE（bit{done_b["offset"]}，只读）"""')
            L.append('        import time')
            L.append('        t0 = time.time()')
            L.append('        while time.time() - t0 < timeout:')
            L.append(f'            if self.register_map.{cn} & 0x{m:08X}:')
            L.append('                return True')
            # 下面生成的是目标文件里的代码，含嵌套引号与目标侧的 f-string。
            # 用拼接而非嵌套 f-string —— 否则生成器会先求值目标文件的占位符，
            # 且转义引号会提前终止字符串。实测踩过这两个坑。
            L.append('        raise TimeoutError(')
            L.append('            "等待 AP_DONE 超时(" + str(timeout) + "s). '
                     f'{cn}="')
            L.append(f'            + format(self.register_map.{cn}, "#010x")')
            L.append('            + "\\n  排查: 1) IP 是否收到有效输入"')
            L.append('            + " 2) 流接口是否缺 TLAST"')
            L.append('            + " 3) 时钟/复位是否连接(见 09-pitfalls.md C3)"')
            L.append('        )')
            L.append('')
        if idle_b:
            m = 1 << idle_b["offset"]
            L.append('    def is_idle(self):')
            L.append(f'        return bool(self.register_map.{cn} & 0x{m:08X})')
            L.append('')

        L.append('    def run(self, timeout=5.0, **params):')
        L.append('        """启动一次并等待完成。params 键名对应标量参数寄存器名。"""')
        L.append('        for k, v in params.items():')
        L.append('            setattr(self.register_map, k, v)')
        L.append('        self.start()')
        L.append('        return self.wait_done(timeout)')
        L.append('')

    L.append('')
    L.append('# ── 用法示例 ──────────────────────────────────────────')
    L.append('# from pynq import Overlay')
    L.append(f'# ol = Overlay("design.bit")')
    L.append(f'# ip = ol.{inst}')
    for name in list(scalar)[:2]:
        L.append(f'# ip.{_snake(name)} = ...   # TODO: 填业务含义')
    L.append('# ip.run(timeout=5.0)')
    L.append('# ─────────────────────────────────────────────────────')

    return "\n".join(L)


# ---------------------------------------------------------------------
#  C（裸机）
# ---------------------------------------------------------------------
def gen_c(inst, c, prefix=None):
    pfx = (prefix or inst).upper().replace("-", "_")
    ctrl, scalar, other = _classify(c["registers"])
    ctrl_name = next(iter(ctrl), None)

    L = [
        '/* ─────────────────────────────────────────────────────────',
        f' * {pfx.lower()}_hw.h —— 由 gen_host_stub.py 从硬件接口契约生成',
        f' * 源 VLNV: {c.get("vlnv","")}',
        ' *',
        ' * ⚠ 勿手改偏移 —— 改了硬件要重新生成。',
        ' * ───────────────────────────────────────────────────────── */',
        f'#ifndef {pfx}_HW_H',
        f'#define {pfx}_HW_H',
        '',
        '#include <stdint.h>',
        '',
        '/* ---- 寄存器偏移 ---- */',
    ]
    for name, r in sorted(c["registers"].items(), key=lambda kv: kv[1]["offset"]):
        L.append(f'#define {pfx}_REG_{name.upper():<16} 0x{r["offset"]:02X}u')

    if ctrl:
        L.append('')
        L.append('/* ---- 控制位域 ---- */')
        for name, r in ctrl.items():
            for fn, f in r.get("fields", {}).items():
                if fn.upper().startswith("RESERVED"):
                    continue
                mask = ((1 << f["width"]) - 1) << f["offset"]
                L.append(f'#define {pfx}_{name.upper()}_{fn.upper()}_MASK  0x{mask:08X}u')
                L.append(f'#define {pfx}_{name.upper()}_{fn.upper()}_SHIFT {f["offset"]}u')

    L += [
        '',
        '/* ---- 供应用层使用的句柄 ---- */',
        'typedef struct {',
        '    uint32_t base;      /* AXI-Lite 基地址 */',
        '} %s_t;' % pfx.lower(),
        '',
        f'static inline void {pfx.lower()}_init({pfx.lower()}_t *d, uint32_t base) {{',
        '    d->base = base;',
        '}',
        '',
        'static inline uint32_t %s_rd(%s_t *d, uint32_t off) {' % (pfx.lower(), pfx.lower()),
        '    return *(volatile uint32_t *)(d->base + off);',
        '}',
        '',
        'static inline void %s_wr(%s_t *d, uint32_t off, uint32_t v) {' % (pfx.lower(), pfx.lower()),
        '    *(volatile uint32_t *)(d->base + off) = v;',
        '}',
        '',
    ]

    if ctrl_name:
        cn = ctrl_name
        fields = {k.upper(): v for k, v in ctrl[cn].get("fields", {}).items()}
        if "AP_START" in fields:
            m = 1 << fields["AP_START"]["offset"]
            L += [
                f'/* 启动一次（置 AP_START） */',
                f'static inline void {pfx.lower()}_start({pfx.lower()}_t *d) {{',
                f'    {pfx.lower()}_wr(d, {pfx}_REG_{cn.upper()},',
                f'                   {pfx.lower()}_rd(d, {pfx}_REG_{cn.upper()}) | 0x{m:08X}u);',
                '}',
                '',
            ]
        if "AP_DONE" in fields:
            m = 1 << fields["AP_DONE"]["offset"]
            L += [
                f'/*',
                f' * 等待完成。返回 0=成功，-1=超时。',
                f' *',
                f' * ⚠ 状态位在 {cn}(0x{ctrl[cn]["offset"]:02X}) 里，不在单独的 STATUS 寄存器。',
                f' *   HLS 的 AXI-Lite 没有 STATUS 寄存器 —— 这是个常见误解，',
                f' *   把 0x04(GIER, 中断使能) 当成状态会永远轮询不到。',
                f' *   详见 references/09-pitfalls.md D2。',
                f' */',
                f'static inline int {pfx.lower()}_wait_done({pfx.lower()}_t *d, uint32_t max_poll) {{',
                f'    uint32_t i;',
                f'    for (i = 0; i < max_poll; i++) {{',
                f'        if ({pfx.lower()}_rd(d, {pfx}_REG_{cn.upper()}) & 0x{m:08X}u) return 0;',
                '    }',
                '    return -1;',
                '}',
                '',
            ]

    if scalar:
        L.append('/* ---- 标量参数（按业务含义取用）---- */')
        for name in scalar:
            L.append(f'/* #define {pfx}_PARAM_{name.upper()}  {pfx}_REG_{name.upper()}  '
                     f'-- TODO: 确认含义 */')
        L.append('')

    L.append(f'#endif /* {pfx}_HW_H */')
    return "\n".join(L)


# ---------------------------------------------------------------------
#  测试骨架
# ---------------------------------------------------------------------
def gen_tb(inst, c, pkg=None):
    cls = _cls(inst)
    _ctrl, scalar, _other = _classify(c["registers"])

    L = [
        '"""',
        f'tb_{_snake(inst)}.py —— 由 gen_host_stub.py 生成的测试骨架',
        '',
        '跑法（无板卡也能跑，走 dma_guard 的主机仿真后端）：',
        '    python tb_%s.py --golden golden.bin' % _snake(inst),
        '',
        '⚠ 需要你补的地方标了 TODO —— 主要就是「输入怎么造、参数什么含义」。',
        '"""',
        '',
        'import argparse',
        'import sys',
        'from pathlib import Path',
        '',
        'import numpy as np',
        '',
        '# 与本 skill 的 pynq/ 目录同级的工具',
        'sys.path.insert(0, str(Path(__file__).resolve().parent))',
        'from dma_guard import DmaChannel',
        'from golden_compare import compare, fmt_compare',
        '',
        '',
        'def make_input(shape):',
        '    """TODO: 造测试输入。默认用随机数据。"""',
        '    rng = np.random.default_rng(0)',
        '    return rng.integers(0, 256, size=shape, dtype=np.uint8)',
        '',
        '',
        'def golden_model(src):',
        '    """TODO: 参考实现。这是整个测试的黄金标准。"""',
        '    raise NotImplementedError("请填入参考实现（Python/C 都行）")',
        '',
        '',
        'def main():',
        '    ap = argparse.ArgumentParser()',
        '    ap.add_argument("--shape", default="1080x1920", help="HxW")',
        '    ap.add_argument("--golden", help="已有的黄金输出文件（省略则用 golden_model）")',
        '    ap.add_argument("--board", action="store_true", help="跑在真实板卡上")',
        '    args = ap.parse_args()',
        '',
        '    h, w = (int(x) for x in args.shape.lower().split("x"))',
        '    src = make_input((h, w))',
        '',
        '    # 参考输出',
        '    if args.golden:',
        '        golden = np.fromfile(args.golden, dtype=np.uint8).reshape(h, w)',
        '    else:',
        '        golden = golden_model(src)',
        '',
    ]

    # 参数设置片段
    if scalar:
        L.append('    # ---- 参数设置（TODO: 确认业务含义）----')
        for name in scalar:
            L.append(f'    # param_{_snake(name)} = 0   '
                     f'# 寄存器 {name} @ 0x{c["registers"][name]["offset"]:02X}')
        L.append('')

    L += [
        '    if args.board:',
        '        from pynq import Overlay, allocate',
        f'        ol = Overlay("design.bit")',
        f'        ip = ol.{inst}',
        '        src_buf = allocate(shape=(h, w), dtype=np.uint8)',
        '        dst_buf = allocate(shape=(h, w), dtype=np.uint8)',
        '        src_buf[:] = src',
        '        src_buf.flush()            # DMA 前必须 flush',
        '        dma = DmaChannel(ol.axi_dma_0)',
        '        with dma.transfer(src_buf, dst_buf) as t:',
        '            t.wait(timeout=10.0)',
        '        result = np.array(dst_buf)  # transfer 退出时已 invalidate',
        '    else:',
        '        # 主机仿真：验证驱动逻辑，不含 cache / TLAST 问题',
        '        result = np.zeros_like(src)',
        '        dma = DmaChannel(None)',
        '        with dma.transfer(src, result) as t:',
        '            t.wait()',
        '',
        '    # ---- 黄金比对 ----',
        '    ok, info = compare(result, golden)',
        '    print(fmt_compare(info))',
        '    return 0 if ok else 1',
        '',
        '',
        'if __name__ == "__main__":',
        '    sys.exit(main())',
    ]
    return "\n".join(L)


# ---------------------------------------------------------------------
#  CLI
# ---------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="从接口契约生成主机侧调用代码 / 测试骨架",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("【用法】")[1].split("【设计原则】")[0])
    ap.add_argument("contract", help="ip_contract.py 产出的 JSON 契约")
    ap.add_argument("--ip", required=True, help="IP 实例名")
    ap.add_argument("--lang", required=True,
                    choices=["py", "c", "tb", "all"], help="生成哪种代码")
    ap.add_argument("-o", "--out", help="输出文件（lang=all 时作为输出目录）")
    ap.add_argument("--prefix", help="C 宏前缀（默认用实例名）")
    ap.add_argument("--version", action="version", version=f"gen_host_stub {__version__}")

    args = ap.parse_args(argv)

    p = Path(args.contract)
    if not p.is_file():
        print(f"[错误] 契约文件不存在: {p}", file=sys.stderr)
        print("       先用 ip_contract.py 生成，例如：", file=sys.stderr)
        print("       python ip_contract.py board.hwh --ip X --json contract.json",
              file=sys.stderr)
        return 1

    try:
        contracts = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"[错误] 契约 JSON 解析失败: {e}", file=sys.stderr)
        return 1

    if args.ip not in contracts:
        print(f"[错误] 契约里没有 IP '{args.ip}'。可用: "
              f"{', '.join(sorted(contracts))}", file=sys.stderr)
        return 1

    c = contracts[args.ip]
    if not c.get("registers"):
        print(f"[警告] '{args.ip}' 没有任何寄存器信息 —— 生成的代码可能不可用。",
              file=sys.stderr)
        print("       HLS IP 请用 component.xml，Block Design 请用 .hwh。",
              file=sys.stderr)

    stem = _snake(args.ip)

    if args.lang == "all":
        outdir = Path(args.out or ".")
        outdir.mkdir(parents=True, exist_ok=True)
        files = {
            outdir / f"{stem}_pynq.py": gen_py(args.ip, c),
            outdir / f"{stem}_hw.h": gen_c(args.ip, c, args.prefix),
            outdir / f"tb_{stem}.py": gen_tb(args.ip, c),
        }
        for fp, content in files.items():
            fp.write_text(content, encoding="utf-8")
            print(f"[OK] {fp}  ({len(content)} 字节)")
        print()
        print("[注意] 生成的骨架里有 TODO 标记 —— 那些是需要你补业务语义的地方。")
        return 0

    gen = {"py": gen_py, "c": gen_c, "tb": gen_tb}[args.lang]
    content = gen(args.ip, c) if args.lang != "c" else gen(args.ip, c, args.prefix)

    if args.out:
        Path(args.out).write_text(content, encoding="utf-8")
        print(f"[OK] 已写入 {args.out}  ({len(content)} 字节)")
    else:
        print(content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
