// ===========================================================================
//
//  hda_codec_engine.v
//  Creative Sound Blaster AE-9 — CORB/RIRB Codec Verb 响应引擎
//
// ===========================================================================
//
//  功能概述
//  --------
//  模拟 CA0132 (Sound Core3D) Codec 的 Verb 处理逻辑。
//  当 HDA 驱动向 CORB 写入命令后，本模块:
//    1. 通过 DMA MRd 读取主机 CORB 内存中的 Verb 命令
//    2. 根据 Verb ID 生成符合 CA0132 规范的响应
//    3. 通过 DMA MWr 将响应写入主机 RIRB 内存
//    4. 更新 RIRB Write Pointer 并触发中断请求
//
//  CA0132 Codec 拓扑 (Sound Blaster AE-9)
//  ----------------------------------------
//  Root Node (NID 0x00):
//    └─ AFG  (NID 0x01): Audio Function Group
//        ├─ DAC  (NID 0x02): Line Out DAC
//        ├─ ADC  (NID 0x03): Line In ADC
//        ├─ Pin  (NID 0x04): Line Out Pin Complex
//        ├─ Pin  (NID 0x05): Line In Pin Complex
//        ├─ Pin  (NID 0x06): Headphone Pin Complex
//        ├─ Pin  (NID 0x07): Mic In Pin Complex
//        ├─ DAC  (NID 0x08): Headphone DAC
//        └─ Mix  (NID 0x09): Mixer
//
// ===========================================================================

module hda_codec_engine (
    input  wire         clk,
    input  wire         rst_n,

    // CORB/RIRB 寄存器接口 (来自 bar0_hda_sim)
    input  wire [31:0]  corb_base_lo,       // CORBLBASE
    input  wire [31:0]  corb_base_hi,       // CORBUBASE
    input  wire [15:0]  corb_wp,            // CORBWP (主机写指针)
    input  wire [ 7:0]  corb_ctl,           // CORBCTL
    input  wire [31:0]  rirb_base_lo,       // RIRBLBASE
    input  wire [31:0]  rirb_base_hi,       // RIRBUBASE
    input  wire [ 7:0]  rirb_ctl,           // RIRBCTL
    output reg  [15:0]  rirb_wp,            // RIRBWP (设备写指针)
    output reg  [ 7:0]  rirb_sts,           // RIRBSTS

    // CORB Read Pointer 输出
    output reg  [15:0]  corb_rp,            // CORBRP (设备读指针)

    // DMA 请求接口 (送往 hda_dma_engine)
    output reg          dma_rd_req,         // DMA 读请求
    output reg  [63:0]  dma_rd_addr,        // DMA 读地址
    input  wire         dma_rd_done,        // DMA 读完成
    input  wire [31:0]  dma_rd_data,        // DMA 读数据

    output reg          dma_wr_req,         // DMA 写请求
    output reg  [63:0]  dma_wr_addr,        // DMA 写地址
    output reg  [63:0]  dma_wr_data,        // DMA 写数据 (RIRB entry = 64-bit)
    input  wire         dma_wr_done,        // DMA 写完成

    // 中断请求
    output reg          irq_rirb           // RIRB 中断请求
);

    // ===================================================================
    //  状态机
    // ===================================================================

    localparam [3:0] ST_IDLE       = 4'd0,
                     ST_CHECK_CORB = 4'd1,
                     ST_DMA_RD_REQ = 4'd2,
                     ST_DMA_RD_WAIT= 4'd3,
                     ST_PROCESS    = 4'd4,
                     ST_DMA_WR_REQ = 4'd5,
                     ST_DMA_WR_WAIT= 4'd6,
                     ST_UPDATE_PTR = 4'd7,
                     ST_COOLDOWN   = 4'd8;

    reg [3:0] state;
    reg [31:0] verb_cmd;        // 当前 CORB 命令
    reg [31:0] verb_resp;       // 生成的响应
    reg [ 3:0] resp_codec_addr; // 响应中的 Codec Address

    // CORB Run 标志
    wire corb_run = corb_ctl[1];
    // RIRB DMA 使能
    wire rirb_run = rirb_ctl[1];

    // Cooldown 计数器 — 模拟真实 Codec 处理延迟
    reg [7:0] cooldown_cnt;

    // ===================================================================
    //  Cooldown LFSR — 随机 8~24 周期延迟
    // ===================================================================
    //
    // 8-bit Galois LFSR, 多项式 x^8 + x^6 + x^5 + x^4 + 1
    // 输出 lfsr[3:0] 映射到 8~24 周期: delay = lfsr[3:0] + 8

    reg [7:0] cd_lfsr;
    wire cd_fb = cd_lfsr[0];
    wire [7:0] cd_random_delay = {4'h0, cd_lfsr[3:0]} + 8'd8; // 8~23 周期

    always @(posedge clk) begin
        if (!rst_n)
            cd_lfsr <= 8'hA3;  // 非零种子
        else
            cd_lfsr <= {1'b0, cd_lfsr[7:1]}
                     ^ (cd_fb ? 8'hB8 : 8'h00);  // taps: 8,6,5,4
    end

    // ===================================================================
    //  Verb 解码逻辑 — CA0132 Codec 响应
    // ===================================================================

    // CORB 命令格式: [31:28]=Codec Addr, [27:20]=NID, [19:0]=Verb+Payload
    wire [3:0]  cmd_codec = verb_cmd[31:28];
    wire [7:0]  cmd_nid   = verb_cmd[27:20];
    wire [19:0] cmd_verb  = verb_cmd[19:0];

    // 标准 Get Parameter Verb: Verb ID = Fxx (12-bit verb, 8-bit payload)
    wire is_get_param  = (cmd_verb[19:8] == 12'hF00);
    wire [7:0] param_id = cmd_verb[7:0];

    // 其他常用 Verb
    wire is_get_conn_sel  = (cmd_verb[19:8] == 12'hF01);
    wire is_get_amp_gain  = (cmd_verb[19:8] == 12'hB00) || (cmd_verb[19:0] == 20'hF0D00);
    wire is_get_power     = (cmd_verb[19:8] == 12'hF05);
    wire is_get_pin_ctl   = (cmd_verb[19:8] == 12'hF07);
    wire is_get_eapd      = (cmd_verb[19:8] == 12'hF0C);
    wire is_get_pin_sense = (cmd_verb[19:8] == 12'hF09);
    wire is_get_config    = (cmd_verb[19:8] == 12'hF1C);
    wire is_get_vol_knob  = (cmd_verb[19:8] == 12'hF0F);

    // Set Verb (3xxx, 7xx 等) — 返回 0 即可
    wire is_set_verb = (cmd_verb[19:16] == 4'h3) ||
                       (cmd_verb[19:16] == 4'h7) ||
                       (cmd_verb[19:16] == 4'h4) ||
                       (cmd_verb[19:16] == 4'h5);

    function [31:0] decode_verb;
        input [7:0] nid;
        input [19:0] verb;
        input [7:0] pid;
        begin
            decode_verb = 32'h0000_0000; // 默认响应

            if (is_get_param) begin
                case (pid)
                    8'h00: begin // Vendor ID
                        case (nid)
                            8'h00: decode_verb = 32'h11020011; // Root: Creative AE-9
                            8'h01: decode_verb = 32'h11020011; // AFG
                            default: decode_verb = 32'h11020011;
                        endcase
                    end
                    8'h02: begin // Revision ID
                        decode_verb = 32'h00100400; // Rev 1.0, Stepping 4.0
                    end
                    8'h04: begin // Subordinate Node Count
                        case (nid)
                            8'h00: decode_verb = {16'h0001, 16'h0001}; // Root: 1 sub (AFG at NID 1)
                            8'h01: decode_verb = {16'h0002, 16'h0008}; // AFG: 8 subs (NID 2-9)
                            default: decode_verb = 32'h0000_0000;
                        endcase
                    end
                    8'h05: begin // Function Group Type
                        if (nid == 8'h01)
                            decode_verb = 32'h0000_0001; // Audio Function Group
                        else
                            decode_verb = 32'h0000_0000;
                    end
                    8'h08: begin // Audio Capabilities
                        if (nid == 8'h01)
                            decode_verb = 32'h0001_0011; // PCM, 48kHz/16bit
                    end
                    8'h09: begin // Widget Type/Capabilities
                        case (nid)
                            8'h02: decode_verb = {4'h0, 28'h000_0041}; // DAC, stereo
                            8'h03: decode_verb = {4'h1, 28'h010_0B41}; // ADC, stereo, conn list
                            8'h04: decode_verb = {4'h4, 28'h000_0010}; // Pin, output
                            8'h05: decode_verb = {4'h4, 28'h002_0010}; // Pin, input
                            8'h06: decode_verb = {4'h4, 28'h000_0010}; // Pin, HP out
                            8'h07: decode_verb = {4'h4, 28'h002_0010}; // Pin, Mic in
                            8'h08: decode_verb = {4'h0, 28'h000_0041}; // DAC, stereo
                            8'h09: decode_verb = {4'h2, 28'h020_0001}; // Mixer
                            default: decode_verb = 32'h0000_0000;
                        endcase
                    end
                    8'h0A: begin // Supported PCM Size/Rate
                        decode_verb = 32'h0007_0070; // 16/20/24 bit, 44.1/48/96 kHz
                    end
                    8'h0B: begin // Supported Stream Formats
                        decode_verb = 32'h0000_0001; // PCM
                    end
                    8'h0C: begin // Pin Capabilities
                        case (nid)
                            8'h04: decode_verb = 32'h0001_0014; // Output, Pres Detect
                            8'h05: decode_verb = 32'h0002_0020; // Input
                            8'h06: decode_verb = 32'h0001_001C; // HP Out, Pres Detect
                            8'h07: decode_verb = 32'h0002_0024; // Input, Pres Detect
                            default: decode_verb = 32'h0000_0000;
                        endcase
                    end
                    8'h0D: begin // Input Amp Capabilities
                        decode_verb = 32'h0004_0080; // NumSteps=4, Offset=0, StepSize=80
                    end
                    8'h0E: begin // Connection List Length
                        case (nid)
                            8'h03: decode_verb = 32'h0000_0002; // ADC: 2 connections
                            8'h09: decode_verb = 32'h0000_0003; // Mixer: 3 connections
                            default: decode_verb = 32'h0000_0000;
                        endcase
                    end
                    8'h0F: begin // Output Amp Capabilities
                        decode_verb = 32'h8005_0080; // Mute cap, NumSteps=5, Offset=0
                    end
                    8'h12: begin // Volume Knob Capabilities
                        decode_verb = 32'h0000_0000;
                    end
                    default: decode_verb = 32'h0000_0000;
                endcase
            end else if (is_get_conn_sel) begin
                decode_verb = 32'h0000_0000; // Connection Select = 0
            end else if (is_get_power) begin
                decode_verb = 32'h0000_0000; // D0 state
            end else if (is_get_pin_ctl) begin
                case (nid)
                    8'h04: decode_verb = 32'h0000_0040; // Out Enable
                    8'h05: decode_verb = 32'h0000_0020; // In Enable
                    8'h06: decode_verb = 32'h0000_00C0; // HP Out Enable
                    8'h07: decode_verb = 32'h0000_0020; // In Enable
                    default: decode_verb = 32'h0000_0000;
                endcase
            end else if (is_get_eapd) begin
                decode_verb = 32'h0000_0002; // EAPD enable
            end else if (is_get_config) begin
                // Pin Configuration Default
                case (nid)
                    8'h04: decode_verb = 32'h01014010; // Line Out, Jack
                    8'h05: decode_verb = 32'h01A19020; // Line In, Jack
                    8'h06: decode_verb = 32'h02214030; // HP Out, Jack
                    8'h07: decode_verb = 32'h01813040; // Mic In, Jack
                    default: decode_verb = 32'h411111F0; // NC
                endcase
            end else if (is_get_vol_knob) begin
                decode_verb = 32'h0000_0000;
            end else if (is_get_pin_sense) begin
                // Pin Sense: Presence Detect (bit 31) for HP and Mic
                case (nid)
                    8'h06: decode_verb = 32'h8000_0000; // HP plugged
                    8'h07: decode_verb = 32'h8000_0000; // Mic plugged
                    default: decode_verb = 32'h0000_0000;
                endcase
            end else if (is_set_verb) begin
                decode_verb = 32'h0000_0000; // Set verbs: ack with 0
            end else begin
                decode_verb = 32'h0000_0000; // Unknown verb: return 0
            end
        end
    endfunction

    // ===================================================================
    //  主状态机
    // ===================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            corb_rp        <= 16'h0;
            rirb_wp        <= 16'h0;
            rirb_sts       <= 8'h0;
            verb_cmd       <= 32'h0;
            verb_resp      <= 32'h0;
            resp_codec_addr <= 4'h0;
            dma_rd_req     <= 1'b0;
            dma_rd_addr    <= 64'h0;
            dma_wr_req     <= 1'b0;
            dma_wr_addr    <= 64'h0;
            dma_wr_data    <= 64'h0;
            irq_rirb       <= 1'b0;
            cooldown_cnt   <= 8'h0;
        end else begin
            // 默认清除单周期脉冲
            dma_rd_req <= 1'b0;
            dma_wr_req <= 1'b0;
            irq_rirb   <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (corb_run && rirb_run) begin
                        state <= ST_CHECK_CORB;
                    end
                end

                ST_CHECK_CORB: begin
                    // 检查 CORB 是否有新命令
                    if (corb_rp[7:0] != corb_wp[7:0]) begin
                        // 有新命令，发起 DMA 读
                        state <= ST_DMA_RD_REQ;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_DMA_RD_REQ: begin
                    // 计算下一个 CORB entry 地址
                    // CORB entry = 4 bytes (1 DWORD), 地址 = base + (rp+1)*4
                    dma_rd_req  <= 1'b1;
                    dma_rd_addr <= {corb_base_hi, corb_base_lo} +
                                   {48'h0, (corb_rp[7:0] + 8'd1), 2'b00};
                    state <= ST_DMA_RD_WAIT;
                end

                ST_DMA_RD_WAIT: begin
                    if (dma_rd_done) begin
                        verb_cmd <= dma_rd_data;
                        resp_codec_addr <= dma_rd_data[31:28];
                        // 更新 CORB RP
                        corb_rp <= {8'h0, corb_rp[7:0] + 8'd1};
                        state <= ST_PROCESS;
                    end
                end

                ST_PROCESS: begin
                    // 解码 Verb 并生成响应
                    verb_resp <= decode_verb(cmd_nid, cmd_verb, param_id);
                    // 模拟 Codec 处理延迟 (LFSR 随机 8~23 周期)
                    cooldown_cnt <= cd_random_delay;
                    state <= ST_COOLDOWN;
                end

                ST_COOLDOWN: begin
                    if (cooldown_cnt == 8'd0) begin
                        state <= ST_DMA_WR_REQ;
                    end else begin
                        cooldown_cnt <= cooldown_cnt - 8'd1;
                    end
                end

                ST_DMA_WR_REQ: begin
                    // RIRB entry = 8 bytes: [63:32]=Resp EX (codec addr), [31:0]=Response
                    dma_wr_req  <= 1'b1;
                    dma_wr_addr <= {rirb_base_hi, rirb_base_lo} +
                                   {48'h0, (rirb_wp[7:0] + 8'd1), 3'b000};
                    dma_wr_data <= {{28'h0, resp_codec_addr}, verb_resp};
                    state <= ST_DMA_WR_WAIT;
                end

                ST_DMA_WR_WAIT: begin
                    if (dma_wr_done) begin
                        state <= ST_UPDATE_PTR;
                    end
                end

                ST_UPDATE_PTR: begin
                    // 更新 RIRB WP
                    rirb_wp <= {8'h0, rirb_wp[7:0] + 8'd1};
                    // 设置 RIRB 中断状态
                    rirb_sts <= rirb_sts | 8'h01; // RINTFL
                    // 触发中断
                    if (rirb_ctl[0]) begin // RINTCTL enable
                        irq_rirb <= 1'b1;
                    end
                    // 回到检查是否还有更多命令
                    state <= ST_CHECK_CORB;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
