# Third-Party Notices

This repository contains or depends on components maintained by other authors.
Their licenses apply to those components independently of the repository's
Apache-2.0 license.

## PicoRV32

- Project: PicoRV32 - A Size-Optimized RISC-V CPU
- Upstream: <https://github.com/YosysHQ/picorv32>
- Pinned commit: `87c89acc18994c8cf9a2311e871818e87d304568`
- License: ISC
- Copyright: Claire Xenia Wolf and PicoRV32 contributors

The dependency is recorded as the `external/picorv32` Git submodule. Its
complete ISC license remains available in `external/picorv32/COPYING` after
submodule initialization.

The project uses:

- `external/picorv32/picorv32.v`
- `external/picorv32/picosoc/simpleuart.v`

## PYNQ-Z2 Pin Constraints

`constraints/pynqz2_accel_board.xdc` is adapted from the public PYNQ-Z2 master
constraint definitions distributed for the TUL PYNQ-Z2 board. Only the ports
used by this design are active; the remaining reference lines are retained as
comments so pin provenance remains auditable.

- Board documentation: <https://www.tulembedded.com/FPGA/ProductsPYNQ-Z2.html>
- Reference repository: <https://github.com/Xilinx/PYNQ>

