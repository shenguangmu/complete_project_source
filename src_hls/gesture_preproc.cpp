/**
 * @file    gesture_preproc.cpp
 * @brief   手势图像预处理链 —— HLS 实现
 *
 * ────────────────────────────────────────────────────────────────────
 *  处理链顺序（已按"昂贵算子只在小图上跑"重排）
 * ────────────────────────────────────────────────────────────────────
 *   crop_scale ─► rgb2gray ─► gaussian ─► sobel ─► adaptive_thresh ─► morph
 *   640x480                                                  96x96
 *   (RGB565)        └────────── 全部在 96x96 = 9216 像素上 ──────────┘
 *
 *  为什么把裁剪缩放放最前面：
 *    若先做 640x480 的滤波再裁剪，高斯的 9 次加法要跑 307200 次；
 *    重排后同样的 9 次加法只跑 9216 次 —— 33 倍的算力差。
 *    代价是 Sobel 在 96x96 上算，梯度响应偏弱，靠 gain 补偿。
 *
 * ────────────────────────────────────────────────────────────────────
 *  骨架来源与统一约定
 * ────────────────────────────────────────────────────────────────────
 *  所有 3x3 窗口阶段的循环结构直接沿用
 *  legacy/sobel/src_hls/sobel_hls.cpp（已 csynth 通过、II=1、时序收敛的那版），
 *  这是本项目唯一被硬件验证过的骨架，不要另创一套。
 *
 *  统一约定（改之前先读懂）：
 *
 *  1. **越界补零靠多跑一圈**
 *     行 y 从 0 跑到 height（含），列 x 从 0 跑到 width+1（含）。
 *     越界位置输入 0，于是四周自动获得一圈零，
 *     流水线内没有任何数据相关的分支。
 *
 *     ⚠ 3 级列移位寄存器在**内部迭代坐标**上引入一个 (−1, −2)
 *       的常数偏移，但这个偏移在**输出数组索引**上恰好抵消：
 *         读出第 (x-1) 个值 ⇔ 图像列 x-1，窗口覆盖图像列 x-2..x
 *       而它写的正是输出下标 (Y, X)。
 *       净效果就是最朴素的标准 3x3 卷积：
 *         输出 (Y,X) 的窗口 = 图像 (Y-1..Y+1, X-1..X+1)，越界补零。
 *
 *       这条曾经推导错过一次（把内部偏移当成了输出偏移，
 *       于是在流里预先补零边框），导致整幅图错位。
 *       要改这里，先把上面这段重新推一遍。
 *
 *  2. **内部流用纯 ap_uint<8>，不用 ap_axiu**
 *     ap_axis/ap_axiu/hls::axis 只能在 AXI-Stream 接口端口上用，
 *     做内部 hls::stream 的负载会在 csynth 报 [HLS 214-208]。
 *     csim 不报这个错 —— csim 通过 ≠ 能综合。
 *
 *  3. **各级 enable=0 时走纯流拷贝**
 *     不要"照常走窗口路径再取中心值当直通"：窗口路径有自身的
 *     节拍，直通取值与输出位置不是恒等关系，会整体错列。
 *
 *  4. **TLAST 只在外层输出阶段加**
 *     输出长度恒为 GESTURE_OUT_PIXELS，最后一拍置位。
 *     AXI DMA 的 S2MM 靠 TLAST 界定一次传输的结束，漏了会一直等。
 */

#include "gesture_preproc.h"

/* ================================================================== *
 *  内部类型与常量
 * ================================================================== */

/** 内部流字：纯 8bit 数据，无侧带。
 *
 *  ⚠ 不要用 ap_axiu<8,...> 做内部流负载。
 *  HLS 规定 ap_axis/ap_axiu/qdma_axis/hls::axis 这些类型
 *  **只能挂在 AXI-Stream 接口端口上**，用作内部 hls::stream 的
 *  负载会在 csynth 阶段报错：
 *    [HLS 214-208] The ap_axis|ap_axiu|... data types must only be
 *                  used for AXI-Stream ports in the interface.
 *  csim 对此是宽容的，所以这个错误只有在综合时才暴露 ——
 *  这也说明"csim 通过"不等于"能综合"。
 *
 *  ⚠ 侧带也曾被废弃：曾想用 TUSER 携带 ROI 统计量跨级传递，
 *  但全链每级尺寸固定（96x96），下游自己算均值更简单可靠。
 *  少一次跨级耦合，就少一处 DATAFLOW 死锁的可能。 */
typedef ap_uint<8> ix_t;

/** 缩放后的尺寸。全链从 crop_scale 之后都是这个尺寸。 */
namespace G {

const int OW = GESTURE_OUT_SIZE;   /* 96 */
const int OH = GESTURE_OUT_SIZE;   /* 96 */
const int OPIX = GESTURE_OUT_PIXELS;  /* 9216 */

const int MAXW = GESTURE_MAX_WIDTH;

struct window3x3 {
    ap_uint<8> p00, p01, p02;
    ap_uint<8> p10, p11, p12;
    ap_uint<8> p20, p21, p22;
};

/**
 * @brief 3x3 窗口阶段的共用状态
 *
 * 拿掉了一切 "static 函数局部变量" ——
 * 那会让状态跨帧保持（HLS 里 static 局部等价于全局），
 * 第一帧看似正常、第二帧开始出错，是最难查的一类 bug。
 * 全部改成由调用者持有的局部结构体，每帧显式 reset。
 */
struct win_ctx {
    ap_uint<8> lb[3][MAXW + 2];
    ap_uint<8> sr[3][3];   /* 三行各自的 3 级列移位寄存器 */
};

inline void win_reset(win_ctx &C, int width)
{
#pragma HLS INLINE
    for (int i = 0; i < 3; i++) {
        for (int c = 0; c < width + 2; c++) {
#pragma HLS PIPELINE II=1
            C.lb[i][c] = 0;
        }
        for (int j = 0; j < 3; j++) {
#pragma HLS UNROLL
            C.sr[i][j] = 0;
        }
    }
}

/**
 * @brief 推入一个像素，取出对准 (y-1, x-2) 的 3x3 窗口
 *
 * 行缓存按 y%3 轮转角色，三个索引互不相同，同周期读写不冲突。
 * 列移位寄存器的行为与 sobel_hls.cpp 完全一致：
 * 移位后 sr[i][0]=列 x-1, [1]=列 x-2, [2]=列 x-3，
 * 而窗口以 (行 y-1, 列 x-2) 为中心，故
 *   左列 = x-3 -> [2]，中列 = x-2 -> [1]，右列 = x-1 -> [0]。
 */
inline void win_push(win_ctx &C, int y, int x, ap_uint<8> p,
                     window3x3 &win)
{
#pragma HLS INLINE

    const int wi  = y % 3;
    const int r1i = (y + 2) % 3;
    const int r2i = (y + 1) % 3;

    ap_uint<8> v1 = C.lb[r1i][x];   /* 第 y-1 行，列 x-1 */
    ap_uint<8> v2 = C.lb[r2i][x];   /* 第 y-2 行，列 x-1 */
    C.lb[wi][x] = p;                /* 第 y   行，列 x-1 */

    C.sr[0][2] = C.sr[0][1]; C.sr[0][1] = C.sr[0][0]; C.sr[0][0] = p;
    C.sr[1][2] = C.sr[1][1]; C.sr[1][1] = C.sr[1][0]; C.sr[1][0] = v1;
    C.sr[2][2] = C.sr[2][1]; C.sr[2][1] = C.sr[2][0]; C.sr[2][0] = v2;

    win.p00 = C.sr[2][2]; win.p01 = C.sr[2][1]; win.p02 = C.sr[2][0];
    win.p10 = C.sr[1][2]; win.p11 = C.sr[1][1]; win.p12 = C.sr[1][0];
    win.p20 = C.sr[0][2]; win.p21 = C.sr[0][1]; win.p22 = C.sr[0][0];
}

inline void emit(ix_t &o, ap_uint<8> v, bool last)
{
#pragma HLS INLINE
    o = v;   /* 内部流不带 TLAST；TLAST 只在最后的输出转换阶段加 */
    (void)last;
}

} /* namespace G */

/* ================================================================== *
 *  阶段 1：crop_scale —— ROI 裁剪 + 盒式缩放 + RGB565→灰度
 * ================================================================== */

/**
 * @brief 从 RGB565 整帧裁出 ROI 并缩放成 96x96 灰度
 *
 * 盒式平均降采样：每个输出像素 = 对应源块的算术平均。
 * 用平均而非抽样，是因为平均本身就是一次低通，
 * 能压掉高频噪声、减轻后续高斯的负担。
 *
 * 输出**普通行优先的 96x96**，不做任何边框预填充 ——
 * 下游各级自己 zero-feed（读条件之外的位置喂 0），
 * 净效果见文件头「统一约定」第 1 条。
 *
 * 输出长度恒为 GESTURE_OUT_PIXELS，与输入分辨率无关；
 * 这是与 CNN 侧的契约，见 docs/架构与接口契约.md §3.1。
 *
 * @param step_x  横向块宽（每多少个源像素出一个输出像素）
 * @param step_y  纵向块高
 */
static void crop_scale(hls::stream<axis_rgb_t> &src,
                       hls::stream<ix_t>       &dst,
                       int width, int height,
                       int roi_x, int roi_y, int roi_w, int roi_h,
                       int step_x, int step_y)
{
#pragma HLS INLINE off

    /* 先算完整帧再统一吐出：输入按 (y,x) 扫描，而块平均的
     * 输出顺序与之不同，必须缓冲。 */
    static ap_uint<8> ox[G::OW * G::OH];
#pragma HLS BIND_STORAGE variable=ox type=RAM_2P impl=BRAM

    ap_uint<24> acc = 0;
    ap_uint<8>  cx  = 0;
    ap_uint<8>  cy  = 0;
    int         n_out = 0;

    for (int y = 0; y < height; y++) {
#pragma HLS LOOP_TRIPCOUNT min=480 max=1080

        for (int x = 0; x < width; x++) {
#pragma HLS LOOP_TRIPCOUNT min=640 max=1920
#pragma HLS PIPELINE II=1

            axis_rgb_t w_in = src.read();
            ap_uint<16> rgb = w_in.data;

            /* RGB565 → 灰度（BT.601 整数近似，权重见 .h） */
            ap_uint<8> r8 = (ap_uint<8>)(ap_uint<5>)rgb.range(15, 11) << 3;
            ap_uint<8> g8 = (ap_uint<8>)(ap_uint<6>)rgb.range(10,  5) << 2;
            ap_uint<8> b8 = (ap_uint<8>)(ap_uint<5>)rgb.range( 4,  0) << 3;

            ap_uint<16> lum  = (ap_uint<16>)r8 * GESTURE_Y_R
                             + (ap_uint<16>)g8 * GESTURE_Y_G
                             + (ap_uint<16>)b8 * GESTURE_Y_B;
            ap_uint<8>  gray = (ap_uint<8>)(lum >> 8);

            bool in_roi = (x >= roi_x) && (x < roi_x + roi_w) &&
                          (y >= roi_y) && (y < roi_y + roi_h);

            if (in_roi) {
                acc = acc + (ap_uint<24>)gray;
                cx  = cx + 1;

                if (cx == step_x) {
                    cx = 0;
                    cy = cy + 1;

                    if (cy == step_y) {
                        cy = 0;
                        const ap_uint<24> n =
                            (ap_uint<24>)step_x * (ap_uint<24>)step_y;
                        if (n_out < G::OPIX)
                            ox[n_out++] = (ap_uint<8>)(acc / n);
                        acc = 0;
                    }
                }
            }
        }
    }

    /* 若 ROI 尺寸不是 96 的整数倍，块覆盖会少一部分，补零到定长 */
    while (n_out < G::OPIX) ox[n_out++] = 0;

    /* ---- 按普通 96x96 行优先顺序吐出 ----
     * ⚠ 这里**不要**预补零边框。
     *
     * 曾经试过在流里预先补一圈零（顶部 1 行、左侧 2 列），想让下游
     * 的 3x3 阶段直接读到零。那是错的：下游阶段自己已经做 zero-feed
     * （读条件 x>=1 && x<=width 之外的位置喂 0），预补的零会在流里
     * 多占位置，等于又注入一层偏移，使整幅图错位。
     *
     * 下游 stage 读取时的对应关系是：读第 (x-1) 个值 ⇔ 图像列 x-1。
     * 所以这里只要按行优先把这 9216 个值依次吐出即可。 */
    for (int i = 0; i < G::OPIX; i++) {
#pragma HLS PIPELINE II=1
        ix_t o;
        G::emit(o, ox[i], false);
        dst.write(o);
    }
}

/* ================================================================== *
 *  阶段 2：gaussian_stage —— 3x3 高斯去噪
 * ================================================================== */
static void gaussian_stage(hls::stream<ix_t> &src,
                           hls::stream<ix_t> &dst,
                           int width, int height, int enable)
{
#pragma HLS INLINE off

    /* ---- 关闭时：纯流拷贝 ----
     * 不要走窗口路径再取 w.p11 当直通 —— 窗口的列移位寄存器有
     * 自身的节拍，直通取值与输出位置不是恒等关系，会整体错列。
     * 直接原样搬运最直白，也与 golden 的 memcpy 一一对应。 */
    if (!enable) {
        for (int i = 0; i < width * height; i++) {
#pragma HLS PIPELINE II=1
            ix_t o;
            G::emit(o, src.read(), false);
            dst.write(o);
        }
        return;
    }

    G::win_ctx C;
    G::win_reset(C, width);

    /* 与 sobel_hls.cpp 完全同构的循环边界 */
    for (int y = 0; y <= height; y++) {

        for (int x = 0; x <= width + 1; x++) {
#pragma HLS PIPELINE II=1

            ap_uint<8> p = 0;
            if (y < height && x >= 1 && x <= width) {
                p = src.read();
            }

            G::window3x3 w;
#pragma HLS ARRAY_PARTITION variable=w complete
            G::win_push(C, y, x, p, w);

            /* 核 = [1 2 1; 2 4 2; 1 2 1]/16；加权和最大 16*255=4080，13 位够 */
            ap_uint<13> g =
                  (ap_uint<13>)w.p00 + ((ap_uint<13>)w.p01 << 1) + (ap_uint<13>)w.p02
                + ((ap_uint<13>)w.p10 << 1) + ((ap_uint<13>)w.p11 << 2) + ((ap_uint<13>)w.p12 << 1)
                + (ap_uint<13>)w.p20 + ((ap_uint<13>)w.p21 << 1) + (ap_uint<13>)w.p22;

            if (y >= 1 && x >= 2) {
                ix_t o;
                G::emit(o, (ap_uint<8>)(g >> 4),
                        (y == height && x == width + 1));
                dst.write(o);
            }
        }
    }
}

/* ================================================================== *
 *  阶段 3：sobel_stage —— Sobel 梯度
 * ================================================================== */

/** 由 3x3 窗口算 Sobel 幅值 |Gx|+|Gy|，带 Q8 增益与饱和 */
static ap_uint<8> sobel_mag(const G::window3x3 &w, int gain)
{
#pragma HLS INLINE

    /* 累加用 11 位：单项最大 4*255 = 1020，差值范围 ±1020 */
    ap_int<11> gx = (ap_int<11>)w.p00 + (ap_int<11>)w.p10 * 2 + (ap_int<11>)w.p20
                  - (ap_int<11>)w.p02 - (ap_int<11>)w.p12 * 2 - (ap_int<11>)w.p22;
    ap_int<11> gy = (ap_int<11>)w.p00 + (ap_int<11>)w.p01 * 2 + (ap_int<11>)w.p02
                  - (ap_int<11>)w.p20 - (ap_int<11>)w.p21 * 2 - (ap_int<11>)w.p22;

    /* 必须写成显式 if 而不是三元 —— 后者在 ap_int 下因 -gx 进位到
     * 12 位、与 gx 的 11 位不匹配而触发编译歧义。
     * sobel_hls.cpp 的注释里已记录过这个坑。 */
    ap_int<11> ax = gx, ay = gy;
    if (gx < 0) ax = (ap_int<11>)(-gx);
    if (gy < 0) ay = (ap_int<11>)(-gy);

    ap_uint<12> abs_sum = (ap_uint<12>)ax + (ap_uint<12>)ay;

    /* 增益 Q8：gain=256 表示 x1.0。2040*256 = 522240，21 位够。
     * 注意在 96x96 上算 Sobel，相邻像素差被缩放平均削平，
     * 幅值天然偏小 —— 这是把 crop_scale 前置的代价，
     * 用增大 gain（而非改算法）补偿，操作时按实测调。 */
    ap_int<21> mag     = (ap_int<21>)abs_sum * (ap_int<21>)gain;
    ap_int<21> shifted = mag >> 8;

    if (shifted < 0)   shifted = 0;
    if (shifted > 255) shifted = 255;

    return (ap_uint<8>)shifted;
}

static void sobel_stage(hls::stream<ix_t> &src,
                        hls::stream<ix_t> &dst,
                        int width, int height, int gain, int enable)
{
#pragma HLS INLINE off

    /* 关闭时纯流拷贝，理由同 gaussian_stage */
    if (!enable) {
        for (int i = 0; i < width * height; i++) {
#pragma HLS PIPELINE II=1
            ix_t o;
            G::emit(o, src.read(), false);
            dst.write(o);
        }
        return;
    }

    G::win_ctx C;
    G::win_reset(C, width);

    for (int y = 0; y <= height; y++) {
        for (int x = 0; x <= width + 1; x++) {
#pragma HLS PIPELINE II=1

            ap_uint<8> p = 0;
            if (y < height && x >= 1 && x <= width) {
                p = src.read();
            }

            G::window3x3 w;
#pragma HLS ARRAY_PARTITION variable=w complete
            G::win_push(C, y, x, p, w);

            if (y >= 1 && x >= 2) {
                ix_t o;
                G::emit(o, sobel_mag(w, gain), (y == height && x == width + 1));
                dst.write(o);
            }
        }
    }
}

/* ================================================================== *
 *  阶段 4：thresh_stage —— 自适应阈值（全局均值，两遍法）
 * ================================================================== */

/**
 * @brief 均值自适应阈值：阈值 = 全图均值 + 有符号偏置
 *
 * 实现上必须两遍 —— 第一遍缓冲整帧并求均值，第二遍才按阈值输出。
 * 用全图均值而不是"先读几个像素估一个"：后者对首行内容敏感，
 * 手入画时会把阈值带偏，表现为"画面边缘先亮后暗"的闪烁。
 *
 * 缓冲 9216 字节 = 需要 5 个 BRAM_18K，对这个规模完全可接受。
 * 有它才换来稳定的阈值，这是本项目"光照鲁棒"的可量化依据。
 */
static void thresh_stage(hls::stream<ix_t> &src,
                         hls::stream<ix_t> &dst,
                         int width, int height, int offset, int enable)
{
#pragma HLS INLINE off

    const int total = width * height;

    /* ⚠ 缓冲声明在函数内、但**不加 static** —— 加 static 会让它
     * 变成跨帧保持状态，且 HLS 对 static 大数组配 PIPELINE 会报
     * II 违例（无法判定跨迭代依赖）。作为普通局部数组会被正常
     * 映射到 BRAM，生命周期就是本次调用。 */
    ap_uint<8> buf[GESTURE_OUT_PIXELS];
#pragma HLS BIND_STORAGE variable=buf type=RAM_2P impl=BRAM

    /* ---- 第一遍：缓冲 + 求和 ---- */
    ap_uint<32> sum = 0;
    for (int i = 0; i < total; i++) {
#pragma HLS PIPELINE II=1
        ap_uint<8> v = src.read();
        buf[i] = v;
        sum = sum + (ap_uint<32>)v;
    }

    /* ---- 算阈值 ---- */
    int mean = (total > 0) ? (int)(sum / (ap_uint<32>)total) : 0;
    int th   = mean + offset;
    if (th < 0)   th = 0;
    if (th > 255) th = 255;

    /* ---- 第二遍：二值化输出 ----
     * 启用阈值时输出 0/255 而不是保留灰度值 ——
     * 保留灰度会在形态学阶段被最大值滤波器放大成整片前景。
     * 未启用时按契约直通（thresh_mode=0 表示"灰度直通"）。 */
    for (int i = 0; i < total; i++) {
#pragma HLS PIPELINE II=1
        ap_uint<8> v = buf[i];
        ap_uint<8> b = enable ? (((int)v > th) ? (ap_uint<8>)255 : (ap_uint<8>)0)
                              : v;

        ix_t o;
        G::emit(o, b, (i == total - 1));
        dst.write(o);
    }
}

/* ================================================================== *
 *  阶段 5：morph_stage —— 3x3 形态学闭运算
 * ================================================================== */

/**
 * @brief 闭运算 = 先膨胀后腐蚀
 *
 * 闭运算填掉前景内部的小孔、连接断裂的笔画，
 * 这正是"边缘图 → 手部实体轮廓"需要的一步：
 * Sobel 出来的轮廓是细线且可能断开，闭运算后成为连通的区域。
 *
 * ⚠ 为什么用两遍法而不是"两个 3x3 窗口串联"：
 *   串联时第二级的输入是第一级"本拍输出"（几何坐标 (y-2, x-3)），
 *   与窗内其余邻居不同步，结果会整体错位。这类错误在 csim 里
 *   表现为"图看着对但边界偏一格"，极难定位。
 *   改成两遍法后，每一遍都是标准的单级 3x3，对齐关系退化成
 *   与 gaussian/sobel 完全相同，可以直接复用 win_ctx。
 *
 * ⚠ 边界语义：每一遍都把源图当作"零边框"访问，即
 *   at(r, c) 在 r/c 越界时返回 0。这与 golden 的 at() 一一对应。
 *
 * 只做闭（不是开）：开运算会先腐蚀掉细小前景，
 * 而手势的指尖恰恰是细小前景，会被削掉。
 */
static void morph_stage(hls::stream<ix_t> &src,
                        hls::stream<ix_t> &dst,
                        int width, int height, int enable)
{
#pragma HLS INLINE off

    /* ⚠ 本段的索引 `yy * width + xx`（变量乘变量）看着像是 DSP 大户，
     *   但它**不是**。2026-09-18 实测过三种改法，结论如下，别重试：
     *
     *     改法                          DSP    II    评价
     *     ─────────────────────────────────────────────────────
     *     原样（当前）                   71    1     —
     *     width 改成模板常量             71    1     无效，省 0 个
     *     + 预计算行地址/手写边界分支     54    2     ✗ 吞吐减半
     *
     *   第 3 行是唯一能降 DSP 的改法，但代价是 **II 从 1 退化成 2**、
     *   迭代延迟 23 → 26 —— 省 17 个 DSP（7.7%）换掉一半吞吐，不划算，
     *   且关键路径变长会吃掉仅剩的 +0.265 ns 时序余量。
     *
     *   真实 DSP 去向（实测）：本模块 56 个中，55 个在腐蚀 pipeline 的
     *   若干 `mul_*` 上，那些乘法器带 16 位常数魔数（如 21846），
     *   不是 `oy*96` 这类常量乘 —— HLS 对常量乘本来就用移位。
     *
     *   **教训：优化必须同时看资源、吞吐、时序三个数。只盯 DSP 会选出更差的方案。** */

    const int total = width * height;

    /* 关闭时纯流拷贝，理由同 gaussian_stage */
    if (!enable) {
        for (int i = 0; i < total; i++) {
#pragma HLS PIPELINE II=1
            ix_t o;
            G::emit(o, src.read(), false);
            dst.write(o);
        }
        return;
    }

    static ap_uint<8> r1[GESTURE_OUT_PIXELS];   /* 离体缓冲，供第二遍回读 */
#pragma HLS BIND_STORAGE variable=r1 type=RAM_2P impl=BRAM

    /* ---- 第一遍：读入 + 膨胀 ----
     * 输入流是普通的行优先 96x96（crop_scale 不做任何预填充）。
     * win_push 的 (−1, −2) 偏移在输出索引上恰好抵消，
     * 所以窗口就是标准 3x3：win.pRC 对应图像 (y-1+row, x-2+col)。
     *
     * 写出的坐标 (y-1, x-2) 是严格压缩的 0..95 网格，与 golden
     * 的膨胀输出一一对应。 */
    G::win_ctx C;
    G::win_reset(C, width);

    for (int y = 0; y <= height; y++) {
        for (int x = 0; x <= width + 1; x++) {
#pragma HLS PIPELINE II=1

            /* 必须无条件推进窗口状态 —— 放进 if 会让边界轮次漏推。 */
            ap_uint<8> p = 0;
            if (y < height && x >= 1 && x <= width) {
                p = src.read();
            }

            G::window3x3 w;
#pragma HLS ARRAY_PARTITION variable=w complete
            G::win_push(C, y, x, p, w);

            if (y >= 1 && x >= 2) {
                ap_uint<8> mx = w.p00;
                if (w.p01 > mx) mx = w.p01;
                if (w.p02 > mx) mx = w.p02;
                if (w.p10 > mx) mx = w.p10;
                if (w.p11 > mx) mx = w.p11;
                if (w.p12 > mx) mx = w.p12;
                if (w.p20 > mx) mx = w.p20;
                if (w.p21 > mx) mx = w.p21;
                if (w.p22 > mx) mx = w.p22;

                r1[(y - 1) * width + (x - 2)] = mx;
            }
        }
    }

    /* ---- 第二遍：腐蚀 ----
     * 直接对紧凑的 r1 做 3x3 取最小循环，**不再走流式窗口**。
     *
     * 为什么这里要用普通循环而不是 win_push：
     *   膨胀的紧凑输出索引已经归位，若再用一次 win_push 会
     *   叠加第二次 (−1, −2) 偏移，结果整体错两格。
     *   而且腐蚀要同时读 (y-1)、y、(y+1) 三行，本身就是
     *   随机访问，用循环比流式窗口更直白、更容易与 golden 对齐。
     *
     * ⚠ 膨胀必须全部算完才能开始腐蚀（要读 y+1 行），
     *   所以这两段不能放进 DATAFLOW 并行。 */
    int out_n = 0;
    for (int oy = 0; oy < height; oy++) {
        for (int ox = 0; ox < width; ox++) {
#pragma HLS PIPELINE II=1

            ap_uint<8> mn = (ap_uint<8>)255;
            for (int dy = -1; dy <= 1; dy++) {
#pragma HLS UNROLL
                for (int dx = -1; dx <= 1; dx++) {
#pragma HLS UNROLL
                    const int yy = oy + dy, xx = ox + dx;
                    ap_uint<8> p = 0;
                    if (yy >= 0 && yy < height && xx >= 0 && xx < width)
                        p = r1[yy * width + xx];
                    if (p < mn) mn = p;
                }
            }

            out_n++;
            ix_t o;
            G::emit(o, mn, (out_n == total));
            dst.write(o);
        }
    }
}

/* ================================================================== *
 *  阶段 6：收尾 —— 内部流 → 对外契约的 axis_gray_t
 *
 *  ⚠ 为什么单独包成一个函数：
 *    DATAFLOW 区域里**只允许变量声明和函数调用**，不能直接写 for
 *    循环。原来这里是个裸 for，HLS 报：
 *      [HLS 214-114] Since the only kind of statements allowed in a
 *      canonical dataflow region are variable declarations and function
 *      calls, the compiler may not be able to correctly handle the region
 *      [HLS 214-169] There are a total of 6 such instances ...
 *
 *    这不是"风格建议" —— 它会导致 **C/RTL 协同仿真死锁**（实测卡在
 *    0/6 事务不再推进）。csim 和 csynth 都不会暴露这个问题，
 *    只有 cosim 才炸。
 *
 *    包成函数后 DATAFLOW 区域就是纯函数调用了，规范。
 * ================================================================== */
static void output_stage(hls::stream<ix_t>        &src,
                         hls::stream<axis_gray_t> &dst)
{
#pragma HLS INLINE off

    for (int i = 0; i < GESTURE_OUT_PIXELS; i++) {
#pragma HLS PIPELINE II=1
        /* 内部流是纯 ap_uint<8>，这里转成带 TLAST 的接口类型。
         * TLAST 落在最后一个像素上 —— AXI DMA 的 S2MM 靠它
         * 界定一次传输结束。 */
        ap_uint<8> v = src.read();
        axis_gray_t o;
        o.data = v;
        o.keep = 1;
        o.strb = 1;
        o.last = (i == GESTURE_OUT_PIXELS - 1) ? 1 : 0;
        dst.write(o);
    }
}

/* ================================================================== *
 *  内层：纯 DATAFLOW 链（**不含任何 AXI-Lite 接口**）
 *
 *  ⚠⚠ 为什么要拆成内外两层 —— 这是 cosim 死锁的根因
 *
 *  HLS 明确警告（本设计实际报过）：
 *    [HLS 200-616] This design uses AXI slave interface in dataflow
 *                  mode, which can result in simulation dead-lock
 *                  and/or mismatching results (due to AXI slave FIFO
 *                  sizing).
 *
 *  含义：如果**标量参数走 s_axilite** 的同时函数体又是 DATAFLOW，
 *  HLS 生成的 RTL 里 AXI-Lite 写通道的 FIFO 深度是固定的，而
 *  DATAFLOW 各阶段的并行度与之不匹配 —— 握手对不上就死锁。
 *
 *  实测症状（csim 完全看不出来）：
 *      RTL Simulation : 0 / 6 [n/a] @ "1000000635000"   ← 一个事务都不完成
 *      Simulation engine not responding
 *      The simulator has terminated in an unexpected manner.
 *  而且**与输入分辨率无关**（64x64 和 640x480 表现一样）——
 *  因为卡在控制路径，不在数据路径。
 *
 *  解法（官方推荐）：把 DATAFLOW 链抽成**纯流函数**，
 *  所有标量参数作为**普通值传递**（不走 AXI），
 *  AXI-Lite 接口只留在外层顶上。这样 DATAFLOW 区域里
 *  只有流，没有 AXI 从口，握手关系是干净的。
 *
 *  ⚠ 改这里之前先想清楚：把 s_axilite 参数直接用在 DATAFLOW
 *    区域的函数里，就会退回到死锁的那个结构。
 * ================================================================== */
static void preproc_pipeline(hls::stream<axis_rgb_t>  &src,
                             hls::stream<axis_gray_t> &dst,
                             int width, int height,
                             int thresh_mode, int thresh_offset,
                             int gauss_en, int sobel_en, int morph_en,
                             int gain,
                             int roi_x, int roi_y, int roi_w, int roi_h,
                             int step_x, int step_y)
{
#pragma HLS INLINE off

    /* ---- 级间 FIFO ----
     * 深度 2 足够：各级的消费速率一致（都是 96x96 定长），
     * 靠流控自然节拍，不需要额外缓冲。
     *
     * ⚠ 所有流声明与 STREAM 指令都放在 DATAFLOW **之前** ——
     *   夹在函数调用之间会被算作"非规范语句"（HLS 214-114）。 */
    hls::stream<ix_t> s0("s0");
    hls::stream<ix_t> s1("s1");
    hls::stream<ix_t> s2("s2");
    hls::stream<ix_t> s3("s3");
    hls::stream<ix_t> s4("s4");
#pragma HLS STREAM variable=s0 depth=2
#pragma HLS STREAM variable=s1 depth=2
#pragma HLS STREAM variable=s2 depth=2
#pragma HLS STREAM variable=s3 depth=2
#pragma HLS STREAM variable=s4 depth=2

#pragma HLS DATAFLOW

    crop_scale(src, s0, width, height,
               roi_x, roi_y, roi_w, roi_h, step_x, step_y);

    gaussian_stage(s0, s1, G::OW, G::OH, gauss_en);

    sobel_stage(s1, s2, G::OW, G::OH, gain, sobel_en);

    thresh_stage(s2, s3, G::OW, G::OH, thresh_offset, thresh_mode);

    morph_stage(s3, s4, G::OW, G::OH, morph_en);

    output_stage(s4, dst);
}

/* ================================================================== *
 *  顶层
 * ================================================================== */
void gesture_preproc(hls::stream<axis_rgb_t>  &src,
                     hls::stream<axis_gray_t> &dst,
                     int width,
                     int height,
                     int thresh_mode,
                     int thresh_offset,
                     int gauss_en,
                     int sobel_en,
                     int morph_en,
                     int gain,
                     int roi_x,
                     int roi_y,
                     int roi_w,
                     int roi_h)
{
    /* ---- 接口映射 ----
     * axis 指令不接受 bundle 参数：写了会被判为 unexpected pragma
     * parameter，整条指令被忽略，端口退化成 ap_none 单根线。
     * 只在连 BD 时才炸，csim 看不出来。 */
#pragma HLS INTERFACE mode=axis     port=src
#pragma HLS INTERFACE mode=axis     port=dst

#pragma HLS INTERFACE mode=s_axilite port=width         bundle=control
#pragma HLS INTERFACE mode=s_axilite port=height        bundle=control
#pragma HLS INTERFACE mode=s_axilite port=thresh_mode   bundle=control
#pragma HLS INTERFACE mode=s_axilite port=thresh_offset bundle=control
#pragma HLS INTERFACE mode=s_axilite port=gauss_en      bundle=control
#pragma HLS INTERFACE mode=s_axilite port=sobel_en      bundle=control
#pragma HLS INTERFACE mode=s_axilite port=morph_en      bundle=control
#pragma HLS INTERFACE mode=s_axilite port=gain          bundle=control
#pragma HLS INTERFACE mode=s_axilite port=roi_x         bundle=control
#pragma HLS INTERFACE mode=s_axilite port=roi_y         bundle=control
#pragma HLS INTERFACE mode=s_axilite port=roi_w         bundle=control
#pragma HLS INTERFACE mode=s_axilite port=roi_h         bundle=control
#pragma HLS INTERFACE mode=s_axilite port=return        bundle=control

    /* ---- 参数合法性检查 ----
     * ⚠ 必须在读任何 stream 之前做完 —— 提前 return 不会让上游阻塞。 */
    if (width <= 0 || height <= 0 ||
        width > GESTURE_MAX_WIDTH || height > GESTURE_MAX_HEIGHT) {
        return;
    }
    if (roi_w <= 0 || roi_h <= 0 || roi_x < 0 || roi_y < 0) return;
    if (roi_x + roi_w > width || roi_y + roi_h > height) return;

    /* ---- 缩放步长：向上取整 ---- */
    int step_x = (roi_w + G::OW - 1) / G::OW;
    int step_y = (roi_h + G::OH - 1) / G::OH;
    if (step_x < 1) step_x = 1;
    if (step_y < 1) step_y = 1;

    /* ⚠ 这里**不能**直接展开 DATAFLOW —— 那会让 AXI-Lite 的参数
     *   落进 DATAFLOW 区域，触发 [HLS 200-616] 的仿真死锁。
     *   交给内层纯流函数去展开（见 preproc_pipeline 的注释）。 */
    preproc_pipeline(src, dst, width, height,
                     thresh_mode, thresh_offset,
                     gauss_en, sobel_en, morph_en,
                     gain, roi_x, roi_y, roi_w, roi_h,
                     step_x, step_y);
}

