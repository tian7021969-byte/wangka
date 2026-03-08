// ===========================================================================
//
//  tb_bar0_hda_sim.v
//  BAR0 HDA Register Read Verification Testbench
//
// ===========================================================================
//
//  Test Plan
//  ---------
//  Directly instantiate bar0_hda_sim module (without PCIe IP or tag
//  randomizer) and simulate host-initiated Memory Read TLPs targeting
//  specific BAR0 register offsets.
//
//  Test Cases:
//    1. Read 0x00 (DWORD 0) -- GCAP[15:0] + VMIN[23:16] + VMAJ[31:24]
//       Expected: 32'h0100_4409  (VMAJ=01, VMIN=00, GCAP=4409)
//       Must NOT be 32'hFFFF_FFFF
//
//    2. Read 0x04 (DWORD 1) -- OUTPAY[15:0] + INPAY[31:16]
//       Expected: 32'h001D_003C  (INPAY=001D, OUTPAY=003C)
//
//    3. Read 0x08 (DWORD 2) -- GCTL (Global Control)
//       Expected: 32'h0000_0001  (CRST=1, controller out of reset)
//       Must NOT be 32'hFFFF_FFFF
//
//    4. Read 0x0C (DWORD 3) -- WAKEEN[15:0] + STATESTS[31:16]
//       Expected: 32'h0001_0000  (STATESTS=0001 codec detected)
//
//    5. Read 0x10 (DWORD 4) -- GSTS
//       Expected: 32'h0000_0000
//
//    6. Read 0x18 (DWORD 6) -- OUTSTRMPAY + INSTRMPAY
//       Expected: 32'h001D_003C
//
//    7. Read 0x30 (DWORD 12) -- WALCLK (Wall Clock)
//       Expected: non-zero after several clock cycles (free-running)
//
//    8. Read 0x4C (DWORD 19) -- CORBCTL/CORBST/CORBSIZE
//       Expected: CORBSIZE=42h
//
//  Each read verifies:
//    (a) CplD is returned (not dropped/timeout)
//    (b) Data matches AE-9 preset (not 0xFFFFFFFF)
//
//  Simulation Runtime: ~1 us at 62.5 MHz
//
// ===========================================================================

`timescale 1ns / 1ps

module tb_bar0_hda_sim;

    // ===================================================================
    //  Parameters
    // ===================================================================

    localparam CLK_PERIOD = 16.0;   // 62.5 MHz
    localparam NUM_TESTS  = 8;
    localparam TIMEOUT_CYCLES = 100;

    // AE-9 expected register values
    localparam [31:0] EXP_DW00 = 32'h0100_4409;  // VMAJ=01, VMIN=00, GCAP=4409
    localparam [31:0] EXP_DW01 = 32'h001D_003C;  // INPAY=001D, OUTPAY=003C
    localparam [31:0] EXP_DW02 = 32'h0000_0001;  // GCTL: CRST=1
    localparam [31:0] EXP_DW03 = 32'h0001_0000;  // STATESTS=0001, WAKEEN=0000
    localparam [31:0] EXP_DW04 = 32'h0000_0000;  // GSTS=0000
    localparam [31:0] EXP_DW06 = 32'h001D_003C;  // INSTRMPAY + OUTSTRMPAY
    // WALCLK (DW12) -- just check non-FFFFFFFF, value changes
    // CORBSIZE (DW19) partial check

    // ===================================================================
    //  Clock & Reset
    // ===================================================================

    reg clk;
    reg rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ===================================================================
    //  AXI-Stream RX (testbench -> bar0_hda_sim)
    // ===================================================================

    reg  [63:0] rx_tdata;
    reg  [ 7:0] rx_tkeep;
    reg         rx_tlast;
    reg         rx_tvalid;
    wire        rx_tready;
    reg  [21:0] rx_tuser;

    // ===================================================================
    //  AXI-Stream TX (bar0_hda_sim -> testbench)
    // ===================================================================

    wire [63:0] tx_tdata;
    wire [ 7:0] tx_tkeep;
    wire        tx_tlast;
    wire        tx_tvalid;
    reg         tx_tready;
    wire [ 3:0] tx_tuser;

    // ===================================================================
    //  DUT: bar0_hda_sim
    // ===================================================================

    wire [15:0] completer_id = {8'd1, 5'd0, 3'd0};  // Bus=1, Dev=0, Fn=0

    // 简易 24 MHz tick 生成 (测试用: 62.5/2.604... ≈ 24 MHz 近似)
    reg [2:0] tick_div;
    reg       walclk_tick_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            tick_div     <= 3'd0;
            walclk_tick_r <= 1'b0;
        end else begin
            // 每 2~3 周期产生一个 tick, 平均约 24 MHz
            if (tick_div >= 3'd2) begin
                tick_div     <= 3'd0;
                walclk_tick_r <= 1'b1;
            end else begin
                tick_div     <= tick_div + 3'd1;
                walclk_tick_r <= 1'b0;
            end
        end
    end

    bar0_hda_sim u_dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .completer_id       (completer_id),
        .jitter_seed        (16'hCAFE),
        .walclk_tick        (walclk_tick_r),

        .m_axis_rx_tdata    (rx_tdata),
        .m_axis_rx_tkeep    (rx_tkeep),
        .m_axis_rx_tlast    (rx_tlast),
        .m_axis_rx_tvalid   (rx_tvalid),
        .m_axis_rx_tready   (rx_tready),
        .m_axis_rx_tuser    (rx_tuser),

        .s_axis_tx_tdata    (tx_tdata),
        .s_axis_tx_tkeep    (tx_tkeep),
        .s_axis_tx_tlast    (tx_tlast),
        .s_axis_tx_tvalid   (tx_tvalid),
        .s_axis_tx_tready   (tx_tready),
        .s_axis_tx_tuser    (tx_tuser),

        // Codec Engine 接口 — 不连接
        .corb_base_lo       (),
        .corb_base_hi       (),
        .corb_wp_out        (),
        .corb_ctl_out       (),
        .rirb_base_lo       (),
        .rirb_base_hi       (),
        .rirb_ctl_out       (),
        .codec_rirb_wp      (16'h0),
        .codec_rirb_sts     (8'h0),
        .codec_corb_rp      (16'h0),
        .msi_irq_request    (),
        .walclk_out         ()
    );

    // ===================================================================
    //  Task: Send 3DW Memory Read TLP
    // ===================================================================

    task send_mrd;
        input [ 7:0] tag;
        input [31:0] address;
        begin
            @(posedge clk);
            wait(rx_tready);
            @(posedge clk);
            // Beat 0: {DW1, DW0}
            rx_tdata  <= {16'hBEEF,                             // Requester ID
                          tag, 4'h0, 4'hF,                      // Tag, LastBE=0, FirstBE=F
                          1'b0, 2'b00, 5'b00000, 1'b0,          // Fmt=00(3DW no data), Type=00000
                          3'b000, 4'b0000, 1'b0, 1'b0,          // TC=0, R, TD=0, EP=0
                          2'b00, 2'b00, 10'd1};                  // Attr=0, R, Length=1
            rx_tkeep  <= 8'hFF;
            rx_tlast  <= 1'b0;
            rx_tvalid <= 1'b1;
            rx_tuser  <= 22'h00_0004;
            @(posedge clk);

            // Beat 1: {padding, DW2(address)}
            rx_tdata  <= {32'h0, address[31:2], 2'b00};
            rx_tkeep  <= 8'h0F;
            rx_tlast  <= 1'b1;
            rx_tvalid <= 1'b1;
            rx_tuser  <= 22'h0;
            @(posedge clk);

            // De-assert
            rx_tdata  <= 64'h0;
            rx_tkeep  <= 8'h0;
            rx_tlast  <= 1'b0;
            rx_tvalid <= 1'b0;
            rx_tuser  <= 22'h0;
        end
    endtask

    // ===================================================================
    //  Task: Capture CplD data from TX output
    // ===================================================================
    //
    //  CplD format (from bar0_hda_sim):
    //    Beat 0: {cpld_dw1, cpld_dw0}  -- Completion header
    //    Beat 1: {reg_rd_data, cpld_dw2}  -- Data + Requester info
    //
    //  reg_rd_data is in tx_tdata[63:32] of Beat 1.

    task capture_cpld;
        output [31:0] data;
        output        valid;
        integer       timeout;
        begin
            valid = 1'b0;
            timeout = 0;

            // Wait for Beat 0 (SOF)
            while (!(tx_tvalid && tx_tready) && timeout < TIMEOUT_CYCLES) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (timeout >= TIMEOUT_CYCLES) begin
                $display("    [TIMEOUT] No CplD Beat 0 received!");
                data = 32'hDEAD_DEAD;
                valid = 1'b0;
            end else begin
                @(posedge clk);
                // Wait for Beat 1 (tlast)
                timeout = 0;
                while (!(tx_tvalid && tx_tready && tx_tlast) && timeout < TIMEOUT_CYCLES) begin
                    @(posedge clk);
                    timeout = timeout + 1;
                end

                if (timeout >= TIMEOUT_CYCLES) begin
                    $display("    [TIMEOUT] No CplD Beat 1 received!");
                    data = 32'hDEAD_DEAD;
                    valid = 1'b0;
                end else begin
                    data = tx_tdata[63:32];  // reg_rd_data
                    valid = 1'b1;
                end
            end

            @(posedge clk);
        end
    endtask

    // ===================================================================
    //  Test Infrastructure
    // ===================================================================

    integer test_num;
    integer pass_total;
    integer fail_total;
    reg [31:0] rd_data;
    reg        rd_valid;

    task check_register;
        input [31:0] byte_addr;
        input [31:0] expected;
        input [8*32-1:0] reg_name;  // string
        input        check_exact;   // 1 = exact match, 0 = just not FFFFFFFF
        begin
            test_num = test_num + 1;
            send_mrd(test_num[7:0], byte_addr);
            capture_cpld(rd_data, rd_valid);

            $display("");
            $display("  TEST %0d: Read BAR0+%03Xh (%0s)", test_num, byte_addr, reg_name);
            $display("    Returned : %08Xh", rd_data);

            if (!rd_valid) begin
                $display("    [FAIL] No valid CplD returned!");
                fail_total = fail_total + 1;
            end else if (rd_data == 32'hFFFF_FFFF) begin
                $display("    [FAIL] Got FFFFFFFF -- device appears as empty shell!");
                fail_total = fail_total + 1;
            end else if (check_exact && (rd_data != expected)) begin
                $display("    Expected : %08Xh", expected);
                $display("    [FAIL] Value mismatch!");
                fail_total = fail_total + 1;
            end else begin
                if (check_exact)
                    $display("    Expected : %08Xh", expected);
                $display("    [PASS] %0s", check_exact ? "Exact match" : "Non-FFFF confirmed");
                pass_total = pass_total + 1;
            end

            repeat (3) @(posedge clk);
        end
    endtask

    // ===================================================================
    //  Main Test Sequence
    // ===================================================================

    initial begin
        // ---- Init ----
        rst_n     = 1'b0;
        rx_tdata  = 64'h0;
        rx_tkeep  = 8'h0;
        rx_tlast  = 1'b0;
        rx_tvalid = 1'b0;
        rx_tuser  = 22'h0;
        tx_tready = 1'b1;
        test_num  = 0;
        pass_total = 0;
        fail_total = 0;

        // ---- Reset ----
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        // Let wall clock tick for a while before reading WALCLK
        repeat (20) @(posedge clk);

        $display("");
        $display("=============================================================");
        $display("  BAR0 HDA Register Read Verification Testbench");
        $display("  Target: Creative Sound Blaster AE-9 (bar0_hda_sim)");
        $display("=============================================================");

        // Test 1: 0x00 -- GCAP + VMIN + VMAJ (PID/VID equivalent)
        check_register(32'h0000_0000, EXP_DW00, "GCAP/VMIN/VMAJ", 1);

        // Test 2: 0x04 -- OUTPAY + INPAY
        check_register(32'h0000_0004, EXP_DW01, "OUTPAY/INPAY", 1);

        // Test 3: 0x08 -- GCTL (Revision ID / Global Control)
        check_register(32'h0000_0008, EXP_DW02, "GCTL", 1);

        // Test 4: 0x0C -- WAKEEN + STATESTS
        check_register(32'h0000_000C, EXP_DW03, "WAKEEN/STATESTS", 1);

        // Test 5: 0x10 -- GSTS
        check_register(32'h0000_0010, EXP_DW04, "GSTS", 1);

        // Test 6: 0x18 -- OUTSTRMPAY + INSTRMPAY
        check_register(32'h0000_0018, EXP_DW06, "OUTSTRMPAY/INSTRMPAY", 1);

        // Test 7: 0x30 -- WALCLK (free-running, just check not FFFFFFFF)
        check_register(32'h0000_0030, 32'h0, "WALCLK", 0);

        // Test 8: 0x4C -- CORBCTL/CORBST/CORBSIZE
        // Expected partial: byte[2] = CORBSIZE = 0x42
        begin : test_corbsize
            test_num = test_num + 1;
            send_mrd(test_num[7:0], 32'h0000_004C);
            capture_cpld(rd_data, rd_valid);

            $display("");
            $display("  TEST %0d: Read BAR0+04Ch (CORBCTL/CORBST/CORBSIZE)", test_num);
            $display("    Returned : %08Xh", rd_data);

            if (!rd_valid) begin
                $display("    [FAIL] No valid CplD returned!");
                fail_total = fail_total + 1;
            end else if (rd_data == 32'hFFFF_FFFF) begin
                $display("    [FAIL] Got FFFFFFFF!");
                fail_total = fail_total + 1;
            end else if (rd_data[23:16] != 8'h42) begin
                $display("    Expected CORBSIZE (byte 2) = 42h, Got: %02Xh", rd_data[23:16]);
                $display("    [FAIL] CORBSIZE mismatch!");
                fail_total = fail_total + 1;
            end else begin
                $display("    CORBSIZE = %02Xh (256 entries)", rd_data[23:16]);
                $display("    [PASS] CORBSIZE matches AE-9");
                pass_total = pass_total + 1;
            end
        end

        // ============================================================
        //  Summary
        // ============================================================

        $display("");
        $display("=============================================================");
        $display("  SUMMARY: %0d PASSED, %0d FAILED (out of %0d tests)",
                 pass_total, fail_total, pass_total + fail_total);
        $display("-------------------------------------------------------------");
        if (fail_total == 0) begin
            $display("  RESULT: *** ALL TESTS PASSED ***");
            $display("  BAR0 returns authentic AE-9 HDA register values.");
            $display("  Device will NOT be detected as empty shell (no FFFFFFFF).");
        end else begin
            $display("  RESULT: *** SOME TESTS FAILED ***");
            $display("  BAR0 register values do not match AE-9 expectations.");
        end
        $display("=============================================================");
        $display("");

        repeat (10) @(posedge clk);
        $finish;
    end

    // ===================================================================
    //  Waveform Dump
    // ===================================================================

    initial begin
        $dumpfile("tb_bar0_hda_sim.vcd");
        $dumpvars(0, tb_bar0_hda_sim);
    end

endmodule
