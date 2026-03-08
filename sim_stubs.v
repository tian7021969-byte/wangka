// ===========================================================================
//
//  sim_stubs.v
//  仿真专用行为模型 — 仅加入 Simulation Sources (sim_1)
//
//  包含:
//    1. IBUFDS_GTE2  — Xilinx 7-Series GTP 差分参考时钟缓冲器行为模型
//    2. pcie_7x_0    — PCIe IP 行为级仿真 Stub
//
//  重要: 此文件只能放在 Vivado 的 Simulation Sources (sim_1) 中，
//        绝对不能放在 Design Sources (sources_1) 中。
//
// ===========================================================================

`timescale 1ns / 1ps


// ===========================================================================
//  IBUFDS_GTE2 — 行为级仿真模型
// ===========================================================================

module IBUFDS_GTE2 (
    output wire O,
    output wire ODIV2,
    input  wire I,
    input  wire IB,
    input  wire CEB
);
    assign O     = (CEB == 1'b0) ? I : 1'b0;
    assign ODIV2 = 1'b0;
endmodule


// ===========================================================================
//  pcie_7x_0 — 行为级仿真 Stub (更新: 支持 MSI 中断和电源管理)
// ===========================================================================

module pcie_7x_0 (
    output [0:0]  pci_exp_txp,
    output [0:0]  pci_exp_txn,
    input  [0:0]  pci_exp_rxp,
    input  [0:0]  pci_exp_rxn,

    output        int_pclk_out_slave,
    output        int_pipe_rxusrclk_out,
    output [0:0]  int_rxoutclk_out,
    output        int_dclk_out,
    output        int_mmcm_lock_out,
    output        int_userclk1_out,
    output        int_userclk2_out,
    output        int_oobclk_out,
    output [1:0]  int_qplllock_out,
    output [1:0]  int_qplloutclk_out,
    output [1:0]  int_qplloutrefclk_out,
    input  [0:0]  int_pclk_sel_slave,

    input         sys_clk,
    input         sys_rst_n,

    output reg    user_clk_out,
    output reg    user_reset_out,
    output reg    user_lnk_up,
    output        user_app_rdy,

    output [5:0]  tx_buf_av,
    output        tx_cfg_req,
    output        tx_err_drop,
    output reg    s_axis_tx_tready,
    input  [63:0] s_axis_tx_tdata,
    input  [7:0]  s_axis_tx_tkeep,
    input         s_axis_tx_tlast,
    input         s_axis_tx_tvalid,
    input  [3:0]  s_axis_tx_tuser,
    input         tx_cfg_gnt,

    output reg [63:0] m_axis_rx_tdata,
    output reg [7:0]  m_axis_rx_tkeep,
    output reg        m_axis_rx_tlast,
    output reg        m_axis_rx_tvalid,
    input             m_axis_rx_tready,
    output reg [21:0] m_axis_rx_tuser,
    input         rx_np_ok,
    input         rx_np_req,

    output [11:0] fc_cpld,
    output [7:0]  fc_cplh,
    output [11:0] fc_npd,
    output [7:0]  fc_nph,
    output [11:0] fc_pd,
    output [7:0]  fc_ph,
    input  [2:0]  fc_sel,

    output [31:0] cfg_mgmt_do,
    output        cfg_mgmt_rd_wr_done,
    output [15:0] cfg_status,
    output [15:0] cfg_command,
    output [15:0] cfg_dstatus,
    output [15:0] cfg_dcommand,
    output [15:0] cfg_lstatus,
    output [15:0] cfg_lcommand,
    output [15:0] cfg_dcommand2,
    output [2:0]  cfg_pcie_link_state,
    output        cfg_pmcsr_pme_en,
    output [1:0]  cfg_pmcsr_powerstate,
    output        cfg_pmcsr_pme_status,
    output        cfg_received_func_lvl_rst,
    input  [31:0] cfg_mgmt_di,
    input  [3:0]  cfg_mgmt_byte_en,
    input  [9:0]  cfg_mgmt_dwaddr,
    input         cfg_mgmt_wr_en,
    input         cfg_mgmt_rd_en,
    input         cfg_mgmt_wr_readonly,

    input         cfg_err_ecrc,
    input         cfg_err_ur,
    input         cfg_err_cpl_timeout,
    input         cfg_err_cpl_unexpect,
    input         cfg_err_cpl_abort,
    input         cfg_err_posted,
    input         cfg_err_cor,
    input         cfg_err_atomic_egress_blocked,
    input         cfg_err_internal_cor,
    input         cfg_err_malformed,
    input         cfg_err_mc_blocked,
    input         cfg_err_poisoned,
    input         cfg_err_norecovery,
    input  [47:0] cfg_err_tlp_cpl_header,
    output        cfg_err_cpl_rdy,
    input         cfg_err_locked,
    input         cfg_err_acs,
    input         cfg_err_internal_uncor,

    input         cfg_trn_pending,
    input         cfg_pm_halt_aspm_l0s,
    input         cfg_pm_halt_aspm_l1,
    input         cfg_pm_force_state_en,
    input  [1:0]  cfg_pm_force_state,
    input  [63:0] cfg_dsn,

    input         cfg_interrupt,
    output        cfg_interrupt_rdy,
    input         cfg_interrupt_assert,
    input  [7:0]  cfg_interrupt_di,
    output [7:0]  cfg_interrupt_do,
    output [2:0]  cfg_interrupt_mmenable,
    output        cfg_interrupt_msienable,
    output        cfg_interrupt_msixenable,
    output        cfg_interrupt_msixfm,
    input         cfg_interrupt_stat,
    input  [4:0]  cfg_pciecap_interrupt_msgnum,

    output        cfg_to_turnoff,
    input         cfg_turnoff_ok,
    output [7:0]  cfg_bus_number,
    output [4:0]  cfg_device_number,
    output [2:0]  cfg_function_number,
    input         cfg_pm_wake,
    input         cfg_pm_send_pme_to,
    input  [7:0]  cfg_ds_bus_number,
    input  [4:0]  cfg_ds_device_number,
    input  [2:0]  cfg_ds_function_number,
    input         cfg_mgmt_wr_rw1c_as_rw,

    output        cfg_msg_received,
    output [15:0] cfg_msg_data,

    output        cfg_bridge_serr_en,
    output        cfg_slot_control_electromech_il_ctl_pulse,
    output        cfg_root_control_syserr_corr_err_en,
    output        cfg_root_control_syserr_non_fatal_err_en,
    output        cfg_root_control_syserr_fatal_err_en,
    output        cfg_root_control_pme_int_en,
    output        cfg_aer_rooterr_corr_err_reporting_en,
    output        cfg_aer_rooterr_non_fatal_err_reporting_en,
    output        cfg_aer_rooterr_fatal_err_reporting_en,
    output        cfg_aer_rooterr_corr_err_received,
    output        cfg_aer_rooterr_non_fatal_err_received,
    output        cfg_aer_rooterr_fatal_err_received,

    output        cfg_msg_received_err_cor,
    output        cfg_msg_received_err_non_fatal,
    output        cfg_msg_received_err_fatal,
    output        cfg_msg_received_pm_as_nak,
    output        cfg_msg_received_pm_pme,
    output        cfg_msg_received_pme_to_ack,
    output        cfg_msg_received_assert_int_a,
    output        cfg_msg_received_assert_int_b,
    output        cfg_msg_received_assert_int_c,
    output        cfg_msg_received_assert_int_d,
    output        cfg_msg_received_deassert_int_a,
    output        cfg_msg_received_deassert_int_b,
    output        cfg_msg_received_deassert_int_c,
    output        cfg_msg_received_deassert_int_d,
    output        cfg_msg_received_setslotpowerlimit,

    input  [1:0]  pl_directed_link_change,
    input  [1:0]  pl_directed_link_width,
    input         pl_directed_link_speed,
    input         pl_directed_link_auton,
    input         pl_upstream_prefer_deemph,
    output        pl_sel_lnk_rate,
    output [1:0]  pl_sel_lnk_width,
    output [5:0]  pl_ltssm_state,
    output [1:0]  pl_lane_reversal_mode,
    output        pl_phy_lnk_up,
    output [2:0]  pl_tx_pm_state,
    output [1:0]  pl_rx_pm_state,
    output        pl_link_upcfg_cap,
    output        pl_link_gen2_cap,
    output        pl_link_partner_gen2_supported,
    output [2:0]  pl_initial_link_width,
    output        pl_directed_change_done,
    output        pl_received_hot_rst,
    input         pl_transmit_hot_rst,
    input         pl_downstream_deemph_source,

    input  [127:0] cfg_err_aer_headerlog,
    input  [4:0]  cfg_aer_interrupt_msgnum,
    output        cfg_err_aer_headerlog_set,
    output        cfg_aer_ecrc_check_en,
    output        cfg_aer_ecrc_gen_en,
    output [6:0]  cfg_vc_tcvc_map,

    input         pcie_drp_clk,
    input         pcie_drp_en,
    input         pcie_drp_we,
    input  [8:0]  pcie_drp_addr,
    input  [15:0] pcie_drp_di,
    output [15:0] pcie_drp_do,
    output        pcie_drp_rdy
);

    // =================================================================
    //  所有 wire 输出赋予明确常量值
    // =================================================================

    assign pci_exp_txp                  = 1'b0;
    assign pci_exp_txn                  = 1'b1;

    assign int_pclk_out_slave           = 1'b0;
    assign int_pipe_rxusrclk_out        = 1'b0;
    assign int_rxoutclk_out             = 1'b0;
    assign int_dclk_out                 = 1'b0;
    assign int_mmcm_lock_out            = 1'b0;
    assign int_userclk1_out             = 1'b0;
    assign int_userclk2_out             = 1'b0;
    assign int_oobclk_out               = 1'b0;
    assign int_qplllock_out             = 2'b0;
    assign int_qplloutclk_out           = 2'b0;
    assign int_qplloutrefclk_out        = 2'b0;

    assign user_app_rdy                 = 1'b1;

    assign tx_buf_av                    = 6'h3F;
    assign tx_cfg_req                   = 1'b0;
    assign tx_err_drop                  = 1'b0;

    assign fc_cpld                      = 12'hFFF;
    assign fc_cplh                      = 8'hFF;
    assign fc_npd                       = 12'hFFF;
    assign fc_nph                       = 8'hFF;
    assign fc_pd                        = 12'hFFF;
    assign fc_ph                        = 8'hFF;

    assign cfg_mgmt_do                  = 32'h0;
    assign cfg_mgmt_rd_wr_done          = 1'b0;
    assign cfg_status                   = 16'h0010;
    assign cfg_command                  = 16'h0006;
    assign cfg_dstatus                  = 16'h0;
    assign cfg_dcommand                 = 16'h0;
    assign cfg_lstatus                  = 16'h0011;
    assign cfg_lcommand                 = 16'h0;
    assign cfg_dcommand2                = 16'h0;
    assign cfg_pcie_link_state          = 3'b0;
    assign cfg_pmcsr_pme_en             = 1'b0;
    assign cfg_pmcsr_powerstate         = 2'b00;
    assign cfg_pmcsr_pme_status         = 1'b0;
    assign cfg_received_func_lvl_rst    = 1'b0;

    assign cfg_err_cpl_rdy              = 1'b1;

    // MSI 中断: 现在启用 MSI
    assign cfg_interrupt_rdy            = 1'b1;
    assign cfg_interrupt_do             = 8'h0;
    assign cfg_interrupt_mmenable       = 3'b0;
    assign cfg_interrupt_msienable      = 1'b1;   // MSI 已启用
    assign cfg_interrupt_msixenable     = 1'b0;
    assign cfg_interrupt_msixfm         = 1'b0;

    // 电源管理
    assign cfg_to_turnoff               = 1'b0;

    assign cfg_bus_number               = 8'h01;
    assign cfg_device_number            = 5'h00;
    assign cfg_function_number          = 3'h0;

    assign cfg_msg_received             = 1'b0;
    assign cfg_msg_data                 = 16'h0;

    assign cfg_bridge_serr_en                           = 1'b0;
    assign cfg_slot_control_electromech_il_ctl_pulse     = 1'b0;
    assign cfg_root_control_syserr_corr_err_en          = 1'b0;
    assign cfg_root_control_syserr_non_fatal_err_en     = 1'b0;
    assign cfg_root_control_syserr_fatal_err_en         = 1'b0;
    assign cfg_root_control_pme_int_en                  = 1'b0;
    assign cfg_aer_rooterr_corr_err_reporting_en        = 1'b0;
    assign cfg_aer_rooterr_non_fatal_err_reporting_en   = 1'b0;
    assign cfg_aer_rooterr_fatal_err_reporting_en       = 1'b0;
    assign cfg_aer_rooterr_corr_err_received            = 1'b0;
    assign cfg_aer_rooterr_non_fatal_err_received       = 1'b0;
    assign cfg_aer_rooterr_fatal_err_received           = 1'b0;

    assign cfg_msg_received_err_cor             = 1'b0;
    assign cfg_msg_received_err_non_fatal       = 1'b0;
    assign cfg_msg_received_err_fatal           = 1'b0;
    assign cfg_msg_received_pm_as_nak           = 1'b0;
    assign cfg_msg_received_pm_pme              = 1'b0;
    assign cfg_msg_received_pme_to_ack          = 1'b0;
    assign cfg_msg_received_assert_int_a        = 1'b0;
    assign cfg_msg_received_assert_int_b        = 1'b0;
    assign cfg_msg_received_assert_int_c        = 1'b0;
    assign cfg_msg_received_assert_int_d        = 1'b0;
    assign cfg_msg_received_deassert_int_a      = 1'b0;
    assign cfg_msg_received_deassert_int_b      = 1'b0;
    assign cfg_msg_received_deassert_int_c      = 1'b0;
    assign cfg_msg_received_deassert_int_d      = 1'b0;
    assign cfg_msg_received_setslotpowerlimit   = 1'b0;

    assign pl_sel_lnk_rate                      = 1'b0;
    assign pl_sel_lnk_width                     = 2'b01;
    assign pl_ltssm_state                       = 6'h16;
    assign pl_lane_reversal_mode                = 2'b0;
    assign pl_phy_lnk_up                        = 1'b1;
    assign pl_tx_pm_state                       = 3'b0;
    assign pl_rx_pm_state                       = 2'b0;
    assign pl_link_upcfg_cap                    = 1'b0;
    assign pl_link_gen2_cap                     = 1'b0;
    assign pl_link_partner_gen2_supported       = 1'b0;
    assign pl_initial_link_width                = 3'b001;
    assign pl_directed_change_done              = 1'b0;
    assign pl_received_hot_rst                  = 1'b0;

    assign cfg_err_aer_headerlog_set            = 1'b0;
    assign cfg_aer_ecrc_check_en                = 1'b0;
    assign cfg_aer_ecrc_gen_en                  = 1'b0;
    assign cfg_vc_tcvc_map                      = 7'h01;

    assign pcie_drp_do                          = 16'h0;
    assign pcie_drp_rdy                         = 1'b0;

    // =================================================================
    //  行为级时钟与复位生成
    // =================================================================

    initial begin
        user_clk_out     = 1'b0;
        user_reset_out   = 1'b1;
        user_lnk_up      = 1'b0;
        s_axis_tx_tready = 1'b0;
        m_axis_rx_tdata  = 64'h0;
        m_axis_rx_tkeep  = 8'h0;
        m_axis_rx_tlast  = 1'b0;
        m_axis_rx_tvalid = 1'b0;
        m_axis_rx_tuser  = 22'h0;
    end

    reg user_clk_running;
    initial user_clk_running = 1'b0;

    always begin
        #(16.0 / 2.0);
        if (user_clk_running)
            user_clk_out = ~user_clk_out;
    end

    // MSI 中断确认监控
    always @(posedge user_clk_out) begin
        if (cfg_interrupt && cfg_interrupt_rdy) begin
            $display("[%0t] pcie_7x_0 stub: MSI interrupt acknowledged (vector=%02Xh)",
                     $time, cfg_interrupt_di);
        end
    end

    initial begin
        wait(sys_rst_n == 1'b1);
        user_clk_running = 1'b1;
        repeat (4) @(posedge user_clk_out);
        user_reset_out   = 1'b0;
        s_axis_tx_tready = 1'b1;
        #400;
        user_lnk_up = 1'b1;
        $display("[%0t] pcie_7x_0 stub: user_lnk_up asserted", $time);
    end

endmodule


// ===========================================================================
//  MMCME2_BASE — 行为级仿真模型
// ===========================================================================
//
//  简化的 MMCM 行为模型: 从 CLKIN1 产生 CLKOUT0, 频率由参数决定。
//  仿真中直接用分频/倍频近似, 不模拟 PLL 锁定瞬态。

module MMCME2_BASE #(
    parameter          BANDWIDTH          = "OPTIMIZED",
    parameter real     CLKFBOUT_MULT_F    = 5.0,
    parameter real     CLKFBOUT_PHASE     = 0.0,
    parameter real     CLKIN1_PERIOD      = 10.0,
    parameter real     CLKOUT0_DIVIDE_F   = 1.0,
    parameter real     CLKOUT0_DUTY_CYCLE = 0.5,
    parameter real     CLKOUT0_PHASE      = 0.0,
    parameter integer  CLKOUT1_DIVIDE     = 1,
    parameter real     CLKOUT1_DUTY_CYCLE = 0.5,
    parameter real     CLKOUT1_PHASE      = 0.0,
    parameter integer  CLKOUT2_DIVIDE     = 1,
    parameter real     CLKOUT2_DUTY_CYCLE = 0.5,
    parameter real     CLKOUT2_PHASE      = 0.0,
    parameter integer  CLKOUT3_DIVIDE     = 1,
    parameter real     CLKOUT3_DUTY_CYCLE = 0.5,
    parameter real     CLKOUT3_PHASE      = 0.0,
    parameter integer  CLKOUT4_DIVIDE     = 1,
    parameter real     CLKOUT4_DUTY_CYCLE = 0.5,
    parameter real     CLKOUT4_PHASE      = 0.0,
    parameter integer  CLKOUT5_DIVIDE     = 1,
    parameter real     CLKOUT5_DUTY_CYCLE = 0.5,
    parameter real     CLKOUT5_PHASE      = 0.0,
    parameter integer  CLKOUT6_DIVIDE     = 1,
    parameter real     CLKOUT6_DUTY_CYCLE = 0.5,
    parameter real     CLKOUT6_PHASE      = 0.0,
    parameter integer  DIVCLK_DIVIDE      = 1,
    parameter real     REF_JITTER1        = 0.010,
    parameter          STARTUP_WAIT       = "FALSE"
)(
    output reg  CLKOUT0,
    output wire CLKOUT0B,
    output reg  CLKOUT1,
    output wire CLKOUT1B,
    output reg  CLKOUT2,
    output wire CLKOUT2B,
    output reg  CLKOUT3,
    output wire CLKOUT3B,
    output reg  CLKOUT4,
    output reg  CLKOUT5,
    output reg  CLKOUT6,
    output wire CLKFBOUT,
    output wire CLKFBOUTB,
    output reg  LOCKED,
    input  wire CLKIN1,
    input  wire PWRDWN,
    input  wire RST,
    input  wire CLKFBIN
);

    // 计算 CLKOUT0 半周期 (ns)
    // VCO freq = (1/CLKIN1_PERIOD) * CLKFBOUT_MULT_F / DIVCLK_DIVIDE
    // OUT0 freq = VCO / CLKOUT0_DIVIDE_F
    // OUT0 period = CLKIN1_PERIOD * DIVCLK_DIVIDE * CLKOUT0_DIVIDE_F / CLKFBOUT_MULT_F

    real out0_period;
    real out0_half;

    initial begin
        out0_period = CLKIN1_PERIOD * DIVCLK_DIVIDE * CLKOUT0_DIVIDE_F / CLKFBOUT_MULT_F;
        out0_half   = out0_period / 2.0;
        CLKOUT0 = 1'b0;
        CLKOUT1 = 1'b0;
        CLKOUT2 = 1'b0;
        CLKOUT3 = 1'b0;
        CLKOUT4 = 1'b0;
        CLKOUT5 = 1'b0;
        CLKOUT6 = 1'b0;
        LOCKED  = 1'b0;
    end

    // 反馈直通
    assign CLKFBOUT  = CLKIN1;
    assign CLKFBOUTB = ~CLKIN1;
    assign CLKOUT0B  = ~CLKOUT0;
    assign CLKOUT1B  = ~CLKOUT1;
    assign CLKOUT2B  = ~CLKOUT2;
    assign CLKOUT3B  = ~CLKOUT3;

    // CLKOUT0 生成
    always begin
        #(out0_half);
        if (!RST && !PWRDWN)
            CLKOUT0 = ~CLKOUT0;
        else
            CLKOUT0 = 1'b0;
    end

    // LOCKED 生成: 复位释放后 ~100 ns 锁定
    always @(posedge CLKIN1 or posedge RST) begin
        if (RST)
            LOCKED <= 1'b0;
        else if (!LOCKED && !PWRDWN)
            #100 LOCKED <= 1'b1;
    end

endmodule
