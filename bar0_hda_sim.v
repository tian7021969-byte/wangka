// ===========================================================================
//
//  bar0_hda_sim.v
//  Creative Sound Blaster AE-9 — BAR0 HDA 寄存器交互仿真
//
// ===========================================================================
//
//  功能概述
//  --------
//  模拟 Creative AE-9 的 BAR0 MMIO 寄存器空间。当主机（操作系统驱动
//  或检测工具）对 BAR0 执行 Memory Read/Write 时，本模块解析 RX 路径
//  上的 TLP 报文，返回符合 Intel HDA 规范的寄存器值。
//
//  对抗策略: 检测工具通过探测 BAR0 寄存器来验证设备真实性。
//  如果 BAR0 返回全 0 或全 F，设备将被识别为空壳伪装。
//  本模块返回与真实 AE-9 一致的寄存器值（含活动计数器），
//  使设备在寄存器级探测下无法被区分。
//
//  HDA 寄存器布局 (Intel HD Audio Spec Rev 1.0a)
//  -----------------------------------------------
//  偏移      名称          宽度   描述
//  0x00      GCAP          16b    全局能力
//  0x02      VMIN          8b     次版本号
//  0x03      VMAJ          8b     主版本号
//  0x04      OUTPAY        16b    输出负载能力
//  0x06      INPAY         16b    输入负载能力
//  0x08      GCTL          32b    全局控制 (可写)
//  0x0C      WAKEEN        16b    唤醒使能 (可写)
//  0x0E      STATESTS      16b    状态变化状态 (W1C)
//  0x10      GSTS          16b    全局状态
//  0x18      OUTSTRMPAY    16b    输出流负载能力
//  0x1A      INSTRMPAY     16b    输入流负载能力
//  0x20      INTCTL        32b    中断控制 (可写)
//  0x24      INTSTS        32b    中断状态
//  0x30      WALCLK        32b    挂钟计数器 (自由运行)
//  0x38      SSYNC         32b    流同步
//  0x40-0x5F CORB/RIRB     --     命令输出/响应输入缓冲区
//  0x80+     Stream Desc   --     流描述符寄存器 (每个 0x20 字节)
//
//  TLP 处理流程
//  ------------
//  1. 从 m_axis_rx 解析 3DW MRd (Fmt=00, Type=00000) TLP
//  2. 提取 BAR0 偏移地址、Requester ID、Tag、Length
//  3. 查寄存器表，组装 CplD (Fmt=10, Type=01010) TLP
//  4. 通过 s_axis_tx 发送完成报文
//  5. MWr TLP 更新可写寄存器，不产生完成报文
//
// ===========================================================================

module bar0_hda_sim (
    input  wire         clk,
    input  wire         rst_n,

    // 配置信息 (从 PCIe IP 获取)
    input  wire [15:0]  completer_id,       // Bus/Dev/Func

    // RX AXI4-Stream (来自 PCIe IP 的接收路径)
    input  wire [63:0]  m_axis_rx_tdata,
    input  wire [ 7:0]  m_axis_rx_tkeep,
    input  wire         m_axis_rx_tlast,
    input  wire         m_axis_rx_tvalid,
    output reg          m_axis_rx_tready,
    input  wire [21:0]  m_axis_rx_tuser,

    // TX AXI4-Stream (送往 TLP Tag 随机化器或 PCIe IP)
    output reg  [63:0]  s_axis_tx_tdata,
    output reg  [ 7:0]  s_axis_tx_tkeep,
    output reg          s_axis_tx_tlast,
    output reg          s_axis_tx_tvalid,
    input  wire         s_axis_tx_tready,
    output reg  [ 3:0]  s_axis_tx_tuser
);

    // ===================================================================
    //  AE-9 HDA 寄存器默认值
    // ===================================================================
    //
    // GCAP: 4 output + 4 input + 1 bidi 流, 64-bit 地址, HDA 1.0
    // 字段: OSS[15:12]=4, ISS[11:8]=4, BSS[7:3]=1, 64OK[0]=1
    localparam [15:0] AE9_GCAP      = 16'h4409;
    localparam [ 7:0] AE9_VMIN      = 8'h00;
    localparam [ 7:0] AE9_VMAJ      = 8'h01;
    localparam [15:0] AE9_OUTPAY    = 16'h003C;  // 60 bytes
    localparam [15:0] AE9_INPAY     = 16'h001D;  // 29 bytes
    localparam [15:0] AE9_OUTSTRMPAY = 16'h003C;
    localparam [15:0] AE9_INSTRMPAY = 16'h001D;
    localparam [15:0] AE9_GSTS_INIT = 16'h0000;
    localparam [31:0] AE9_INTSTS_INIT = 32'h0000_0000;

    // CORB/RIRB 容量: AE-9 支持 256 条目
    localparam [ 7:0] AE9_CORBSIZE  = 8'h42;  // CAP=0100(256), SIZE=10(256)
    localparam [ 7:0] AE9_RIRBSIZE  = 8'h42;

    // ===================================================================
    //  可写寄存器
    // ===================================================================

    reg [31:0] reg_gctl;        // 0x08: Global Control
    reg [15:0] reg_wakeen;      // 0x0C: Wake Enable
    reg [15:0] reg_statests;    // 0x0E: State Change Status (W1C)
    reg [31:0] reg_intctl;      // 0x20: Interrupt Control
    reg [31:0] reg_ssync;       // 0x38: Stream Synchronization
    reg [31:0] reg_walclk;      // 0x30: Wall Clock Counter (自由运行)

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

    // ===================================================================
    //  挂钟计数器 (Wall Clock)
    // ===================================================================
    //
    // 以 24 MHz 节拍递增 (HDA 规范要求)。
    // 在 user_clk (62.5/125 MHz) 域下用分频器近似模拟。
    // 62.5 MHz / 24 MHz ≈ 2.6, 取 3 作为分频比。

    reg [1:0] walclk_div;

    always @(posedge clk) begin
        if (!rst_n) begin
            reg_walclk <= 32'h0;
            walclk_div <= 2'h0;
        end else begin
            if (walclk_div == 2'd2) begin
                walclk_div <= 2'h0;
                reg_walclk <= reg_walclk + 1'b1;
            end else begin
                walclk_div <= walclk_div + 1'b1;
            end
        end
    end

    // ===================================================================
    //  寄存器读取逻辑
    // ===================================================================

    function [31:0] read_register;
        input [13:0] dw_offset;   // DWORD 地址 (byte_addr >> 2)
        begin
            case (dw_offset[5:0])  // BAR0 低 256 字节 (64 DWORD)
                6'h00: read_register = {AE9_VMAJ, AE9_VMIN, AE9_GCAP};
                6'h01: read_register = {AE9_INPAY, AE9_OUTPAY};
                6'h02: read_register = reg_gctl;
                6'h03: read_register = {reg_statests, reg_wakeen};
                6'h04: read_register = {16'h0, AE9_GSTS_INIT};
                6'h06: read_register = {AE9_INSTRMPAY, AE9_OUTSTRMPAY};
                6'h08: read_register = reg_intctl;
                6'h09: read_register = AE9_INTSTS_INIT;
                6'h0C: read_register = reg_walclk;
                6'h0E: read_register = reg_ssync;
                // CORB
                6'h10: read_register = reg_corblbase;
                6'h11: read_register = reg_corbubase;
                6'h12: read_register = {reg_corbrp, reg_corbwp};
                6'h13: read_register = {8'h0, AE9_CORBSIZE, reg_corbst, reg_corbctl};
                // RIRB
                6'h14: read_register = reg_rirblbase;
                6'h15: read_register = reg_rirbubase;
                6'h16: read_register = {reg_rintcnt, reg_rirbwp};
                6'h17: read_register = {8'h0, AE9_RIRBSIZE, reg_rirbsts, reg_rirbctl};
                // 流描述符区域 (0x80+) — 返回空闲状态默认值
                default: read_register = 32'h0000_0000;
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
            case (dw_offset[5:0])
                6'h02: begin // GCTL
                    if (be[0]) reg_gctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_gctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_gctl[23:16] <= data[23:16];
                    if (be[3]) reg_gctl[31:24] <= data[31:24];
                end
                6'h03: begin // WAKEEN / STATESTS (W1C)
                    if (be[0]) reg_wakeen[ 7:0] <= data[ 7:0];
                    if (be[1]) reg_wakeen[15:8] <= data[15:8];
                    if (be[2]) reg_statests[ 7:0] <= reg_statests[ 7:0] & ~data[23:16];
                    if (be[3]) reg_statests[15:8] <= reg_statests[15:8] & ~data[31:24];
                end
                6'h08: begin // INTCTL
                    if (be[0]) reg_intctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_intctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_intctl[23:16] <= data[23:16];
                    if (be[3]) reg_intctl[31:24] <= data[31:24];
                end
                6'h0E: begin // SSYNC
                    if (be[0]) reg_ssync[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ssync[15: 8] <= data[15: 8];
                    if (be[2]) reg_ssync[23:16] <= data[23:16];
                    if (be[3]) reg_ssync[31:24] <= data[31:24];
                end
                6'h10: begin // CORBLBASE
                    if (be[0]) reg_corblbase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_corblbase[15: 8] <= data[15: 8];
                    if (be[2]) reg_corblbase[23:16] <= data[23:16];
                    if (be[3]) reg_corblbase[31:24] <= data[31:24];
                end
                6'h11: begin // CORBUBASE
                    if (be[0]) reg_corbubase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_corbubase[15: 8] <= data[15: 8];
                    if (be[2]) reg_corbubase[23:16] <= data[23:16];
                    if (be[3]) reg_corbubase[31:24] <= data[31:24];
                end
                6'h14: begin // RIRBLBASE
                    if (be[0]) reg_rirblbase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rirblbase[15: 8] <= data[15: 8];
                    if (be[2]) reg_rirblbase[23:16] <= data[23:16];
                    if (be[3]) reg_rirblbase[31:24] <= data[31:24];
                end
                6'h15: begin // RIRBUBASE
                    if (be[0]) reg_rirbubase[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rirbubase[15: 8] <= data[15: 8];
                    if (be[2]) reg_rirbubase[23:16] <= data[23:16];
                    if (be[3]) reg_rirbubase[31:24] <= data[31:24];
                end
                default: ;  // 忽略其他地址写入
            endcase
        end
    endtask

    // ===================================================================
    //  TLP 解析状态机
    // ===================================================================
    //
    // 状态:
    //   IDLE     — 等待新 TLP
    //   RX_HDR1  — 已接收 Header 第一拍 (DW1+DW0), 等待第二拍
    //   RX_DATA  — 接收 MWr 数据
    //   TX_CPL0  — 发送 CplD 第一拍 (DW1+DW0)
    //   TX_CPL1  — 发送 CplD 第二拍 (Data+DW2)

    localparam [2:0] ST_IDLE    = 3'd0,
                     ST_RX_HDR1 = 3'd1,
                     ST_RX_DATA = 3'd2,
                     ST_TX_CPL0 = 3'd3,
                     ST_TX_CPL1 = 3'd4;

    reg [2:0] state;

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

    // 用于 TLP 类型判断
    wire is_mrd_3dw = (lat_fmt == 2'b00) && (lat_type == 5'b00000);
    wire is_mwr_3dw = (lat_fmt == 2'b10) && (lat_type == 5'b00000);

    // 寄存器读结果
    reg [31:0] reg_rd_data;

    // ===================================================================
    //  CplD TLP 字段计算
    // ===================================================================

    wire [11:0] byte_count = (lat_length == 10'd1) ? 12'd4 : {lat_length, 2'b00};
    wire [ 6:0] lower_addr = {lat_addr[6:2], 2'b00};

    wire [31:0] cpld_dw0 = {
        1'b0,           // R
        2'b10,          // Fmt = 3DW w/ data
        5'b01010,       // Type = Completion
        1'b0,           // R
        lat_tc,         // TC
        4'b0000,        // R
        1'b0,           // TD
        1'b0,           // EP
        2'b00,          // Attr
        2'b00,          // R
        lat_length      // Length (DWORD)
    };

    wire [31:0] cpld_dw1 = {
        completer_id,           // Completer ID
        3'b000,                 // Status = Successful Completion
        1'b0,                   // BCM
        byte_count              // Byte Count
    };

    wire [31:0] cpld_dw2 = {
        lat_requester_id,       // Requester ID
        lat_tag,                // Tag (原始值，后续被 Tag 随机化器替换)
        1'b0,                   // R
        lower_addr              // Lower Address
    };

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

            // 寄存器初始化
            reg_gctl       <= 32'h0000_0001;  // CRST=1 (controller not in reset)
            reg_wakeen     <= 16'h0;
            reg_statests   <= 16'h0001;       // SDIN0 codec detected
            reg_intctl     <= 32'h0;
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
        end else begin
            case (state)

                // ---- 等待新 TLP ----
                ST_IDLE: begin
                    s_axis_tx_tvalid <= 1'b0;
                    m_axis_rx_tready <= 1'b1;

                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        // 解析 Header 第一拍: {DW1, DW0}
                        lat_fmt    <= m_axis_rx_tdata[30:29];
                        lat_type   <= m_axis_rx_tdata[28:24];
                        lat_tc     <= m_axis_rx_tdata[22:20];
                        lat_length <= m_axis_rx_tdata[ 9: 0];

                        lat_requester_id <= m_axis_rx_tdata[63:48];
                        lat_tag          <= m_axis_rx_tdata[47:40];
                        lat_last_be      <= m_axis_rx_tdata[39:36];
                        lat_first_be     <= m_axis_rx_tdata[35:32];

                        state <= ST_RX_HDR1;
                    end
                end

                // ---- 接收 Header 第二拍 (DW2 / DW2+数据) ----
                ST_RX_HDR1: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        lat_addr <= {m_axis_rx_tdata[31:2], 2'b00};

                        if (is_mrd_3dw) begin
                            // Memory Read: 准备 Completion
                            reg_rd_data <= read_register(m_axis_rx_tdata[15:2]);
                            m_axis_rx_tready <= 1'b0;
                            state <= ST_TX_CPL0;
                        end else if (is_mwr_3dw) begin
                            // Memory Write: 3DW Header 时数据在高 32 位
                            lat_wr_data <= m_axis_rx_tdata[63:32];
                            state <= ST_RX_DATA;
                        end else begin
                            // 非 BAR0 操作，跳过
                            if (m_axis_rx_tlast)
                                state <= ST_IDLE;
                            // else: 继续接收直到 tlast
                        end
                    end
                end

                // ---- 处理 MWr 数据 / 跳过非目标 TLP ----
                ST_RX_DATA: begin
                    // MWr 3DW: 数据已在 ST_RX_HDR1 拿到
                    write_register(lat_addr[15:2], lat_wr_data, lat_first_be);
                    state <= ST_IDLE;
                end

                // ---- 发送 CplD 第一拍: {DW1, DW0} ----
                ST_TX_CPL0: begin
                    s_axis_tx_tdata  <= {cpld_dw1, cpld_dw0};
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= 1'b0;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0100; // bit[2]=1: SOF 在 DW0

                    if (s_axis_tx_tready) begin
                        state <= ST_TX_CPL1;
                    end
                end

                // ---- 发送 CplD 第二拍: {Data, DW2} ----
                ST_TX_CPL1: begin
                    s_axis_tx_tdata  <= {reg_rd_data, cpld_dw2};
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= 1'b1;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;

                    if (s_axis_tx_tready) begin
                        s_axis_tx_tvalid <= 1'b0;
                        s_axis_tx_tlast  <= 1'b0;
                        m_axis_rx_tready <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
