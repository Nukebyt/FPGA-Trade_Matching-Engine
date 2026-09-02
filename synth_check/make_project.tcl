# Standalone synthesis-only sanity check for fpga_matching_core - NOT the
# real board project (that's ../DE10_Standard_golden_top.qpf, still
# pending Phase 24's Platform Designer/HPS integration). This just proves
# the RTL elaborates/synthesizes on the real target part and gives an
# early LE/BRAM/DSP estimate, ahead of full pin-out + fit + timing closure.
package require ::quartus::project

set proj_name "fpga_matching_core_synth"

if {[project_exists $proj_name]} {
    project_open $proj_name
} else {
    project_new $proj_name
}

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSXFC6D6F31C6
set_global_assignment -name TOP_LEVEL_ENTITY fpga_matching_core
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/cdc_pulse_sync.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/bounded_order_book.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/fpga_matching_core.sv

export_assignments
project_close
