# Questa compile + run script for fpga_matching_core.
# Invoke from inside sim/: vsim -c -do sim.do
vlib work
vlog -sv ../rtl/cdc_pulse_sync.sv ../rtl/bounded_order_book.sv ../rtl/fpga_matching_core.sv tb_fpga_matching_core.sv
vsim -c work.tb_fpga_matching_core
run -all
quit -f
