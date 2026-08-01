set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ..]]
set bitstream [file join $root build pynqz2_board pynqz2_accel.bit]
if {![file exists $bitstream]} {
    error "Bitstream does not exist: $bitstream"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set zynq_devices {}
foreach device [get_hw_devices -quiet] {
    set part [string tolower [get_property PART $device]]
    if {[string match *xc7z020* $part]} {
        lappend zynq_devices $device
    }
}

if {[llength $zynq_devices] != 1} {
    error "Expected exactly one XC7Z020 JTAG device, found [llength $zynq_devices]: [get_hw_devices -quiet]"
}

set device [lindex $zynq_devices 0]
current_hw_device $device
refresh_hw_device -update_hw_probes false $device
set_property PROGRAM.FILE $bitstream $device
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device

puts "PROGRAM_PASS: programmed $device with $bitstream"
close_hw_target
disconnect_hw_server
close_hw_manager
