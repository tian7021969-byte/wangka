// ===========================================================================
//
//  tx_arbiter.v
//  TX AXI-Stream Arbiter
//
// ===========================================================================
//
//  Overview
//  --------
//  Merges BAR0 CplD responses and DMA engine MRd/MWr TLPs into a
//  single TX path.
//  Priority: CplD response > DMA (PCIe spec requires Completion first)
//
//  Arbitration Policy
//  ------------------
//  - Strict priority: BAR0 CplD always wins
//  - Frame integrity: once a TLP frame starts, must complete before switch
//  - Backpressure: losing port gets tready=0, winning port gets passthrough
//
// ===========================================================================

module tx_arbiter (
    input  wire         clk,
    input  wire         rst_n,

    // Port 0: BAR0 CplD (high priority)
    input  wire [63:0]  p0_tdata,
    input  wire [ 7:0]  p0_tkeep,
    input  wire         p0_tlast,
    input  wire         p0_tvalid,
    output wire         p0_tready,
    input  wire [ 3:0]  p0_tuser,

    // Port 1: DMA Engine (low priority)
    input  wire [63:0]  p1_tdata,
    input  wire [ 7:0]  p1_tkeep,
    input  wire         p1_tlast,
    input  wire         p1_tvalid,
    output wire         p1_tready,
    input  wire [ 3:0]  p1_tuser,

    // Merged output (to Tag Randomizer)
    output reg  [63:0]  m_tdata,
    output reg  [ 7:0]  m_tkeep,
    output reg          m_tlast,
    output reg          m_tvalid,
    input  wire         m_tready,
    output reg  [ 3:0]  m_tuser
);

    // ===================================================================
    //  Arbitration State
    // ===================================================================

    localparam [1:0] ARB_IDLE = 2'd0,
                     ARB_P0   = 2'd1,
                     ARB_P1   = 2'd2;

    reg [1:0] arb_state;
    reg       lock_port; // Lock current transmitting port (frame integrity)

    // Port selection signals
    wire sel_p0 = (arb_state == ARB_P0) || (arb_state == ARB_IDLE && p0_tvalid);
    wire sel_p1 = (arb_state == ARB_P1) || (arb_state == ARB_IDLE && !p0_tvalid && p1_tvalid);

    // Ready signals: only the arbitration winner gets ready
    assign p0_tready = sel_p0 ? m_tready : 1'b0;
    assign p1_tready = sel_p1 ? m_tready : 1'b0;

    // ===================================================================
    //  Output MUX
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
    //  Arbitration State Machine - Guarantees Frame Integrity
    // ===================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            arb_state <= ARB_IDLE;
        end else begin
            case (arb_state)
                ARB_IDLE: begin
                    // New frame: select port by priority
                    if (p0_tvalid) begin
                        arb_state <= ARB_P0;
                    end else if (p1_tvalid) begin
                        arb_state <= ARB_P1;
                    end
                end

                ARB_P0: begin
                    // Wait for frame end (tlast)
                    if (p0_tvalid && m_tready && p0_tlast) begin
                        arb_state <= ARB_IDLE;
                    end
                end

                ARB_P1: begin
                    // Wait for frame end (tlast)
                    if (p1_tvalid && m_tready && p1_tlast) begin
                        arb_state <= ARB_IDLE;
                    end
                end

                default: arb_state <= ARB_IDLE;
            endcase
        end
    end

endmodule
