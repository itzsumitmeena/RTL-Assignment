# ============================================================================
# pe_mode_timing.tcl
#   Per-mode static timing of processing_element (INT4 / INT8 / INT16).
#   Synthesises once (worst case, all modes), then fixes the mode pins with
#   set_case_analysis: the constant propagates through the isolation gates,
#   so paths through disabled multipliers / bands drop out of the analysis.
#   Run from the project folder:  genus -f scripts/pe_mode_timing.tcl -log genus_mode_timing
# ============================================================================

# ---------- 1. library ----------
set LIB_PATH  "/afs/iitd.ac.in/service/tools/public/asiclib/umcoa/L65/libraries/UMC65LLSC/synopsys/ccs"
set LIB_FILES "uk65lscllmvbbr_120c25_tc_ccs.lib"
set_db init_lib_search_path [list $LIB_PATH]
set_db library              [list $LIB_FILES]
set_db auto_ungroup none

# ---------- 2. RTL ----------
read_hdl {
    rtl/full_adder.v  rtl/cla4_cla2_rca.v  rtl/mult4x4_dadda.v
    rtl/pe_mode_ctrl.v  rtl/pe_seg_reg.v  rtl/pe_pp_gen.v  rtl/pe_sign_rows.v
    rtl/pe_csa36.v  rtl/pe_csa_tree.v  rtl/pe_pg_cell.v  rtl/pe_bk_prefix.v
    rtl/pe_add36.v  rtl/processing_element.v
}
elaborate processing_element

# ---------- 3. constraints: same as the power run ----------
create_clock -name clk -period 3.333 [get_ports clk]
set_input_delay  0.0 -clock clk [all_inputs]
set_output_delay 0.0 -clock clk [all_outputs]
set_false_path -from [get_ports mode]
set_false_path -from [get_ports rst]

# ---------- 4. one synthesis for all modes ----------
syn_generic
syn_map
syn_opt

set RPT reports/mode_timing
file mkdir $RPT

# ---------- 5. timing per mode (mode[1] mode[0]) ----------
foreach {tag m1 m0} { int4 0 0  int8 0 1  int16 1 0 } {
    set_case_analysis $m1 [get_ports {mode[1]}]
    set_case_analysis $m0 [get_ports {mode[0]}]
    report_timing > $RPT/timing_$tag.rpt
    puts "==== $tag : timing written to $RPT/timing_$tag.rpt"
}

exit
