# ============================================================================
# pe_genus.tcl
#   Genus: synthesis of processing_element at 300 MHz (UMC 65 nm) and
#   INT4 / INT8 / INT16 power from the three VCD files of tb_pe_power.
#   Run from the project folder:   genus -f scripts/pe_genus.tcl -log genus_pe
#   Set CG to 1 to let Genus insert clock gating on the band enables.
# ============================================================================
set CG 1

# ---------- 1. library ----------
set LIB_PATH  "/afs/iitd.ac.in/service/tools/public/asiclib/umcoa/L65/libraries/UMC65LLSC/synopsys/ccs"
set LIB_FILES "uk65lscllmvbbr_120c25_tc_ccs.lib"
set_db init_lib_search_path [list $LIB_PATH]
set_db library              [list $LIB_FILES]
set_db information_level    7

# keep the module hierarchy, so area / power can be split per block
set_db auto_ungroup none

# clock gating: library ICG cells are marked unusable by default.
# Genus 15.2 calls the lib-cell attribute 'avoid' (newer releases: 'dont_use')
if {$CG} {
    foreach c [get_db lib_cells *LAGCE*] {
        if {[catch {set_db $c .avoid false}]} { catch {set_db $c .dont_use false} }
    }
    set_db lp_insert_clock_gating true
}

# ---------- 2. RTL ----------
read_hdl {
    rtl/full_adder.v  rtl/cla4_cla2_rca.v  rtl/mult4x4_dadda.v
    rtl/pe_mode_ctrl.v  rtl/pe_seg_reg.v  rtl/pe_pp_gen.v  rtl/pe_sign_rows.v
    rtl/pe_csa36.v  rtl/pe_csa_tree.v  rtl/pe_pg_cell.v  rtl/pe_bk_prefix.v
    rtl/pe_add36.v  rtl/processing_element.v
}
elaborate processing_element
check_design -unresolved

# ---------- 3. constraints: 300 MHz ----------
create_clock -name clk -period 3.333 [get_ports clk]
set_input_delay  0.0 -clock clk [all_inputs]
set_output_delay 0.0 -clock clk [all_outputs]

# mode is static for a whole matrix multiplication, reset is asynchronous
set_false_path -from [get_ports mode]
set_false_path -from [get_ports rst]

# ---------- 4. synthesis ----------
syn_generic
syn_map
syn_opt

set RPT reports/pe_cg$CG
file mkdir $RPT
report_area   > $RPT/area.rpt
report_gates  > $RPT/gates.rpt
report_timing > $RPT/timing.rpt
report_timing -max_paths 10 > $RPT/timing_top10.rpt
if {$CG} { report_clock_gating > $RPT/clock_gating.rpt }
write_hdl > $RPT/pe_netlist.v

# ---------- 5. power per mode ----------
set scope tb_pe_power/dut
foreach {tag vcd} { int4 activity/pe_int4.vcd  int8 activity/pe_int8.vcd  int16 activity/pe_int16.vcd } {
    puts "\n========== $vcd ($tag) =========="
    read_vcd -static -vcd_scope $scope $vcd
    report_power > $RPT/power_$tag.rpt
}

exit
