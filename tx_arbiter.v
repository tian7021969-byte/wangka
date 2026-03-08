// ===========================================================================
//
//  tx_arbiter.v
//  Creative Sound Blaster AE-9 — TX AXI-Stream 仲裁器
//
// ===========================================================================
//
//  功能概述
//  --------
//  将 BAR0 CplD 响应和 DMA 引擎的 MRd/MWr TLP 合并到一条 TX 通路。
//  优先级: CplD 响应 > DMA (PCIe 规范要求 Completion 优先)
//
//  仲裁策略
//  --------
//  - 严格优先级: BAR0 CplD 始终优先
//  - 帧完整性: 一旦开始传输一帧 TLP，必须传完才切换
//  - 反压传递: 被仲裁掉的端口 tready=0，赢得仲裁的端口 tready 透传
//
// ===========================================================================

module tx_arbiter (
    input  wire         clk,
    input  wire         rst_n,

    // 端口 0: BAR0 CplD (高优先级)
    input  wire [63:0]  p0_tdata,
    input  wire [ 7:0]  p0_tkeep,
    input  wire         p0_tlast,
    input  wire         p0_tvalid,
    output wire         p0_tready,
    input  wire [ 3:0]  p0_tuser,

    // 端口 1: DMA 引擎 (低优先级)
    input  wire [63:0]  p1_tdata,
    input  wire [ 7:0]  p1_tkeep,
    input  wire         p1_tlast,
    input  wire         p1_tvalid,
    output wire         p1_tready,
    input  wire [ 3:0]  p1_tuser,

    // 合并输出 (送往 Tag 随机化器)
    output reg  [63:0]  m_tdata,
    output reg  [ 7:0]  m_tkeep,
    output reg          m_tlast,
    output reg          m_tvalid,
    input  wire         m_tready,
    output reg  [ 3:0]  m_tuser
);

    // ===================================================================
    //  仲裁状态
    // ===================================================================

    localparam [1:0] ARB_IDLE = 2'd0,
                     ARB_P0   = 2'd1,
                     ARB_P1   = 2'd2;

    reg [1:0] arb_state;
    reg       lock_port; // 锁定当前传输端口 (帧完整性)

    // 端口选择信号
    wire sel_p0 = (arb_state == ARB_P0) || (arb_state == ARB_IDLE && p0_tvalid);
    wire sel_p1 = (arb_state == ARB_P1) || (arb_state == ARB_IDLE && !p0_tvalid && p1_tvalid);

    // Ready 信号: 只有获得仲裁的端口才能得到 ready
    assign p0_tready = sel_p0 ? m_tready : 1'b0;
    assign p1_tready = sel_p1 ? m_tready : 1'b0;

    // ===================================================================
    //  输出 MUX
    // ===================================================================

    always @(*) begin
        if (sel_p0) begin
            m_tdata  = p0_tdata;
            m_tkeep  = p0_tkeep;
            m_tlast  = p0_tlast;
            m_tvalid = p0_tvalid;
            m_tuser  = p0_tuser;
        end else if (sel_p1) begin
            m_tdata  = p1_tdata;
            m_tkeep  = p1_tkeep;
            m_tlast  = p1_tlast;
            m_tvalid = p1_tvalid;
            m_tuser  = p1_tuser;
        end else begin
            m_tdata  = 64'h0;
            m_tkeep  = 8'h0;
            m_tlast  = 1'b0;
            m_tvalid = 1'b0;
            m_tuser  = 4'h0;
        end
    end

    // ===================================================================
    //  仲裁状态机 — 保证帧完整性
    // ===================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            arb_state <= ARB_IDLE;
        end else begin
            case (arb_state)
                ARB_IDLE: begin
                    // 新帧开始: 按优先级选择端口
                    if (p0_tvalid) begin
                        arb_state <= ARB_P0;
                    end else if (p1_tvalid) begin
                        arb_state <= ARB_P1;
                    end
                end

                ARB_P0: begin
                    // 等待帧结束 (tlast)
                    if (p0_tvalid && m_tready && p0_tlast) begin
                        arb_state <= ARB_IDLE;
                    end
                end

                ARB_P1: begin
                    // 等待帧结束 (tlast)
                    if (p1_tvalid && m_tready && p1_tlast) begin
                        arb_state <= ARB_IDLE;
                    end
                end

                default: arb_state <= ARB_IDLE;
            endcase
        end
    end

endmodule
