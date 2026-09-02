# Swaps cfar_bridge_0 (Weibull_CFAR-specific) out of the copied
# soc_system.qsys for fpga_matching_core, on the same mm_bridge_0
# (lightweight HPS-to-FPGA bridge) connection point cfar_bridge_0 used.
#
# core_clk/core_reset are wired to the SAME clk_0/clk_0.clk_reset as
# avs_clk for THIS integration pass, deliberately, not as an oversight:
# proving the Avalon-MM register file + CDC synchronizers work correctly
# on real hardware first, before adding a PLL to give core_clk a genuinely
# faster, independent frequency (that's follow-up work, not done here -
# see fpga-roadmap.md Phase 24/25). cdc_pulse_sync's handshake design
# works correctly even same-clock (a degenerate case of CDC, not a
# special-cased bypass), so this is a safe, honest starting point, not a
# shortcut that silently breaks the "separate clock" design intent.
package require -exact qsys 12.0

load_system {soc_system.qsys}

remove_instance cfar_bridge_0

add_instance fpga_matching_core_0 fpga_matching_core 1.0

add_connection clk_0.clk fpga_matching_core_0.clk clock
add_connection clk_0.clk_reset fpga_matching_core_0.reset reset
add_connection clk_0.clk fpga_matching_core_0.core_clk clock
add_connection clk_0.clk_reset fpga_matching_core_0.core_reset reset

add_connection mm_bridge_0.m0 fpga_matching_core_0.avs avalon
set_connection_parameter_value mm_bridge_0.m0/fpga_matching_core_0.avs baseAddress {0x7000}

save_system {soc_system.qsys}
