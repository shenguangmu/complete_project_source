#!/usr/bin/env python3
"""
test_mdblock.py —— mdblock 解析器的测试

【为什么值得单独测一个"小解析器"】

因为它错了不会报错，只会**静静地少渲染一段**。
本手册是打印出来照着做的，**漏掉一行可能就是漏掉一个烧板前的检查步骤**。
所以这里既测构造用例，也**拿真实文档当夹具**
（`docs/board-bringup-guide.md` 本身）—— 后者能抓到"某些写法没被识别"。

跑法：
    python scripts/test_mdblock.py
判定：`*** MDBLOCK TESTS PASSED ***`
"""

import io
import re
import sys
from pathlib import Path

try:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
except Exception:
    pass

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mdblock  # noqa: E402

_p = _f = 0


def ck(cond, msg):
    global _p, _f
    if cond:
        _p += 1
    else:
        _f += 1
        print("    [FAIL] %s" % msg)
    return cond


def types(blocks):
    return [b['type'] for b in blocks]


# =====================================================================
def test_heading():
    b = mdblock.parse("# 一级\n## 二级\n### 三级")
    ck(types(b) == ['heading'] * 3, "三级标题各成一个块")
    ck([x['level'] for x in b] == [1, 2, 3], "标题级别正确")
    ck(b[0]['text'] == '一级', "标题文本正确")


def test_hr_vs_list():
    # ⚠ `---` 既像分隔线又像列表项，必须判成 hr
    ck(types(mdblock.parse("---")) == ['hr'], "`---` 判为分隔线，不是列表")
    ck(types(mdblock.parse("- 甲")) == ['list'], "`- 甲` 判为列表")
    ck(types(mdblock.parse("- - -")) == ['hr'], "`- - -` 判为分隔线")


def test_table():
    md = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
    b = mdblock.parse(md)
    ck(types(b) == ['table'], "表格识别为一个块")
    ck(b[0]['header'] == ['A', 'B'], "表头正确")
    ck(b[0]['rows'] == [['1', '2'], ['3', '4']], "行正确")

    # ⚠ 列数不齐时必须补齐，否则渲染时下标越界
    md2 = "| A | B | C |\n|---|---|---|\n| 1 | 2 |"
    b2 = mdblock.parse(md2)
    ck(b2[0]['rows'][0] == ['1', '2', ''], "列数不齐时补空单元格")

    # 分隔行带对齐冒号
    ck(types(mdblock.parse("| A |\n|:--:|\n| 1 |")) == ['table'], "带冒号的对齐分隔行")


def test_code_fence():
    md = "前文\n```python\nx = 1\n\ny = 2\n```\n后文"
    b = mdblock.parse(md)
    ck(types(b) == ['para', 'code', 'para'], "代码块前后各成一段")
    ck(b[1]['lines'] == ['x = 1', '', 'y = 2'], "空行保留（代码块内不能合并）")
    ck(b[1]['lang'] == 'python', "语言标签正确")
    ck(mdblock.parse("```\n裸围栏\n```")[0]['lang'] == '', "无语言标签")


def test_list_continuation():
    md = "- 第一项\n  续行内容\n- 第二项"
    b = mdblock.parse(md)
    ck(b[0]['items'] == ['第一项 续行内容', '第二项'], "列表续行并入上一项")

    md2 = "1. 一\n2. 二"
    b2 = mdblock.parse(md2)
    ck(b2[0]['ordered'] and b2[0]['items'] == ['一', '二'], "有序列表")


def test_blockquote_nested():
    # ⚠ 本手册大量使用引用块，且引用里嵌标题/表格/代码
    md = "> ## 标题\n>\n> 正文\n>\n> ```\n> code\n> ```"
    b = mdblock.parse(md)
    ck(types(b) == ['quote'], "整个引用是一个块")
    inner = types(b[0]['blocks'])
    ck(inner == ['heading', 'para', 'code'], "引用内部递归解析（实得 %s）" % inner)


def test_real_document():
    """拿真实手册当夹具 —— 抓"某些写法没被识别" """
    p = Path(__file__).resolve().parent.parent / 'docs' / 'board-bringup-guide.md'
    if not p.is_file():
        print("    (跳过：找不到 %s)" % p)
        return
    text = p.read_text(encoding='utf-8')
    blocks = mdblock.parse(text)

    ck(len(blocks) > 50, "解析出足够多的块（实得 %d）" % len(blocks))

    # 摊平后统计：**不允许有内容整段消失**
    flat = list(mdblock.iter_text(blocks))
    kinds = {}
    for k, _ in flat:
        kinds[k] = kinds.get(k, 0) + 1
    ck(kinds.get('heading', 0) > 20, "标题数合理（%d）" % kinds.get('heading', 0))
    ck(kinds.get('table', 0) > 30, "表格行数合理（%d）" % kinds.get('table', 0))
    ck(kinds.get('code', 0) > 15, "代码块数合理（%d）" % kinds.get('code', 0))

    # ⚠ 最强的一条：原文里所有**有实质内容**的行，都应该能在
    #   摊平后的文本里找到。
    #
    #   抓的是"整段被解析器吞掉"这种静默丢失 —— 漏一行可能就是
    #   漏掉一个烧板前的检查步骤。
    #
    #   ⚠ 两个已修正的**测试自身**的坑（都不是解析器的问题）：
    #     ① 有序列表项存进 items 时**带 `1. ` 前缀**，探针串对不上
    #        → 比之前先剥掉列表标记
    #     ② 表格分隔行 `|---|---|` 是**该被消费掉**的，不算丢失
    #        → 显式排除
    #   这两条都实际发生过：第一版测试报了 5 个"丢失"，其中 1 个是 ②、
    #   4 个是 ①。**如果当时直接去"修解析器"，就改错了地方。**
    sep_re = re.compile(r'^\|[\s:|-]+\|$')
    missing = []
    for raw in text.split('\n'):
        s = raw.strip()
        if not s or s == '---' or sep_re.match(s):
            continue
        # 剥掉块级记号（标题 #、引用 >、列表 - * + 1. ）
        # ⚠ 要**反复剥**：`> ### 标题` 这种同时有引用和标题，
        #   只剥一次会剩下 `### 标题`，探针就永远对不上。
        #   （这也是测试自身踩过的第三个坑。）
        probe = s
        for _ in range(4):
            before = probe
            probe = re.sub(r'^>\s*', '', probe)
            probe = re.sub(r'^#+\s*', '', probe)
            probe = re.sub(r'^[-*+]\s+', '', probe)
            probe = re.sub(r'^\d+[.)]\s+', '', probe)
            if probe == before:
                break
        probe = probe.strip('|').strip()
        if len(probe) < 12:
            continue
        probe = probe[:24]
        if not any(probe in t for _, t in flat):
            missing.append(s[:70])
    ck(not missing,
       "没有整行内容被解析器丢掉（丢 %d 行%s）"
       % (len(missing), ('，例：' + missing[0]) if missing else ''))


# =====================================================================
def main():
    print("=" * 69)
    print("  mdblock 解析器测试")
    print("=" * 69)
    for fn in (test_heading, test_hr_vs_list, test_table, test_code_fence,
               test_list_continuation, test_blockquote_nested,
               test_real_document):
        print("\n[%s]" % fn.__name__)
        fn()
    print("\n" + "=" * 69)
    if _f == 0:
        print("  *** MDBLOCK TESTS PASSED ***  (%d 项)" % _p)
    else:
        print("  *** MDBLOCK TESTS FAILED ***  (%d 通过, %d 失败)" % (_p, _f))
    print("=" * 69)
    return 1 if _f else 0


if __name__ == "__main__":
    sys.exit(main())
