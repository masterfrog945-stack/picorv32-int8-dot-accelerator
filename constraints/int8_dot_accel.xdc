create_clock -name clk -period 10.000 [get_ports clk]

# Standalone out-of-context timing assumptions. The later SoC wrapper will
# replace these with constraints derived from the actual AXI/CPU clock domain.
set_input_delay  0.000 -clock [get_clocks clk] \
    [get_ports {rst_n start vector_a[*] vector_b[*]}]
set_output_delay 0.000 -clock [get_clocks clk] \
    [get_ports {busy done result[*]}]

