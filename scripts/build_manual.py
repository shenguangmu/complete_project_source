#!/usr/bin/env python3
"""
build_manual.py —— 把 docs/board-bringup-guide.md 渲染成可打印的 Word 手册

【定位】

**Markdown 是唯一事实来源，本脚本只负责渲染。**
改了 `.md` 就重跑一次，不要手工改 Word —— 那会让两份内容分叉
（这个项目已经在"双目录分叉"上吃过一次亏）。

    python scripts/build_manual.py                       # 默认输出到 docs/
    python scripts/build_manual.py -o 某处/手册.docx
    python scripts/build_manual.py --check               # 只检查能否渲染，不写文件

【针对"打印出来照着做"做的设计】

  · **A4、页边距 2cm**，正文 10.5pt —— 一页能放下更多步骤，省纸
  · **代码块用等宽 + 灰底 + 左边框**，一眼能和正文分开
    （终端里的命令抄错一个字符就白跑一轮）
  · **引用块加左边框**，因为本手册的"⚠ 注意"全在引用块里
  · **每个二级标题另起一页** —— 手上拿着一张纸做一个阶段
  · **页眉**写文档名，**页脚**写"第 X 页 / 共 Y 页"
  · **实测记录表**：`<!-- FILL: ... -->` 标记处会渲染成空白填写区
  · 文档里的 ⚠ / ✅ / ❌ 等符号用 Word 能显示的字形

【⚠ 已知不做的】

  · 不做目录（TOC）。python-docx 生成的是"域"，Word 打开时需要
    手动更新域才显示页码；打印前忘了更新会印出一页空的。
    与其埋这个坑，不如让用户自己在 Word 里"插入目录"。
  · 不做行内图片/公式（本手册没有）。
"""

import argparse
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

try:
    from docx import Document
    from docx.enum.section import WD_SECTION
    from docx.enum.table import WD_TABLE_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Cm, Pt, RGBColor
except ImportError:
    print("需要 python-docx：  pip install python-docx")
    sys.exit(2)


# =====================================================================
#  字体
# =====================================================================
# ⚠ 中文要同时设 ascii/hAnsi 与 eastAsia，否则 Word 里中文会回退成宋体
CJK   = '微软雅黑'
MONO  = 'Consolas'
LATIN = 'Segoe UI'

# 本机字体情况（与项目里 PPTX 的做法一致）：微软雅黑、Consolas 都随
# Windows 自带，WPS 也有。**不用等线/Cascadia**（不是所有机器都有）。


def _set_font(run, name=CJK, size=10.5, bold=False, italic=False,
              color=None, mono=False):
    f = run.font
    f.name = MONO if mono else name
    f.size = Pt(size)
    f.bold = bold
    f.italic = italic
    if color:
        f.color.rgb = RGBColor(*color)
    rPr = run._element.get_or_add_rPr()
    rf = rPr.find(qn('w:rFonts'))
    if rf is None:
        rf = OxmlElement('w:rFonts')
        rPr.append(rf)
    face = MONO if mono else name
    rf.set(qn('w:ascii'), face)
    rf.set(qn('w:hAnsi'), face)
    rf.set(qn('w:eastAsia'), CJK)
    return run


def _shade(el, fill):
    """给段落/单元格加底色"""
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill)
    el.append(shd)


def _left_border(p, color='B0B0B0', size=18, space=8):
    pPr = p._p.get_or_add_pPr()
    bd = OxmlElement('w:pBdr')
    left = OxmlElement('w:left')
    left.set(qn('w:val'), 'single')
    left.set(qn('w:sz'), str(size))
    left.set(qn('w:space'), str(space))
    left.set(qn('w:color'), color)
    bd.append(left)
    pPr.append(bd)


# =====================================================================
#  行内标记
# =====================================================================
# ⚠ 只处理四种：`code`、**粗**、~~删除~~、*斜*
#   顺序有讲究：先长后短，否则 `**粗**` 会被 `*斜*` 先吃掉。
_INLINE = re.compile(
    r'(`[^`]+`)'          # 1: 行内代码
    r'|(\*\*[^*]+\*\*)'   # 2: 粗体
    r'|(~~[^~]+~~)'       # 3: 删除线
    r'|(\*[^*\s][^*]*\*)' # 4: 斜体
)


def add_inline(p, text, base_size=10.5, base_bold=False):
    """把带行内标记的文本写进段落 p"""
    pos = 0
    for m in _INLINE.finditer(text):
        if m.start() > pos:
            _set_font(p.add_run(text[pos:m.start()]), size=base_size,
                      bold=base_bold)
        tok = m.group(0)
        if tok.startswith('`'):
            r = p.add_run(tok[1:-1])
            _set_font(r, size=base_size - 0.5, mono=True, bold=base_bold,
                      color=(0xA0, 0x30, 0x00))
        elif tok.startswith('**'):
            _set_font(p.add_run(tok[2:-2]), size=base_size, bold=True)
        elif tok.startswith('~~'):
            r = p.add_run(tok[2:-2])
            _set_font(r, size=base_size, bold=base_bold, color=(0x88, 0x88, 0x88))
            r.font.strike = True
        else:
            _set_font(p.add_run(tok[1:-1]), size=base_size,
                      bold=base_bold, italic=True)
        pos = m.end()
    if pos < len(text):
        _set_font(p.add_run(text[pos:]), size=base_size, bold=base_bold)


# =====================================================================
#  手填表格 —— 打印手册的核心价值
# =====================================================================
# ⚠ 为什么按**标题锚点**插入，而不是在 .md 里写 `<!-- FILL -->` 标记：
#
#   试过标记方案，有两个问题：
#     ① 本手册大量使用引用块，标记写在引用里时，`^...$` 匹配不到
#        （整行是 `> <!-- FILL -->`），于是被当成普通文本并进段落；
#     ② 为了加标记就得改 .md —— 而这些标记**只对 Word 版有意义**，
#        留在 Markdown 里是纯噪声，还会让 test_mdblock 的丢失检测报警。
#
#   按标题锚点插入则：**.md 一个字都不用改**，
#   渲染器自己知道哪个章节该配一张记录表。
#
# 每项：(标题里的一段子串, 表头列, 空白行数)
FILL_AFTER = [
    ('2.1 短路检查',
     ['测点', '读数', '判定（< 10 Ω 短路过 / 数百 Ω 正常）'], 4),
    ('2.2 引脚万用表复核',
     ['Pmod 脚位', '信号', 'XDC 预期引脚', '实测（通/断）', '与预期一致？'], 10),
    ('3.1 上电顺序',
     ['项', '设置 / 观察', '是否正常'], 5),
    ('4.0 先把两个文件弄出来',
     ['文件', '理论大小', '实际大小', '一致？'], 4),
    ('5.3 摄像头信号逐级排查',
     ['级', '测点', '期望', '实测（频率/有无）', '判定'], 6),
    ('5.4 VDMA 抓帧',
     ['项', '实测值', '说明'], 4),
    ('5.5 全链路',
     ['项', '结果', '备注'], 4),
]


def _add_fill_area(doc, cols, nrows=6, note=None):
    """一张空白手填表

    为什么需要它：手册是**打印出来照着做**的，
    万用表读数、示波器频率这类东西必须当场记下来。
    没有地方写，人就会记在别的纸上，然后那张纸就丢了。
    """
    if note:
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(2)
        _set_font(p.add_run(note), size=9, bold=True, color=(0x8B, 0x40, 0x00))

    t = doc.add_table(rows=1, cols=len(cols))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    hdr = t.rows[0].cells
    for j, c in enumerate(cols):
        hdr[j].text = ''
        p = hdr[j].paragraphs[0]
        p.paragraph_format.space_after = Pt(0)
        _set_font(p.add_run(c), size=9, bold=True)
        _shade(hdr[j]._tc.get_or_add_tcPr(), 'FFF2CC')

    for _ in range(nrows):
        cells = t.add_row().cells
        for c in cells:
            c.text = ''
            # 行高留够手写的空间
            c.paragraphs[0].paragraph_format.space_before = Pt(3)
            c.paragraphs[0].paragraph_format.space_after = Pt(3)

    doc.add_paragraph().paragraph_format.space_after = Pt(2)


# =====================================================================
#  渲染
# =====================================================================
def render(blocks, doc, first_h1_done=[False]):
    for b in blocks:
        t = b['type']

        if t == 'heading':
            lvl, txt = b['level'], b['text']
            if lvl == 1:
                p = doc.add_paragraph()
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                _set_font(p.add_run(txt), size=20, bold=True)
                p.paragraph_format.space_after = Pt(6)
                first_h1_done[0] = True
            elif lvl == 2:
                # 每个二级标题另起一页 —— 手里拿一张纸做一个阶段
                if first_h1_done[0]:
                    doc.add_page_break()
                p = doc.add_paragraph()
                p.paragraph_format.space_before = Pt(6)
                p.paragraph_format.space_after = Pt(8)
                _set_font(p.add_run(txt), size=15, bold=True,
                          color=(0x0B, 0x35, 0x60))
                p.paragraph_format.keep_with_next = True
            else:
                size = 12.5 if lvl == 3 else 11
                p = doc.add_paragraph()
                p.paragraph_format.space_before = Pt(8 if lvl == 3 else 6)
                p.paragraph_format.space_after = Pt(3)
                _set_font(p.add_run(txt), size=size, bold=True,
                          color=(0x1F, 0x4E, 0x79))
                p.paragraph_format.keep_with_next = True

        elif t == 'para':
            p = doc.add_paragraph()
            p.paragraph_format.space_after = Pt(4)
            p.paragraph_format.line_spacing = 1.15
            add_inline(p, b['text'])

        elif t == 'list':
            for idx, it in enumerate(b['items'], 1):
                p = doc.add_paragraph()
                p.paragraph_format.left_indent = Cm(0.75)
                p.paragraph_format.space_after = Pt(2)
                p.paragraph_format.line_spacing = 1.15
                mark = ('%d. ' % idx) if b.get('ordered') else '• '
                _set_font(p.add_run(mark), bold=b.get('ordered', False))
                add_inline(p, it)

        elif t == 'code':
            # 每行一个段落、整体加左边框 + 灰底，视觉上连成一块
            lines = b['lines'] or ['']
            for k, ln in enumerate(lines):
                p = doc.add_paragraph()
                pf = p.paragraph_format
                pf.left_indent = Cm(0.5)
                pf.space_before = Pt(1 if k == 0 else 0)
                pf.space_after = Pt(1 if k == len(lines) - 1 else 0)
                pf.line_spacing = 1.0
                _left_border(p, 'C0C0C0', 18, 8)
                _shade(p._p.get_or_add_pPr(), 'F5F5F5')
                _set_font(p.add_run(ln if ln else ' '), size=9, mono=True,
                          color=(0x1A, 0x1A, 0x1A))

        elif t == 'table':
            header, rows = b['header'], b['rows']
            tb = doc.add_table(rows=1, cols=len(header))
            tb.style = 'Table Grid'
            for j, c in enumerate(header):
                cell = tb.rows[0].cells[j]
                cell.text = ''
                p = cell.paragraphs[0]
                p.paragraph_format.space_after = Pt(0)
                add_inline(p, c, base_size=9.5, base_bold=True)
                _shade(cell._tc.get_or_add_tcPr(), 'DEEAF6')
            for r in rows:
                cells = tb.add_row().cells
                for j, c in enumerate(r):
                    cells[j].text = ''
                    p = cells[j].paragraphs[0]
                    p.paragraph_format.space_after = Pt(0)
                    add_inline(p, c, base_size=9.5)
            doc.add_paragraph().paragraph_format.space_after = Pt(2)

        elif t == 'quote':
            # 引用块整体缩进 + 左边框；内部再递归渲染
            for ib in b['blocks']:
                _render_quote_block(ib, doc)

        elif t == 'hr':
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            pPr = p._p.get_or_add_pPr()
            bd = OxmlElement('w:pBdr')
            bot = OxmlElement('w:bottom')
            bot.set(qn('w:val'), 'single')
            bot.set(qn('w:sz'), '6')
            bot.set(qn('w:space'), '1')
            bot.set(qn('w:color'), 'CCCCCC')
            bd.append(bot)
            pPr.append(bd)


def _render_quote_block(ib, doc):
    """引用块内部的块。⚠ 必须与主体渲染区分：
    引用里的标题要**降级**（不能另起一页），代码块要更紧凑。
    """
    t = ib['type']

    if t == 'heading':
        p = doc.add_paragraph()
        p.paragraph_format.left_indent = Cm(0.6)
        p.paragraph_format.space_before = Pt(6)
        p.paragraph_format.space_after = Pt(3)
        _set_font(p.add_run(ib['text']), size=11.5 if ib['level'] <= 2 else 10.5,
                  bold=True, color=(0x8B, 0x40, 0x00))
        p.paragraph_format.keep_with_next = True

    elif t == 'para':
        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.left_indent = Cm(0.6)
        pf.space_after = Pt(3)
        pf.line_spacing = 1.12
        _left_border(p, 'E0A060', 16, 8)
        add_inline(p, ib['text'])

    elif t == 'list':
        for idx, it in enumerate(ib['items'], 1):
            p = doc.add_paragraph()
            pf = p.paragraph_format
            pf.left_indent = Cm(1.1)
            pf.space_after = Pt(2)
            _left_border(p, 'E0A060', 16, 8)
            mark = ('%d. ' % idx) if ib.get('ordered') else '• '
            _set_font(p.add_run(mark))
            add_inline(p, it)

    elif t == 'code':
        lines = ib['lines'] or ['']
        for k, ln in enumerate(lines):
            p = doc.add_paragraph()
            pf = p.paragraph_format
            pf.left_indent = Cm(0.9)
            pf.space_before = Pt(1 if k == 0 else 0)
            pf.space_after = Pt(1 if k == len(lines) - 1 else 0)
            pf.line_spacing = 1.0
            _left_border(p, 'C0C0C0', 18, 8)
            _shade(p._p.get_or_add_pPr(), 'F5F5F5')
            _set_font(p.add_run(ln if ln else ' '), size=9, mono=True)

    elif t == 'table':
        tb = doc.add_table(rows=1, cols=len(ib['header']))
        tb.style = 'Table Grid'
        for j, c in enumerate(ib['header']):
            cell = tb.rows[0].cells[j]
            cell.text = ''
            p = cell.paragraphs[0]
            add_inline(p, c, base_size=9, base_bold=True)
            _shade(cell._tc.get_or_add_tcPr(), 'DEEAF6')
        for r in ib['rows']:
            cells = tb.add_row().cells
            for j, c in enumerate(r):
                cells[j].text = ''
                p = cells[j].paragraphs[0]
                add_inline(p, c, base_size=9)
        doc.add_paragraph()

    elif t == 'quote':
        for sub in ib['blocks']:
            _render_quote_block(sub, doc)

    elif t == 'hr':
        pass   # 引用里的分隔线直接忽略，省纸


# =====================================================================
#  页眉页脚
# =====================================================================
def _add_field(paragraph, instr):
    """插入 Word 域（用于页码）"""
    r = paragraph.add_run()
    fld1 = OxmlElement('w:fldChar'); fld1.set(qn('w:fldCharType'), 'begin')
    it = OxmlElement('w:instrText'); it.set(qn('xml:space'), 'preserve')
    it.text = instr
    fld2 = OxmlElement('w:fldChar'); fld2.set(qn('w:fldCharType'), 'end')
    r._r.append(fld1); r._r.append(it); r._r.append(fld2)
    return r


def setup_header_footer(doc, title):
    sec = doc.sections[0]

    hp = sec.header.paragraphs[0]
    hp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    _set_font(hp.add_run(title), size=8.5, color=(0x80, 0x80, 0x80))

    fp = sec.footer.paragraphs[0]
    fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    _set_font(fp.add_run('第 '), size=8.5, color=(0x80, 0x80, 0x80))
    _set_font(_add_field(fp, ' PAGE '), size=8.5, color=(0x80, 0x80, 0x80))
    _set_font(fp.add_run(' 页 / 共 '), size=8.5, color=(0x80, 0x80, 0x80))
    _set_font(_add_field(fp, ' NUMPAGES '), size=8.5, color=(0x80, 0x80, 0x80))
    _set_font(fp.add_run(' 页'), size=8.5, color=(0x80, 0x80, 0x80))

    # ⚠ 域在 Word 打开时可能显示为空白，需要 Ctrl+A → F9 更新。
    #   所以**不生成目录**（目录是个更显眼的域），页脚这个不影响阅读。


# =====================================================================
def build(md_path, out_path):
    text = Path(md_path).read_text(encoding='utf-8')
    blocks = mdblock.parse(text)

    doc = Document()

    # 页面：A4 + 2cm 边距
    sec = doc.sections[0]
    sec.page_width = Cm(21.0)
    sec.page_height = Cm(29.7)
    sec.left_margin = sec.right_margin = Cm(2.0)
    sec.top_margin = Cm(1.8)
    sec.bottom_margin = Cm(1.8)

    # 正文默认样式
    st = doc.styles['Normal']
    st.font.name = CJK
    st.font.size = Pt(10.5)
    st.element.rPr.rFonts.set(qn('w:eastAsia'), CJK)
    st.paragraph_format.space_after = Pt(4)

    title = '上板测试指南 — 手势识别系统（PYNQ-Z2）'
    setup_header_footer(doc, title)

    # ---- 渲染，并把记录表插到**该小节末尾** ----
    #
    # ⚠ 位置很关键：不能插在标题之后（那样会把"判定标准"挤到表格下面，
    #   人填数时看不到该填什么）。要等这个小节的内容渲染完再插。
    #
    #   实现：先扫描，算出每个锚点标题到**下一个同级或更高级标题**
    #   之间的结束位置，在那之前插入。
    pend = {}          # 锚点 idx -> 该小节最后一个块的全局下标
    cur = None
    for i, b in enumerate(blocks):
        if b['type'] == 'heading':
            lvl = b['level']
            # 遇到同级或更高级标题 → 当前小节结束
            if cur is not None and lvl <= cur[1]:
                pend[cur[0]] = i - 1
                cur = None
            if cur is None:
                for idx, (anchor, _, _) in enumerate(FILL_AFTER):
                    if idx not in pend and anchor in b['text']:
                        cur = (idx, lvl)
                        break
    if cur is not None:                     # 文档末尾的那个
        pend[cur[0]] = len(blocks) - 1

    missing = [FILL_AFTER[i][0] for i in range(len(FILL_AFTER))
               if i not in pend]
    if missing:
        print("  [!] 这些锚点没在文档里找到，对应记录表未插入：")
        for m in missing:
            print("      " + m)

    by_pos = {pos: idx for idx, pos in pend.items()}
    for i, b in enumerate(blocks):
        render([b], doc)
        if i in by_pos:
            _, cols, nrow = FILL_AFTER[by_pos[i]]
            doc.add_paragraph().paragraph_format.space_after = Pt(2)
            _add_fill_area(doc, cols, nrow,
                           note='▼ 现场记录（打印后手填）')

    # 打印前提醒（放在文末，不占开头）
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(12)
    _set_font(p.add_run('— 手册结束 —'), size=9, color=(0x99, 0x99, 0x99))
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(out_path))
    return len(blocks)


def main():
    ap = argparse.ArgumentParser(description='把上板指南渲染成可打印的 Word 手册')
    root = Path(__file__).resolve().parent.parent
    ap.add_argument('-i', '--input', default=str(root / 'docs' / 'board-bringup-guide.md'))
    ap.add_argument('-o', '--output',
                    default=str(root / 'docs' / '上板测试操作手册.docx'))
    ap.add_argument('--check', action='store_true',
                    help='只解析并统计，不写文件（用于 CI）')
    args = ap.parse_args()

    if not Path(args.input).is_file():
        print("找不到输入：%s" % args.input)
        return 2

    if args.check:
        blocks = mdblock.parse(Path(args.input).read_text(encoding='utf-8'))
        kinds = {}
        for k, _ in mdblock.iter_text(blocks):
            kinds[k] = kinds.get(k, 0) + 1
        print("解析成功：%d 个块" % len(blocks))
        for k in sorted(kinds):
            print("  %-8s %d" % (k, kinds[k]))
        return 0

    n = build(args.input, args.output)
    size = Path(args.output).stat().st_size
    print("已生成：%s" % args.output)
    print("  块数 %d，大小 %.1f KB" % (n, size / 1024))
    print()
    print("  打印建议：A4 双面，正文已按 2cm 边距排版；")
    print("  每个二级章节另起一页，适合手上拿一张做一个阶段。")
    return 0


if __name__ == '__main__':
    sys.exit(main())
