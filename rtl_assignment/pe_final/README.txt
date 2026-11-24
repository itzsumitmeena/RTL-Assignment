==========================================================================
 Final processing element (PE)  -  precision-scalable fused signed MAC
 INT4 / INT8 / INT16, UMC 65 nm, 300 MHz
==========================================================================

FOLDERS
  rtl/      13 synthesizable structural Verilog files (no + - * operators)
  tb/       6 self-checking testbenches
  scripts/  Genus scripts
  pe_files.f  compile order of the 13 RTL files

RTL HIERARCHY
  processing_element
  +-- pe_mode_ctrl                 mode -> is4/is8/is16, band enables
  +-- pe_seg_reg      x3           A (4|4|8), B (4|4|8), ACC (12|8|16)
  +-- pe_pp_gen                    16 isolated nibble products
  |   +-- mult4x4_dadda  x16
  |       +-- full_adder, cla4_cla2_rca
  +-- pe_sign_rows                 signed correction rows (no adder)
  +-- pe_csa_tree                  20 rows -> 2, carry kill at bit 12 / 20
  |   +-- pe_csa36   x18
  |       +-- full_adder x36
  +-- pe_add36                     single 36-bit carry-propagate adder
      +-- pe_bk_prefix  x3 (12 / 8 / 16 bit Brent-Kung)
          +-- pe_pg_cell

TESTBENCHES (Vivado: add rtl/ as design sources, tb as simulation source,
             set it as top, run all)
  tb_processing_element.v  basic test, 628 dot products, all modes
  tb_pe_int4.v             INT4 near-exhaustive (all products, all 2-term
                           sums, every 12-bit accumulator value)
  tb_pe_int8.v             INT8: all 65,536 products, bit-boundary walk
  tb_pe_int16.v            INT16: sweeps, every 4x4 multiplier exhaustive,
                           1.26 million golden-model cycle checks
                           quick run: -testplusarg SWEEP=0
                                      -testplusarg NPROD=20000
                                      -testplusarg NPAIR=10000
  tb_pe_rigorous.v         mixed modes, mode switching, stress, reset
  tb_pe_power.v            one VCD per mode for power:
                           -testplusarg MODE=0|1|2 -testplusarg VCD=<file>

GENUS (run from the project folder, rtl/ and activity/ next to scripts/)
  scripts/pe_genus.tcl        synthesis, timing, INT4/8/16 power from
                              activity/pe_int4.vcd, pe_int8.vcd, pe_int16.vcd
                              "set CG 1" = clock gating on (final design),
                              "set CG 0" = operand isolation only
  scripts/pe_mode_timing.tcl  per-mode static timing (set_case_analysis)

RESULTS (Genus 15.2, UMC 65 nm tc 1.2 V 25 C, 300 MHz)
                         CG 0 (isolation)   CG 1 (final)
  area                   6101 um^2          5995 um^2
  cells / flip-flops     1443 / 70          1446 / 70 (68 gated, 6 ICG)
  slack @ 300 MHz        +1.022 ns          +1.060 ns
  max frequency          ~433 MHz           ~440 MHz
  P_INT4 dynamic         339.3 uW           217.1 uW
  P_INT8 dynamic         610.2 uW           532.3 uW
  P_INT16 dynamic        1425.5 uW          1429.3 uW
  P_INT4 / P_INT16       0.238              0.152
  P_INT8 / P_INT16       0.428              0.372
  energy/MAC 4 / 8 / 16  1.13/2.04/4.75 pJ  0.73/1.78/4.77 pJ
  critical path: A reg -> 4x4 multiplier -> 6 CSA levels -> 36-bit adder
                 -> ACC reg (2.264 ns, CG 0)
==========================================================================
