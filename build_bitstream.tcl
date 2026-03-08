# ===========================================================================
#
#  build_bitstream.tcl
#  一键重新生成 bitstream (.bit + .bin)
#
#  使用方法 (在 Vivado TCL Console 或命令行):
#    vivado -mode batch -source build_bitstream.tcl
#
#  或在 Vivado GUI 的 TCL Console 中:
#    source build_bitstream.tcl
#
# ===========================================================================

set project_dir [file normalize [file dirname [info script]]]
set xpr_file    [file join $project_dir "Audio_Controller_Logic" "Audio_Controller_Logic.xpr"]

puts "============================================================"
puts "  Build Bitstream — Sound Blaster AE-9 FPGA Project"
puts "============================================================"
puts "  Project: $xpr_file"
puts "  Time:    [clock format [clock seconds]]"
puts "============================================================"

# -- 打开工程 (如果尚未打开) ------------------------------------------------
if {[catch {current_project}]} {
    if {![file exists $xpr_file]} {
        puts "ERROR: Project file not found: $xpr_file"
        return -code error "Project file not found"
    }
    open_project $xpr_file
    puts "  Project opened."
} else {
    puts "  Project already open: [current_project]"
}

# -- 重置并运行综合 ---------------------------------------------------------
puts "\n>>> Step 1/4: Running Synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "  Synthesis status: $synth_status"
if {$synth_status ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    return -code error "Synthesis failed"
}

# -- 重置并运行实现 ---------------------------------------------------------
puts "\n>>> Step 2/4: Running Implementation..."
reset_run impl_1
launch_runs impl_1 -jobs 4
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "  Implementation status: $impl_status"
if {$impl_status ne "route_design Complete!"} {
    puts "ERROR: Implementation failed!"
    return -code error "Implementation failed"
}

# -- 生成 Bitstream (.bit + .bin) -------------------------------------------
puts "\n>>> Step 3/4: Generating Bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# -- 验证输出文件 -----------------------------------------------------------
puts "\n>>> Step 4/4: Verifying output files..."

set bit_file [file join $project_dir "Audio_Controller_Logic" \
              "Audio_Controller_Logic.runs" "impl_1" "hda_pcie_top.bit"]
set bin_file [file join $project_dir "Audio_Controller_Logic" \
              "Audio_Controller_Logic.runs" "impl_1" "hda_pcie_top.bin"]

set ok 1
foreach f [list $bit_file $bin_file] {
    if {[file exists $f]} {
        set sz [file size $f]
        puts "  [OK] [file tail $f] — [format "%,.0f" $sz] bytes"
    } else {
        puts "  [FAIL] [file tail $f] — NOT FOUND"
        set ok 0
    }
}

if {$ok} {
    puts "\n============================================================"
    puts "  BUILD SUCCESSFUL"
    puts "  .bit: $bit_file"
    puts "  .bin: $bin_file"
    puts "============================================================"
    puts "\n  Next: Run 'python verify_bitstream.py' to check AE-9 fingerprints"
    puts "        or 'python ae9_compare.py' to compare with real AE-9 dump"
} else {
    puts "\nERROR: Some output files are missing!"
}

# 仅 batch 模式下关闭项目 (通过 -mode batch 启动时 $::argc >= 0 且无 GUI)
# GUI 中 source 此脚本时不关闭项目
if {![info exists ::rdi::mode] || $::rdi::mode eq "batch"} {
    catch {close_project}
}
puts "\nDone. [clock format [clock seconds]]"
