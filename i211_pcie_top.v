// ===========================================================================
//
//  i211_pcie_top.v
//  Intel I211 Gigabit Ethernet Controller - PCIe Endpoint Top-Level Module
//  Target Device: Xilinx Artix-7 75T (Captain DMA Board)
//
// ===========================================================================
//
//  Data Path:
//    RX: PCIe IP (Gen1 x1) -> tlp_rx_router -> bar0_i211_sim (BAR0 Regs)
//    TX: bar0_i211_sim (CplD) -> tx_arbiter -> tlp_tag_randomizer -> PCIe IP
//
//  Intel I211 PCIe Configuration:
//    Vendor ID  = 0x8086
//    Device ID  = 0x1539
//    Rev ID     = 0x03
//    Class Code = 0x020000 (Ethernet Controller)
//    BAR0       = 128KB Memory, 32-bit
//    PCIe       = Gen1 x1 (2.5 GT/s)
//    MSI-X      = 5 vectors (Table in BAR0)
//
// ===========================================================================

module i211_pcie_top (
    input  wire         pcie_clk_p,
    input  wire         pcie_clk_n,
    input  wire         pcie_rst_n,
    output wire         pcie_tx_p,
    output wire         pcie_tx_n,
    input  wire         pcie_rx_p,
    input  wire         pcie_rx_n,
    output wire         led_status
);

    // ===================================================================
    //  Internal Signals
    // ===================================================================

    wire        pcie_sys_clk;
    wire        user_clk;
    wire        user_reset;
    wire        user_lnk_up;
    wire        user_rst_n;

    // PCIe IP RX (-> TLP Router)
    wire [63:0] rx_tdata;
    wire [ 7:0] rx_tkeep;
    wire        rx_tlast;
    wire        rx_tvalid;
    wire        rx_tready;
    wire [21:0] rx_tuser;

    // TLP Router -> BAR0
    wire [63:0] routed_bar_rx_tdata;
    wire [ 7:0] routed_bar_rx_tkeep;
    wire        routed_bar_rx_tlast;
    wire        routed_bar_rx_tvalid;
    wire        routed_bar_rx_tready;
    wire [21:0] routed_bar_rx_tuser;

    // TLP Router -> DMA (unused, I211 does not need active DMA)
    wire [63:0] routed_dma_rx_tdata;
    wire [ 7:0] routed_dma_rx_tkeep;
    wire        routed_dma_rx_tlast;
    wire        routed_dma_rx_tvalid;
    wire        routed_dma_rx_tready;
    wire [21:0] routed_dma_rx_tuser;

    // BAR0 TX -> TX Arbiter Port 0
    wire [63:0] bar_tx_tdata;
    wire [ 7:0] bar_tx_tkeep;
    wire        bar_tx_tlast;
    wire        bar_tx_tvalid;
    wire        bar_tx_tready;
    wire [ 3:0] bar_tx_tuser;

    // TX Arbiter Output -> Tag Randomizer
    wire [63:0] arb_tx_tdata;
    wire [ 7:0] arb_tx_tkeep;
    wire        arb_tx_tlast;
    wire        arb_tx_tvalid;
    wire        arb_tx_tready;
    wire [ 3:0] arb_tx_tuser;

    // Tag Randomizer Output -> PCIe IP TX
    wire [63:0] tag_tx_tdata;
    wire [ 7:0] tag_tx_tkeep;
    wire        tag_tx_tlast;
    wire        tag_tx_tvalid;
    wire        tag_tx_tready;
    wire [ 3:0] tag_tx_tuser;

    // Completer ID
    wire [ 7:0] cfg_bus_number;
    wire [ 4:0] cfg_device_number;
    wire [ 2:0] cfg_function_number;
    wire [15:0] completer_id = {cfg_bus_number, cfg_device_number, cfg_function_number};

    // Power Management
    wire        cfg_to_turnoff;
    reg         cfg_turnoff_ok_r;
    wire [ 1:0] cfg_pmcsr_powerstate_w;

    // PM Force State: force device back to D0 when OS writes D3
    // The PCIe IP core exposes cfg_pmcsr_powerstate but doesn't auto-recover.
    // We use cfg_pm_force_state to override D3 back to D0.
    reg         cfg_pm_force_state_en_r;
    reg  [ 1:0] cfg_pm_force_state_r;
    reg  [ 1:0] pmcsr_powerstate_prev;

    // Configuration Management Interface - used to directly write PMCSR
    // to force PowerState = D0 when the driver transitions from D3->D0.
    // PMCSR is at config space DW address 0x11 (byte offset 0x44).
    wire [31:0] cfg_mgmt_do_w;
    wire        cfg_mgmt_rd_wr_done_w;
    reg  [31:0] cfg_mgmt_di_r;
    reg  [ 3:0] cfg_mgmt_byte_en_r;
    reg  [ 9:0] cfg_mgmt_dwaddr_r;
    reg         cfg_mgmt_wr_en_r;
    reg         cfg_mgmt_rd_en_r;

    // PMCSR force state machine
    localparam PM_IDLE      = 3'd0,
               PM_READ      = 3'd1,
               PM_READ_WAIT = 3'd2,
               PM_WRITE     = 3'd3,
               PM_WRITE_WAIT = 3'd4,
               PM_DONE      = 3'd5;
    reg [2:0]  pm_state;

    // MSI Status
    wire        cfg_interrupt_rdy;
    wire        cfg_interrupt_msienable;

    // ===================================================================
    //  DSN Dynamic Generation - LFSR generates different serial number
    //  on each power cycle
    // ===================================================================

    reg [63:0] dsn_value;
    reg        dsn_latched;
    reg [31:0] free_run_cnt;  // Free-running counter (replaces walclk)

    always @(posedge user_clk) begin
        if (user_reset)
            free_run_cnt <= 32'h0;
        else
            free_run_cnt <= free_run_cnt + 1'b1;
    end

    always @(posedge user_clk) begin
        if (user_reset) begin
            dsn_value   <= 64'h8086_1539_0000_0000;
            dsn_latched <= 1'b0;
        end else if (user_lnk_up && !dsn_latched) begin
            dsn_value[31:0]  <= free_run_cnt ^ {16'h3A7C, free_run_cnt[15:0]};
            dsn_value[63:32] <= {free_run_cnt[7:0],  free_run_cnt[31:24],
                                 free_run_cnt[23:16], free_run_cnt[15:8]}
                                ^ 32'h8086_1539;
            dsn_latched <= 1'b1;
        end
    end

    // ===================================================================
    //  LFSR Seed - Based on free_run_cnt low bits, different each boot
    // ===================================================================

    reg [15:0] lfsr_seed_latched;
    reg        seed_latched;

    always @(posedge user_clk) begin
        if (user_reset) begin
            lfsr_seed_latched <= 16'hBEEF;
            seed_latched      <= 1'b0;
        end else if (user_lnk_up && !seed_latched) begin
            lfsr_seed_latched <= free_run_cnt[15:0] ^ free_run_cnt[31:16] ^ 16'h7A3F;
            seed_latched <= 1'b1;
        end
    end

    // ===================================================================
    //  Power State Management
    //  
    //  CRITICAL FIX for D3 -> D0 transition:
    //  When Windows driver writes PMCSR PowerState = 11b (D3), the PCIe
    //  IP core transitions to D3. The driver then writes 00b (D0) to wake
    //  the device. We use cfg_pm_force_state to ensure the IP core
    //  transitions back to D0 immediately.
    //
    //  Without this, SIV shows "Current D3" and the driver gets 0xC0000001
    //  because the device appears non-responsive in D3.
    // ===================================================================

    always @(posedge user_clk) begin
        if (user_reset)
            cfg_turnoff_ok_r <= 1'b0;
        else if (cfg_to_turnoff)
            cfg_turnoff_ok_r <= 1'b1;
        else
            cfg_turnoff_ok_r <= 1'b0;
    end

    // ---- PM Force State: D3 -> D0 recovery ----
    // Monitor cfg_pmcsr_powerstate from PCIe IP.
    // When it enters D3 (2'b11), force it back to D0 (2'b00).
    // This ensures the driver's PMCSR write of 00b is accepted and
    // the device wakes up immediately.
    always @(posedge user_clk) begin
        if (user_reset) begin
            cfg_pm_force_state_en_r <= 1'b0;
            cfg_pm_force_state_r    <= 2'b00;
            pmcsr_powerstate_prev   <= 2'b00;
        end else begin
            pmcsr_powerstate_prev <= cfg_pmcsr_powerstate_w;

            // When PCIe IP reports any non-D0 state, force back to D0
            if (cfg_pmcsr_powerstate_w != 2'b00) begin
                cfg_pm_force_state_en_r <= 1'b1;
                cfg_pm_force_state_r    <= 2'b00;  // Force D0
            end
            // Once IP is back in D0, release the force
            else if (cfg_pm_force_state_en_r && cfg_pmcsr_powerstate_w == 2'b00) begin
                cfg_pm_force_state_en_r <= 1'b0;
            end
        end
    end

    // ---- PMCSR Config Space Write-Back via cfg_mgmt ----
    // When we detect cfg_pmcsr_powerstate != D0, use cfg_mgmt interface
    // to directly write PMCSR (DW addr 0x11, byte offset 0x44) with
    // PowerState = 00b (D0). This is the most reliable approach because
    // cfg_pm_force_state may not update the actual config space read-back
    // value fast enough for the driver's verification read.
    //
    // PMCSR register layout (DW at offset 0x44):
    //   bits [1:0] = PowerState (00=D0, 01=D1, 10=D2, 11=D3hot)
    //   bits [31:2] = other PM fields (preserve on write)
    //
    // State machine: IDLE -> detect non-D0 -> READ PMCSR -> clear bits[1:0] -> WRITE back
    always @(posedge user_clk) begin
        if (user_reset) begin
            pm_state         <= PM_IDLE;
            cfg_mgmt_di_r    <= 32'h0;
            cfg_mgmt_byte_en_r <= 4'h0;
            cfg_mgmt_dwaddr_r  <= 10'h0;
            cfg_mgmt_wr_en_r   <= 1'b0;
            cfg_mgmt_rd_en_r   <= 1'b0;
        end else begin
            case (pm_state)
                PM_IDLE: begin
                    cfg_mgmt_wr_en_r <= 1'b0;
                    cfg_mgmt_rd_en_r <= 1'b0;
                    // Trigger when PowerState transitions to non-D0
                    if (cfg_pmcsr_powerstate_w != 2'b00 && pmcsr_powerstate_prev == 2'b00) begin
                        pm_state <= PM_READ;
                    end
                end

                PM_READ: begin
                    // Read PMCSR at DW address 0x11 (byte offset 0x44)
                    cfg_mgmt_dwaddr_r <= 10'h011;
                    cfg_mgmt_rd_en_r  <= 1'b1;
                    pm_state          <= PM_READ_WAIT;
                end

                PM_READ_WAIT: begin
                    cfg_mgmt_rd_en_r <= 1'b0;
                    if (cfg_mgmt_rd_wr_done_w) begin
                        // Got PMCSR value, clear PowerState bits [1:0] to force D0
                        cfg_mgmt_di_r     <= {cfg_mgmt_do_w[31:2], 2'b00};
                        cfg_mgmt_dwaddr_r <= 10'h011;
                        cfg_mgmt_byte_en_r <= 4'b0001; // Only write byte 0 (contains PowerState)
                        pm_state           <= PM_WRITE;
                    end
                end

                PM_WRITE: begin
                    cfg_mgmt_wr_en_r <= 1'b1;
                    pm_state         <= PM_WRITE_WAIT;
                end

                PM_WRITE_WAIT: begin
                    cfg_mgmt_wr_en_r <= 1'b0;
                    if (cfg_mgmt_rd_wr_done_w) begin
                        pm_state <= PM_DONE;
                    end
                end

                PM_DONE: begin
                    // Wait for powerstate to settle back to D0
                    if (cfg_pmcsr_powerstate_w == 2'b00) begin
                        pm_state <= PM_IDLE;
                    end
                    // If still not D0, retry
                    else begin
                        pm_state <= PM_READ;
                    end
                end

                default: pm_state <= PM_IDLE;
            endcase
        end
    end

    // ===================================================================
    //  IBUFDS_GTE2
    // ===================================================================

    IBUFDS_GTE2 pcie_clk_ibuf (
        .O      (pcie_sys_clk),
        .ODIV2  (),
        .I      (pcie_clk_p),
        .IB     (pcie_clk_n),
        .CEB    (1'b0)
    );

    // ===================================================================
    //  PCIe IP (pcie_7x_0)
    // ===================================================================

    pcie_7x_0 u_pcie_ep (
        .pci_exp_txp                    (pcie_tx_p),
        .pci_exp_txn                    (pcie_tx_n),
        .pci_exp_rxp                    (pcie_rx_p),
        .pci_exp_rxn                    (pcie_rx_n),

        .int_pclk_out_slave             (),
        .int_pipe_rxusrclk_out          (),
        .int_rxoutclk_out               (),
        .int_dclk_out                   (),
        .int_mmcm_lock_out              (),
        .int_userclk1_out               (),
        .int_userclk2_out               (),
        .int_oobclk_out                 (),
        .int_qplllock_out               (),
        .int_qplloutclk_out             (),
        .int_qplloutrefclk_out          (),
        .int_pclk_sel_slave             (1'b0),

        .sys_clk                        (pcie_sys_clk),
        .sys_rst_n                      (pcie_rst_n),

        .user_clk_out                   (user_clk),
        .user_reset_out                 (user_reset),
        .user_lnk_up                    (user_lnk_up),
        .user_app_rdy                   (),

        .s_axis_tx_tdata                (tag_tx_tdata),
        .s_axis_tx_tkeep                (tag_tx_tkeep),
        .s_axis_tx_tlast                (tag_tx_tlast),
        .s_axis_tx_tvalid               (tag_tx_tvalid),
        .s_axis_tx_tready               (tag_tx_tready),
        .s_axis_tx_tuser                (tag_tx_tuser),
        .tx_cfg_gnt                     (1'b1),
        .tx_buf_av                      (),
        .tx_cfg_req                     (),
        .tx_err_drop                    (),

        .m_axis_rx_tdata                (rx_tdata),
        .m_axis_rx_tkeep                (rx_tkeep),
        .m_axis_rx_tlast                (rx_tlast),
        .m_axis_rx_tvalid               (rx_tvalid),
        .m_axis_rx_tready               (rx_tready),
        .m_axis_rx_tuser                (rx_tuser),
        .rx_np_ok                       (1'b1),
        .rx_np_req                      (1'b1),

        .fc_cpld                        (),
        .fc_cplh                        (),
        .fc_npd                         (),
        .fc_nph                         (),
        .fc_pd                          (),
        .fc_ph                          (),
        .fc_sel                         (3'b0),

        .cfg_mgmt_do                    (cfg_mgmt_do_w),
        .cfg_mgmt_rd_wr_done            (cfg_mgmt_rd_wr_done_w),
        .cfg_mgmt_di                    (cfg_mgmt_di_r),
        .cfg_mgmt_byte_en               (cfg_mgmt_byte_en_r),
        .cfg_mgmt_dwaddr                (cfg_mgmt_dwaddr_r),
        .cfg_mgmt_wr_en                 (cfg_mgmt_wr_en_r),
        .cfg_mgmt_rd_en                 (cfg_mgmt_rd_en_r),
        .cfg_mgmt_wr_readonly           (1'b0),
        .cfg_mgmt_wr_rw1c_as_rw        (1'b0),

        .cfg_status                     (),
        .cfg_command                    (),
        .cfg_dstatus                    (),
        .cfg_dcommand                   (),
        .cfg_lstatus                    (),
        .cfg_lcommand                   (),
        .cfg_dcommand2                  (),
        .cfg_pcie_link_state            (),
        .cfg_pmcsr_pme_en               (),
        .cfg_pmcsr_powerstate           (cfg_pmcsr_powerstate_w),
        .cfg_pmcsr_pme_status           (),
        .cfg_received_func_lvl_rst      (),

        .cfg_err_ecrc                   (1'b0),
        .cfg_err_ur                     (1'b0),
        .cfg_err_cpl_timeout            (1'b0),
        .cfg_err_cpl_unexpect           (1'b0),
        .cfg_err_cpl_abort              (1'b0),
        .cfg_err_posted                 (1'b0),
        .cfg_err_cor                    (1'b0),
        .cfg_err_atomic_egress_blocked  (1'b0),
        .cfg_err_internal_cor           (1'b0),
        .cfg_err_malformed              (1'b0),
        .cfg_err_mc_blocked             (1'b0),
        .cfg_err_poisoned               (1'b0),
        .cfg_err_norecovery             (1'b0),
        .cfg_err_tlp_cpl_header         (48'h0),
        .cfg_err_cpl_rdy                (),
        .cfg_err_locked                 (1'b0),
        .cfg_err_acs                    (1'b0),
        .cfg_err_internal_uncor         (1'b0),

        // MSI - not used (I211 uses MSI-X, but PCIe IP does not directly support MSI-X emulation)
        .cfg_interrupt                  (1'b0),
        .cfg_interrupt_rdy              (cfg_interrupt_rdy),
        .cfg_interrupt_assert           (1'b0),
        .cfg_interrupt_di               (8'h0),
        .cfg_interrupt_do               (),
        .cfg_interrupt_mmenable         (),
        .cfg_interrupt_msienable        (cfg_interrupt_msienable),
        .cfg_interrupt_msixenable       (),
        .cfg_interrupt_msixfm           (),
        .cfg_interrupt_stat             (1'b0),
        .cfg_pciecap_interrupt_msgnum   (5'b0),

        // Power Management
        .cfg_turnoff_ok                 (cfg_turnoff_ok_r),
        .cfg_to_turnoff                 (cfg_to_turnoff),
        .cfg_trn_pending                (1'b0),
        .cfg_pm_halt_aspm_l0s           (1'b0),
        .cfg_pm_halt_aspm_l1            (1'b0),
        .cfg_pm_force_state_en          (cfg_pm_force_state_en_r),
        .cfg_pm_force_state             (cfg_pm_force_state_r),
        .cfg_pm_wake                    (1'b0),
        .cfg_pm_send_pme_to             (1'b0),

        // DSN
        .cfg_dsn                        (dsn_value),

        .cfg_bus_number                 (cfg_bus_number),
        .cfg_device_number              (cfg_device_number),
        .cfg_function_number            (cfg_function_number),
        .cfg_ds_bus_number              (8'h0),
        .cfg_ds_device_number           (5'h0),
        .cfg_ds_function_number         (3'h0),

        .cfg_msg_received               (),
        .cfg_msg_data                   (),

        .cfg_bridge_serr_en             (),
        .cfg_slot_control_electromech_il_ctl_pulse (),
        .cfg_root_control_syserr_corr_err_en       (),
        .cfg_root_control_syserr_non_fatal_err_en  (),
        .cfg_root_control_syserr_fatal_err_en      (),
        .cfg_root_control_pme_int_en               (),
        .cfg_aer_rooterr_corr_err_reporting_en     (),
        .cfg_aer_rooterr_non_fatal_err_reporting_en (),
        .cfg_aer_rooterr_fatal_err_reporting_en    (),
        .cfg_aer_rooterr_corr_err_received         (),
        .cfg_aer_rooterr_non_fatal_err_received    (),
        .cfg_aer_rooterr_fatal_err_received        (),
        .cfg_err_aer_headerlog          (128'h0),
        .cfg_aer_interrupt_msgnum       (5'h0),
        .cfg_err_aer_headerlog_set      (),
        .cfg_aer_ecrc_check_en          (),
        .cfg_aer_ecrc_gen_en            (),
        .cfg_vc_tcvc_map                (),

        .cfg_msg_received_err_cor       (),
        .cfg_msg_received_err_non_fatal (),
        .cfg_msg_received_err_fatal     (),
        .cfg_msg_received_pm_as_nak     (),
        .cfg_msg_received_pm_pme        (),
        .cfg_msg_received_pme_to_ack    (),
        .cfg_msg_received_assert_int_a  (),
        .cfg_msg_received_assert_int_b  (),
        .cfg_msg_received_assert_int_c  (),
        .cfg_msg_received_assert_int_d  (),
        .cfg_msg_received_deassert_int_a (),
        .cfg_msg_received_deassert_int_b (),
        .cfg_msg_received_deassert_int_c (),
        .cfg_msg_received_deassert_int_d (),
        .cfg_msg_received_setslotpowerlimit (),

        .pl_directed_link_change        (2'b0),
        .pl_directed_link_width         (2'b0),
        .pl_directed_link_speed         (1'b0),
        .pl_directed_link_auton         (1'b0),
        .pl_upstream_prefer_deemph      (1'b1),
        .pl_sel_lnk_rate                (),
        .pl_sel_lnk_width               (),
        .pl_ltssm_state                 (),
        .pl_lane_reversal_mode          (),
        .pl_phy_lnk_up                  (),
        .pl_tx_pm_state                 (),
        .pl_rx_pm_state                 (),
        .pl_link_upcfg_cap              (),
        .pl_link_gen2_cap               (),
        .pl_link_partner_gen2_supported (),
        .pl_initial_link_width          (),
        .pl_directed_change_done        (),
        .pl_received_hot_rst            (),
        .pl_transmit_hot_rst            (1'b0),
        .pl_downstream_deemph_source    (1'b0),

        .pcie_drp_clk                   (1'b0),
        .pcie_drp_en                    (1'b0),
        .pcie_drp_we                    (1'b0),
        .pcie_drp_addr                  (9'h0),
        .pcie_drp_di                    (16'h0),
        .pcie_drp_do                    (),
        .pcie_drp_rdy                   ()
    );

    // ===================================================================
    //  Reset Polarity Conversion
    // ===================================================================

    assign user_rst_n = ~user_reset;

    // ===================================================================
    //  BAR0 I211 Handshake Logic (fixes 0xC0000001 / 0x38)
    // ===================================================================

    i211_handshake_logic u_bar0_sim (
        .clk                (user_clk),
        .rst_n              (user_rst_n),
        .completer_id       (completer_id),
        .cfg_pmcsr_powerstate (cfg_pmcsr_powerstate_w),
        .jitter_seed        (lfsr_seed_latched),

        // RX (from TLP Router)
        .m_axis_rx_tdata    (routed_bar_rx_tdata),
        .m_axis_rx_tkeep    (routed_bar_rx_tkeep),
        .m_axis_rx_tlast    (routed_bar_rx_tlast),
        .m_axis_rx_tvalid   (routed_bar_rx_tvalid),
        .m_axis_rx_tready   (routed_bar_rx_tready),
        .m_axis_rx_tuser    (routed_bar_rx_tuser),

        // TX -> TX Arbiter
        .s_axis_tx_tdata    (bar_tx_tdata),
        .s_axis_tx_tkeep    (bar_tx_tkeep),
        .s_axis_tx_tlast    (bar_tx_tlast),
        .s_axis_tx_tvalid   (bar_tx_tvalid),
        .s_axis_tx_tready   (bar_tx_tready),
        .s_axis_tx_tuser    (bar_tx_tuser)
    );

    // ===================================================================
    //  DMA RX - Unused (I211 emulation does not need active DMA)
    //  TLP Router DMA port must be properly terminated
    // ===================================================================

    assign routed_dma_rx_tready = 1'b1;  // Always accept and discard

    // ===================================================================
    //  RX TLP Router / Dispatcher
    // ===================================================================

    tlp_rx_router u_rx_router (
        .clk            (user_clk),
        .rst_n          (user_rst_n),

        .rx_tdata       (rx_tdata),
        .rx_tkeep       (rx_tkeep),
        .rx_tlast       (rx_tlast),
        .rx_tvalid      (rx_tvalid),
        .rx_tready      (rx_tready),
        .rx_tuser       (rx_tuser),

        .bar_rx_tdata   (routed_bar_rx_tdata),
        .bar_rx_tkeep   (routed_bar_rx_tkeep),
        .bar_rx_tlast   (routed_bar_rx_tlast),
        .bar_rx_tvalid  (routed_bar_rx_tvalid),
        .bar_rx_tready  (routed_bar_rx_tready),
        .bar_rx_tuser   (routed_bar_rx_tuser),

        .dma_rx_tdata   (routed_dma_rx_tdata),
        .dma_rx_tkeep   (routed_dma_rx_tkeep),
        .dma_rx_tlast   (routed_dma_rx_tlast),
        .dma_rx_tvalid  (routed_dma_rx_tvalid),
        .dma_rx_tready  (routed_dma_rx_tready),
        .dma_rx_tuser   (routed_dma_rx_tuser)
    );

    // ===================================================================
    //  TX Arbiter (only BAR0 port used, DMA port idle)
    // ===================================================================

    tx_arbiter u_tx_arb (
        .clk        (user_clk),
        .rst_n      (user_rst_n),

        // Port 0: BAR0 CplD
        .p0_tdata   (bar_tx_tdata),
        .p0_tkeep   (bar_tx_tkeep),
        .p0_tlast   (bar_tx_tlast),
        .p0_tvalid  (bar_tx_tvalid),
        .p0_tready  (bar_tx_tready),
        .p0_tuser   (bar_tx_tuser),

        // Port 1: Unused (no DMA)
        .p1_tdata   (64'h0),
        .p1_tkeep   (8'h0),
        .p1_tlast   (1'b0),
        .p1_tvalid  (1'b0),
        .p1_tready  (),
        .p1_tuser   (4'h0),

        // Merged output
        .m_tdata    (arb_tx_tdata),
        .m_tkeep    (arb_tx_tkeep),
        .m_tlast    (arb_tx_tlast),
        .m_tvalid   (arb_tx_tvalid),
        .m_tready   (arb_tx_tready),
        .m_tuser    (arb_tx_tuser)
    );

    // ===================================================================
    //  TLP Tag Randomizer
    // ===================================================================

    tlp_tag_randomizer u_tag_rand (
        .clk                    (user_clk),
        .rst_n                  (user_rst_n),
        .lfsr_seed              (lfsr_seed_latched),

        .s_axis_tx_tdata_in     (arb_tx_tdata),
        .s_axis_tx_tkeep_in     (arb_tx_tkeep),
        .s_axis_tx_tlast_in     (arb_tx_tlast),
        .s_axis_tx_tvalid_in    (arb_tx_tvalid),
        .s_axis_tx_tready_in    (arb_tx_tready),
        .s_axis_tx_tuser_in     (arb_tx_tuser),

        .s_axis_tx_tdata_out    (tag_tx_tdata),
        .s_axis_tx_tkeep_out    (tag_tx_tkeep),
        .s_axis_tx_tlast_out    (tag_tx_tlast),
        .s_axis_tx_tvalid_out   (tag_tx_tvalid),
        .s_axis_tx_tready_out   (tag_tx_tready),
        .s_axis_tx_tuser_out    (tag_tx_tuser)
    );

    // ===================================================================
    //  Link Status Indicator LED
    // ===================================================================

    assign led_status = ~user_lnk_up;

endmodule
