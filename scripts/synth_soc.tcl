set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set build_dir  [file join $root build synth_soc]

file mkdir $build_dir
create_project -in_memory -part xc7z020clg400-1

read_verilog [file join $root external picorv32 picorv32.v]
read_verilog [file join $root external picorv32 picosoc simpleuart.v]
read_verilog -sv [list \
    [file join $root rtl int8_dot_accel.sv] \
    [file join $root rtl accel_csr.sv] \
    [file join $root rtl simple_ram.sv] \
    [file join $root rtl soc_test_device.sv] \
    [file join $root rtl uart_mmio.sv] \
    [file join $root rtl picorv32_accel_soc.sv]]
read_xdc [file join $root constraints soc.xdc]

synth_design -top picorv32_accel_soc -part xc7z020clg400-1 -mode out_of_context

report_utilization    -file [file join $build_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $build_dir timing_summary.rpt]
report_drc            -file [file join $build_dir drc.rpt]
write_checkpoint -force [file join $build_dir picorv32_accel_soc_synth.dcp]

set worst_path [get_timing_paths -delay_type max -max_paths 1]
if {[llength $worst_path] == 0} {
    puts "SOC_SYNTH_WARN: no timing path was returned"
} else {
    set slack [get_property SLACK $worst_path]
    puts "SOC_SYNTH_INFO: worst setup slack = $slack ns"
    if {$slack < 0.0} {
        error "SoC timing failed: negative setup slack $slack ns"
    }
}

puts "SOC_SYNTH_PASS: PicoRV32 accelerator SoC synthesized at 100 MHz"
