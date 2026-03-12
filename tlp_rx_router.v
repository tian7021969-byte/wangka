// ===========================================================================
//
//  tlp_rx_router.v
//  RX TLP Router / Dispatcher - Routes TLPs to BAR0 or DMA engine
//  based on TLP type
//
// ===========================================================================
//
//  Overview
//  --------
//  The PCIe IP RX AXI4-Stream has a single output, but we have two
//  consumers:
//    - bar0_i211_sim : handles MRd/MWr TLPs (BAR0 register access)
//    - DMA engine    : receives CplD TLPs (DMA read completion data)
//
//  Routing Rules:
//    - Completion / CplD (Fmt[1:0]=0x, Type=01010) -> DMA port
//    - All other TLPs (MRd, MWr, Msg, etc)         -> BAR0 port
//
//  Implementation:
//    - First beat: parse Fmt/Type fields, determine route target
//    - Subsequent beats: forward data directly to selected port
//    - Unselected port sees tvalid=0
//
// ===========================================================================

module tlp_rx_router (
    input  wire         clk,
    input  wire         rst_n,

    // Upstream: PCIe IP RX
    input  wire [63:0]  rx_tdata,
    input  wire [ 7:0]  rx_tkeep,
    input  wire         rx_tlast,
    input  wire         rx_tvalid,
    output wire         rx_tready,
    input  wire [21:0]  rx_tuser,

    // Downstream Port 0: BAR0 (MRd/MWr)
    output wire [63:0]  bar_rx_tdata,
    output wire [ 7:0]  bar_rx_tkeep,
    output wire         bar_rx_tlast,
    output wire         bar_rx_tvalid,
    input  wire         bar_rx_tready,
    output wire [21:0]  bar_rx_tuser,

    // Downstream Port 1: DMA Engine (CplD)
    output wire [63:0]  dma_rx_tdata,
    output wire [ 7:0]  dma_rx_tkeep,
    output wire         dma_rx_tlast,
    output wire         dma_rx_tvalid,
    input  wire         dma_rx_tready,
    output wire [21:0]  dma_rx_tuser
);

    // Route state
    localparam [1:0] RT_IDLE    = 2'd0,  // Waiting for TLP first beat
                     RT_TO_BAR  = 2'd1,  // Routing to BAR0
                     RT_TO_DMA  = 2'd2;  // Routing to DMA

    reg [1:0] route_state;

    // TLP type detection (parsed from first beat DW0)
    // DW0 format: [31]=R, [30:29]=Fmt, [28:24]=Type, ...
    // Completion:      Fmt=0x0, Type=01010
    // CplD (with data): Fmt[1]=1, Type=01010

    wire [1:0] rx_fmt  = rx_tdata[30:29];
    wire [4:0] rx_type = rx_tdata[28:24];

    // CplD/Cpl detection: Type=01010 (Completion)
    wire is_completion = (rx_type == 5'b01010);

    // BAR0 side tready
    wire bar_side_ready = (route_state == RT_TO_BAR) ? bar_rx_tready : 1'b0;
    // DMA side tready
    wire dma_side_ready = (route_state == RT_TO_DMA) ? dma_rx_tready : 1'b0;

    // Upstream tready: in IDLE, check downstream ready based on TLP type
    // Fix: previously IDLE always had ready=1, causing CplD first beat loss
    // when downstream was not ready
    wire idle_ready = rx_tvalid ? (is_completion ? dma_rx_tready : bar_rx_tready) : 1'b1;

    assign rx_tready = (route_state == RT_IDLE)   ? idle_ready :
                       (route_state == RT_TO_BAR) ? bar_rx_tready :
                       (route_state == RT_TO_DMA) ? dma_rx_tready :
                       1'b1;

    // Data path - direct passthrough
    assign bar_rx_tdata  = rx_tdata;
    assign bar_rx_tkeep  = rx_tkeep;
    assign bar_rx_tlast  = rx_tlast;
    assign bar_rx_tuser  = rx_tuser;

    assign dma_rx_tdata  = rx_tdata;
    assign dma_rx_tkeep  = rx_tkeep;
    assign dma_rx_tlast  = rx_tlast;
    assign dma_rx_tuser  = rx_tuser;

    // tvalid routing
    assign bar_rx_tvalid = (route_state == RT_TO_BAR) ? rx_tvalid :
                           (route_state == RT_IDLE && rx_tvalid && !is_completion) ? 1'b1 :
                           1'b0;

    assign dma_rx_tvalid = (route_state == RT_TO_DMA) ? rx_tvalid :
                           (route_state == RT_IDLE && rx_tvalid && is_completion) ? 1'b1 :
                           1'b0;

    // Route state machine
    always @(posedge clk) begin
        if (!rst_n) begin
            route_state <= RT_IDLE;
        end else begin
            case (route_state)
                RT_IDLE: begin
                    // Must wait for successful handshake (tvalid && tready) before transition
                    if (rx_tvalid && idle_ready) begin
                        if (rx_tlast) begin
                            // Single-beat TLP - no need to track route, stay IDLE
                            route_state <= RT_IDLE;
                        end else if (is_completion) begin
                            route_state <= RT_TO_DMA;
                        end else begin
                            route_state <= RT_TO_BAR;
                        end
                    end
                end

                RT_TO_BAR: begin
                    if (rx_tvalid && bar_rx_tready && rx_tlast) begin
                        route_state <= RT_IDLE;
                    end
                end

                RT_TO_DMA: begin
                    if (rx_tvalid && dma_rx_tready && rx_tlast) begin
                        route_state <= RT_IDLE;
                    end
                end

                default: route_state <= RT_IDLE;
            endcase
        end
    end

endmodule
