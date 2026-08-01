set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set build_dir  [file join $root build synth_accel]

file mkdir $build_dir
create_project -in_memory -part xc7z020clg400-1

read_verilog -sv [file join $root rtl int8_dot_accel.sv]
read_xdc           [file join $root constraints int8_dot_accel.xdc]

synth_design -top int8_dot_accel -part xc7z020clg400-1 -mode out_of_context

report_utilization    -file [file join $build_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $build_dir timing_summary.rpt]
report_drc            -file [file join $build_dir drc.rpt]
write_checkpoint -force [file join $build_dir int8_dot_accel_synth.dcp]

set worst_path [get_timing_paths -delay_type max -max_paths 1]
if {[llength $worst_path] == 0} {
    puts "SYNTH_WARN: no timing path was returned"
} else {
    set slack [get_property SLACK $worst_path]
    puts "SYNTH_INFO: worst setup slack = $slack ns"
    if {$slack < 0.0} {
        error "Timing failed: negative setup slack $slack ns"
    }
}

puts "SYNTH_PASS: int8_dot_accel synthesized for PYNQ-Z2 at 100 MHz"

