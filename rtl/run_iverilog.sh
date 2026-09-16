#!/usr/bin/env bash
# =====================================================================
#  run_iverilog.sh —— 纯 RTL 模块的自检回归
#
#  为什么单独有一个脚本：
#    HLS 那部分靠 vitis-run 的 csim/csynth 验证；而 dvp_capture /
#    sccb_master / async_fifo 是**手写 Verilog**，不属于任何 HLS 工程。
#    它们用 iverilog 验证 —— 不需要板卡、不需要 Vivado license，
#    秒级出结果。每次改动 RTL 后都应该跑一遍。
#
#  用法：
#      bash rtl/run_iverilog.sh          # 在工程根目录下执行
#      cd rtl && bash run_iverilog.sh    # 或在 rtl 目录下
#
#  ⚠ 判定标准是日志里的 "*** TB PASSED ***"。
#    "finished" 不算数 —— 见 skill 的 09-pitfalls.md。
# =====================================================================

set -u

# 定位到 rtl 目录（脚本可在任意位置被调用）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# iverilog 通常不在 PATH 里（本机在 C:/iverilog/bin）
if ! command -v iverilog >/dev/null 2>&1; then
    if [ -x "/c/iverilog/bin/iverilog" ]; then
        export PATH="/c/iverilog/bin:$PATH"
    else
        echo "ERROR: 找不到 iverilog。请确认已安装或把它加入 PATH。"
        exit 1
    fi
fi

OUT_DIR="$(mktemp -d 2>/dev/null || echo /tmp)"
PASS=0
FAIL=0
FAILED_TESTS=""

# run_test <名字> <TB 文件> <依赖...>
run_test() {
    local name="$1"; shift
    local tb="$1"; shift
    local vvp="$OUT_DIR/$name.vvp"

    echo ""
    echo "====================================================================="
    echo "  $name"
    echo "====================================================================="

    if ! iverilog -g2012 -o "$vvp" "$tb" "$@" 2>&1 | grep -v "^.*warning:" ; then
        :   # grep 无匹配返回 1，属正常
    fi

    if [ ! -f "$vvp" ]; then
        echo "  *** 编译失败 ***"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name"
        return
    fi

    local log
    log="$OUT_DIR/$name.log"
    vvp "$vvp" > "$log" 2>&1
    tail -n 20 "$log"

    if grep -q "\*\*\* TB PASSED \*\*\*" "$log"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name"
    fi
}

# ---------------------------------------------------------------------
#  各模块的自检
# ---------------------------------------------------------------------
run_test "dvp_capture"   tb/tb_dvp_capture.v dvp_capture.v async_fifo.v
run_test "sccb_master"   tb/tb_sccb_master.v sccb_master.v
run_test "ov5640_regs"   tb/tb_ov5640_regs.v ov5640_regs.v

# ---------------------------------------------------------------------
#  汇总
# ---------------------------------------------------------------------
echo ""
echo "====================================================================="
echo "  回归汇总: $PASS 通过, $FAIL 失败"
if [ "$FAIL" -ne 0 ]; then
    echo "  失败项:$FAILED_TESTS"
    echo "====================================================================="
    exit 1
fi
echo "*** ALL RTL TESTS PASSED ***"
echo "====================================================================="
exit 0
