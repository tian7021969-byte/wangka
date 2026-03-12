# ===========================================================================
#  fix_pcie_ip_gen1.tcl
#  将 PCIe IP 核从 Gen2 (5.0 GT/s) 修改为 Gen1 (2.5 GT/s)
#  匹配真实 Creative AE-9 声卡的 PCIe 链路速率
#
#  用法: 在 Vivado Tcl Console 中运行:
#    source C:/Users/dukehhu/Desktop/amd/fix_pcie_ip_gen1.tcl
#
#  注意: 运行后需要重新综合和实现
# ===========================================================================

# 确保项目已打开
if {[current_project -quiet] eq ""} {
    puts "ERROR: No project is open. Please open the project first."
    return
}

# 修改 PCIe IP 核参数
set_property -dict [list \
    CONFIG.Link_Speed {2.5_GT/s} \
    CONFIG.Trgt_Link_Speed {4'h1} \
    CONFIG.Device_ID {0011} \
    CONFIG.Subsystem_ID {0081} \
] [get_ips pcie_7x_0]

puts "INFO: PCIe IP Link Speed changed to Gen1 (2.5 GT/s)"
puts "INFO: Device ID changed to 0011 (Creative AE-9)"
puts "INFO: Subsystem ID changed to 0081 (AE-9 retail)"
puts "INFO: Please regenerate the IP output products and re-run synthesis."

# 重新生成 IP 输出产品
generate_target all [get_ips pcie_7x_0]

puts "INFO: IP output products regenerated."
puts "INFO: Now run: reset_run synth_1 && launch_runs synth_1 -jobs 4"
