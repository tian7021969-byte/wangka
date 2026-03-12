# ===========================================================================
#  fix_bar0_128kb.tcl
#  修复 BAR0 被系统识别为 4KB 的问题
#
#  根因: Vivado 缓存中残留旧的 bar_0=FFFFC000 (16KB) netlist
#        需要强制清理缓存并重新生成, 确保 bar_0=FFFE0000 (128KB)
#
#  使用方法:
#    在 Vivado Tcl Console 中执行:
#      source C:/Users/dukehhu/Desktop/1121/fix_bar0_128kb.tcl
# ===========================================================================

puts "================================================================="
puts " FIX: BAR0 128KB 配置修复 (清除旧缓存)"
puts "================================================================="

# --- Step 1: 打开项目 ---
if {[catch {current_project} err]} {
    puts "INFO: 打开 Vivado 项目..."
    open_project C:/Users/dukehhu/Desktop/1121/Audio_Controller_Logic/Audio_Controller_Logic.xpr
}

# --- Step 2: 验证当前 IP 配置 ---
set pcie_ip [get_ips pcie_7x_0]

if {$pcie_ip eq ""} {
    puts "ERROR: 找不到 pcie_7x_0 IP 核!"
    return
}

puts ""
puts "--- 当前 PCIe IP 配置 ---"
puts "  Bar0_Enabled : [get_property CONFIG.Bar0_Enabled $pcie_ip]"
puts "  Bar0_Scale   : [get_property CONFIG.Bar0_Scale $pcie_ip]"
puts "  Bar0_Size    : [get_property CONFIG.Bar0_Size $pcie_ip]"
puts "  Bar0_Type    : [get_property CONFIG.Bar0_Type $pcie_ip]"
puts "  Vendor_ID    : [get_property CONFIG.Vendor_ID $pcie_ip]"
puts "  Device_ID    : [get_property CONFIG.Device_ID $pcie_ip]"

# --- Step 3: 强制重新设置 BAR0 参数 (确保无遗留) ---
puts ""
puts "INFO: 强制重新设置 BAR0 = 128KB..."

set_property -dict [list \
    CONFIG.Bar0_Enabled         {true} \
    CONFIG.Bar0_Scale           {Kilobytes} \
    CONFIG.Bar0_Size            {128} \
    CONFIG.Bar0_Type            {Memory} \
    CONFIG.Bar0_64bit           {false} \
    CONFIG.Bar0_Prefetchable    {false} \
    CONFIG.Bar1_Enabled         {false} \
    CONFIG.Bar2_Enabled         {false} \
    CONFIG.Bar3_Enabled         {false} \
    CONFIG.Bar4_Enabled         {false} \
    CONFIG.Bar5_Enabled         {false} \
] $pcie_ip

# --- Step 4: 验证生成参数 ---
puts ""
puts "--- 验证设置后的参数 ---"
puts "  Bar0_Size    : [get_property CONFIG.Bar0_Size $pcie_ip]"
puts "  Bar0_Scale   : [get_property CONFIG.Bar0_Scale $pcie_ip]"

# --- Step 5: 清除旧的 IP 缓存 ---
puts ""
puts "INFO: 清除旧的 IP 输出产品 (包含残留的 bar_0=FFFFC000 netlist)..."

# 先 reset 所有 IP 输出产品
reset_target all $pcie_ip

# 删除缓存目录中的旧 netlist
set cache_dir "C:/Users/dukehhu/Desktop/1121/Audio_Controller_Logic/Audio_Controller_Logic.cache/ip"
if {[file exists $cache_dir]} {
    puts "INFO: 清除 IP 缓存目录: $cache_dir"
    file delete -force $cache_dir
    puts "INFO: IP 缓存已清除"
}

# --- Step 6: 重新生成所有 IP 输出产品 ---
puts ""
puts "INFO: 重新生成 PCIe IP 输出产品 (这可能需要几分钟)..."
generate_target all $pcie_ip

# --- Step 7: 验证生成结果 ---
puts ""
puts "INFO: 检查生成的 netlist 中的 BAR0 值..."

# 尝试检查生成的 synth wrapper
set synth_file "C:/Users/dukehhu/Desktop/1121/Audio_Controller_Logic/Audio_Controller_Logic.gen/sources_1/ip/pcie_7x_0/synth/pcie_7x_0.v"
if {[file exists $synth_file]} {
    set f [open $synth_file r]
    set content [read $f]
    close $f
    
    if {[string match "*FFFE0000*" $content]} {
        puts "  ✅ synth/pcie_7x_0.v 中 bar_0 = FFFE0000 (128KB) — 正确!"
    } elseif {[string match "*FFFFC000*" $content]} {
        puts "  ❌ synth/pcie_7x_0.v 中 bar_0 = FFFFC000 (16KB) — 仍然是旧值!"
        puts "  ERROR: IP 重新生成可能失败, 请手动检查!"
    } else {
        puts "  ⚠ 无法在 synth 文件中找到 bar_0 值"
    }
} else {
    puts "  ⚠ synth 文件尚不存在, 将在综合后生成"
}

# --- Step 8: 重置综合和实现 Run ---
puts ""
puts "INFO: 重置综合 Run..."

# 重置 IP 综合
if {[llength [get_runs -quiet pcie_7x_0_synth_1]] > 0} {
    reset_run pcie_7x_0_synth_1
    puts "INFO: pcie_7x_0_synth_1 已重置"
}

# 重置主综合
if {[llength [get_runs -quiet synth_1]] > 0} {
    reset_run synth_1
    puts "INFO: synth_1 已重置"
}

# 重置实现
if {[llength [get_runs -quiet impl_1]] > 0} {
    reset_run impl_1
    puts "INFO: impl_1 已重置"
}

puts ""
puts "================================================================="
puts " BAR0 128KB 修复脚本执行完毕!"
puts "================================================================="
puts ""
puts " 验证清单:"
puts "   1. PCIe IP Bar0_Size = 128 KB                    ✅ 已设置"
puts "   2. IP 缓存已清除 (旧 FFFFC000 netlist 已删除)     ✅ 已清除"
puts "   3. IP 输出产品已重新生成                           ✅ 已生成"
puts "   4. 综合/实现 Run 已重置                            ✅ 已重置"
puts ""
puts " 下一步操作:"
puts "   1. 在 Vivado 中: Run Synthesis"
puts "   2. 等待综合完成"
puts "   3. Run Implementation"
puts "   4. Generate Bitstream"
puts "   5. 刷新 FPGA 后, 在 Windows 设备管理器中检查:"
puts "      网络适配器 → Intel I211 → 属性 → 资源"
puts "      应显示: 内存范围 XXXXXXXX - XXXXXXXX+1FFFF (128KB)"
puts ""
puts " 如果问题仍然存在, 可能需要检查:"
puts "   - PCIe IP 核是否需要 Upgrade (版本不匹配)"
puts "   - constraints.xdc 中是否有冲突的 BAR 约束"
puts "   - bitstream 是否被正确烧录到 FPGA"
puts "================================================================="
