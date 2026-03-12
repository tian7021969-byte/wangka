# ===========================================================================
#  fix_vivado_sources.tcl
#  在 Vivado Tcl Console 中执行此脚本来修复三个综合错误:
#    1. 移除 bar0_i211_sim.v, 添加 i211_core_logic.v
#    2. 将 sim_stubs.v 从综合中移除 (仅保留仿真)
#    3. 将 tb_hda_pcie_top.v 从综合中移除 (仅保留仿真)
#
#  使用方法: 在 Vivado Tcl Console 中执行:
#    source C:/Users/dukehhu/Desktop/1121/fix_vivado_sources.tcl
# ===========================================================================

puts "=== 开始修复 Vivado 项目源文件 ==="

# --- Step 1: 从 sources_1 中移除旧的 bar0_i211_sim.v ---
set old_file "C:/Users/dukehhu/Desktop/1121/bar0_i211_sim.v"
set old_obj [get_files -quiet $old_file]
if {$old_obj ne ""} {
    remove_files $old_obj
    puts "INFO: 已移除 bar0_i211_sim.v"
} else {
    puts "INFO: bar0_i211_sim.v 不在项目中 (已移除或不存在)"
}

# --- Step 2: 添加 i211_core_logic.v 到 sources_1 ---
set new_file "C:/Users/dukehhu/Desktop/1121/i211_core_logic.v"
set existing [get_files -quiet $new_file]
if {$existing eq ""} {
    add_files -norecurse -fileset [get_filesets sources_1] $new_file
    puts "INFO: 已添加 i211_core_logic.v 到 sources_1"
} else {
    puts "INFO: i211_core_logic.v 已在项目中"
}

# --- Step 3: 将 sim_stubs.v 设置为仅 simulation ---
set sim_stubs [get_files -quiet "C:/Users/dukehhu/Desktop/1121/sim_stubs.v"]
if {$sim_stubs ne ""} {
    set_property USED_IN_SYNTHESIS false [get_files $sim_stubs]
    set_property USED_IN_IMPLEMENTATION false [get_files $sim_stubs]
    puts "INFO: sim_stubs.v 已设置为仅 simulation"
} else {
    puts "WARN: sim_stubs.v 不在项目中"
}

# --- Step 4: 将 tb_hda_pcie_top.v 设置为仅 simulation ---
set tb_file [get_files -quiet "C:/Users/dukehhu/Desktop/1121/tb_hda_pcie_top.v"]
if {$tb_file ne ""} {
    set_property USED_IN_SYNTHESIS false [get_files $tb_file]
    set_property USED_IN_IMPLEMENTATION false [get_files $tb_file]
    puts "INFO: tb_hda_pcie_top.v 已设置为仅 simulation"
} else {
    puts "WARN: tb_hda_pcie_top.v 不在项目中"
}

# --- Step 5: 确认顶层模块设置正确 ---
set_property top i211_pcie_top [current_fileset]
puts "INFO: 顶层模块设置为 i211_pcie_top"

# --- Step 6: 列出当前综合源文件 ---
puts "\n=== 当前综合源文件列表 ==="
foreach f [get_files -filter {USED_IN_SYNTHESIS == 1}] {
    puts "  $f"
}

puts "\n=== 修复完成! 请执行 Reset Runs -> Run Synthesis ==="
