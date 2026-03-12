// ===========================================================================
//
//  bar0_hda_sim.v
//  Creative Sound Blaster AE-9 — BAR0 HDA 寄存器交互仿真
//
// ===========================================================================
//
//  功能概述
//  --------
//  模拟 Creative AE-9 的 BAR0 MMIO 寄存器空间，包括:
//    - 全部 HDA 标准全局寄存器
//    - CORB/RIRB 缓冲区寄存器 (完整控制位)
//    - 8 个 Stream Descriptor 寄存器组 (可读可写)
//    - Wall Clock Counter (24 MHz 精确)
//
//  TLP 处理:
//    - 3DW / 4DW Memory Read  → CplD 回复
//    - 3DW / 4DW Memory Write → 寄存器写入
//    - 未知 Non-Posted TLP    → UR Completion (防止主机 CPU 挂死)
//    - 未知 Posted TLP        → 静默丢弃 (drain)
//
// ===========================================================================

module bar0_hda_sim (
    input  wire         clk,
    input  wire         rst_n,

    // 配置信息 (从 PCIe IP 获取)
    input  wire [15:0]  completer_id,       // Bus/Dev/Func

    // LFSR 种子 (来自顶层, 基于 wall clock 低位)
    input  wire [15:0]  jitter_seed,

    // RX AXI4-Stream (来自 PCIe IP 的接收路径)
    input  wire [63:0]  m_axis_rx_tdata,
    input  wire [ 7:0]  m_axis_rx_tkeep,
    input  wire         m_axis_rx_tlast,
    input  wire         m_axis_rx_tvalid,
    output reg          m_axis_rx_tready,
    input  wire [21:0]  m_axis_rx_tuser,

    // TX AXI4-Stream (送往 TX 仲裁器)
    output reg  [63:0]  s_axis_tx_tdata,
    output reg  [ 7:0]  s_axis_tx_tkeep,
    output reg          s_axis_tx_tlast,
    output reg          s_axis_tx_tvalid,
    input  wire         s_axis_tx_tready,
    output reg  [ 3:0]  s_axis_tx_tuser,

    // Codec Engine 接口 — CORB/RIRB 寄存器输出
    output wire [31:0]  corb_base_lo,
    output wire [31:0]  corb_base_hi,
    output wire [15:0]  corb_wp_out,
    output wire [ 7:0]  corb_ctl_out,
    output wire [31:0]  rirb_base_lo,
    output wire [31:0]  rirb_base_hi,
    output wire [ 7:0]  rirb_ctl_out,

    // Codec Engine 写回接口
    input  wire [15:0]  codec_rirb_wp,      // 来自 codec engine 的 RIRB WP
    input  wire [ 7:0]  codec_rirb_sts,     // 来自 codec engine 的 RIRB STS
    input  wire [15:0]  codec_corb_rp,      // 来自 codec engine 的 CORB RP

    // MSI 中断请求输出
    output wire         msi_irq_request,

    // Wall Clock 输出 (用于 LFSR 种子)
    output wire [31:0]  walclk_out,

    // 精确 24 MHz tick 输入 (来自顶层 MMCM, 在 clk 域同步后的单周期脉冲)
    input  wire         walclk_tick
);

    // ===================================================================
    //  AE-9 HDA 寄存器默认值
    // ===================================================================

    // GCAP: 真实 AE-9 GCAP = 0x4401
    // bit[15]=0 (64OK, 但 AE-9 实际不声明), bit[14:12]=100 (NSDO=4)
    // bit[11:8]=0100 (BSS=4), bit[7:4]=0000 (ISS=0), bit[3:0]=0001 (OSS=1)
    localparam [15:0] AE9_GCAP      = 16'h4401;
    localparam [ 7:0] AE9_VMIN      = 8'h00;
    localparam [ 7:0] AE9_VMAJ      = 8'h01;
    localparam [15:0] AE9_OUTPAY    = 16'h003C;  // 60 bytes
    localparam [15:0] AE9_INPAY     = 16'h001D;  // 29 bytes
    localparam [15:0] AE9_OUTSTRMPAY = 16'h003C;
    localparam [15:0] AE9_INSTRMPAY = 16'h001D;
    localparam [15:0] AE9_GSTS_INIT = 16'h0000;

    // CORB/RIRB 容量: AE-9 支持 256 条目
    localparam [ 7:0] AE9_CORBSIZE  = 8'h42;  // CAP=0100(256), SIZE=10(256)
    localparam [ 7:0] AE9_RIRBSIZE  = 8'h42;

    // ===================================================================
    //  可写寄存器
    // ===================================================================

    reg [31:0] reg_gctl;        // 0x08
    reg [15:0] reg_wakeen;      // 0x0C
    reg [15:0] reg_statests;    // 0x0E (W1C)

    // CRST 退出复位后的 codec 检测延迟计数器
    // HDA spec §4.3: 控制器在 CRST 0→1 后需要时间检测 SDI 线上的 codec
    // 延迟约 25us @ 62.5 MHz ≈ 1563 周期，使用 2048 (~33us) 确保足够
    reg [11:0] codec_detect_cnt;    // codec 检测延迟计数器
    reg        codec_detect_active; // 正在进行 codec 检测

    reg [31:0] reg_intctl;      // 0x20
    reg [31:0] reg_intsts;      // 0x24
    reg [31:0] reg_ssync;       // 0x38
    reg [31:0] reg_walclk;      // 0x30

    // CORB 寄存器
    reg [31:0] reg_corblbase;   // 0x40
    reg [31:0] reg_corbubase;   // 0x44
    reg [15:0] reg_corbwp;      // 0x48
    reg [15:0] reg_corbrp;      // 0x4A
    reg [ 7:0] reg_corbctl;     // 0x4C
    reg [ 7:0] reg_corbst;      // 0x4D

    // RIRB 寄存器
    reg [31:0] reg_rirblbase;   // 0x50
    reg [31:0] reg_rirbubase;   // 0x54
    reg [15:0] reg_rirbwp;      // 0x58
    reg [15:0] reg_rintcnt;     // 0x5A
    reg [ 7:0] reg_rirbctl;     // 0x5C
    reg [ 7:0] reg_rirbsts;     // 0x5D

    // DMA Position Lower Base Address
    reg [31:0] reg_dpiblbase;   // 0x70
    reg [31:0] reg_dpibubase;   // 0x74

    // Immediate Command 接口 (ICW/IRR/ICS)
    // HDA spec §4.5: 驱动可能在 CORB/RIRB 之前用这个接口测试 codec
    reg [31:0] reg_icw;         // 0x60 Immediate Command Write
    reg [31:0] reg_irr;         // 0x64 Immediate Response Read
    reg [15:0] reg_ics;         // 0x68 Immediate Command Status
    reg        ic_pending;      // IC 命令待处理标志
    reg [7:0]  ic_delay_cnt;    // IC 处理延迟计数器

    // ===================================================================
    //  流描述符寄存器 (8 streams × 8 DWORDs = 64 DWORD)
    // ===================================================================
    //
    // 布局: 每个 Stream Descriptor 占 0x20 字节 (8 DWORDs)
    //   偏移 0x80 + stream * 0x20 + dword_offset * 4
    //
    // 每个 Stream Descriptor:
    //   +0x00 SD_CTL (24b) / SD_STS (8b)  — DW0
    //   +0x04 SD_LPIB                      — DW1
    //   +0x08 SD_CBL                       — DW2
    //   +0x0C SD_LVI (16b) / SD_FIFOW(16b)— DW3
    //   +0x10 SD_FIFOS(16b) / SD_FMT(16b) — DW4
    //   +0x18 SD_BDPL                      — DW6
    //   +0x1C SD_BDPU                      — DW7

    reg [31:0] stream_desc [0:63];  // 8 streams × 8 DWORDs

    integer sd_init;

    // ===================================================================
    //  Codec Engine 接口输出
    // ===================================================================

    assign corb_base_lo = reg_corblbase;
    assign corb_base_hi = reg_corbubase;
    assign corb_wp_out  = reg_corbwp;
    assign corb_ctl_out = reg_corbctl;
    assign rirb_base_lo = reg_rirblbase;
    assign rirb_base_hi = reg_rirbubase;
    assign rirb_ctl_out = reg_rirbctl;
    assign walclk_out   = reg_walclk;

    // ===================================================================
    //  中断逻辑
    // ===================================================================
    //
    // INTSTS 位映射:
    //   [30]  = CIE (Controller Interrupt Enable) status
    //   [7:0] = Stream interrupt status
    //
    // MSI 中断条件: INTCTL.GIE=1 且 INTCTL.CIE=1 且 RIRB 有中断

    wire intctl_gie = reg_intctl[31]; // Global Interrupt Enable
    wire intctl_cie = reg_intctl[30]; // Controller Interrupt Enable

    assign msi_irq_request = intctl_gie && intctl_cie &&
                             (reg_rirbsts[0] && reg_rirbctl[0]);

    // ===================================================================
    //  挂钟计数器 (Wall Clock)
    // ===================================================================
    //
    // 精确 24 MHz — 由顶层 MMCM 产生的 walclk_tick 脉冲驱动
    // (替换原来的 62.5 MHz / 3 ≈ 20.83 MHz 近似分频)

    always @(posedge clk) begin
        if (!rst_n) begin
            reg_walclk <= 32'h0;
        end else if (walclk_tick) begin
            reg_walclk <= reg_walclk + 1'b1;
        end
    end

    // ===================================================================
    //  LFSR (保留用于非 HDA 区域读取混淆)
    // ===================================================================

    reg [15:0] jitter_lfsr;
    wire jitter_fb = jitter_lfsr[0];

    always @(posedge clk) begin
        if (!rst_n)
            jitter_lfsr <= jitter_seed ^ 16'hA55A;
        else
            jitter_lfsr <= {1'b0, jitter_lfsr[15:1]}
                         ^ (jitter_fb ? 16'hB400 : 16'h0000);
    end

    // ===================================================================
    //  寄存器读取逻辑
    // ===================================================================

    function [31:0] read_register;
        input [13:0] dw_offset;
        begin
            case (dw_offset[7:0])  // BAR0 低 1KB (256 DWORD)
                // 全局寄存器 (0x00-0x3F)
                8'h00: read_register = {AE9_VMAJ, AE9_VMIN, AE9_GCAP};
                8'h01: read_register = {AE9_INPAY, AE9_OUTPAY};
                8'h02: read_register = reg_gctl;
                8'h03: read_register = {reg_statests, reg_wakeen};
                8'h04: read_register = {16'h0, AE9_GSTS_INIT};
                8'h06: read_register = {AE9_INSTRMPAY, AE9_OUTSTRMPAY};
                8'h08: read_register = reg_intctl;
                8'h09: read_register = reg_intsts;
                8'h0C: read_register = reg_walclk;
                8'h0E: read_register = reg_ssync;

                // CORB (0x40-0x4F)
                8'h10: read_register = reg_corblbase;
                8'h11: read_register = reg_corbubase;
                8'h12: read_register = {reg_corbrp, reg_corbwp};
                8'h13: read_register = {8'h0, AE9_CORBSIZE, reg_corbst, reg_corbctl};

                // RIRB (0x50-0x5F)
                8'h14: read_register = reg_rirblbase;
                8'h15: read_register = reg_rirbubase;
                8'h16: read_register = {reg_rintcnt, reg_rirbwp};
                8'h17: read_register = {8'h0, AE9_RIRBSIZE, reg_rirbsts, reg_rirbctl};

                // Immediate Command 接口 (0x60-0x6B)
                8'h18: read_register = reg_icw;         // 0x60 ICW
                8'h19: read_register = reg_irr;         // 0x64 IRR
                8'h1A: read_register = {16'h0, reg_ics}; // 0x68 ICS

                // DMA Position (0x70-0x77)
                8'h1C: read_register = reg_dpiblbase;
                8'h1D: read_register = reg_dpibubase;

                // 流描述符 (0x80+)
                // stream_desc 索引 = (byte_addr - 0x80) / 4 = dw_offset - 0x20
                default: begin
                    if (dw_offset[7:0] >= 8'h20 && dw_offset[7:0] < 8'h60)
                        read_register = stream_desc[dw_offset[5:0]];
                    else begin
                        // 非 HDA 标准寄存器区域 (含 Expansion ROM 映射):
                        // 返回 LFSR 混淆数据, 消除全零指纹特征。
                        read_register = {jitter_lfsr, jitter_lfsr}
                                      ^ {dw_offset[13:0], dw_offset[13:0], 4'hA};
                    end
                end
            endcase
        end
    endfunction

    // ===================================================================
    //  寄存器写入逻辑
    // ===================================================================

    task write_register;
        input [13:0] dw_offset;
        input [31:0] data;
        input [ 3:0] be;
        begin
            case (dw_offset[7:0])
                8'h02: begin // GCTL
                    if (be[0]) begin
                        // 检测 CRST 从 1→0: 清零 STATESTS (驱动发起控制器复位)
                        if (reg_gctl[0] && !data[0]) begin
                            reg_statests       <= 16'h0000;
                            codec_detect_active <= 1'b0;
                        end
                        // 检测 CRST 从 0→1: 启动 codec 检测延迟
                        // HDA spec §4.3: 退出复位后, 控制器需要时间检测 codec
                        // 延迟 ~33us (2048 周期 @ 62.5 MHz) 后设置 STATESTS
                        if (!reg_gctl[0] && data[0]) begin
                            codec_detect_cnt    <= 12'd2048;
                            codec_detect_active <= 1'b1;
                        end
                        reg_gctl[ 7: 0] <= data[ 7: 0];
                    end
                    if (be[1]) reg_gctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_gctl[23:16] <= data[23:16];
                    if (be[3]) reg_gctl[31:24] <= data[31:24];
                end
                8'h03: begin // WAKEEN / STATESTS (W1C)
                    if (be[0]) reg_wakeen[ 7:0] <= data[ 7:0];
                    if (be[1]) reg_wakeen[15:8] <= data[15:8];
                    if (be[2]) reg_statests[ 7:0] <= reg_statests[ 7:0] & ~data[23:16];
                    if (be[3]) reg_statests[15:8] <= reg_statests[15:8] & ~data[31:24];
                end
                8'h08: begin // INTCTL
                    if (be[0]) reg_intctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_intctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_intctl[23:16] <= data[23:16];
                    if (be[3]) reg_intctl[31:24] <= data[31:24];
                end
                8'h09: begin // INTSTS (W1C for stream bits, read-only for GIS/CIS)
                    if (be[0]) reg_intsts[ 7: 0] <= reg_intsts[ 7:0] & ~data[ 7:0];
                end
                8'h0E: begin // SSYNC
                    if (be[0]) reg_ssync[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ssync[15: 8] <= data[15: 8];
                    if (be[2]) reg_ssync[23:16] <= data[23:16];
                    if (be[3]) reg_ssync[31:24] <= data[31:24];
                end

                // CORB 寄存器
                8'h10: begin // CORBLBASE
                    if (be[0]) reg_corblbase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_corblbase[15: 8] <= data[15: 8];
                    if (be[2]) reg_corblbase[23:16] <= data[23:16];
                    if (be[3]) reg_corblbase[31:24] <= data[31:24];
                end
                8'h11: begin // CORBUBASE
                    if (be[0]) reg_corbubase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_corbubase[15: 8] <= data[15: 8];
                    if (be[2]) reg_corbubase[23:16] <= data[23:16];
                    if (be[3]) reg_corbubase[31:24] <= data[31:24];
                end
                8'h12: begin // CORBWP (low 16) / CORBRP (high 16)
                    // CORBWP: 主机可写低 8 位
                    if (be[0]) reg_corbwp[ 7:0] <= data[ 7:0];
                    if (be[1]) reg_corbwp[15:8] <= data[15:8];
                    // CORBRP: bit 15 (= data[31], be[3]) 是 Reset 位
                    // 低 8 位 (data[23:16]) 由硬件管理, 主机不可写
                    if (be[3] && data[31]) begin
                        // CORBRP Reset: 主机写 1 到 bit 15, 硬件清零 RP
                        reg_corbrp <= 16'h8000; // 置位 reset 标志, RP=0
                    end
                    if (be[3] && !data[31]) begin
                        // 主机写 0 到 bit 15: 清除 reset, RP 有效
                        reg_corbrp <= {1'b0, reg_corbrp[14:0]}; // 仅清 Reset 位, 保留 RP 值
                    end
                end
                8'h13: begin // CORBCTL / CORBST / CORBSIZE
                    if (be[0]) reg_corbctl <= data[ 7:0];
                    if (be[1]) reg_corbst  <= reg_corbst & ~data[15:8]; // W1C
                end

                // RIRB 寄存器
                8'h14: begin // RIRBLBASE
                    if (be[0]) reg_rirblbase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rirblbase[15: 8] <= data[15: 8];
                    if (be[2]) reg_rirblbase[23:16] <= data[23:16];
                    if (be[3]) reg_rirblbase[31:24] <= data[31:24];
                end
                8'h15: begin // RIRBUBASE
                    if (be[0]) reg_rirbubase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rirbubase[15: 8] <= data[15: 8];
                    if (be[2]) reg_rirbubase[23:16] <= data[23:16];
                    if (be[3]) reg_rirbubase[31:24] <= data[31:24];
                end
                8'h16: begin // RIRBWP (low 16) / RINTCNT (high 16)
                    // RIRBWP: bit 15 (data[15], be[1]) = Reset, 写 1 清零 WP
                    // 低 8 位由硬件管理 (codec engine), 主机不可写
                    if (be[1] && data[15]) begin
                        reg_rirbwp <= 16'h0000; // Reset WP
                    end
                    if (be[2]) reg_rintcnt[ 7:0] <= data[23:16];
                    if (be[3]) reg_rintcnt[15:8] <= data[31:24];
                end
                8'h17: begin // RIRBCTL / RIRBSTS / RIRBSIZE
                    if (be[0]) reg_rirbctl <= data[ 7:0];
                    if (be[1]) reg_rirbsts <= reg_rirbsts & ~data[15:8]; // W1C
                end

                // Immediate Command 接口
                8'h18: begin // ICW (0x60) — 写入触发 Immediate Command
                    if (be[0]) reg_icw[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_icw[15: 8] <= data[15: 8];
                    if (be[2]) reg_icw[23:16] <= data[23:16];
                    if (be[3]) begin
                        reg_icw[31:24] <= data[31:24];
                        // 写完整 ICW 后标记命令待处理
                        ic_pending    <= 1'b1;
                        ic_delay_cnt  <= 8'd12; // 模拟 ~12 周期处理延迟
                        reg_ics       <= {reg_ics[15:2], 1'b1, 1'b0}; // ICB=1, IRV=0
                    end
                end
                8'h1A: begin // ICS (0x68)
                    if (be[0]) begin
                        // Bit 0 (ICB): 写 1 清除
                        // Bit 1 (IRV): 只读, 由硬件管理
                        if (data[0]) begin
                            reg_ics[0] <= 1'b0; // 清除 ICB
                        end
                    end
                end

                // DMA Position
                8'h1C: begin
                    if (be[0]) reg_dpiblbase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_dpiblbase[15: 8] <= data[15: 8];
                    if (be[2]) reg_dpiblbase[23:16] <= data[23:16];
                    if (be[3]) reg_dpiblbase[31:24] <= data[31:24];
                end
                8'h1D: begin
                    if (be[0]) reg_dpibubase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_dpibubase[15: 8] <= data[15: 8];
                    if (be[2]) reg_dpibubase[23:16] <= data[23:16];
                    if (be[3]) reg_dpibubase[31:24] <= data[31:24];
                end

                // 流描述符 (0x80+)
                default: begin
                    if (dw_offset[7:0] >= 8'h20 && dw_offset[7:0] < 8'h60) begin
                        if (be[0]) stream_desc[dw_offset[5:0]][ 7: 0] <= data[ 7: 0];
                        if (be[1]) stream_desc[dw_offset[5:0]][15: 8] <= data[15: 8];
                        if (be[2]) stream_desc[dw_offset[5:0]][23:16] <= data[23:16];
                        if (be[3]) stream_desc[dw_offset[5:0]][31:24] <= data[31:24];
                    end
                end
            endcase
        end
    endtask

    // ===================================================================
    //  TLP 解析状态机
    // ===================================================================

    localparam [4:0] ST_IDLE       = 5'd0,
                     ST_RX_HDR1    = 5'd1,
                     ST_RX_DATA    = 5'd2,
                     ST_CPL_WAIT   = 5'd3,
                     ST_TX_CPL0    = 5'd4,
                     ST_TX_CPL1    = 5'd5,
                     ST_RX_HDR2    = 5'd6,
                     ST_RX_DRAIN   = 5'd7,
                     ST_TX_UR0     = 5'd8,
                     ST_TX_UR1     = 5'd9,
                     ST_RX_MWR4_DATA = 5'd10,
                     ST_TX_CPL0_W  = 5'd11,
                     ST_TX_CPL1_W  = 5'd12,
                     ST_TX_UR0_W   = 5'd13,
                     ST_TX_UR1_W   = 5'd14,
                     ST_RX_DRAIN_POST = 5'd15, // 排空后回 IDLE (Posted TLP)
                     ST_RX_DRAIN_UR   = 5'd16; // 排空后回 UR (Non-Posted TLP)

    reg [4:0] state;

    // 锁存的 TLP Header 字段
    reg [ 1:0] lat_fmt;
    reg [ 4:0] lat_type;
    reg [ 2:0] lat_tc;
    reg [ 9:0] lat_length;
    reg [15:0] lat_requester_id;
    reg [ 7:0] lat_tag;
    reg [ 3:0] lat_first_be;
    reg [ 3:0] lat_last_be;
    reg [31:0] lat_addr;
    reg [31:0] lat_wr_data;

    // 3DW: Fmt[1:0]=00(no data)/10(data), Type=00000
    // 4DW: Fmt[1:0]=01(no data)/11(data), Type=00000
    wire is_mrd_3dw = (lat_fmt == 2'b00) && (lat_type == 5'b00000);
    wire is_mrd_4dw = (lat_fmt == 2'b01) && (lat_type == 5'b00000);
    wire is_mwr_3dw = (lat_fmt == 2'b10) && (lat_type == 5'b00000);
    wire is_mwr_4dw = (lat_fmt == 2'b11) && (lat_type == 5'b00000);
    wire is_non_posted = (lat_fmt[1] == 1'b0) && (lat_type == 5'b00000); // MRd (需要 Completion)

    reg [31:0] reg_rd_data;

    // RX tlast 锁存 — 追踪当前 TLP 是否已完整接收
    reg        rx_tlast_seen;

    // CplD 抖动延迟计数器 — 模拟真实 AE-9 的 2~6 周期 CplD 响应延迟
    reg [2:0] cpld_wait_cnt;
    reg [2:0] cpld_wait_target;  // LFSR 生成的目标延迟值

    // ===================================================================
    //  CplD TLP 字段计算
    // ===================================================================

    wire [11:0] byte_count = (lat_length == 10'd1) ? 12'd4 : {lat_length, 2'b00};
    wire [ 6:0] lower_addr = {lat_addr[6:2], 2'b00};

    wire [31:0] cpld_dw0 = {
        1'b0, 2'b10, 5'b01010,             // Fmt=3DW w/data, Type=Cpl
        1'b0, lat_tc, 4'b0000,
        1'b0, 1'b0, 2'b00, 2'b00,
        lat_length
    };

    wire [31:0] cpld_dw1 = {
        completer_id,
        3'b000, 1'b0,
        byte_count
    };

    wire [31:0] cpld_dw2 = {
        lat_requester_id,
        lat_tag,
        1'b0, lower_addr
    };

    // UR (Unsupported Request) Completion — 无数据
    // Fmt=000(3DW no data), Type=01010(Cpl), Status=001(UR)
    wire [31:0] ur_dw0 = {
        1'b0, 2'b00, 5'b01010,             // Fmt=3DW no data, Type=Cpl
        1'b0, lat_tc, 4'b0000,
        1'b0, 1'b0, 2'b00, 2'b00,
        10'd0                               // Length=0 (no data)
    };

    wire [31:0] ur_dw1 = {
        completer_id,
        3'b001, 1'b0,                      // Status=001 (UR)
        12'd0                               // Byte Count=0
    };

    wire [31:0] ur_dw2 = {
        lat_requester_id,
        lat_tag,
        8'h00                               // Lower Address=0
    };

    // ===================================================================
    //  Codec Engine RIRB/CORB 写回同步
    // ===================================================================
    //
    // Codec engine 更新 RIRB WP 和 CORB RP
    // 这里在状态机外同步更新

    // Codec Engine 同步逻辑已合并到主状态机 always 块末尾
    // (避免多 always 块驱动 reg_rirbwp/reg_rirbsts/reg_corbrp)

    // ===================================================================
    //  主状态机
    // ===================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            m_axis_rx_tready <= 1'b1;
            s_axis_tx_tdata  <= 64'h0;
            s_axis_tx_tkeep  <= 8'h0;
            s_axis_tx_tlast  <= 1'b0;
            s_axis_tx_tvalid <= 1'b0;
            s_axis_tx_tuser  <= 4'h0;
            reg_rd_data      <= 32'h0;
            cpld_wait_cnt    <= 3'd0;
            cpld_wait_target <= 3'd2;
            rx_tlast_seen    <= 1'b0;

            // 寄存器初始化
            reg_gctl       <= 32'h0000_0000;  // CRST=0 (控制器上电处于复位状态, 符合 HDA spec)
            reg_wakeen     <= 16'h0;
            reg_statests   <= 16'h0000;       // CRST=0 时无 codec (CRST 0→1 后延迟置 bit 0)
            codec_detect_cnt    <= 12'd0;
            codec_detect_active <= 1'b0;
            reg_intctl     <= 32'h0;
            reg_intsts     <= 32'h0;
            reg_ssync      <= 32'h0;
            reg_corblbase  <= 32'h0;
            reg_corbubase  <= 32'h0;
            reg_corbwp     <= 16'h0;
            reg_corbrp     <= 16'h0;
            reg_corbctl    <= 8'h0;
            reg_corbst     <= 8'h0;
            reg_rirblbase  <= 32'h0;
            reg_rirbubase  <= 32'h0;
            reg_rirbwp     <= 16'h0;
            reg_rintcnt    <= 16'h0;
            reg_rirbctl    <= 8'h0;
            reg_rirbsts    <= 8'h0;
            reg_dpiblbase  <= 32'h0;
            reg_dpibubase  <= 32'h0;
            reg_icw        <= 32'h0;
            reg_irr        <= 32'h0;
            reg_ics        <= 16'h0;
            ic_pending     <= 1'b0;
            ic_delay_cnt   <= 8'h0;

            lat_fmt          <= 2'b0;
            lat_type         <= 5'b0;
            lat_tc           <= 3'b0;
            lat_length       <= 10'b0;
            lat_requester_id <= 16'b0;
            lat_tag          <= 8'b0;
            lat_first_be     <= 4'b0;
            lat_last_be      <= 4'b0;
            lat_addr         <= 32'b0;
            lat_wr_data      <= 32'b0;

            // 流描述符初始化
            for (sd_init = 0; sd_init < 64; sd_init = sd_init + 1)
                stream_desc[sd_init] <= 32'h0;

        end else begin
            case (state)

                // ============================================================
                //  IDLE: 等待 RX TLP 第一拍 (DW0 + DW1)
                // ============================================================
                ST_IDLE: begin
                    s_axis_tx_tvalid <= 1'b0;
                    m_axis_rx_tready <= 1'b1;
                    rx_tlast_seen    <= 1'b0;

                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        lat_fmt    <= m_axis_rx_tdata[30:29];
                        lat_type   <= m_axis_rx_tdata[28:24];
                        lat_tc     <= m_axis_rx_tdata[22:20];
                        lat_length <= m_axis_rx_tdata[ 9: 0];
                        lat_requester_id <= m_axis_rx_tdata[63:48];
                        lat_tag          <= m_axis_rx_tdata[47:40];
                        lat_last_be      <= m_axis_rx_tdata[39:36];
                        lat_first_be     <= m_axis_rx_tdata[35:32];
                        rx_tlast_seen    <= m_axis_rx_tlast;
                        state <= ST_RX_HDR1;
                    end
                end

                // ============================================================
                //  RX_HDR1: 第二拍 — 根据 Fmt 分派
                //  3DW: [31:0]=Address, [63:32]=Data(MWr) 或 pad(MRd)
                //  4DW: [31:0]=Addr_Hi, [63:32]=Addr_Lo → 还需一拍
                //
                //  关键: 必须确认 tlast 状态，未排空的 TLP 必须 drain
                // ============================================================
                ST_RX_HDR1: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin

                        if (is_mrd_3dw) begin
                            // 3DW MRd Length=1: 应该在本拍 tlast=1
                            lat_addr <= {m_axis_rx_tdata[31:2], 2'b00};
                            reg_rd_data <= read_register(m_axis_rx_tdata[15:2]);
                            rx_tlast_seen <= m_axis_rx_tlast;
                            if (m_axis_rx_tlast) begin
                                // TLP 已完整接收，安全发送 CplD
                                m_axis_rx_tready <= 1'b0;
                                state <= ST_TX_CPL0;
                            end else begin
                                // 异常: 3DW MRd 多于预期的拍数，先排空
                                state <= ST_RX_DRAIN;
                            end

                        end else if (is_mrd_4dw) begin
                            // 4DW MRd: Addr_Hi=[31:0], Addr_Lo=[63:32]
                            lat_addr <= {m_axis_rx_tdata[63:34], 2'b00};
                            reg_rd_data <= read_register(m_axis_rx_tdata[47:34]);
                            rx_tlast_seen <= m_axis_rx_tlast;
                            if (m_axis_rx_tlast) begin
                                // 4DW MRd Length=1 在 64bit 接口上可能 2 拍结束
                                m_axis_rx_tready <= 1'b0;
                                state <= ST_TX_CPL0;
                            end else begin
                                // 还有更多数据拍，排空后再回 CplD
                                state <= ST_RX_DRAIN;
                            end

                        end else if (is_mwr_3dw) begin
                            // 3DW MWr: Address=[31:0], Data=[63:32]
                            lat_addr    <= {m_axis_rx_tdata[31:2], 2'b00};
                            lat_wr_data <= m_axis_rx_tdata[63:32];
                            rx_tlast_seen <= m_axis_rx_tlast;
                            if (m_axis_rx_tlast) begin
                                // 完整 TLP，直接写寄存器
                                state <= ST_RX_DATA;
                            end else begin
                                // 多 DWORD MWr: 写第一个，然后排空其余
                                state <= ST_RX_DATA;
                            end

                        end else if (is_mwr_4dw) begin
                            // 4DW MWr: Addr_Hi=[31:0], Addr_Lo=[63:32]
                            lat_addr <= {m_axis_rx_tdata[63:34], 2'b00};
                            rx_tlast_seen <= m_axis_rx_tlast;
                            state <= ST_RX_MWR4_DATA;

                        end else begin
                            // 不认识的 TLP 类型
                            rx_tlast_seen <= m_axis_rx_tlast;
                            if (lat_fmt[1] == 1'b0 && lat_type != 5'b00000) begin
                                // Non-Posted 且不是 MRd → 必须回 UR Completion
                                if (m_axis_rx_tlast) begin
                                    m_axis_rx_tready <= 1'b0;
                                    state <= ST_TX_UR0;
                                end else begin
                                    state <= ST_RX_DRAIN_UR;
                                end
                            end else begin
                                // Posted 或其他: 排空后回 IDLE
                                if (m_axis_rx_tlast)
                                    state <= ST_IDLE;
                                else
                                    state <= ST_RX_DRAIN_POST;
                            end
                        end
                    end
                end

                // ============================================================
                //  RX_DATA: MWr 写入寄存器，然后确保 TLP 完整排空
                // ============================================================
                ST_RX_DATA: begin
                    write_register(lat_addr[15:2], lat_wr_data, lat_first_be);
                    if (rx_tlast_seen) begin
                        // TLP 已完整接收
                        state <= ST_IDLE;
                    end else begin
                        // 还有未排空的数据拍，必须排空
                        state <= ST_RX_DRAIN_POST;
                    end
                end

                // ============================================================
                //  CPL_WAIT: CplD 发送前抖动延迟
                //  模拟真实 AE-9 的 CplD 响应时序 (2~6 周期)
                //  RX 通路已释放 (tready=0 防止新 TLP), 不阻塞上游
                // ============================================================
                ST_CPL_WAIT: begin
                    cpld_wait_cnt <= cpld_wait_cnt + 1'b1;
                    if (cpld_wait_cnt >= cpld_wait_target) begin
                        state <= ST_TX_CPL0;
                    end
                end

                // ============================================================
                //  RX_MWR4_DATA: 4DW MWr 第三拍 — 读取数据
                // ============================================================
                ST_RX_MWR4_DATA: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        lat_wr_data <= m_axis_rx_tdata[31:0];
                        rx_tlast_seen <= m_axis_rx_tlast;
                        state <= ST_RX_DATA;
                    end
                end

                // ============================================================
                //  RX_DRAIN: 旧状态，保留兼容性 (4DW MRd 排空后发 CplD)
                //  等到 tlast 后发 CplD
                // ============================================================
                ST_RX_DRAIN: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast) begin
                        m_axis_rx_tready <= 1'b0;
                        state <= ST_TX_CPL0;
                    end
                end

                // ============================================================
                //  RX_DRAIN_POST: 排空 Posted TLP 后回 IDLE
                // ============================================================
                ST_RX_DRAIN_POST: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast) begin
                        state <= ST_IDLE;
                    end
                end

                // ============================================================
                //  RX_DRAIN_UR: 排空 Non-Posted TLP 后回 UR
                // ============================================================
                ST_RX_DRAIN_UR: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast) begin
                        m_axis_rx_tready <= 1'b0;
                        state <= ST_TX_UR0;
                    end
                end

                // ============================================================
                //  TX_CPL0: 设置 CplD 第一拍数据 (DW0 + DW1)
                //  数据和 tvalid 在此拍设置, 下一拍等待握手
                // ============================================================
                ST_TX_CPL0: begin
                    s_axis_tx_tdata  <= {cpld_dw1, cpld_dw0};
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= 1'b0;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;
                    state <= ST_TX_CPL0_W;
                end

                // TX_CPL0_W: 等待第一拍握手
                // 握手成功时立即设置第二拍数据 (消除 bubble)
                ST_TX_CPL0_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        // 第一拍已被接收, 立即设置第二拍
                        s_axis_tx_tdata  <= {reg_rd_data, cpld_dw2};
                        s_axis_tx_tkeep  <= 8'hFF;
                        s_axis_tx_tlast  <= 1'b1;
                        s_axis_tx_tvalid <= 1'b1;
                        s_axis_tx_tuser  <= 4'b0000;
                        state <= ST_TX_CPL1_W;
                    end
                end

                // TX_CPL1_W: 等待第二拍握手完成, 然后回 IDLE
                ST_TX_CPL1_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        s_axis_tx_tvalid <= 1'b0;
                        s_axis_tx_tlast  <= 1'b0;
                        m_axis_rx_tready <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                // ============================================================
                //  TX_UR0: 设置 UR Completion 第一拍 (DW0 + DW1)
                // ============================================================
                ST_TX_UR0: begin
                    s_axis_tx_tdata  <= {ur_dw1, ur_dw0};
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= 1'b0;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;
                    state <= ST_TX_UR0_W;
                end

                // TX_UR0_W: 等待握手, 握手成功立即设置第二拍
                ST_TX_UR0_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        s_axis_tx_tdata  <= {32'h0, ur_dw2};
                        s_axis_tx_tkeep  <= 8'h0F;
                        s_axis_tx_tlast  <= 1'b1;
                        s_axis_tx_tvalid <= 1'b1;
                        s_axis_tx_tuser  <= 4'b0000;
                        state <= ST_TX_UR1_W;
                    end
                end

                // TX_UR1_W: 等待握手完成, 回 IDLE
                ST_TX_UR1_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        s_axis_tx_tvalid <= 1'b0;
                        s_axis_tx_tlast  <= 1'b0;
                        m_axis_rx_tready <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase

            // ---- GCTL CRST 说明 ----
            // CRST 完全由主机驱动控制:
            //   驱动写 CRST=0 → 控制器进入复位 (STATESTS 清零)
            //   驱动写 CRST=1 → 启动 codec 检测延迟 (~33us)
            //   延迟到期 → STATESTS[0]=1 (报告 SDI0 codec)
            // 不做自动恢复, 避免与驱动轮询 CRST 竞争

            // ---- Codec 检测延迟 ----
            // HDA spec §4.3: CRST 退出后, 控制器检测 SDI 线上的 codec
            // 真实硬件需要约 25us, 这里用 2048 周期 (~33us @ 62.5 MHz)
            if (codec_detect_active) begin
                if (codec_detect_cnt > 12'd0) begin
                    codec_detect_cnt <= codec_detect_cnt - 12'd1;
                end else begin
                    // 延迟到期: 设置 STATESTS 报告 codec 存在
                    reg_statests        <= 16'h0001; // SDI0 检测到 CA0132 Codec
                    codec_detect_active <= 1'b0;
                end
            end

            // ---- INTSTS 自动更新 ----
            reg_intsts[31] <= msi_irq_request;
            reg_intsts[30] <= (reg_rirbsts[0] && reg_rirbctl[0]);

            // ---- Codec Engine 同步 (原独立 always 块合并到此处) ----
            // 从 codec engine 同步 RIRB WP (仅在 RIRB DMA Enable 时)
            if (reg_rirbctl[1]) begin
                reg_rirbwp  <= codec_rirb_wp;
                reg_rirbsts <= codec_rirb_sts;
            end
            // 从 codec engine 同步 CORB RP:
            //   - 仅在 CORB Run 且未处于 Reset 状态
            //   - 且当前周期状态机不在写寄存器 (避免覆盖主机的 CORBRP reset 操作)
            if (reg_corbctl[1] && !(reg_corbrp[15]) && (state != ST_RX_DATA)) begin
                reg_corbrp[7:0] <= codec_corb_rp[7:0];
            end

            // ---- Immediate Command 处理 ----
            // HDA spec §4.5: IC 接口提供无需 CORB/RIRB 的直接 Verb 通道
            // Windows hdaudbus.sys 可能在启用 CORB/RIRB 之前通过 IC 接口测试 codec
            if (ic_pending) begin
                if (ic_delay_cnt > 8'd0) begin
                    ic_delay_cnt <= ic_delay_cnt - 8'd1;
                end else begin
                    // 处理 Immediate Command — 使用与 codec engine 相同的解码
                    // ICW 格式同 CORB entry: [31:28]=Codec, [27:20]=NID, [19:0]=Verb
                    // 简化处理: 返回基本的 codec 响应
                    case (reg_icw[19:8])
                        12'hF00: begin // Get Parameter
                            case (reg_icw[7:0])
                                8'h00: reg_irr <= 32'h11020011; // Vendor ID
                                8'h02: reg_irr <= 32'h00100400; // Revision
                                8'h04: begin // Subordinate Node Count
                                    case (reg_icw[27:20])
                                        8'h00: reg_irr <= {16'h0001, 16'h0001}; // Root
                                        8'h01: reg_irr <= {16'h0002, 16'h0008}; // AFG
                                        default: reg_irr <= 32'h0;
                                    endcase
                                end
                                8'h05: reg_irr <= (reg_icw[27:20] == 8'h01) ? 32'h0000_0001 : 32'h0; // FG Type
                                8'h09: begin // Widget Type
                                    case (reg_icw[27:20])
                                        8'h02: reg_irr <= {4'h0, 28'h000_0041};
                                        8'h03: reg_irr <= {4'h1, 28'h010_0B41};
                                        8'h04: reg_irr <= {4'h4, 28'h000_0010};
                                        8'h05: reg_irr <= {4'h4, 28'h002_0010};
                                        8'h06: reg_irr <= {4'h4, 28'h000_0010};
                                        8'h07: reg_irr <= {4'h4, 28'h002_0010};
                                        8'h08: reg_irr <= {4'h0, 28'h000_0041};
                                        8'h09: reg_irr <= {4'h2, 28'h020_0001};
                                        default: reg_irr <= 32'h0;
                                    endcase
                                end
                                default: reg_irr <= 32'h0;
                            endcase
                        end
                        default: reg_irr <= 32'h0; // 其他 Verb: 返回 0
                    endcase
                    reg_ics    <= {reg_ics[15:2], 1'b0, 1'b1}; // ICB=0 (done), IRV=1 (valid)
                    ic_pending <= 1'b0;
                end
            end
        end
    end

endmodule
