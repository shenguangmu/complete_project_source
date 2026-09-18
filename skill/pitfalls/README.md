# 踩坑清单 —— 工具静默失败的定位方法

> **为什么这份清单值得读**：这些坑的共同特征是
> **工具不报错，或者报错位置离真正原因很远**。
> 每一条都给出**验证命令** —— 不靠推理，靠输出。

## 怎么用

按**现象**查，不按原因查。你手里只有现象。

| 现象 | 去哪条 |
|---|---|
| 综合/实现全过，但 DRC 报一堆莫名其妙的端口名 | **P1** |
| 加了"失败重试"，日志显示重试了但同一秒返回 | **P2** |
| 脚本跑到最后突然 `No open design`，产物缺失 | **P3** |
| OOC 综合日志里出现 `Failed to create directory 'C'` | **P4** |
| **改了源码，报告里的旧数字还在，没人发现** | **P5** |
| 综合通过但上板数据不对 | 见 `docs/board-bringup-guide.md` 的分级验证 |
| HLS 相关（pragma 被丢、csim 假成功…） | 见附录索引 |

---

## P1 · 顶层被静默设成子模块，整条流水线未进综合

**现象**

```
[DRC NSTD-1] 67 out of 67 logical ports use IOSTANDARD 'DEFAULT'
问题端口: cam_data[7:0], frame_cnt[15:0], aclk, pclk ...
```

端口名**看着像某个子模块的**，不是你的顶层。
日志里是 `Command: synth_design -top <子模块名>`。

**根因**

Block Design 生成时会**重新生成 wrapper**，把它从工程文件表里挤掉。
Vivado 只好在剩余模块里**自动挑一个当顶层** —— 挑中了某个 RTL 子模块。

**为什么难查**：**全流程静默通过**。综合、实现、出比特流都不报错。

**对策**

**必须回读断言**，不能靠"没报错就当对了"：

```tcl
set top_now [get_property top [current_fileset]]
if {$top_now ne "${BD_NAME}_wrapper"} {
    error "顶层设置失败：期望 ${BD_NAME}_wrapper，实际 '$top_now'"
}
if {[llength [get_files -quiet *${BD_NAME}_wrapper.v]] == 0} {
    error "wrapper 未登记进工程文件表"
}
```

**验证**

```bash
grep "Command: synth_design" <project>.runs/synth_1/runme.log
# 必须是你的顶层名。是子模块名 → 中招了
```

---

## P2 · `launch_runs` 对**已失败**的 run 不做任何事 → 重试是假的

**现象**

给 run 加了"失败就重跑"的重试，日志显示重试了，但**同一秒就返回**：

```
>>> synth_1 进度 0% —— 第 1 次未完成
>>> 重试...
[21:38:34] Waiting for synth_1 to finish...
[21:38:34] synth_1 finished        ← 同一秒返回，根本没跑
```

**根因**

`launch_runs` 认为那个 run "已经跑过了"（只是结果是失败），**于是什么都不做**。
光靠"再 launch 一次"是**假重试**。

**对策**

重试前先 `reset_run`（**已完成的子 run 不受影响**，只有失败的需要重跑）：

```tcl
if {$attempt > 1} { catch {reset_run -quiet $run_name} }
catch {launch_runs $run_name -jobs 8 {*}$launch_args}
catch {wait_on_run $run_name}
```

**⚠ 配套坑**：找失败子 run **不能用** `get_runs "${run_name}_*"` ——
run 叫 `synth_1`，子 run 却叫 `bd_video_dma_in_0_synth_1`，**glob 匹配不到**，
那段诊断会**静默失效**（你以为在报错，其实一行没输出）：

```tcl
# 错：匹配不到任何东西
foreach sr [get_runs -quiet "${run_name}_*"] { ... }

# 对：遍历全部，按后缀筛，排除父 run
foreach sr [get_runs] {
    set sn [get_property NAME $sr]
    if {$sn eq $run_name} { continue }
    if {[string match "*_$run_name" $sn] && [get_property PROGRESS $sr] ne "100%"} { ... }
}
```

> **这条的教训**：桩函数能验证"重试被调用了"，但**验证不了
> `launch_runs` 的真实语义**。控制流对 ≠ 行为对。

---

## P3 · `get_timing_paths` 需要**已打开的设计**

**现象**

脚本跑到 "实现完成" 后突然中断：

```
>>> 实现完成
ERROR: [Common 17-53] User Exception: No open design.
```

**后果**：后面的产物导出**根本没执行到**。
而 `write_bitstream completed successfully` 就在日志里 —— **容易误以为"都成功了"**。

**根因**

`get_timing_paths` 写在 `open_run impl_1` **之前**。

**对策**

```tcl
open_run impl_1        # ← 必须在前面

# 时序查询本身也加 catch —— 它只是**报告**，不该有中断整个流程的能力
if {[catch {
    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    puts ">>> WNS = $wns ns"
} err]} {
    puts "WARN: 取时序失败（不影响产物）: $err"
}
```

**验证**

判据不是"脚本没报错"，而是**产物在不在**：

```bash
ls -la <project>/<name>.xsa <project>/utilization.rpt
```

> **这条的教训**：脚本"跑到最后一行"和"所有产物都生成了"是**两回事**。

---

## P4 · `Failed to create directory 'C'` —— 产物无害，**流程致命**

**现象**

OOC 综合日志里出现（**每次打中的 run 都不一样**，是随机的）：

```
ERROR: [Common 17-354] Could not open 'C' for writing.
ERROR: [Common 17-1257] Failed to create directory 'C'.
```

看起来像环境变量问题（某个变量为空、被展开成裸盘符 `C`），**但不是**。

**根因**

一次性启动 16–22 个 OOC 综合，每个 Vivado 实例都要建一批临时目录 ——
**并发建目录竞争的瞬时失败**。重跑必然成功
（中招的 run 自己的 `.dcp` 其实照样生成了）。

**已排除**（这些查过都不是原因）：
- `TEMP` / `TMP` 正常
- 无空环境变量会被展开成裸盘符
- 脚本里没有任何地方传过 `"C"`

**⚠ 为什么不能当噪声忽略**

Vivado 会把这个瞬时失败**判定成 run 失败**：

```
ERROR: [Vivado 12-13638] Failed runs(s) : '<run 名>'
ERROR: [Common 17-39] 'wait_on_runs' failed due to earlier errors.
```

于是 `wait_on_run` **直接抛错返回**，脚本中断 —— **后面的产物根本导不出来**。

**对策**：带 `reset_run` 的重试（见 **P2**）。

**验证**

```bash
grep -c "17-1257\|17-354" <run>/runme.log   # 出现了几条
grep -c "^ERROR" <impl>/runme.log            # 但整体 ERROR 应为 0
```

---

## P5 · 报告里的数字比源码旧 —— 改了代码，没人发现

**现象**：你改完源码、跑完综合、去读报告里的资源数，
**读到的是上一次运行的**。报告不会自己告诉你它过期了。

**本项目实际发生的**：
做 DSP 对照实验时来回改了四次源码，最后一次（展开版，86 DSP）跑完
就去写文档了；等回头核对数字时，`csynth.rpt` 里躺着的还是**85 实验版**的数，
而源码已经 `git checkout` 回基线了。
**如果当时没顺手多跑一次，写进报告的就是一组对不上源码的数字。**

**为什么危险**：这类错误的后果和 P2 一样 ——
**看起来一切正常**。数字是"真的"（确实是工具产出的），
只是**不是当前源码的**。csim 会拦住代码错误，**谁也拦不住这个**。

**验证命令**：

```bash
# ① 比时间戳：报告比源码旧，就说明报告过期了
ls -l --time-style=+%m-%d_%H:%M src_hls/gesture_preproc.cpp \
      gesture_comp/solution1/syn/report/csynth.rpt
#         源码必须比报告旧（或同一时刻）

# ② 比 git 状态：源码有未提交改动，报告必然对不上
git status --short src_hls/
```

**根治**：**不要在"源代码有未提交改动"的状态下引用报告数字**。
要么先 `git stash`/`checkout` 到目标状态重跑，要么在提交后重跑一次。

> **更一般的教训**：**引用一个数字前，先确认它属于哪次运行。**
> 这和"引用前先确认它属于哪个模块"（`WNS +0.265` 的教训）是同一类问题 ——
> 数字的**出处**和数字本身一样重要。

---

## 附录：更完整的清单

本目录只列了**"工具流程全过、只有上板才暴露"**这一类中最典型的 5 条。
更完整的 15 条（HLS 接口/pragma、Vitis 命令行、BD/Tcl、Zynq 协同、环境噪声）
见项目仓库 `vivado/README.md` 的「踩过的 19 个坑」一节，
其中前 15 条按 A–E 五类组织。

**判断一条报错要不要管的通用方法**：

```bash
# 只看这两种级别
grep -E "ERROR|CRITICAL WARNING" <runme.log>
# 数一下
grep -c "^ERROR" <runme.log>
```

> 一个 33 KB 的 `vivado.log` 里有 **111 条 WARNING 但 0 条 ERROR** 是**正常**的。
> 别因为刷屏就以为工程有问题 —— 但也别反过来，把 ERROR 当噪声。
> **P4 就是后者**：它对产物无害，但对流程致命。
