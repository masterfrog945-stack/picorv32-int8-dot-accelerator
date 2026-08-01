set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set build_dir  [file join $root build pynqz2_board]

file mkdir $build_dir
cd $root

create_project -in_memory -part xc7z020clg400-1
set_property target_language Verilog [current_project]

set board_part tul.com.tw:pynq-z2:part0:1.0
if {[llength [get_board_parts -quiet $board_part]] > 0} {
    set_property board_part $board_part [current_project]
}

read_verilog -sv [file join $root rtl int8_dot_accel.sv]
read_verilog -sv [file join $root rtl accel_csr.sv]
read_verilog -sv [file join $root rtl simple_ram.sv]
read_verilog -sv [file join $root rtl soc_test_device.sv]
read_verilog [file join $root external picorv32 picorv32.v]
read_verilog [file join $root external picorv32 picosoc simpleuart.v]
read_verilog -sv [file join $root rtl uart_mmio.sv]
read_verilog -sv [file join $root rtl picorv32_accel_soc.sv]
read_verilog -sv [file join $root rtl pynqz2_accel_top.sv]

set firmware_hex [file join $root build firmware firmware.hex]
if {![file exists $firmware_hex]} {
    error "Missing firmware image: $firmware_hex. Run scripts/build_firmware.ps1 first."
}
add_files -norecurse $firmware_hex
set_property file_type {Memory Initialization Files} [get_files $firmware_hex]

read_xdc [file join $root constraints pynqz2_accel_board.xdc]

synth_design -top pynqz2_accel_top -part xc7z020clg400-1
write_checkpoint -force [file join $build_dir post_synth.dcp]
report_utilization -file [file join $build_dir utilization_synth.rpt]

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $build_dir post_route.dcp]
report_route_status -file [file join $build_dir route_status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $build_dir timing_summary.rpt]
report_utilization -file [file join $build_dir utilization_route.rpt]
report_drc -file [file join $build_dir drc.rpt]

set timing_paths [get_timing_paths -quiet -max_paths 1 -slack_lesser_than 0]
if {[llength $timing_paths] > 0} {
    error "Board implementation has timing violations. See $build_dir/timing_summary.rpt"
}

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force [file join $build_dir pynqz2_accel.bit]

puts "BOARD_PASS: bitstream and reports written to $build_dir"
exit
