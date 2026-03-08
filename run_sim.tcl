# run_sim.tcl — Vivado 行为仿真
# 用法: 在 Vivado Tcl Console 中 source 此脚本

# 关闭可能残留的仿真
catch {close_sim -quiet}

# 设置仿真顶层
set_property top tb_hda_pcie_top [get_filesets sim_1]
set_property verilog_define "SIMULATION" [get_filesets sim_1]
update_compile_order -fileset sim_1

# 关键: 确保不是 scripts_only 模式
set_property -name {xsim.simulate.runtime} -value {-1ns} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true} -objects [get_filesets sim_1]

# 用 Tcl 替换 xsim 的 tclbatch 内容为 "run all; quit"
set sim_dir "C:/Users/dukehhu/Desktop/amd/Audio_Controller_Logic/Audio_Controller_Logic.sim/sim_1/behav/xsim"
file mkdir $sim_dir
set fp [open "${sim_dir}/tb_hda_pcie_top.tcl" w]
puts $fp "run all"
puts $fp "quit"
close $fp

# 启动仿真
launch_simulation -mode behavioral
