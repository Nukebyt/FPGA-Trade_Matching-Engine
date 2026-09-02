// tb_bounded_order_book_multilevel
//
// Targeted reproduction testbench for the real total_filled overcounting
// found on physical hardware (fpga_docs/bugs.md #10/#11): a 1,000,000-
// order real-hardware run reported total filled quantity 4.5x higher
// than the theoretical maximum possible (no single order can ever fill
// more than its own submitted qty). tb_fpga_matching_core.sv's 14
// directed cases all pass, but run at N_LEVELS=4/M_ORDERS=2 (overridden
// down for tractability) and never exercise a walk across more than a
// couple of levels. This testbench drives bounded_order_book directly
// (bypassing fpga_matching_core's Avalon wrapper/CDC - the bug is a
// quantity value exceeding a hard structural bound, not the kind of
// thing a clock-domain-crossing issue produces) at the REAL default
// N_LEVELS=16/M_ORDERS=8, and forces a single order to walk across
// exactly 4 resting price levels - the simplest case broader than
// anything the existing directed suite covers.
`timescale 1ns/1ps

module tb_bounded_order_book_multilevel;

    localparam int N_LEVELS = 16; // real defaults, deliberately NOT overridden
    localparam int M_ORDERS = 8;
    localparam int PRICE_W  = 32;
    localparam int QTY_W    = 32;
    localparam int ID_W     = 64;

    localparam logic SIDE_BUY  = 1'b0;
    localparam logic SIDE_SELL = 1'b1;

    logic clk = 0;
    logic rst_n = 0;

    logic                       start_pulse;
    logic [ID_W-1:0]            in_order_id;
    logic                        in_side;
    logic signed [PRICE_W-1:0]  in_price;
    logic [QTY_W-1:0]           in_qty;

    logic                       busy;
    logic                       done_pulse;
    logic [QTY_W-1:0]           out_trade_qty;
    logic signed [PRICE_W-1:0] out_trade_price;
    logic [ID_W-1:0]            out_trade_id;
    logic                        out_rejected;
    logic [31:0]                 out_latency_cycles;

    int errors = 0;
    int passes = 0;

    always #5 clk = ~clk; // 10 ns period, 100 MHz - value doesn't matter for this test

    bounded_order_book #(
        .N_LEVELS (N_LEVELS),
        .M_ORDERS (M_ORDERS),
        .PRICE_W  (PRICE_W),
        .QTY_W    (QTY_W),
        .ID_W     (ID_W)
    ) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .start_pulse         (start_pulse),
        .in_order_id         (in_order_id),
        .in_side             (in_side),
        .in_price            (in_price),
        .in_qty              (in_qty),
        .busy                (busy),
        .done_pulse          (done_pulse),
        .out_trade_qty       (out_trade_qty),
        .out_trade_price     (out_trade_price),
        .out_trade_id        (out_trade_id),
        .out_rejected        (out_rejected),
        .out_latency_cycles  (out_latency_cycles)
    );

    task automatic reset_dut();
        rst_n = 0;
        start_pulse = 0;
        in_order_id = '0;
        in_side = 0;
        in_price = '0;
        in_qty = '0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);
    endtask

    task automatic submit_and_wait(
        input logic [63:0]        order_id,
        input logic                side,
        input logic signed [31:0] price,
        input logic [31:0]        qty
    );
        int timeout;
        @(negedge clk);
        in_order_id = order_id;
        in_side     = side;
        in_price    = price;
        in_qty      = qty;
        start_pulse = 1'b1;
        @(negedge clk);
        start_pulse = 1'b0;
        timeout = 0;
        while (!done_pulse && timeout < 1000) begin
            @(negedge clk);
            timeout++;
        end
        if (timeout >= 1000) begin
            $display("[TIMEOUT] submit_and_wait order_id=%0d never saw done_pulse", order_id);
            errors++;
        end
    endtask

    task automatic check(
        input string               name,
        input logic [31:0]         exp_trade_qty,
        input logic signed [31:0] exp_trade_price,
        input logic                exp_rejected
    );
        if (out_trade_qty !== exp_trade_qty || out_trade_price !== exp_trade_price
            || out_rejected !== exp_rejected) begin
            $display("[FAIL] %-28s got qty=%0d price=%0d rejected=%0b latency=%0d | expected qty=%0d price=%0d rejected=%0b",
                      name, out_trade_qty, out_trade_price, out_rejected, out_latency_cycles,
                      exp_trade_qty, exp_trade_price, exp_rejected);
            errors++;
        end else begin
            $display("[PASS] %-28s qty=%0d price=%0d rejected=%0b latency=%0d",
                      name, out_trade_qty, out_trade_price, out_rejected, out_latency_cycles);
            passes++;
        end
    endtask

    initial begin
        reset_dut();

        // Rest 4 SELL levels at increasing prices, qty 50 each - all rest
        // cleanly since the book starts empty (nothing to cross against).
        submit_and_wait(64'd101, SIDE_SELL, 32'sd100, 32'd50);
        check("rest sell@100", 32'd0, 32'sd0, 1'b0);

        submit_and_wait(64'd102, SIDE_SELL, 32'sd101, 32'd50);
        check("rest sell@101", 32'd0, 32'sd0, 1'b0);

        submit_and_wait(64'd103, SIDE_SELL, 32'sd102, 32'd50);
        check("rest sell@102", 32'd0, 32'sd0, 1'b0);

        submit_and_wait(64'd104, SIDE_SELL, 32'sd103, 32'd50);
        check("rest sell@103", 32'd0, 32'sd0, 1'b0);

        // One aggressive BUY at price 200, qty 500 - crosses all 4 resting
        // levels (200 >= 100/101/102/103), consuming 50 from each in
        // ascending-price order (best/lowest sell price matched first),
        // then rests the remainder (500 - 200 = 300) as a new BUY level.
        // The ONLY correct aggregate fill is 50*4 = 200 - anything else
        // (in particular the real-hardware-observed pattern of wildly
        // exceeding what a single order could structurally fill) is the
        // bug this testbench exists to catch.
        submit_and_wait(64'd201, SIDE_BUY, 32'sd200, 32'd500);
        check("sweep 4 levels", 32'd200, 32'sd103, 1'b0);

        if (errors == 0)
            $display("ALL %0d CHECKS PASSED", passes);
        else
            $display("%0d PASSED, %0d FAILED", passes, errors);

        $finish;
    end

endmodule
