#!/usr/bin/env bash
# =====================================================================
#  build_preproc_sim.sh —— 编译并运行预处理驱动的主机自检
#
#  用法：bash sw/build_preproc_sim.sh
#
#  ⚠ 判定标准是 "*** PREPROC DRIVER SIM PASSED ***"
#
#  ─────────────────────────────────────────────────────────────────
#  为什么要有这个脚本（踩过的坑）
#  ─────────────────────────────────────────────────────────────────
#  Vitis 自带的 clang.exe 依赖**同目录**的 DLL
#  （LLVM-C.dll / libclang.dll / Remarks.dll）。
#
#  找不到它们时报：
#      clang.exe: error while loading shared libraries: ?
#  或（Windows 层）返回码 -1073741515 = 0xC0000135 = DLL not found
#
#  解法就是**把 clang 所在目录加进 PATH** —— 仅此而已。
#
#  ⚠ 但有两个陷阱：
#
#    1. 不要把 PATH 裁得太窄。我一度写成
#         export PATH="/usr/bin:/bin"
#       结果连基本的 shell 工具都找不到，白白绕了远路。
#       这里用 "$PATH:<clang_dir>" 追加，不动原 PATH。
#
#    2. **不要绕道 PowerShell**。我试过写 .ps1 来"正确设置 Windows
#       环境变量"，反而引入两个新问题：
#         - .ps1 不带 UTF-8 BOM 时，中文注释被按 GBK 解码，
#           报 "字符串缺少终止符" 的 ParserError
#         - bash → PowerShell 的路径/引号要过两层转义，极易写坏
#       直接在 bash 里追加 PATH 就够，简单可靠。
# =====================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

CLANG_DIR="D:/BaiduNetdiskDownload/2025.2/Vitis/win64/tools/clang-16/bin"

if [ ! -x "$CLANG_DIR/clang.exe" ]; then
    echo "ERROR: 找不到 Vitis 自带的 clang：$CLANG_DIR/clang.exe"
    echo "       若 Vitis 装在别处，请改本脚本的 CLANG_DIR"
    exit 1
fi

# ⚠ 追加而不是替换 —— 保留原有 PATH
export PATH="$PATH:$CLANG_DIR"

# ⚠ MSYS_NO_PATHCONV 阻止 Git Bash 把参数里的路径转成 Windows 形式
#   （对相对路径无害，但设上更保险）
export MSYS_NO_PATHCONV=1

echo "=== 编译 preproc_sim.exe ==="
"$CLANG_DIR/clang.exe" -DPREPROC_SIM_BUILD -I. \
    preproc_driver.c preproc_sim.c main_preproc.c \
    -o preproc_sim.exe
RC=$?

if [ $RC -ne 0 ] || [ ! -f preproc_sim.exe ]; then
    echo "编译失败 (clang 返回 $RC)"
    exit 1
fi
echo "编译成功"

echo
echo "=== 运行自检 ==="
./preproc_sim.exe
RC=$?

rm -f preproc_sim.exe

echo
if [ $RC -eq 0 ]; then
    echo "*** PREPROC DRIVER SIM PASSED ***"
else
    echo "*** PREPROC DRIVER SIM FAILED ***"
fi
exit $RC
