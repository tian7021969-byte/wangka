// ===========================================================================
//
//  tlp_tag_randomizer.v
//  TLP Transaction Tag Randomization Module
//
// ===========================================================================
//
//  Overview
//  --------
//  Intercepts TLPs on the AXI4-Stream TX path and replaces the Header
//  Tag field with an LFSR pseudo-random sequence, eliminating the
//  sequential increment pattern from the FPGA PCIe IP core default.
//
//  LFSR Seed Dynamic Generation
//  ----------------------------
//  Seed is sourced from external input (based on Wall Clock and PCIe
//  link establishment time low bits), ensuring a different Tag sequence
//  on each power cycle to avoid fixed-pattern fingerprint detection.
//
// ===========================================================================

module tlp_tag_randomizer (
    input  wire         clk,
    input  wire         rst_n,

    // Dynamic seed input (from top level, based on wall clock)
    input  wire [15:0]  lfsr_seed,

    // AXI4-Stream TX from user logic (input side)
    input  wire [63:0]  s_axis_tx_tdata_in,
    input  wire [ 7:0]  s_axis_tx_tkeep_in,
    input  wire         s_axis_tx_tlast_in,
    input  wire         s_axis_tx_tvalid_in,
    output wire         s_axis_tx_tready_in,
    input  wire [ 3:0]  s_axis_tx_tuser_in,

    // AXI4-Stream TX to PCIe IP core (output side)
    output reg  [63:0]  s_axis_tx_tdata_out,
    output reg  [ 7:0]  s_axis_tx_tkeep_out,
    output reg          s_axis_tx_tlast_out,
    output reg          s_axis_tx_tvalid_out,
    input  wire         s_axis_tx_tready_out,
    output reg  [ 3:0]  s_axis_tx_tuser_out
);

    // ===================================================================
    //  16-bit Galois LFSR - Dynamic Seed
    // ===================================================================
    //
    // Polynomial: x^16 + x^14 + x^13 + x^11 + 1
    // Seed from external (wall clock low bits XOR link establishment time)
    // Force non-zero seed: if lfsr_seed is 0, use 0xBEEF instead

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
    //  TLP Start-of-Frame (SOF) Detection
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
    //  Tag Replacement Logic - Pure Combinational Passthrough (Zero Delay)
    // ===================================================================
    //
    //  Previously used registered output (1 cycle delay), which could
    //  cause CplD delays or upstream handshake inconsistency under
    //  certain AXI backpressure scenarios.
    //  Changed to pure combinational passthrough to eliminate all
    //  delay risks.

    assign handshake = s_axis_tx_tvalid_in && s_axis_tx_tready_out;

    // Detect TLP type: DW0 in tdata[31:0], Type field at bit[28:24]
    // Completion TLP: Type = 01010 (0x0A)
    // Only replace Tag for non-Completion request TLPs (MRd/MWr)
    wire is_completion = (s_axis_tx_tdata_in[28:24] == 5'b01010);
    wire is_request_tlp = is_sof && s_axis_tx_tvalid_in && !is_completion;
    assign advance_lfsr = handshake && is_request_tlp;

    // tready direct passthrough
    assign s_axis_tx_tready_in = s_axis_tx_tready_out;

    // Pure combinational output - zero delay passthrough
    always @(*) begin
        s_axis_tx_tkeep_out  = s_axis_tx_tkeep_in;
        s_axis_tx_tlast_out  = s_axis_tx_tlast_in;
        s_axis_tx_tvalid_out = s_axis_tx_tvalid_in;
        s_axis_tx_tuser_out  = s_axis_tx_tuser_in;

        if (is_request_tlp) begin
            // Only replace Tag field on request TLP (MRd/MWr) first beat
            s_axis_tx_tdata_out = {
                s_axis_tx_tdata_in[63:48],  // Requester ID
                random_tag,                  // Tag <- LFSR
                s_axis_tx_tdata_in[39:0]     // BE + DW0
            };
        end else begin
            // Completion TLP and non-first beats: no modification, passthrough
            s_axis_tx_tdata_out = s_axis_tx_tdata_in;
        end
    end

endmodule
