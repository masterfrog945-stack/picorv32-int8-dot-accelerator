# PYNQ-Z2 125 MHz Reference Build

These reports were generated with Vivado 2024.2 for `xc7z020clg400-1` after
full placement and routing.

| Metric | Result |
|---|---:|
| Clock period | 8.000 ns |
| WNS | +0.706 ns |
| WHS | +0.076 ns |
| Slice LUTs | 1,501 |
| Slice registers | 956 |
| BRAM tiles | 16 |
| DSP48 blocks | 0 |
| Fully routed nets | 2,272 |
| Nets with routing errors | 0 |
| DRC errors | 0 |

The DRC report contains two non-blocking warnings: `PDRC-134` and `ZPS7-1`.
`ZPS7-1` is expected for this PL-only design because it intentionally does not
instantiate the Zynq processing system.

These are complete-SoC figures and must not be presented as accelerator-only
area. The reports are retained for reproducibility; regenerate them after any
RTL, firmware, constraint, or tool-version change.

