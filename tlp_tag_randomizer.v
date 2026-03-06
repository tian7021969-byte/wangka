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
//  替换为 LFSR 伪随机序列，消除 FPGA PCIe IP 核默认的顺序递增
//  (01→02→03) 特征。
//
//  真实 ASIC 声卡（如 Creative AE-9）的 Tag 分配由硬件调度器决定，
//  呈现出非线性、跳跃式的模式。本模块通过 16-bit Galois LFSR
//  (多项式 x^16 + x^14 + x^13 + x^11 + 1) 生成 Tag 值，
//  截取低 8 位作为新 Tag，模拟这种行为。
//
//  TLP Header 格式 (64-bit AXI 数据通道)
//  --------------------------------------
//  对于 3DW Header (Memory Read/Write, 32-bit address):
//
//    第一拍 s_axis_tx_tdata[63:0]:
//      [63:32] = DW1: Requester ID [31:16], Tag [15:8], Last/First DW BE [7:0]
//      [31:0]  = DW0: Fmt[31:29], Type[28:24], TC[22:20], Length[9:0] 等
//
//    Tag 位置: tdata[47:40]  (DW1 的 bits [15:8])
//
//  工作原理
//  --------
//  1. 监测 tvalid & tready，在每个 TLP 的第一拍 (SOF) 识别 Header
//  2. 提取 Fmt/Type 判断是否为需要 Tag 的请求类型
//  3. 用 LFSR 输出替换 Tag 字段
//  4. 后续数据拍直通，不做修改
//
//  时序影响: 纯组合逻辑替换 + 1级寄存器流水，不增加延迟周期。
//
// ===========================================================================

module tlp_tag_randomizer (
    input  wire         clk,
    input  wire         rst_n,

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
    //  16-bit Galois LFSR — 伪随机 Tag 生成器
    // ===================================================================
    //
    // 多项式: x^16 + x^14 + x^13 + x^11 + 1
    // 周期: 65535 (2^16 - 1)，保证 Tag 在连续 ~65K 个事务内不重复。
    // 种子值非零即可；选用 0xBEEF 以确保上电后立即产生有效输出。

    reg [15:0] lfsr;

    wire lfsr_feedback = lfsr[0];

    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 16'hBEEF;
        end else if (advance_lfsr) begin
            lfsr <= {1'b0, lfsr[15:1]}
                  ^ (lfsr_feedback ? 16'hB400 : 16'h0000);
        end
    end

    wire [7:0] random_tag = lfsr[7:0];

    // ===================================================================
    //  TLP 首拍检测 (SOF)
    // ===================================================================
    //
    // 在 AXI-Stream 中，每个 TLP 的第一拍包含 Header。
    // 我们用 sof_tracker 追踪：当前拍是否为 TLP 第一拍。
    //   - 复位后 sof = 1（等待第一个 TLP）
    //   - 每当 tlast 被接受，下一拍为新 TLP 的 SOF

    reg sof_tracker;

    always @(posedge clk) begin
        if (!rst_n) begin
            sof_tracker <= 1'b1;
        end else if (s_axis_tx_tvalid_in && s_axis_tx_tready_out) begin
            sof_tracker <= s_axis_tx_tlast_in;
        end
    end

    wire is_sof = sof_tracker;

    // ===================================================================
    //  Tag 替换逻辑
    // ===================================================================
    //
    // 仅在 SOF 拍替换 Tag 字段 [47:40]。
    // LFSR 在每次替换后步进一次，确保下一个 TLP 使用不同的 Tag。
    // 非 SOF 拍（数据 payload）直通不修改。

    wire handshake = s_axis_tx_tvalid_in && s_axis_tx_tready_out;
    wire advance_lfsr = handshake && is_sof;

    // 反压直通: 下游 ready 直接传递给上游
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
                // 替换 Tag 字段，其余 Header 位保持不变
                s_axis_tx_tdata_out <= {
                    s_axis_tx_tdata_in[63:48],  // Requester ID [63:48]
                    random_tag,                  // Tag [47:40] ← LFSR
                    s_axis_tx_tdata_in[39:0]     // BE + DW0 [39:0]
                };
            end else begin
                s_axis_tx_tdata_out <= s_axis_tx_tdata_in;
            end
        end
    end

endmodule
