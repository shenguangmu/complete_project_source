#!/usr/bin/env python3
"""
mdblock.py —— 极小的 Markdown 块级解析器（只做本手册需要的那部分）

【为什么自己写，不用现成的】

本机没有 pandoc；`python-docx` 只管生成 .docx，不管把 Markdown 解析成块。
需求也很窄：只要**标题 / 段落 / 列表 / 表格 / 围栏代码块 / 引用块 / 分隔线**
七种块，够渲染这份手册就行。

【⚠ 已知的局限（写在前面，别指望它通用）】

  · **不支持嵌套引用块**。`> > 文字` 会被当成普通引用。
    本手册里确实有这种写法（更正说明里嵌了代码块），
    处理方式见 `_flush_quote()` —— 引用内部仍识别围栏代码块。
  · 不支持行内 HTML、脚注、图片、任务列表的勾选状态（`- [x]`）。
  · 表格不支持单元格内换行（Markdown 本身也表达不了）。
  · 不考虑转义反斜杠（本手册没用到）。

**如果哪天这些局限挡路了，先加一条针对性测试再改** ——
本文件的行为由 `test_mdblock.py` 钉住。
"""

import re


class Block(dict):
    """一个块。用 dict 而非 class，方便直接 dump 出来看。"""
    __getattr__ = dict.get


def _split_table_row(line):
    """把一个表格行切成单元格。跳过首尾的竖线。"""
    s = line.strip()
    if s.startswith('|'):
        s = s[1:]
    if s.endswith('|'):
        s = s[:-1]
    return [c.strip() for c in s.split('|')]


def _is_table_sep(line):
    """是不是 `|---|---|:--:|` 这种表格分隔行"""
    s = line.strip()
    if not s.startswith('|') or '-' not in s:
        return False
    for cell in _split_table_row(s):
        if not re.fullmatch(r':?-{2,}:?', cell.strip()):
            return False
    return True


_HEADING = re.compile(r'^(#{1,6})\s+(.*?)\s*$')
_UL      = re.compile(r'^(\s*)[-*+]\s+(.*)$')
_OL      = re.compile(r'^(\s*)(\d+)[.)]\s+(.*)$')
_FENCE   = re.compile(r'^(\s*)(```+|~~~+)\s*([\w+-]*)\s*$')
_HR      = re.compile(r'^\s*([-*_])\s*\1\s*\1[-*_\s]*$')


def parse(text):
    """把 Markdown 文本切成块列表。

    返回 list[Block]，每个 Block 有 'type' 与各自的字段：
      heading : level, text
      para    : text
      list    : ordered, items[list[str]]
      table   : header[list[str]], rows[list[list[str]]]
      code    : lang, lines[list[str]]
      quote   : blocks[list[Block]]   ← 递归！
      hr      : (无字段)
    """
    lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    blocks = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        # ---- 空行 ----
        if not line.strip():
            i += 1
            continue

        # ---- 分隔线（放在标题/列表之前判，避免 `---` 被当成列表项）----
        if _HR.match(line) and not line.strip().startswith('|'):
            blocks.append(Block(type='hr'))
            i += 1
            continue

        # ---- 标题 ----
        m = _HEADING.match(line)
        if m:
            blocks.append(Block(type='heading', level=len(m.group(1)),
                                text=m.group(2).strip()))
            i += 1
            continue

        # ---- 围栏代码块 ----
        m = _FENCE.match(line)
        if m:
            indent, fence, lang = m.group(1), m.group(2), m.group(3)
            body = []
            i += 1
            while i < n and not re.match(r'^\s*' + re.escape(fence[0]) * 3 + r'+', lines[i]):
                # 去掉公共缩进
                body.append(lines[i][len(indent):] if lines[i].startswith(indent)
                            else lines[i].lstrip())
                i += 1
            i += 1   # 跳过收尾的 ```
            blocks.append(Block(type='code', lang=lang, lines=body))
            continue

        # ---- 引用块 ----
        if line.lstrip().startswith('>'):
            qlines = []
            while i < n and lines[i].lstrip().startswith('>'):
                # 去掉一级 '>' 及其后的一个空格
                s = lines[i].lstrip()[1:]
                qlines.append(s[1:] if s.startswith(' ') else s)
                i += 1
            blocks.append(Block(type='quote', blocks=parse('\n'.join(qlines))))
            continue

        # ---- 表格 ----
        if (line.strip().startswith('|') and i + 1 < n
                and _is_table_sep(lines[i + 1])):
            header = _split_table_row(line)
            i += 2
            rows = []
            while i < n and lines[i].strip().startswith('|'):
                cells = _split_table_row(lines[i])
                # 补齐/截断到表头列数，防列数不齐时后面下标越界
                cells = (cells + [''] * len(header))[:len(header)]
                rows.append(cells)
                i += 1
            blocks.append(Block(type='table', header=header, rows=rows))
            continue

        # ---- 无序列表 ----
        m = _UL.match(line)
        if m:
            items = []
            while i < n:
                mm = _UL.match(lines[i])
                if not mm:
                    # 续行（缩进的普通文本）并到上一条
                    if items and lines[i].strip() and lines[i].startswith((' ', '\t')):
                        items[-1] += ' ' + lines[i].strip()
                        i += 1
                        continue
                    break
                items.append(mm.group(2))
                i += 1
            blocks.append(Block(type='list', ordered=False, items=items))
            continue

        # ---- 有序列表 ----
        m = _OL.match(line)
        if m:
            items = []
            while i < n:
                mm = _OL.match(lines[i])
                if not mm:
                    if items and lines[i].strip() and lines[i].startswith((' ', '\t')):
                        items[-1] += ' ' + lines[i].strip()
                        i += 1
                        continue
                    break
                items.append(mm.group(3))
                i += 1
            blocks.append(Block(type='list', ordered=True, items=items))
            continue

        # ---- 普通段落（连续非空行并成一段）----
        # ⚠ 终止条件必须包含列表标记 —— 否则"段落紧跟列表、中间没有空行"
        #   会把列表项并进段落。本手册 §7.1 的证据链就是这种写法。
        para = [line.strip()]
        i += 1
        while (i < n and lines[i].strip()
               and not _HEADING.match(lines[i])
               and not _FENCE.match(lines[i])
               and not lines[i].lstrip().startswith('>')
               and not lines[i].strip().startswith('|')
               and not _UL.match(lines[i])
               and not _OL.match(lines[i])
               and not _HR.match(lines[i])):
            para.append(lines[i].strip())
            i += 1
        blocks.append(Block(type='para', text=' '.join(para)))

    return blocks


def iter_text(blocks):
    """把块树摊平成 (类型, 文本) 序列，便于测试与搜索"""
    for b in blocks:
        if b['type'] == 'quote':
            yield from iter_text(b['blocks'])
        elif b['type'] == 'table':
            yield ('table', ' | '.join(b['header']))
            for r in b['rows']:
                yield ('table', ' | '.join(r))
        elif b['type'] == 'list':
            for it in b['items']:
                yield ('list', it)
        elif b['type'] == 'code':
            yield ('code', '\n'.join(b['lines']))
        elif b['type'] == 'heading':
            yield ('heading', b['text'])
        elif b['type'] == 'para':
            yield ('para', b['text'])
        else:
            yield (b['type'], '')
