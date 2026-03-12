# ===========================================================================
#
#  fix_pcie_msix.tcl
#  修复 Intel I211 驱动 Problem 0xA (0xC0000001) / Problem 0x38
#  根本原因: PCIe IP 核 MSI-X 未启用, e1r68x64.sys 强制需要 MSI-X
#
#  用法: 在 Vivado Tcl Console 中执行:
#    source C:/Users/dukehhu/Desktop/1121/fix_pcie_msix.tcl
#
# ===========================================================================

puts "================================================================="
puts " FIX: 启用 PCIe IP MSI-X (Intel I211 驱动必需)"
puts "================================================================="

# --- Step 1: 打开项目 (如果未打开) ---
if {[catch {current_project} err]} {
    puts "INFO: 打开 Vivado 项目..."
    open_project C:/Users/dukehhu/Desktop/1121/Audio_Controller_Logic/Audio_Controller_Logic.xpr
}

# --- Step 2: 重新配置 PCIe IP 核 ---
# Intel I211 (8086:1539) 需要 MSI-X 5 vectors
# MSI-X Table 在 BAR0 offset 0xE000, PBA 在 BAR0 offset 0xE800

puts "INFO: 修改 pcie_7x_0 IP 配置 - 启用 MSI-X..."

# 获取 IP 对象
set pcie_ip [get_ips pcie_7x_0]

if {$pcie_ip eq ""} {
    puts "ERROR: 找不到 pcie_7x_0 IP 核!"
    return
}

# 使用 set_property -dict 一次性设置所有 MSI-X 参数
# Intel I211 需要 5 个 MSI-X 向量
# MSI-X Table 在 BAR0 offset 0xE000, PBA 在 BAR0 offset 0xE800
set_property -dict [list \
    CONFIG.MSIx_Enabled       {true} \
    CONFIG.MSIx_Table_Size    {5} \
    CONFIG.MSIx_Table_BIR     {BAR_0} \
    CONFIG.MSIx_Table_Offset  {0000E000} \
    CONFIG.MSIx_PBA_BIR       {BAR_0} \
    CONFIG.MSIx_PBA_Offset    {0000E800} \
] $pcie_ip

# 保留 MSI 也启用 (某些驱动可能回退到 MSI)
# MSI 已经是 true, 不需要改

puts "INFO: MSI-X 配置已更新:"
puts "  MSIx_Enabled     = [get_property CONFIG.MSIx_Enabled $pcie_ip]"
puts "  MSIx_Table_Size  = [get_property CONFIG.MSIx_Table_Size $pcie_ip]"
puts "  MSIx_Table_BIR   = [get_property CONFIG.MSIx_Table_BIR $pcie_ip]"
puts "  MSIx_Table_Offset= [get_property CONFIG.MSIx_Table_Offset $pcie_ip]"
puts "  MSIx_PBA_BIR     = [get_property CONFIG.MSIx_PBA_BIR $pcie_ip]"
puts "  MSIx_PBA_Offset  = [get_property CONFIG.MSIx_PBA_Offset $pcie_ip]"
puts "  MSI_Enabled      = [get_property CONFIG.MSI_Enabled $pcie_ip]"

# --- Step 3: 重新生成 IP 核 ---
puts "INFO: 重新生成 PCIe IP 核 (这可能需要几分钟)..."
generate_target all [get_files */pcie_7x_0/pcie_7x_0.xci]

# --- Step 4: 重新运行 IP 核综合 ---
puts "INFO: 重置 IP 核综合 run..."
reset_run pcie_7x_0_synth_1

puts "INFO: 启动 IP 核综合..."
launch_runs pcie_7x_0_synth_1
wait_on_run pcie_7x_0_synth_1

puts "================================================================="
puts " MSI-X 修复完成!"
puts " 现在请执行: Reset Runs -> Run Synthesis -> Implementation -> Bitstream"
puts "================================================================="
