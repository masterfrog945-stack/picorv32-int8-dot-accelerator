# Run this script from the Tcl Console of an already-open Vivado project.
# It intentionally does not call open_project/close_project.

if {[current_project -quiet] eq ""} {
    error "No Vivado project is open. Open the target .xpr first."
}

set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ..]]
set required_sources [list \
    $root/rtl/sync_fifo.sv \
    $root/rtl/uart_rx_core.sv \
    $root/rtl/uart_tx_core.sv \
    $root/rtl/uart_mmio.sv]

foreach source_file $required_sources {
    if {![file exists $source_file]} {
        error "Required RTL source does not exist: $source_file"
    }

    set project_file [get_files -quiet -of_objects [get_filesets sources_1] $source_file]
    if {[llength $project_file] == 0} {
        add_files -fileset sources_1 -norecurse $source_file
    }

    set project_file [get_files -quiet -of_objects [get_filesets sources_1] $source_file]
    if {[llength $project_file] != 1} {
        error "Failed to add source to sources_1: $source_file"
    }
    set_property FILE_TYPE SystemVerilog $project_file
    set_property USED_IN_SYNTHESIS true $project_file
    set_property USED_IN_IMPLEMENTATION true $project_file
    puts "UART_SOURCE_OK: $source_file"
}

set_property top pynqz2_accel_top [get_filesets sources_1]
update_compile_order -fileset sources_1

if {[llength [get_runs -quiet synth_1]] > 0} {
    reset_run synth_1
}

puts "UART_PROJECT_FIX_PASS: all UART/FIFO sources are in sources_1"
