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
#
#  ─────────────────────────────────────────────────────────────────
#  关于「为什么要支持非 Vitis 编译器」（2026-09 追加）
#  ─────────────────────────────────────────────────────────────────
#  上面那套以 .exe 结尾的探测**只在 Windows 成立**。本项目
#  加了 GitHub Actions（.github/workflows/rtl-sim.yml）之后，
#  runner 是 Ubuntu，没有、也不该装 Vitis —— 于是这个脚本在 CI 上
#  必然红。而它跑的其实是一份**纯 C 的主机自检**：
#
#      grep 过三个 .c：不含 <windows.h>，不含 _WIN32，
#      不含任何 MS 专有调用。目标侧的 xil_* 头文件
#      被 #ifdef PREPROC_SIM_BUILD 隔开，仿真模式根本不会用到。
#
#  所以这里加一层**向后兼容的探测**：先按老规矩找 Vitis clang，
#  找不到再退回 PATH 上的通用 C 编译器。Windows 本地行为**一字未变**。
#
#  ⚠ 已知且接受的缺口：Windows 的 Git Bash 默认不带 gcc/clang
#    （本机 /mingw64/bin 里只有 libgcc_s_seh-1.dll）。所以在
#    **裸 Windows** 上没装 Vitis 时，本脚本仍然找不到编译器 ——
#    那是环境本身就没有 C 编译器，不是脚本的错。
#    ⚠ 这个分支**本机无法验证**（改完后本地仍走 Vitis clang 那条路）；
#      它的正确性由 CI 实际跑通来背书。
# =====================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

usage() {
    cat <<'EOF'
  用法：
    bash sw/build_preproc_sim.sh              # 自动找编译器（Windows 上优先 Vitis clang）
    bash sw/build_preproc_sim.sh --show-cmd   # 只打印编译命令，不执行

  手工编译（任何 C 编译器都行）：
    <CC> -DPREPROC_SIM_BUILD -I. preproc_driver.c preproc_sim.c \
         main_preproc.c -o preproc_sim
EOF
}

# ⚠ 只要两样东西：编译器可执行文件的**绝对路径**（含 .exe 也可，
#   bash 在 Windows 上照样能执行），和它的**调用名**。
#   分开存是为了让 --show-cmd 打印出来的命令人也能照抄。
SRC_FILES="preproc_driver.c preproc_sim.c main_preproc.c"

# ---------------------------------------------------------------------
#  一、先试 Vitis 自带的 clang（Windows 本地路径，行为与改动前一致）
# ---------------------------------------------------------------------
CC_BIN=""      # 绝对路径
CC_NAME=""     # 调用名（如 clang.exe / cc）
CC_ORIGIN=""

CLANG_DIR=""

# 1) 显式指定
if [ -n "${VITIS_CLANG:-}" ]; then
    CLANG_DIR="$VITIS_CLANG"
fi

# 2) 从 XILINX_VITIS 推导
if [ -z "$CLANG_DIR" ] && [ -n "${XILINX_VITIS:-}" ]; then
    # 转成 POSIX 路径（Windows 的 D:\... → /d/...）
    cand="$(cygpath -u "$XILINX_VITIS" 2>/dev/null || echo "$XILINX_VITIS")"
    if [ -x "$cand/win64/tools/clang-16/bin/clang.exe" ]; then
        CLANG_DIR="$cand/win64/tools/clang-16/bin"
    fi
fi

# 3) 常见安装位置
if [ -z "$CLANG_DIR" ]; then
    for cand in         "D:/Xilinx/Vitis/win64/tools/clang-16/bin"         "C:/Xilinx/Vitis/win64/tools/clang-16/bin"         "/c/Xilinx/Vitis/win64/tools/clang-16/bin"         "/opt/Xilinx/Vitis/win64/tools/clang-16/bin"
    do
        if [ -x "$cand/clang.exe" ]; then CLANG_DIR="$cand"; break; fi
    done
fi

if [ -n "$CLANG_DIR" ] && [ -x "$CLANG_DIR/clang.exe" ]; then
    CC_BIN="$CLANG_DIR/clang.exe"
    CC_NAME="$CLANG_DIR/clang.exe"
    CC_ORIGIN="Vitis 自带 clang"
    # ⚠ 追加而不是替换 —— 保留原有 PATH。
    #   Vitis 的 clang.exe 依赖**同目录**的 DLL（LLVM-C.dll 等），
    #   不在 PATH 里就报 "error while loading shared libraries"，
    #   或返回码 -1073741515 (0xC0000135 = DLL not found)。
    export PATH="$PATH:$CLANG_DIR"
fi

# ---------------------------------------------------------------------
#  二、退回到 PATH 上的通用编译器（Linux / macOS / 装了 mingw 的 Windows）
# ---------------------------------------------------------------------
if [ -z "$CC_BIN" ]; then
    for c in cc gcc clang; do
        if command -v "$c" >/dev/null 2>&1; then
            CC_NAME="$c"
            CC_BIN="$(command -v "$c")"
            CC_ORIGIN="系统 PATH 上的 $c"
            break
        fi
    done
fi

# ---------------------------------------------------------------------
#  三、两个都没有 —— 说清楚为什么，别只说"失败"
# ---------------------------------------------------------------------
if [ -z "$CC_BIN" ]; then
    echo "ERROR: 找不到任何 C 编译器"
    echo ""
    echo "  按这个顺序找过："
    echo "    1) 环境变量 \$VITIS_CLANG      （当前: ${VITIS_CLANG:-未设置}）"
    echo "    2) 环境变量 \$XILINX_VITIS     （当前: ${XILINX_VITIS:-未设置}）"
    echo "    3) 几个常见 Vitis 安装路径"
    echo "    4) 系统 PATH 上的 cc / gcc / clang"
    echo ""
    echo "  [!] 本脚本跑的是**纯 C 主机自检**，不需要 Vitis，也不需要板子。"
    echo "      任装一个 C 编译器即可："
    echo "        Windows : 装 Vitis，或 mingw-w64（Git Bash 默认不带 gcc）"
    echo "        Ubuntu  : sudo apt-get install -y build-essential"
    echo "        macOS   : xcode-select --install"
    echo ""
    usage
    exit 1
fi

echo "  使用编译器: $CC_ORIGIN"
echo "             $CC_BIN"

# ⚠ MSYS_NO_PATHCONV 阻止 Git Bash 把参数里的路径转成 Windows 形式
#   （对相对路径无害，但设上更保险）
export MSYS_NO_PATHCONV=1

# ⚠ 产物名随平台变（Windows 上 clang 会自动补 .exe，Linux 上不会）。
#   写死 .exe 会让 CI 上的 `rm -f` 和存在性检查都落空。
BIN="preproc_sim"
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) BIN="preproc_sim.exe" ;;
esac

if [ "${1:-}" = "--show-cmd" ]; then
    echo
    echo "  编译命令（复制即用）："
    echo "    $CC_NAME -DPREPROC_SIM_BUILD -I. $SRC_FILES -o $BIN"
    exit 0
fi

echo "=== 编译 $BIN ==="
# shellcheck disable=SC2086  # SRC_FILES 就是要按空格拆成多个参数
"$CC_BIN" -DPREPROC_SIM_BUILD -I. $SRC_FILES -o "$BIN"
RC=$?

if [ $RC -ne 0 ] || [ ! -f "$BIN" ]; then
    echo "编译失败 ($CC_ORIGIN 返回 $RC)"
    exit 1
fi
echo "编译成功"

echo
echo "=== 运行自检 ==="
./"$BIN"
RC=$?

rm -f "$BIN"

echo
if [ $RC -eq 0 ]; then
    echo "*** PREPROC DRIVER SIM PASSED ***"
else
    echo "*** PREPROC DRIVER SIM FAILED ***"
fi
exit $RC
