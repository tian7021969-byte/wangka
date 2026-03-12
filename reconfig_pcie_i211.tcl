# ===========================================================================
#  reconfig_pcie_i211.tcl
#  重新配置 PCIe IP 核参数 — 从 AE-9 切换到 Intel I211
#
#  使用方法:
#    在 Vivado Tcl Console 中执行:
#      source C:/Users/dukehhu/Desktop/amd/reconfig_pcie_i211.tcl
#
#  或在 Vivado GUI 中: Tools → Run Tcl Script...
# ===========================================================================

# 打开项目 (如果尚未打开)
if {[catch {current_project}]} {
    open_project C:/Users/dukehhu/Desktop/amd/Audio_Controller_Logic/Audio_Controller_Logic.xpr
}

# ===========================================================================
#  1. 更新 PCIe IP 参数 — Intel I211 标识
# ===========================================================================

set pcie_ip [get_ips pcie_7x_0]

set_property -dict [list \
    CONFIG.Vendor_ID                    {8086} \
    CONFIG.Device_ID                    {1539} \
    CONFIG.Revision_ID                  {03} \
    CONFIG.Subsystem_Vendor_ID          {1849} \
    CONFIG.Subsystem_ID                 {1539} \
    CONFIG.Class_Code_Base              {02} \
    CONFIG.Class_Code_Sub               {00} \
    CONFIG.Class_Code_Interface         {00} \
    CONFIG.Bar0_Scale                   {Kilobytes} \
    CONFIG.Bar0_Size                    {128} \
    CONFIG.Bar0_Enabled                 {true} \
    CONFIG.Bar0_Type                    {Memory} \
    CONFIG.Bar1_Enabled                 {false} \
    CONFIG.Bar2_Enabled                 {false} \
    CONFIG.Bar3_Enabled                 {false} \
    CONFIG.Bar4_Enabled                 {false} \
    CONFIG.Bar5_Enabled                 {false} \
    CONFIG.Maximum_Link_Width           {X1} \
    CONFIG.Link_Speed                   {2.5_GT/s} \
    CONFIG.IntX_Generation              {false} \
    CONFIG.MSI_Enabled                  {true} \
    CONFIG.MSI_64b                      {true} \
] $pcie_ip

puts "INFO: PCIe IP 已更新为 Intel I211 配置"
puts "  Vendor ID  = 0x8086"
puts "  Device ID  = 0x1539"
puts "  Rev ID     = 0x03"
puts "  SVID:SSID  = 0x1849:0x1539"
puts "  Class Code = 0x020000 (Ethernet Controller)"
puts "  BAR0       = 128KB Memory"

# ===========================================================================
#  2. 更新项目源文件 — 替换顶层模块
# ===========================================================================

# 移除旧的 HDA 源文件 (从项目中移除, 不删除文件)
set old_files [list \
    "C:/Users/dukehhu/Desktop/amd/bar0_hda_sim.v" \
    "C:/Users/dukehhu/Desktop/amd/hda_codec_engine.v" \
    "C:/Users/dukehhu/Desktop/amd/hda_dma_engine.v" \
    "C:/Users/dukehhu/Desktop/amd/hda_pcie_top.v" \
    "C:/Users/dukehhu/Desktop/amd/pcileech_pcie_cfg_a7.v" \
]

foreach f $old_files {
    if {[llength [get_files -quiet $f]] > 0} {
        remove_files $f
        puts "INFO: 已从项目移除 $f"
    }
}

# 添加新的 I211 源文件
set new_files [list \
    "C:/Users/dukehhu/Desktop/amd/bar0_i211_sim.v" \
    "C:/Users/dukehhu/Desktop/amd/i211_pcie_top.v" \
]

foreach f $new_files {
    if {[llength [get_files -quiet $f]] == 0} {
        add_files -norecurse $f
        puts "INFO: 已添加 $f"
    }
}

# 设置新的顶层模块
set_property top i211_pcie_top [current_fileset]
puts "INFO: 顶层模块已设置为 i211_pcie_top"

# ===========================================================================
#  3. 重新生成 PCIe IP
# ===========================================================================

generate_target all $pcie_ip
puts "INFO: PCIe IP 目标已重新生成"

# ===========================================================================
#  4. 更新约束文件中的 MMCM 相关内容
# ===========================================================================
# 注意: I211 设计不使用 MMCM (无 24MHz Wall Clock 需求)
# 约束文件中的 MMCM 相关 set_clock_groups 和 false_path 需要手动移除
# 或在综合时 Vivado 会自动忽略不存在的时钟对象

puts ""
puts "============================================================"
puts "  PCIe IP 重新配置完成!"
puts "============================================================"
puts ""
puts "  下一步操作:"
puts "    1. 检查约束文件 constraints.xdc 是否需要更新"
puts "       (MMCM 相关约束可以删除)"
puts "    2. 在 Vivado 中运行 Reset Runs"
puts "    3. 运行 Run Synthesis → Run Implementation → Generate Bitstream"
puts ""
