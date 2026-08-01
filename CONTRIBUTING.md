# Contributing

Issues and pull requests are welcome. Keep changes focused and include evidence
for functional or timing claims.

Before opening a pull request:

1. Initialize the PicoRV32 submodule.
2. Run the affected simulation scripts under `scripts/`.
3. For RTL changes, run `scripts/run_all.ps1` when Vivado is available.
4. Update the register map, architecture documentation, and reference results
   when an interface or measured metric changes.
5. Do not commit generated Vivado projects, caches, bitstreams, or toolchains.

New accelerator features should include directed edge cases, randomized tests,
and a software or Python golden reference.

