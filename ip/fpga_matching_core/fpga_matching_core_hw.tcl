# fpga_matching_core_hw.tcl -- Platform Designer (Qsys) component
# descriptor for fpga_matching_core.sv. Modeled directly on the
# de10_ghrd reference project's cfar_avalon_bridge_hw.tcl (a proven
# working pattern on this exact toolchain/board), not written from
# scratch - same package/API version, same plain add_fileset_file
# pattern (hand-written HDL, no procedural codegen).
#
# References rtl/*.sv by relative path rather than copying them into
# this ip/ directory - single source of truth, same files
# sim/tb_fpga_matching_core.sv and synth_check/ already exercise and
# have been verified against (14/14 tests, real quartus_map/quartus_fit
# resource numbers - see fpga_docs/bugs.md).

package require -exact qsys 12.0

set_module_property NAME fpga_matching_core
set_module_property DISPLAY_NAME "Bounded FPGA Matching Engine"
set_module_property VERSION 1.0
set_module_property GROUP "Trading Infra FPGA"
set_module_property DESCRIPTION "Bounded price-time-priority matching engine (ADR-007): Avalon-MM register file (avs_clk) wrapping bounded_order_book.sv on its own core_clk domain, crossed via cdc_pulse_sync."
set_module_property AUTHOR "trading_infra_fpga project"
set_module_property INTERNAL false
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE false
set_module_property ELABORATION_CALLBACK elaborate

# ---- source files -------------------------------------------------------
# Relative to this file: ip/fpga_matching_core/ -> ../../rtl/
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL fpga_matching_core
foreach f {
    ../../rtl/cdc_pulse_sync.sv
    ../../rtl/bounded_order_book.sv
    ../../rtl/fpga_matching_core.sv
} {
    add_fileset_file $f SYSTEM_VERILOG PATH $f
}

add_fileset SIM_VERILOG SIM_VERILOG "" ""
set_fileset_property SIM_VERILOG TOP_LEVEL fpga_matching_core
foreach f {
    ../../rtl/cdc_pulse_sync.sv
    ../../rtl/bounded_order_book.sv
    ../../rtl/fpga_matching_core.sv
} {
    add_fileset_file $f SYSTEM_VERILOG PATH $f
}

# ---- parameters (match fpga_matching_core.sv's own #() defaults, and
# ADR-007's locked-in bounds - N_LEVELS=16/M_ORDERS=8/PRICE_W=32/QTY_W=32/
# ID_W=64) ------------------------------------------------------------
add_parameter N_LEVELS INTEGER 16
set_parameter_property N_LEVELS DISPLAY_NAME "N_LEVELS (price levels per side)"
set_parameter_property N_LEVELS HDL_PARAMETER true

add_parameter M_ORDERS INTEGER 8
set_parameter_property M_ORDERS DISPLAY_NAME "M_ORDERS (resting orders per level)"
set_parameter_property M_ORDERS HDL_PARAMETER true

add_parameter PRICE_W INTEGER 32
set_parameter_property PRICE_W DISPLAY_NAME "Price width (bits, signed ticks)"
set_parameter_property PRICE_W HDL_PARAMETER true

add_parameter QTY_W INTEGER 32
set_parameter_property QTY_W DISPLAY_NAME "Quantity width (bits)"
set_parameter_property QTY_W HDL_PARAMETER true

add_parameter ID_W INTEGER 64
set_parameter_property ID_W DISPLAY_NAME "Order/trade ID width (bits)"
set_parameter_property ID_W HDL_PARAMETER true

# ---- interfaces -----------------------------------------------------------
proc elaborate {} {

    # avs_clk domain - the register file / LWH2F bridge side
    add_interface clk clock end
    set_interface_property clk clockRate 0
    add_interface_port clk avs_clk clk Input 1

    add_interface reset reset end
    set_interface_property reset associatedClock clk
    set_interface_property reset synchronousEdges DEASSERT
    add_interface_port reset avs_rst_n reset_n Input 1

    # avs: word-addressed, fixed 0/1-cycle latency - no waitrequest port,
    # a deliberate v1 simplification (fpga_docs/bugs.md; every read is
    # combinational, every write completes in the cycle it's issued).
    add_interface avs avalon end
    set_interface_property avs associatedClock clk
    set_interface_property avs associatedReset reset
    set_interface_property avs addressUnits WORDS
    set_interface_property avs addressAlignment NATIVE
    set_interface_property avs bitsPerSymbol 8
    set_interface_property avs readLatency 0
    set_interface_property avs readWaitTime 0
    set_interface_property avs writeWaitTime 0
    set_interface_property avs setupTime 0
    set_interface_property avs holdTime 0

    add_interface_port avs avs_address    address     Input  4
    add_interface_port avs avs_write      write       Input  1
    add_interface_port avs avs_writedata  writedata   Input  32
    add_interface_port avs avs_read       read        Input  1
    add_interface_port avs avs_readdata   readdata    Output 32

    # core_clk domain - the matching engine's own faster fabric clock,
    # deliberately separate from avs_clk (see fpga_matching_core.sv's
    # header comment: the whole point is running the matching loop
    # faster than the bus that talks to it). Exposed as its own Qsys
    # clock/reset interface so it can be driven by a PLL output distinct
    # from the LWH2F bridge clock once one exists in the system.
    add_interface core_clk clock end
    set_interface_property core_clk clockRate 0
    add_interface_port core_clk core_clk clk Input 1

    add_interface core_reset reset end
    set_interface_property core_reset associatedClock core_clk
    set_interface_property core_reset synchronousEdges DEASSERT
    add_interface_port core_reset core_rst_n reset_n Input 1
}
