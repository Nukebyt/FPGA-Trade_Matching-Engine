// cdc_pulse_sync
//
// Crosses a single-cycle pulse from src_clk into dst_clk safely, using the
// standard toggle + double-flop-synchronizer technique: a pulse in the
// source domain flips a toggle flop; two flops in the destination domain
// resynchronize that toggle bit (resolving metastability, per the usual
// MTBF argument for a 2-flop synchronizer); an edge detector on the
// resynchronized toggle produces one dst_clk-wide pulse per source pulse.
//
// Only the 1-bit toggle crosses domains here. Any data associated with the
// pulse (the order fields, the trade result) must be held stable in its
// own domain across the full round trip and only sampled by the *other*
// domain after it has observed this synchronized pulse — never
// synchronized bit-by-bit itself, which would let different bits of a
// multi-bit bus resolve on different clock edges ("bus skew") and produce
// a torn, incorrect value. fpga_matching_core relies on this: it holds
// order inputs stable for the whole transaction and only lets avs_clk
// sample the result registers after start_ack/done have both crossed.
//
// Does not handle asynchronous reset deassertion synchronization (a real
// production concern - reset-recovery metastability - deliberately not
// built here, same as this project's other named scope boundaries).
module cdc_pulse_sync (
    input  logic src_clk,
    input  logic src_rst_n,
    input  logic src_pulse,

    input  logic dst_clk,
    input  logic dst_rst_n,
    output logic dst_pulse
);

    logic src_toggle;
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            src_toggle <= 1'b0;
        else if (src_pulse)
            src_toggle <= ~src_toggle;
    end

    logic [2:0] dst_sync;
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n)
            dst_sync <= 3'b000;
        else
            dst_sync <= {dst_sync[1:0], src_toggle};
    end

    assign dst_pulse = dst_sync[2] ^ dst_sync[1];

endmodule
