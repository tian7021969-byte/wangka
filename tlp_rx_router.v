// ===========================================================================
//
//  tlp_rx_router.v
//  RX TLP 路由分发器 — 根据 TLP 类型路由到 BAR0 或 DMA 引擎
//
// ===========================================================================
//
//  功能概述
//  --------
//  PCIe IP 的 RX AXI4-Stream 通路只有一个输出，但我们有两个消费者:
//    - bar0_hda_sim : 处理 MRd/MWr TLP (BAR0 寄存器访问)
//    - hda_dma_engine : 接收 CplD TLP (DMA 读返回的 Completion)
//
//  路由规则:
//    - Completion / CplD (Fmt[1:0]=0x, Type=01010) → DMA 端口
//    - 其他所有 TLP (MRd, MWr, Msg, etc)          → BAR0 端口
//
//  实现方式:
//    - 第一拍解析 Fmt/Type 字段, 决定路由目标
//    - 后续拍数据直接转发到选定端口
//    - 未被选中的端口 tvalid=0
//
// ===========================================================================

module tlp_rx_router (
    input  wire         clk,
    input  wire         rst_n,

    // 上游: PCIe IP RX
    input  wire [63:0]  rx_tdata,
    input  wire [ 7:0]  rx_tkeep,
    input  wire         rx_tlast,
    input  wire         rx_tvalid,
    output wire         rx_tready,
    input  wire [21:0]  rx_tuser,

    // 下游端口 0: BAR0 (MRd/MWr)
    output wire [63:0]  bar_rx_tdata,
    output wire [ 7:0]  bar_rx_tkeep,
    output wire         bar_rx_tlast,
    output wire         bar_rx_tvalid,
    input  wire         bar_rx_tready,
    output wire [21:0]  bar_rx_tuser,

    // 下游端口 1: DMA 引擎 (CplD)
    output wire [63:0]  dma_rx_tdata,
    output wire [ 7:0]  dma_rx_tkeep,
    output wire         dma_rx_tlast,
    output wire         dma_rx_tvalid,
    input  wire         dma_rx_tready,
    output wire [21:0]  dma_rx_tuser
);

    // 路由状态
    localparam [1:0] RT_IDLE    = 2'd0,  // 等待 TLP 第一拍
                     RT_TO_BAR  = 2'd1,  // 路由到 BAR0
                     RT_TO_DMA  = 2'd2;  // 路由到 DMA

    reg [1:0] route_state;

    // TLP 类型检测 (从第一拍 DW0 解析)
    // DW0 格式: [31]=R, [30:29]=Fmt, [28:24]=Type, ...
    // Completion:      Fmt=0x0, Type=01010  → CplD 是 Fmt=010
    // CplD (with data): Fmt[1]=1, Type=01010

    wire [1:0] rx_fmt  = rx_tdata[30:29];
    wire [4:0] rx_type = rx_tdata[28:24];

    // CplD/Cpl 判断: Type=01010 (Completion)
    wire is_completion = (rx_type == 5'b01010);

    // BAR0 方向 tready
    wire bar_side_ready = (route_state == RT_TO_BAR) ? bar_rx_tready : 1'b0;
    // DMA 方向 tready
    wire dma_side_ready = (route_state == RT_TO_DMA) ? dma_rx_tready : 1'b0;

    // 上游 tready: IDLE 时始终 ready (接受第一拍); 路由中跟踪目标
    assign rx_tready = (route_state == RT_IDLE)   ? 1'b1 :
                       (route_state == RT_TO_BAR) ? bar_rx_tready :
                       (route_state == RT_TO_DMA) ? dma_rx_tready :
                       1'b1;

    // 数据通路 — 直接透传
    assign bar_rx_tdata  = rx_tdata;
    assign bar_rx_tkeep  = rx_tkeep;
    assign bar_rx_tlast  = rx_tlast;
    assign bar_rx_tuser  = rx_tuser;

    assign dma_rx_tdata  = rx_tdata;
    assign dma_rx_tkeep  = rx_tkeep;
    assign dma_rx_tlast  = rx_tlast;
    assign dma_rx_tuser  = rx_tuser;

    // tvalid 路由
    assign bar_rx_tvalid = (route_state == RT_TO_BAR) ? rx_tvalid :
                           (route_state == RT_IDLE && rx_tvalid && !is_completion) ? 1'b1 :
                           1'b0;

    assign dma_rx_tvalid = (route_state == RT_TO_DMA) ? rx_tvalid :
                           (route_state == RT_IDLE && rx_tvalid && is_completion) ? 1'b1 :
                           1'b0;

    // 路由状态机
    always @(posedge clk) begin
        if (!rst_n) begin
            route_state <= RT_IDLE;
        end else begin
            case (route_state)
                RT_IDLE: begin
                    if (rx_tvalid) begin
                        if (rx_tlast) begin
                            // 单拍 TLP — 不需要跟踪路由, 保持 IDLE
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
