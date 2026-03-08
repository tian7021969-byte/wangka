// ===========================================================================
//
//  tlp_tag_randomizer.v
//  TLP Transaction Tag 随机化模块
//
// ===========================================================================
//
//  功能概述
//  --------
//  拦截 AXI4-Stream TX 路径上的 TLP 报文，将 Header 中的 Tag 字段
//  替换为 LFSR 伪随机序列，消除 FPGA PCIe IP 核默认的顺序递增特征。
//
//  LFSR 种子动态化
//  ----------------
//  种子来源于外部输入 (基于 Wall Clock 和 PCIe 链路建立时刻的低位),
//  确保每次上电 Tag 序列不同，避免固定模式被检测工具指纹识别。
//
// ===========================================================================

module tlp_tag_randomizer (
    input  wire         clk,
    input  wire         rst_n,

    // 动态种子输入 (来自顶层, 基于 wall clock)
    input  wire [15:0]  lfsr_seed,

    // 来自用户逻辑的 AXI4-Stream TX (输入侧)
    input  wire [63:0]  s_axis_tx_tdata_in,
    input  wire [ 7:0]  s_axis_tx_tkeep_in,
    input  wire         s_axis_tx_tlast_in,
    input  wire         s_axis_tx_tvalid_in,
    output wire         s_axis_tx_tready_in,
    input  wire [ 3:0]  s_axis_tx_tuser_in,

    // 送往 PCIe IP 核的 AXI4-Stream TX (输出侧)
    output reg  [63:0]  s_axis_tx_tdata_out,
    output reg  [ 7:0]  s_axis_tx_tkeep_out,
    output reg          s_axis_tx_tlast_out,
    output reg          s_axis_tx_tvalid_out,
    input  wire         s_axis_tx_tready_out,
    output reg  [ 3:0]  s_axis_tx_tuser_out
);

    // ===================================================================
    //  16-bit Galois LFSR — 动态种子
    // ===================================================================
    //
    // 多项式: x^16 + x^14 + x^13 + x^11 + 1
    // 种子来自外部 (wall clock 低位 XOR 链路建立时刻)
    // 确保种子非零: 如果 lfsr_seed 为 0, 强制为 0xBEEF

    // ===================================================================
    //  前向声明 (forward declarations)
    // ===================================================================
    wire handshake;
    wire advance_lfsr;
    wire is_sof;

    reg [15:0] lfsr;
    wire [15:0] safe_seed = (lfsr_seed == 16'h0) ? 16'hBEEF : lfsr_seed;

    wire lfsr_feedback = lfsr[0];

    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= safe_seed;
        end else if (advance_lfsr) begin
            lfsr <= {1'b0, lfsr[15:1]}
                  ^ (lfsr_feedback ? 16'hB400 : 16'h0000);
        end
    end

    wire [7:0] random_tag = lfsr[7:0];

    // ===================================================================
    //  TLP 首拍检测 (SOF)
    // ===================================================================

    reg sof_tracker;

    always @(posedge clk) begin
        if (!rst_n) begin
            sof_tracker <= 1'b1;
        end else if (s_axis_tx_tvalid_in && s_axis_tx_tready_out) begin
            sof_tracker <= s_axis_tx_tlast_in;
        end
    end

    assign is_sof = sof_tracker;

    // ===================================================================
    //  Tag 替换逻辑
    // ===================================================================

    assign handshake = s_axis_tx_tvalid_in && s_axis_tx_tready_out;
    assign advance_lfsr = handshake && is_sof;

    assign s_axis_tx_tready_in = s_axis_tx_tready_out;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axis_tx_tdata_out  <= 64'h0;
            s_axis_tx_tkeep_out  <= 8'h0;
            s_axis_tx_tlast_out  <= 1'b0;
            s_axis_tx_tvalid_out <= 1'b0;
            s_axis_tx_tuser_out  <= 4'h0;
        end else if (s_axis_tx_tready_out) begin
            s_axis_tx_tvalid_out <= s_axis_tx_tvalid_in;
            s_axis_tx_tkeep_out  <= s_axis_tx_tkeep_in;
            s_axis_tx_tlast_out  <= s_axis_tx_tlast_in;
            s_axis_tx_tuser_out  <= s_axis_tx_tuser_in;

            if (is_sof && s_axis_tx_tvalid_in) begin
                s_axis_tx_tdata_out <= {
                    s_axis_tx_tdata_in[63:48],  // Requester ID
                    random_tag,                  // Tag ← LFSR
                    s_axis_tx_tdata_in[39:0]     // BE + DW0
                };
            end else begin
                s_axis_tx_tdata_out <= s_axis_tx_tdata_in;
            end
        end
    end

endmodule
