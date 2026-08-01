set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set build_dir  [file join $root build vivado_project]

file mkdir $build_dir
create_project -force picorv32_int8_accelerator $build_dir \
    -part xc7z020clg400-1
set_property target_language Verilog [current_project]

set board_part tul.com.tw:pynq-z2:part0:1.0
if {[llength [get_board_parts -quiet $board_part]] > 0} {
    set_property board_part $board_part [current_project]
}

add_files -norecurse [list \
    [file join $root external picorv32 picorv32.v] \
    [file join $root external picorv32 picosoc simpleuart.v] \
    [file join $root rtl int8_dot_accel.sv] \
    [file join $root rtl accel_csr.sv] \
    [file join $root rtl simple_ram.sv] \
    [file join $root rtl soc_test_device.sv] \
    [file join $root rtl uart_mmio.sv] \
    [file join $root rtl picorv32_accel_soc.sv] \
    [file join $root rtl pynqz2_accel_top.sv]]

set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property file_type Verilog [get_files -quiet picorv32.v]
set_property file_type Verilog [get_files -quiet simpleuart.v]

add_files -fileset constrs_1 -norecurse \
    [file join $root constraints pynqz2_accel_board.xdc]

set firmware_hex [file join $root build firmware firmware.hex]
if {[file exists $firmware_hex]} {
    add_files -norecurse $firmware_hex
    set_property file_type {Memory Initialization Files} \
        [get_files $firmware_hex]
} else {
    puts "PROJECT_WARN: firmware.hex is absent; run build_firmware.ps1 before synthesis"
}

set_property top pynqz2_accel_top [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "PROJECT_PASS: [file join $build_dir picorv32_int8_accelerator.xpr]"
close_project

