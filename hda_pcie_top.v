// ===========================================================================
//
//  hda_pcie_top.v
//  Creative Sound Blaster AE-9 — PCIe 端点顶层模块
//  目标器件: Xilinx Artix-7 75T (Captain 开发板)
//
// ===========================================================================
//
//  私人定制级 DMA 完整实现
//  -----------------------
//  数据路径:
//    RX: PCIe IP → bar0_hda_sim (BAR0 寄存器, AE-9 CplD 时序抖动)
//                → hda_codec_engine (CORB/RIRB Verb 处理)
//                → hda_dma_engine (Bus Master DMA)
//    TX: bar0_hda_sim (CplD) ─┐
//        hda_dma_engine (MRd/MWr) ──┤→ tx_arbiter → tlp_tag_randomizer → PCIe IP
//
//  新增模块:
//    1. hda_codec_engine — CA0132 Codec Verb 响应引擎
//    2. hda_dma_engine   — Bus Master DMA (MRd/MWr TLP 生成)
//    3. tx_arbiter       — TX 仲裁器 (CplD 优先于 DMA)
//
//  改进:
//    - MSI 中断支持 (RIRB 响应后触发)
//    - 电源状态管理 (D3hot 响应)
//    - DSN 基于 LFSR 每次上电不同
//    - LFSR 种子动态化 (基于 Wall Clock)
//    - CplD 响应延迟抖动 (模仿 AE-9)
//
// ===========================================================================

module hda_pcie_top (
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
    //  内部信号
    // ===================================================================

    wire        pcie_sys_clk;
    wire        user_clk;
    wire        user_reset;
    wire        user_lnk_up;
    wire        user_rst_n;

    // 配置管理
    wire [31:0] cfg_mgmt_do;
    wire        cfg_mgmt_rd_wr_done;

    // PCIe IP RX (→ BAR0)
    wire [63:0] rx_tdata;
    wire [ 7:0] rx_tkeep;
    wire        rx_tlast;
    wire        rx_tvalid;
    wire        rx_tready;
    wire [21:0] rx_tuser;

    // BAR0 TX → TX 仲裁器 端口 0
    wire [63:0] bar_tx_tdata;
    wire [ 7:0] bar_tx_tkeep;
    wire        bar_tx_tlast;
    wire        bar_tx_tvalid;
    wire        bar_tx_tready;
    wire [ 3:0] bar_tx_tuser;

    // DMA 引擎 TX → TX 仲裁器 端口 1
    wire [63:0] dma_tx_tdata;
    wire [ 7:0] dma_tx_tkeep;
    wire        dma_tx_tlast;
    wire        dma_tx_tvalid;
    wire        dma_tx_tready;
    wire [ 3:0] dma_tx_tuser;

    // TX 仲裁器输出 → Tag 随机化器
    wire [63:0] arb_tx_tdata;
    wire [ 7:0] arb_tx_tkeep;
    wire        arb_tx_tlast;
    wire        arb_tx_tvalid;
    wire        arb_tx_tready;
    wire [ 3:0] arb_tx_tuser;

    // Tag 随机化器输出 → PCIe IP TX
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

    // CORB/RIRB 信号 (bar0 ↔ codec engine)
    wire [31:0] corb_base_lo, corb_base_hi;
    wire [15:0] corb_wp_out;
    wire [ 7:0] corb_ctl_out;
    wire [31:0] rirb_base_lo, rirb_base_hi;
    wire [ 7:0] rirb_ctl_out;
    wire [15:0] codec_rirb_wp;
    wire [ 7:0] codec_rirb_sts;
    wire [15:0] codec_corb_rp;

    // DMA 接口 (codec engine ↔ dma engine)
    wire        dma_rd_req, dma_rd_done;
    wire [63:0] dma_rd_addr;
    wire [31:0] dma_rd_data;
    wire        dma_wr_req, dma_wr_done;
    wire [63:0] dma_wr_addr;
    wire [63:0] dma_wr_data;

    // DMA 引擎 CplD RX (暂不使用独立 RX 通路, 通过 DMA 引擎内部 stub 处理)
    wire        dma_cpl_timeout;

    // MSI 中断
    wire        msi_irq_request;
    wire        irq_rirb;

    // Wall Clock
    wire [31:0] walclk_out;

    // MMCM 24 MHz 精确时钟信号
    wire        clk_24m;          // MMCM 输出的 24 MHz 时钟
    wire        mmcm_locked;      // MMCM 锁定指示
    wire        mmcm_fb;          // MMCM 反馈时钟

    // 24 MHz 域复位同步器 (将 user_reset 安全同步到 clk_24m 域)
    reg  [1:0]  rst_24m_sync;     // 两级同步器
    wire        rst_24m;          // clk_24m 域的同步复位信号

    // walclk_tick: 将 24 MHz 时钟边沿转换为 user_clk 域的单周期脉冲
    reg  [2:0]  clk24_sync;      // 3 级同步器
    wire        walclk_tick;

    // 电源管理
    wire        cfg_to_turnoff;
    reg         cfg_turnoff_ok_r;
    wire [ 1:0] cfg_pmcsr_powerstate_w; // 当前电源状态 (00=D0, 11=D3hot)
    wire        in_d3hot;               // D3hot 状态指示

    // MSI 状态
    wire        cfg_interrupt_rdy;
    wire        cfg_interrupt_msienable;

    // ===================================================================
    //  DSN 动态化 — 基于 LFSR 每次上电产生不同序列号
    // ===================================================================
    //
    // 使用 Wall Clock 在链路建立时刻的值作为 DSN 低位部分
    // 高位保持固定前缀 (避免完全随机, 保持合理的序列号模式)

    reg [63:0] dsn_value;
    reg        dsn_latched;

    always @(posedge user_clk) begin
        if (user_reset) begin
            dsn_value   <= 64'hA7C3_E5F1_0000_0000;
            dsn_latched <= 1'b0;
        end else if (user_lnk_up && !dsn_latched) begin
            // 链路建立时锁定 DSN — 全 64 位动态化
            // 低 32 位: walclk XOR 常量混合
            dsn_value[31:0]  <= walclk_out ^ {16'h2D8C, walclk_out[15:0]};
            // 高 32 位: walclk 位反转 XOR 不同常量, 消除固定前缀指纹
            dsn_value[63:32] <= {walclk_out[7:0],  walclk_out[31:24],
                                 walclk_out[23:16], walclk_out[15:8]}
                                ^ 32'hA7C3_E5F1;
            dsn_latched <= 1'b1;
        end
    end

    // ===================================================================
    //  LFSR 种子 — 基于 Wall Clock 低位, 每次上电不同
    // ===================================================================

    reg [15:0] lfsr_seed_latched;
    reg        seed_latched;

    always @(posedge user_clk) begin
        if (user_reset) begin
            lfsr_seed_latched <= 16'hBEEF;
            seed_latched      <= 1'b0;
        end else if (user_lnk_up && !seed_latched) begin
            lfsr_seed_latched <= walclk_out[15:0] ^ walclk_out[31:16] ^ 16'h7A3F;
            seed_latched <= 1'b1;
        end
    end

    // ===================================================================
    //  MSI 中断控制逻辑
    // ===================================================================

    reg        cfg_interrupt_r;
    reg [ 7:0] cfg_interrupt_di_r;

    always @(posedge user_clk) begin
        if (user_reset) begin
            cfg_interrupt_r    <= 1'b0;
            cfg_interrupt_di_r <= 8'h0;
        end else begin
            if (msi_irq_request && cfg_interrupt_msienable && !cfg_interrupt_r) begin
                cfg_interrupt_r    <= 1'b1;
                cfg_interrupt_di_r <= 8'h00; // MSI vector 0
            end else if (cfg_interrupt_r && cfg_interrupt_rdy) begin
                cfg_interrupt_r    <= 1'b0;
            end
        end
    end

    // ===================================================================
    //  电源状态管理 — D3hot 响应
    // ===================================================================

    always @(posedge user_clk) begin
        if (user_reset)
            cfg_turnoff_ok_r <= 1'b0;
        else if (cfg_to_turnoff)
            cfg_turnoff_ok_r <= 1'b1;
        else
            cfg_turnoff_ok_r <= 1'b0;
    end

    // D3hot 检测: powerstate == 2'b11 表示 D3hot
    assign in_d3hot = (cfg_pmcsr_powerstate_w == 2'b11);

    // TX Gate: D3hot 期间强制拉低所有 TX tvalid,
    // 防止 Tag 随机化器和仲裁器在电源状态转换时锁死。
    // D0 恢复后 user_reset 会重置整条通路, 此处仅做安全门控。
    wire        gated_tag_tx_tvalid;
    wire [63:0] gated_tag_tx_tdata;
    wire [ 7:0] gated_tag_tx_tkeep;
    wire        gated_tag_tx_tlast;
    wire [ 3:0] gated_tag_tx_tuser;

    assign gated_tag_tx_tvalid = in_d3hot ? 1'b0 : tag_tx_tvalid;
    assign gated_tag_tx_tdata  = tag_tx_tdata;
    assign gated_tag_tx_tkeep  = tag_tx_tkeep;
    assign gated_tag_tx_tlast  = tag_tx_tlast;
    assign gated_tag_tx_tuser  = tag_tx_tuser;

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
    //  MMCM — 精确 24 MHz Wall Clock 生成
    // ===================================================================
    //
    // 从 user_clk (62.5 MHz) 产生精确 24.0 MHz:
    //
    // Artix-7 MMCM 规格:
    //   CLKFBOUT_MULT_F: 2.000 ~ 64.000 (步长 0.125)
    //   CLKOUT0_DIVIDE_F: 1.000 ~ 128.000 (步长 0.125)
    //   VCO 范围: 600 ~ 1440 MHz (speed grade -1, DRC 实测上限 1440)
    //
    // 配置: MULT=12.000, DIV=1, OUT_DIV=31.250
    //   VCO = 62.5 × 12.000 / 1 = 750 MHz ✓ (在 600~1440 范围内)
    //   OUT = 750 / 31.250 = 24.000 MHz ✓ (精确)
    //   所有参数均为 0.125 的整数倍 → 无 AVAL-139 DRC 警告

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (12.000),       // VCO = 62.5 × 12.0 = 750 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKIN1_PERIOD       (16.000),       // 62.5 MHz → 16 ns
        .CLKOUT0_DIVIDE_F   (31.250),       // 750 / 31.25 = 24.0 MHz
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .DIVCLK_DIVIDE      (1),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm_walclk (
        .CLKOUT0    (clk_24m),
        .CLKOUT0B   (),
        .CLKOUT1    (),
        .CLKOUT1B   (),
        .CLKOUT2    (),
        .CLKOUT2B   (),
        .CLKOUT3    (),
        .CLKOUT3B   (),
        .CLKOUT4    (),
        .CLKOUT5    (),
        .CLKOUT6    (),
        .CLKFBOUT   (mmcm_fb),
        .CLKFBOUTB  (),
        .LOCKED     (mmcm_locked),
        .CLKIN1     (user_clk),
        .PWRDWN     (1'b0),
        .RST        (user_reset),
        .CLKFBIN    (mmcm_fb)
    );

    // ===================================================================
    //  24 MHz 域复位同步器
    // ===================================================================
    //
    // user_reset 来自 PCIe IP (user_clk 域)，直接用于 clk_24m 域
    // 会造成亚稳态和高扇出延迟。使用两级同步器将复位安全传递到
    // clk_24m 域，同时考虑 MMCM 锁定状态。
    //
    // 复位条件: user_reset 有效 或 MMCM 未锁定

    always @(posedge clk_24m or posedge user_reset) begin
        if (user_reset)
            rst_24m_sync <= 2'b11;               // 异步置位 (立即复位)
        else if (!mmcm_locked)
            rst_24m_sync <= 2'b11;               // MMCM 未锁定时保持复位
        else
            rst_24m_sync <= {rst_24m_sync[0], 1'b0};  // 同步释放
    end

    assign rst_24m = rst_24m_sync[1];            // 两级同步后的复位

    // ===================================================================
    //  24 MHz → user_clk 域 Tick 同步器
    // ===================================================================
    //
    // clk_24m 的上升沿通过 toggle + 双 FF 同步转换为
    // user_clk 域的单周期脉冲 (walclk_tick)

    // 24 MHz 域: toggle register (使用同步后的 rst_24m)
    reg clk24_toggle;
    always @(posedge clk_24m or posedge rst_24m) begin
        if (rst_24m)
            clk24_toggle <= 1'b0;
        else
            clk24_toggle <= ~clk24_toggle;
    end

    // user_clk 域: 3 级同步 + 边沿检测
    always @(posedge user_clk) begin
        if (user_reset)
            clk24_sync <= 3'b000;
        else
            clk24_sync <= {clk24_sync[1:0], clk24_toggle};
    end

    assign walclk_tick = clk24_sync[2] ^ clk24_sync[1];

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

        .s_axis_tx_tdata                (gated_tag_tx_tdata),
        .s_axis_tx_tkeep                (gated_tag_tx_tkeep),
        .s_axis_tx_tlast                (gated_tag_tx_tlast),
        .s_axis_tx_tvalid               (gated_tag_tx_tvalid),
        .s_axis_tx_tready               (tag_tx_tready),
        .s_axis_tx_tuser                (gated_tag_tx_tuser),
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

        .cfg_mgmt_do                    (cfg_mgmt_do),
        .cfg_mgmt_rd_wr_done            (cfg_mgmt_rd_wr_done),
        .cfg_mgmt_di                    (32'h0),
        .cfg_mgmt_byte_en               (4'h0),
        .cfg_mgmt_dwaddr                (10'h0),
        .cfg_mgmt_wr_en                 (1'b0),
        .cfg_mgmt_rd_en                 (1'b0),
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
        .cfg_err_cpl_timeout            (dma_cpl_timeout),
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

        // MSI 中断 — 现在连接到中断控制逻辑
        .cfg_interrupt                  (cfg_interrupt_r),
        .cfg_interrupt_rdy              (cfg_interrupt_rdy),
        .cfg_interrupt_assert           (1'b0),
        .cfg_interrupt_di               (cfg_interrupt_di_r),
        .cfg_interrupt_do               (),
        .cfg_interrupt_mmenable         (),
        .cfg_interrupt_msienable        (cfg_interrupt_msienable),
        .cfg_interrupt_msixenable       (),
        .cfg_interrupt_msixfm           (),
        .cfg_interrupt_stat             (1'b0),
        .cfg_pciecap_interrupt_msgnum   (5'b0),

        // 电源管理 — 现在响应 D3hot 请求
        .cfg_turnoff_ok                 (cfg_turnoff_ok_r),
        .cfg_to_turnoff                 (cfg_to_turnoff),
        .cfg_trn_pending                (1'b0),
        .cfg_pm_halt_aspm_l0s           (1'b0),
        .cfg_pm_halt_aspm_l1            (1'b0),
        .cfg_pm_force_state_en          (1'b0),
        .cfg_pm_force_state             (2'b0),
        .cfg_pm_wake                    (1'b0),
        .cfg_pm_send_pme_to             (1'b0),

        // DSN — 动态化
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
    //  复位极性转换
    // ===================================================================

    assign user_rst_n = ~user_reset;

    // ===================================================================
    //  配置空间控制器 (保留, 不使用 cfg_mgmt 接口)
    // ===================================================================

    pcileech_pcie_cfg_a7 #(
        .DEVICE_SERIAL_NUMBER   (64'hA7C3_E5F1_2D8C_49B6)
    ) u_cfg_space (
        .clk            (user_clk),
        .rst_n          (user_rst_n),
        .dsn_runtime    (dsn_value),
        .dsn_valid      (dsn_latched),
        .cfg_rd_en      (1'b0),
        .cfg_wr_en      (1'b0),
        .cfg_dwaddr     (12'h0),
        .cfg_wr_data    (32'h0),
        .cfg_wr_be      (4'h0),
        .cfg_rd_data    (),
        .cfg_rd_valid   ()
    );

    // ===================================================================
    //  BAR0 HDA 寄存器交互仿真 (带 AE-9 CplD 时序抖动)
    // ===================================================================

    bar0_hda_sim u_bar0_sim (
        .clk                (user_clk),
        .rst_n              (user_rst_n),
        .completer_id       (completer_id),
        .jitter_seed        (lfsr_seed_latched),

        // RX
        .m_axis_rx_tdata    (rx_tdata),
        .m_axis_rx_tkeep    (rx_tkeep),
        .m_axis_rx_tlast    (rx_tlast),
        .m_axis_rx_tvalid   (rx_tvalid),
        .m_axis_rx_tready   (rx_tready),
        .m_axis_rx_tuser    (rx_tuser),

        // TX → TX 仲裁器 端口 0
        .s_axis_tx_tdata    (bar_tx_tdata),
        .s_axis_tx_tkeep    (bar_tx_tkeep),
        .s_axis_tx_tlast    (bar_tx_tlast),
        .s_axis_tx_tvalid   (bar_tx_tvalid),
        .s_axis_tx_tready   (bar_tx_tready),
        .s_axis_tx_tuser    (bar_tx_tuser),

        // Codec Engine 接口
        .corb_base_lo       (corb_base_lo),
        .corb_base_hi       (corb_base_hi),
        .corb_wp_out        (corb_wp_out),
        .corb_ctl_out       (corb_ctl_out),
        .rirb_base_lo       (rirb_base_lo),
        .rirb_base_hi       (rirb_base_hi),
        .rirb_ctl_out       (rirb_ctl_out),
        .codec_rirb_wp      (codec_rirb_wp),
        .codec_rirb_sts     (codec_rirb_sts),
        .codec_corb_rp      (codec_corb_rp),

        .msi_irq_request    (msi_irq_request),
        .walclk_out         (walclk_out),
        .walclk_tick        (walclk_tick)
    );

    // ===================================================================
    //  CORB/RIRB Codec Verb 响应引擎
    // ===================================================================

    hda_codec_engine u_codec_eng (
        .clk            (user_clk),
        .rst_n          (user_rst_n),

        .corb_base_lo   (corb_base_lo),
        .corb_base_hi   (corb_base_hi),
        .corb_wp        (corb_wp_out),
        .corb_ctl       (corb_ctl_out),
        .rirb_base_lo   (rirb_base_lo),
        .rirb_base_hi   (rirb_base_hi),
        .rirb_ctl       (rirb_ctl_out),
        .rirb_wp        (codec_rirb_wp),
        .rirb_sts       (codec_rirb_sts),
        .corb_rp        (codec_corb_rp),

        .dma_rd_req     (dma_rd_req),
        .dma_rd_addr    (dma_rd_addr),
        .dma_rd_done    (dma_rd_done),
        .dma_rd_data    (dma_rd_data),

        .dma_wr_req     (dma_wr_req),
        .dma_wr_addr    (dma_wr_addr),
        .dma_wr_data    (dma_wr_data),
        .dma_wr_done    (dma_wr_done),

        .irq_rirb       (irq_rirb)
    );

    // ===================================================================
    //  HDA DMA 引擎 (Bus Master)
    // ===================================================================

    hda_dma_engine u_dma_eng (
        .clk            (user_clk),
        .rst_n          (user_rst_n),
        .requester_id   (completer_id),

        .dma_rd_req     (dma_rd_req),
        .dma_rd_addr    (dma_rd_addr),
        .dma_rd_done    (dma_rd_done),
        .dma_rd_data    (dma_rd_data),

        .dma_wr_req     (dma_wr_req),
        .dma_wr_addr    (dma_wr_addr),
        .dma_wr_data    (dma_wr_data),
        .dma_wr_done    (dma_wr_done),

        // TX → TX 仲裁器 端口 1
        .s_axis_tx_tdata    (dma_tx_tdata),
        .s_axis_tx_tkeep    (dma_tx_tkeep),
        .s_axis_tx_tlast    (dma_tx_tlast),
        .s_axis_tx_tvalid   (dma_tx_tvalid),
        .s_axis_tx_tready   (dma_tx_tready),
        .s_axis_tx_tuser    (dma_tx_tuser),

        // DMA RX (CplD 接收) — 简化: 不使用独立 RX 通路
        .m_axis_rx_tdata    (64'h0),
        .m_axis_rx_tkeep    (8'h0),
        .m_axis_rx_tlast    (1'b0),
        .m_axis_rx_tvalid   (1'b0),
        .m_axis_rx_tready   (),
        .m_axis_rx_tuser    (22'h0),

        .cpl_timeout    (dma_cpl_timeout),
        .lfsr_seed      (lfsr_seed_latched)
    );

    // ===================================================================
    //  TX 仲裁器 (CplD 优先于 DMA)
    // ===================================================================

    tx_arbiter u_tx_arb (
        .clk        (user_clk),
        .rst_n      (user_rst_n),

        // 端口 0: BAR0 CplD (高优先级)
        .p0_tdata   (bar_tx_tdata),
        .p0_tkeep   (bar_tx_tkeep),
        .p0_tlast   (bar_tx_tlast),
        .p0_tvalid  (bar_tx_tvalid),
        .p0_tready  (bar_tx_tready),
        .p0_tuser   (bar_tx_tuser),

        // 端口 1: DMA 引擎 (低优先级)
        .p1_tdata   (dma_tx_tdata),
        .p1_tkeep   (dma_tx_tkeep),
        .p1_tlast   (dma_tx_tlast),
        .p1_tvalid  (dma_tx_tvalid),
        .p1_tready  (dma_tx_tready),
        .p1_tuser   (dma_tx_tuser),

        // 合并输出
        .m_tdata    (arb_tx_tdata),
        .m_tkeep    (arb_tx_tkeep),
        .m_tlast    (arb_tx_tlast),
        .m_tvalid   (arb_tx_tvalid),
        .m_tready   (arb_tx_tready),
        .m_tuser    (arb_tx_tuser)
    );

    // ===================================================================
    //  TLP Tag 随机化器 (动态种子)
    // ===================================================================

    tlp_tag_randomizer u_tag_rand (
        .clk                    (user_clk),
        .rst_n                  (user_rst_n),
        .lfsr_seed              (lfsr_seed_latched),

        // 输入: 来自 TX 仲裁器
        .s_axis_tx_tdata_in     (arb_tx_tdata),
        .s_axis_tx_tkeep_in     (arb_tx_tkeep),
        .s_axis_tx_tlast_in     (arb_tx_tlast),
        .s_axis_tx_tvalid_in    (arb_tx_tvalid),
        .s_axis_tx_tready_in    (arb_tx_tready),
        .s_axis_tx_tuser_in     (arb_tx_tuser),

        // 输出: 送往 PCIe IP
        .s_axis_tx_tdata_out    (tag_tx_tdata),
        .s_axis_tx_tkeep_out    (tag_tx_tkeep),
        .s_axis_tx_tlast_out    (tag_tx_tlast),
        .s_axis_tx_tvalid_out   (tag_tx_tvalid),
        .s_axis_tx_tready_out   (tag_tx_tready),
        .s_axis_tx_tuser_out    (tag_tx_tuser)
    );

    // ===================================================================
    //  链路状态指示灯
    // ===================================================================

    assign led_status = user_lnk_up;

endmodule
