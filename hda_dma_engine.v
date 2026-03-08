// ===========================================================================
//
//  hda_dma_engine.v
//  Creative Sound Blaster AE-9 — HDA DMA 引擎 (Bus Master)
//
// ===========================================================================
//
//  功能概述
//  --------
//  为 CORB/RIRB 和 Codec Engine 提供 Bus Master DMA 能力:
//    - DMA Read  (MRd TLP): 从主机内存读取 CORB 命令
//    - DMA Write (MWr TLP): 向主机内存写入 RIRB 响应
//
//  TLP 格式
//  --------
//  MRd 3DW (32-bit addr): Fmt=00, Type=00000, Length=1
//  MWr 3DW (32-bit addr): Fmt=10, Type=00000, Length=1 (4B) / 2 (8B)
//  MRd 4DW (64-bit addr): Fmt=01, Type=00000, Length=1
//  MWr 4DW (64-bit addr): Fmt=11, Type=00000, Length=1 / 2
//
//  对于 CORB: MRd 1 DWORD (4 bytes)
//  对于 RIRB: MWr 2 DWORDs (8 bytes = 1 RIRB entry)
//
//  时序抖动 (模仿 AE-9)
//  --------
//  DMA 请求发出前插入可变延迟，模拟真实 ASIC 内部队列深度变化。
//  延迟值来自 LFSR，范围 4~20 周期。
//
// ===========================================================================

module hda_dma_engine (
    input  wire         clk,
    input  wire         rst_n,

    // Requester ID (来自 PCIe IP)
    input  wire [15:0]  requester_id,

    // Codec Engine DMA 读接口
    input  wire         dma_rd_req,
    input  wire [63:0]  dma_rd_addr,
    output reg          dma_rd_done,
    output reg  [31:0]  dma_rd_data,

    // Codec Engine DMA 写接口
    input  wire         dma_wr_req,
    input  wire [63:0]  dma_wr_addr,
    input  wire [63:0]  dma_wr_data,
    output reg          dma_wr_done,

    // AXI4-Stream TX 输出 (送往 TX 仲裁器)
    output reg  [63:0]  s_axis_tx_tdata,
    output reg  [ 7:0]  s_axis_tx_tkeep,
    output reg          s_axis_tx_tlast,
    output reg          s_axis_tx_tvalid,
    input  wire         s_axis_tx_tready,
    output reg  [ 3:0]  s_axis_tx_tuser,

    // AXI4-Stream RX 输入 (来自 PCIe IP, 仅接收 CplD)
    input  wire [63:0]  m_axis_rx_tdata,
    input  wire [ 7:0]  m_axis_rx_tkeep,
    input  wire         m_axis_rx_tlast,
    input  wire         m_axis_rx_tvalid,
    output reg          m_axis_rx_tready,
    input  wire [21:0]  m_axis_rx_tuser,

    // Completion Timeout
    output reg          cpl_timeout,

    // LFSR 种子 (来自顶层, 基于 wall clock)
    input  wire [15:0]  lfsr_seed
);

    // ===================================================================
    //  DMA Tag 管理
    // ===================================================================

    reg [7:0] dma_tag_cnt;

    // ===================================================================
    //  抖动 LFSR (模仿 AE-9 DMA 时序特征)
    // ===================================================================

    reg [15:0] jitter_lfsr;
    wire jitter_fb = jitter_lfsr[0];

    always @(posedge clk) begin
        if (!rst_n)
            jitter_lfsr <= lfsr_seed ^ 16'hCAFE;
        else
            jitter_lfsr <= {1'b0, jitter_lfsr[15:1]}
                         ^ (jitter_fb ? 16'hD008 : 16'h0000);
    end

    // 抖动延迟: 4~19 周期 (模拟真实 DMA 引擎处理延迟)
    wire [4:0] jitter_delay = {1'b0, jitter_lfsr[3:0]} + 5'd4;

    // ===================================================================
    //  状态机
    // ===================================================================

    localparam [3:0] ST_IDLE       = 4'd0,
                     ST_RD_JITTER  = 4'd1,
                     ST_RD_HDR0    = 4'd2,
                     ST_RD_HDR1    = 4'd3,
                     ST_RD_WAIT    = 4'd4,
                     ST_RD_CPL0    = 4'd5,
                     ST_RD_CPL1    = 4'd6,
                     ST_WR_JITTER  = 4'd7,
                     ST_WR_HDR0    = 4'd8,
                     ST_WR_HDR1    = 4'd9,
                     ST_WR_DATA    = 4'd10,
                     ST_WR_DONE    = 4'd11,
                     ST_TIMEOUT    = 4'd12;

    reg [3:0]  state;
    reg [4:0]  jitter_cnt;
    reg [15:0] timeout_cnt;
    reg [63:0] pending_addr;
    reg [63:0] pending_data;
    reg        pending_is_64bit;
    reg [7:0]  pending_tag;

    // 超时阈值 (约 1ms @ 62.5 MHz = 62500 周期, 用 16 位计数器)
    localparam [15:0] TIMEOUT_LIMIT = 16'hF424;

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            s_axis_tx_tdata  <= 64'h0;
            s_axis_tx_tkeep  <= 8'h0;
            s_axis_tx_tlast  <= 1'b0;
            s_axis_tx_tvalid <= 1'b0;
            s_axis_tx_tuser  <= 4'h0;
            m_axis_rx_tready <= 1'b0;
            dma_rd_done    <= 1'b0;
            dma_rd_data    <= 32'h0;
            dma_wr_done    <= 1'b0;
            dma_tag_cnt    <= 8'h80; // DMA tags 从 0x80 开始, 与 BAR0 CplD 区分
            cpl_timeout    <= 1'b0;
            jitter_cnt     <= 5'd0;
            timeout_cnt    <= 16'h0;
            pending_addr   <= 64'h0;
            pending_data   <= 64'h0;
            pending_is_64bit <= 1'b0;
            pending_tag    <= 8'h0;
        end else begin
            // 默认清除单周期脉冲
            dma_rd_done <= 1'b0;
            dma_wr_done <= 1'b0;
            cpl_timeout <= 1'b0;

            case (state)
                // ---- 空闲: 等待 DMA 请求 ----
                ST_IDLE: begin
                    s_axis_tx_tvalid <= 1'b0;
                    m_axis_rx_tready <= 1'b0;
                    if (dma_rd_req) begin
                        pending_addr     <= dma_rd_addr;
                        pending_is_64bit <= (dma_rd_addr[63:32] != 32'h0);
                        pending_tag      <= dma_tag_cnt;
                        dma_tag_cnt      <= dma_tag_cnt + 8'd1;
                        jitter_cnt       <= jitter_delay;
                        state            <= ST_RD_JITTER;
                    end else if (dma_wr_req) begin
                        pending_addr     <= dma_wr_addr;
                        pending_data     <= dma_wr_data;
                        pending_is_64bit <= (dma_wr_addr[63:32] != 32'h0);
                        jitter_cnt       <= jitter_delay;
                        state            <= ST_WR_JITTER;
                    end
                end

                // ==== DMA 读路径 ====

                ST_RD_JITTER: begin
                    if (jitter_cnt == 5'd0)
                        state <= ST_RD_HDR0;
                    else
                        jitter_cnt <= jitter_cnt - 5'd1;
                end

                ST_RD_HDR0: begin
                    // 3DW MRd: {DW1, DW0}
                    s_axis_tx_tdata <= {
                        requester_id,           // Requester ID
                        pending_tag,            // Tag
                        4'h0,                   // Last DW BE
                        4'hF,                   // First DW BE
                        1'b0,                   // R
                        pending_is_64bit ? 2'b01 : 2'b00, // Fmt
                        5'b00000,               // Type = MRd
                        1'b0, 3'b000, 4'b0000,  // R, TC=0, R
                        1'b0, 1'b0, 2'b00, 2'b00,// TD=0, EP=0, Attr=0, R
                        10'd1                   // Length = 1 DW
                    };
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= pending_is_64bit ? 1'b0 : 1'b0;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0100; // SOF

                    if (s_axis_tx_tready) begin
                        state <= ST_RD_HDR1;
                    end
                end

                ST_RD_HDR1: begin
                    if (pending_is_64bit) begin
                        // 4DW: {DW3(addr_lo), DW2(addr_hi)}
                        s_axis_tx_tdata <= {pending_addr[31:2], 2'b00,
                                           pending_addr[63:32]};
                    end else begin
                        // 3DW: {pad, DW2(addr)}
                        s_axis_tx_tdata <= {32'h0, pending_addr[31:2], 2'b00};
                    end
                    s_axis_tx_tkeep  <= pending_is_64bit ? 8'hFF : 8'h0F;
                    s_axis_tx_tlast  <= 1'b1;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;

                    if (s_axis_tx_tready) begin
                        s_axis_tx_tvalid <= 1'b0;
                        s_axis_tx_tlast  <= 1'b0;
                        m_axis_rx_tready <= 1'b1;
                        timeout_cnt      <= 16'h0;
                        state            <= ST_RD_WAIT;
                    end
                end

                // 等待 CplD 返回
                ST_RD_WAIT: begin
                    timeout_cnt <= timeout_cnt + 16'd1;
                    if (timeout_cnt >= TIMEOUT_LIMIT) begin
                        cpl_timeout      <= 1'b1;
                        m_axis_rx_tready <= 1'b0;
                        state            <= ST_IDLE;
                    end else if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        // CplD 第一拍: {DW1, DW0}
                        state <= ST_RD_CPL0;
                    end
                end

                ST_RD_CPL0: begin
                    // CplD 第二拍: {Data, DW2}
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        dma_rd_data      <= m_axis_rx_tdata[63:32]; // Data
                        dma_rd_done      <= 1'b1;
                        m_axis_rx_tready <= 1'b0;
                        state            <= ST_IDLE;
                    end
                end

                // CplD 数据已在 ST_RD_CPL0 获取
                ST_RD_CPL1: begin
                    state <= ST_IDLE;
                end

                // ==== DMA 写路径 ====

                ST_WR_JITTER: begin
                    if (jitter_cnt == 5'd0)
                        state <= ST_WR_HDR0;
                    else
                        jitter_cnt <= jitter_cnt - 5'd1;
                end

                ST_WR_HDR0: begin
                    // MWr: {DW1, DW0}
                    s_axis_tx_tdata <= {
                        requester_id,           // Requester ID
                        8'h00,                  // Tag (MWr 不需要 Tag 匹配)
                        4'hF,                   // Last DW BE
                        4'hF,                   // First DW BE
                        1'b0,
                        pending_is_64bit ? 2'b11 : 2'b10, // Fmt = MWr (w/ data)
                        5'b00000,               // Type
                        1'b0, 3'b000, 4'b0000,
                        1'b0, 1'b0, 2'b00, 2'b00,
                        10'd2                   // Length = 2 DWORDs (8 bytes)
                    };
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= 1'b0;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0100; // SOF

                    if (s_axis_tx_tready)
                        state <= ST_WR_HDR1;
                end

                ST_WR_HDR1: begin
                    if (pending_is_64bit) begin
                        // 4DW: {DW3(addr_lo), DW2(addr_hi)}
                        s_axis_tx_tdata <= {pending_addr[31:2], 2'b00,
                                           pending_addr[63:32]};
                        s_axis_tx_tkeep <= 8'hFF;
                        s_axis_tx_tlast <= 1'b0;
                    end else begin
                        // 3DW: {Data_DW0, DW2(addr)}
                        s_axis_tx_tdata <= {pending_data[31:0],
                                           pending_addr[31:2], 2'b00};
                        s_axis_tx_tkeep <= 8'hFF;
                        s_axis_tx_tlast <= 1'b0;
                    end
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;

                    if (s_axis_tx_tready)
                        state <= ST_WR_DATA;
                end

                ST_WR_DATA: begin
                    if (pending_is_64bit) begin
                        // 4DW MWr: 第三拍是 Data
                        s_axis_tx_tdata <= pending_data;
                    end else begin
                        // 3DW MWr: 第三拍只剩 Data_DW1
                        s_axis_tx_tdata <= {32'h0, pending_data[63:32]};
                    end
                    s_axis_tx_tkeep  <= pending_is_64bit ? 8'hFF : 8'h0F;
                    s_axis_tx_tlast  <= 1'b1;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;

                    if (s_axis_tx_tready) begin
                        s_axis_tx_tvalid <= 1'b0;
                        s_axis_tx_tlast  <= 1'b0;
                        state <= ST_WR_DONE;
                    end
                end

                ST_WR_DONE: begin
                    dma_wr_done <= 1'b1;
                    state       <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
