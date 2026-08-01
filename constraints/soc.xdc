create_clock -name clk -period 10.000 [get_ports clk]

# Out-of-context assumptions for the complete PL SoC. Final board constraints
# will be derived from the PS-generated FCLK and top-level reset network.
set_input_delay  0.000 -clock [get_clocks clk] [get_ports resetn]
set_output_delay 0.000 -clock [get_clocks clk] \
    [get_ports {trap accel_irq test_done test_pass test_code[*]}]

