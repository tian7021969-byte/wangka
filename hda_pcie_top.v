// ===========================================================================
//
//  hda_pcie_top.v
//  Creative Sound Blaster AE-9 — PCIe 端点顶层模块
//  目标器件: Xilinx Artix-7 75T (Captain 开发板)
//
// ===========================================================================
//
//  概述
//  ----
//  顶层集成模块，桥接物理 PCIe 接口到内部音频控制器逻辑。
//  数据路径:
//    RX: PCIe IP → bar0_hda_sim (BAR0 寄存器仿真，解析 MRd/MWr)
//    TX: bar0_hda_sim (CplD 生成) → tlp_tag_randomizer (Tag 随机化) → PCIe IP
//
//  基于 Vivado 生成的 pcie_7x_0 IP (.veo) 完整端口列表，
//  确保所有输入端口均显式连接，消除 BlackBox 未连接警告。
//
//  时钟域
//  ------
//    1. PCIe 参考时钟 (100 MHz, 外部)  → IBUFDS_GTE2 → GTP PLL
//    2. PCIe 用户时钟 (62.5/125 MHz)   → user_clk_out → 所有用户逻辑
//    无需显式 CDC，Xilinx PCIe IP 内部处理。
//
//  引脚映射 (75T Captain, FGG484)
//  ------------------------------
//  信号名          引脚    约束方式
//  pcie_clk_p      F6      PACKAGE_PIN
//  pcie_clk_n      E6      PACKAGE_PIN
//  pcie_rst_n      J1      PACKAGE_PIN + PULLUP
//  pcie_tx_p/n     D2/D1   IP 自动放置
//  pcie_rx_p/n     E2/E1   IP 自动放置
//  led_status      G1      PACKAGE_PIN
//
// ===========================================================================

module hda_pcie_top (
    // PCIe 参考时钟 — 100 MHz 差分 (MGT Bank 216 专用引脚)
    input  wire         pcie_clk_p,
    input  wire         pcie_clk_n,

    // PCIe 基本复位 (PERST#, 低电平有效)
    input  wire         pcie_rst_n,

    // PCIe x1 GTP 收发器通道 (IP 自动放置，XDC 中不约束)
    output wire         pcie_tx_p,
    output wire         pcie_tx_n,
    input  wire         pcie_rx_p,
    input  wire         pcie_rx_n,

    // 状态指示灯 (高电平 = 链路已建立)
    output wire         led_status
);

    // ===================================================================
    //  内部信号
    // ===================================================================

    wire        pcie_sys_clk;       // IBUFDS_GTE2 输出
    wire        user_clk;           // 用户域时钟
    wire        user_reset;         // 高电平有效复位
    wire        user_lnk_up;       // 链路建立指示
    wire        user_rst_n;         // 低电平有效复位 (给 cfg 子模块)

    // 配置管理接口
    wire [31:0] cfg_mgmt_do;
    wire        cfg_mgmt_rd_wr_done;

    // PCIe IP AXI-Stream RX 输出 (IP → BAR0 仿真器)
    wire [63:0] rx_tdata;
    wire [ 7:0] rx_tkeep;
    wire        rx_tlast;
    wire        rx_tvalid;
    wire        rx_tready;
    wire [21:0] rx_tuser;

    // BAR0 仿真器 TX 输出 → TLP Tag 随机化器输入
    wire [63:0] bar_tx_tdata;
    wire [ 7:0] bar_tx_tkeep;
    wire        bar_tx_tlast;
    wire        bar_tx_tvalid;
    wire        bar_tx_tready;
    wire [ 3:0] bar_tx_tuser;

    // TLP Tag 随机化器输出 → PCIe IP TX 输入
    wire [63:0] tag_tx_tdata;
    wire [ 7:0] tag_tx_tkeep;
    wire        tag_tx_tlast;
    wire        tag_tx_tvalid;
    wire        tag_tx_tready;
    wire [ 3:0] tag_tx_tuser;

    // Completer ID (Bus/Device/Function)
    wire [ 7:0] cfg_bus_number;
    wire [ 4:0] cfg_device_number;
    wire [ 2:0] cfg_function_number;
    wire [15:0] completer_id = {cfg_bus_number, cfg_device_number, cfg_function_number};

    // ===================================================================
    //  差分参考时钟缓冲器 (IBUFDS_GTE2)
    // ===================================================================

    IBUFDS_GTE2 pcie_clk_ibuf (
        .O      (pcie_sys_clk),
        .ODIV2  (),
        .I      (pcie_clk_p),
        .IB     (pcie_clk_n),
        .CEB    (1'b0)
    );

    // ===================================================================
    //  Xilinx 7 系列 PCIe IP 核 (pcie_7x_0)
    // ===================================================================
    //
    // 以下端口列表来自 Vivado 生成的 pcie_7x_0.veo，确保与 IP
    // 完全一致。所有未使用的输入端口均接常量，防止 BlackBox 警告。

    pcie_7x_0 u_pcie_ep (

        // ---- PCIe 串行接口 ----
        .pci_exp_txp                    (pcie_tx_p),
        .pci_exp_txn                    (pcie_tx_n),
        .pci_exp_rxp                    (pcie_rx_p),
        .pci_exp_rxn                    (pcie_rx_n),

        // ---- PIPE 时钟管理 (shared logic in core) ----
        // int_pclk_sel_slave: PIPE 时钟速率选择输入
        // 单端点设计中接 1'b0 (固定使用 IP 内部时钟管理)
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

        // ---- 系统接口 ----
        .sys_clk                        (pcie_sys_clk),
        .sys_rst_n                      (pcie_rst_n),

        // ---- 用户时钟与复位 ----
        .user_clk_out                   (user_clk),
        .user_reset_out                 (user_reset),
        .user_lnk_up                    (user_lnk_up),
        .user_app_rdy                   (),

        // ---- AXI4-Stream 发送 (经 Tag 随机化器输出) ----
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

        // ---- AXI4-Stream 接收 (送往 BAR0 仿真器) ----
        .m_axis_rx_tdata                (rx_tdata),
        .m_axis_rx_tkeep                (rx_tkeep),
        .m_axis_rx_tlast                (rx_tlast),
        .m_axis_rx_tvalid               (rx_tvalid),
        .m_axis_rx_tready               (rx_tready),
        .m_axis_rx_tuser                (rx_tuser),
        .rx_np_ok                       (1'b1),
        .rx_np_req                      (1'b1),

        // ---- 流控 ----
        .fc_cpld                        (),
        .fc_cplh                        (),
        .fc_npd                         (),
        .fc_nph                         (),
        .fc_pd                          (),
        .fc_ph                          (),
        .fc_sel                         (3'b0),

        // ---- 配置管理接口 ----
        .cfg_mgmt_do                    (cfg_mgmt_do),
        .cfg_mgmt_rd_wr_done            (cfg_mgmt_rd_wr_done),
        .cfg_mgmt_di                    (32'h0),
        .cfg_mgmt_byte_en               (4'h0),
        .cfg_mgmt_dwaddr                (10'h0),
        .cfg_mgmt_wr_en                 (1'b0),
        .cfg_mgmt_rd_en                 (1'b0),
        .cfg_mgmt_wr_readonly           (1'b0),
        .cfg_mgmt_wr_rw1c_as_rw        (1'b0),

        // ---- 配置状态输出 ----
        .cfg_status                     (),
        .cfg_command                    (),
        .cfg_dstatus                    (),
        .cfg_dcommand                   (),
        .cfg_lstatus                    (),
        .cfg_lcommand                   (),
        .cfg_dcommand2                  (),
        .cfg_pcie_link_state            (),
        .cfg_pmcsr_pme_en               (),
        .cfg_pmcsr_powerstate           (),
        .cfg_pmcsr_pme_status           (),
        .cfg_received_func_lvl_rst      (),

        // ---- 配置错误报告 (全部拉低 = 无错误) ----
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

        // ---- 配置中断 ----
        .cfg_interrupt                  (1'b0),
        .cfg_interrupt_rdy              (),
        .cfg_interrupt_assert           (1'b0),
        .cfg_interrupt_di               (8'h0),
        .cfg_interrupt_do               (),
        .cfg_interrupt_mmenable         (),
        .cfg_interrupt_msienable        (),
        .cfg_interrupt_msixenable       (),
        .cfg_interrupt_msixfm           (),
        .cfg_interrupt_stat             (1'b0),
        .cfg_pciecap_interrupt_msgnum   (5'b0),

        // ---- 配置电源管理 ----
        .cfg_turnoff_ok                 (1'b0),
        .cfg_to_turnoff                 (),
        .cfg_trn_pending                (1'b0),
        .cfg_pm_halt_aspm_l0s           (1'b0),
        .cfg_pm_halt_aspm_l1            (1'b0),
        .cfg_pm_force_state_en          (1'b0),
        .cfg_pm_force_state             (2'b0),
        .cfg_pm_wake                    (1'b0),
        .cfg_pm_send_pme_to             (1'b0),

        // ---- 配置设备序列号 (DSN) ----
        // 64 位 DSN，与 cfg 子模块中的 DEVICE_SERIAL_NUMBER 一致
        .cfg_dsn                        (64'hA7C3_E5F1_2D8C_49B6),

        // ---- 配置总线号 (用于 CplD Completer ID) ----
        .cfg_bus_number                 (cfg_bus_number),
        .cfg_device_number              (cfg_device_number),
        .cfg_function_number            (cfg_function_number),
        .cfg_ds_bus_number              (8'h0),
        .cfg_ds_device_number           (5'h0),
        .cfg_ds_function_number         (3'h0),

        // ---- 配置消息 ----
        .cfg_msg_received               (),
        .cfg_msg_data                   (),

        // ---- 配置桥接/AER ----
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

        // ---- 配置消息接收状态 ----
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

        // ---- 物理层控制 ----
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

        // ---- DRP 接口 (动态重配置，不使用) ----
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
    //  配置空间控制器
    // ===================================================================
    //
    // 注意: 当前 cfg_mgmt 接口未连接到 cfg 子模块（IP 内部 cfg 寄存器
    // 已由 IP 参数配置）。如需运行时修改配置空间，取消下方注释并
    // 将 cfg_mgmt 输入从常量改为 cfg 子模块的输出。

    pcileech_pcie_cfg_a7 #(
        .DEVICE_SERIAL_NUMBER   (64'hA7C3_E5F1_2D8C_49B6)
    ) u_cfg_space (
        .clk            (user_clk),
        .rst_n          (user_rst_n),
        .cfg_rd_en      (1'b0),
        .cfg_wr_en      (1'b0),
        .cfg_dwaddr     (12'h0),
        .cfg_wr_data    (32'h0),
        .cfg_wr_be      (4'h0),
        .cfg_rd_data    (),
        .cfg_rd_valid   ()
    );

    // ===================================================================
    //  BAR0 HDA 寄存器交互仿真 (D2-3)
    // ===================================================================
    //
    // 解析 RX 路径上的 Memory Read/Write TLP，返回符合 AE-9 HDA
    // 规范的寄存器值。CplD 报文输出到 TX 路径。

    bar0_hda_sim u_bar0_sim (
        .clk                (user_clk),
        .rst_n              (user_rst_n),
        .completer_id       (completer_id),

        // RX: 来自 PCIe IP
        .m_axis_rx_tdata    (rx_tdata),
        .m_axis_rx_tkeep    (rx_tkeep),
        .m_axis_rx_tlast    (rx_tlast),
        .m_axis_rx_tvalid   (rx_tvalid),
        .m_axis_rx_tready   (rx_tready),
        .m_axis_rx_tuser    (rx_tuser),

        // TX: 输出到 Tag 随机化器
        .s_axis_tx_tdata    (bar_tx_tdata),
        .s_axis_tx_tkeep    (bar_tx_tkeep),
        .s_axis_tx_tlast    (bar_tx_tlast),
        .s_axis_tx_tvalid   (bar_tx_tvalid),
        .s_axis_tx_tready   (bar_tx_tready),
        .s_axis_tx_tuser    (bar_tx_tuser)
    );

    // ===================================================================
    //  TLP Tag 随机化器 (D2-2)
    // ===================================================================
    //
    // 拦截所有出站 TLP，将 Header 中的 Tag 字段替换为 LFSR 伪随机值，
    // 消除 FPGA PCIe IP 默认的顺序递增 Tag 特征。

    tlp_tag_randomizer u_tag_rand (
        .clk                    (user_clk),
        .rst_n                  (user_rst_n),

        // 输入: 来自 BAR0 仿真器
        .s_axis_tx_tdata_in     (bar_tx_tdata),
        .s_axis_tx_tkeep_in     (bar_tx_tkeep),
        .s_axis_tx_tlast_in     (bar_tx_tlast),
        .s_axis_tx_tvalid_in    (bar_tx_tvalid),
        .s_axis_tx_tready_in    (bar_tx_tready),
        .s_axis_tx_tuser_in     (bar_tx_tuser),

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
