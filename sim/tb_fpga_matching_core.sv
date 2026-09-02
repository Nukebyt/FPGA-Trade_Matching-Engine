// tb_fpga_matching_core
//
// Directed-test testbench for fpga_matching_core, mirroring the naming
// and intent of the software project's MatchingEngineTest cases
// (low_latency_trading_infra/matching-engine/tests/matching_engine_test.cpp)
// as closely as a bounded hardware core's scope allows - see
// docs/adr/ADR-007-fpga-bounded-order-book.md for what's deliberately
// different (bounded N/M, aggregate trade reporting, no CANCEL/MODIFY).
//
// Runs with N_LEVELS=4, M_ORDERS=2 (overridden down from the default
// 16/8) specifically so the two overflow paths (level-full, book-full)
// are reachable with a handful of directed orders instead of dozens.
//
// avs_clk and core_clk are deliberately NOT an integer multiple of each
// other (20 ns vs 7 ns) so the CDC synchronizers are genuinely exercised
// with an arbitrary phase relationship, not a suspiciously clean one.
`timescale 1ns/1ps

module tb_fpga_matching_core;

    localparam int N_LEVELS = 4;
    localparam int M_ORDERS = 2;
    localparam int PRICE_W  = 32;
    localparam int QTY_W    = 32;
    localparam int ID_W     = 64;

    localparam logic [3:0] ADDR_ORDER_ID_LO = 4'h0;
    localparam logic [3:0] ADDR_ORDER_ID_HI = 4'h1;
    localparam logic [3:0] ADDR_SIDE        = 4'h2;
    localparam logic [3:0] ADDR_PRICE       = 4'h3;
    localparam logic [3:0] ADDR_QTY         = 4'h4;
    localparam logic [3:0] ADDR_CONTROL     = 4'h5;
    localparam logic [3:0] ADDR_STATUS      = 4'h6;
    localparam logic [3:0] ADDR_TRADE_QTY   = 4'h7;
    localparam logic [3:0] ADDR_TRADE_PRICE = 4'h8;

    localparam logic SIDE_BUY  = 1'b0;
    localparam logic SIDE_SELL = 1'b1;

    logic avs_clk = 0;
    logic core_clk = 0;
    logic avs_rst_n = 0;
    logic core_rst_n = 0;

    logic [3:0]  avs_address;
    logic        avs_write;
    logic        avs_read;
    logic [31:0] avs_writedata;
    logic [31:0] avs_readdata;

    int errors = 0;
    int passes = 0;

    always #10 avs_clk  = ~avs_clk;   // 20 ns period, 50 MHz
    always #3.5 core_clk = ~core_clk; // 7 ns period, ~142.9 MHz

    fpga_matching_core #(
        .N_LEVELS (N_LEVELS),
        .M_ORDERS (M_ORDERS),
        .PRICE_W  (PRICE_W),
        .QTY_W    (QTY_W),
        .ID_W     (ID_W)
    ) dut (
        .avs_clk       (avs_clk),
        .avs_rst_n     (avs_rst_n),
        .avs_address   (avs_address),
        .avs_write     (avs_write),
        .avs_read      (avs_read),
        .avs_writedata (avs_writedata),
        .avs_readdata  (avs_readdata),
        .core_clk      (core_clk),
        .core_rst_n    (core_rst_n)
    );

    task automatic reset_dut();
        avs_rst_n  = 0;
        core_rst_n = 0;
        avs_write  = 0;
        avs_read   = 0;
        avs_address = '0;
        avs_writedata = '0;
        repeat (4) @(negedge avs_clk);
        repeat (4) @(negedge core_clk);
        avs_rst_n  = 1;
        core_rst_n = 1;
        repeat (4) @(negedge avs_clk);
    endtask

    task automatic write_reg(input logic [3:0] addr, input logic [31:0] data);
        @(negedge avs_clk);
        avs_address   = addr;
        avs_writedata = data;
        avs_write     = 1'b1;
        @(negedge avs_clk);
        avs_write     = 1'b0;
    endtask

    task automatic read_reg(input logic [3:0] addr, output logic [31:0] data);
        @(negedge avs_clk);
        avs_address = addr;
        avs_read    = 1'b1;
        #1;
        data = avs_readdata;
        @(negedge avs_clk);
        avs_read    = 1'b0;
    endtask

    task automatic submit_order(
        input logic [63:0]        order_id,
        input logic                side,
        input logic signed [31:0] price,
        input logic [31:0]        qty
    );
        write_reg(ADDR_ORDER_ID_LO, order_id[31:0]);
        write_reg(ADDR_ORDER_ID_HI, order_id[63:32]);
        write_reg(ADDR_SIDE, {31'b0, side});
        write_reg(ADDR_PRICE, price);
        write_reg(ADDR_QTY, qty);
        write_reg(ADDR_CONTROL, 32'h1);
    endtask

    task automatic wait_done();
        logic [31:0] status;
        int timeout;
        status = 0;
        timeout = 0;
        while (!status[1] && timeout < 5000) begin
            read_reg(ADDR_STATUS, status);
            timeout++;
        end
        if (timeout >= 5000) begin
            $display("[TIMEOUT] wait_done never saw STATUS.DONE");
            errors++;
        end
    endtask

    task automatic check_result(
        input string               name,
        input logic [31:0]         exp_trade_qty,
        input logic signed [31:0] exp_trade_price,
        input logic                exp_rejected
    );
        logic [31:0] status, tq, tp;
        read_reg(ADDR_STATUS, status);
        read_reg(ADDR_TRADE_QTY, tq);
        read_reg(ADDR_TRADE_PRICE, tp);
        if (tq !== exp_trade_qty || tp !== 32'(exp_trade_price) || status[2] !== exp_rejected) begin
            $display("[FAIL] %-28s got qty=%0d price=%0d rejected=%0b | expected qty=%0d price=%0d rejected=%0b",
                      name, tq, $signed(tp), status[2], exp_trade_qty, exp_trade_price, exp_rejected);
            errors++;
        end else begin
            $display("[PASS] %-28s qty=%0d price=%0d rejected=%0b", name, tq, $signed(tp), status[2]);
            passes++;
        end
    endtask

    task automatic run_order(
        input string               name,
        input logic [63:0]         order_id,
        input logic                side,
        input logic signed [31:0] price,
        input logic [31:0]         qty,
        input logic [31:0]         exp_trade_qty,
        input logic signed [31:0] exp_trade_price,
        input logic                exp_rejected
    );
        submit_order(order_id, side, price, qty);
        wait_done();
        check_result(name, exp_trade_qty, exp_trade_price, exp_rejected);
    endtask

    initial begin
        $display("=== tb_fpga_matching_core: N_LEVELS=%0d M_ORDERS=%0d ===", N_LEVELS, M_ORDERS);

        // ---- Group A: resting add, price improvement, full consume+pop
        reset_dut();
        run_order("RestingAddNoCross",        64'd1, SIDE_BUY,  32'd100, 32'd10, 32'd0, 32'd0,   1'b0);
        run_order("PartialMatchPriceImprove",  64'd2, SIDE_SELL, 32'd95,  32'd5,  32'd5, 32'd100, 1'b0);
        run_order("FullConsumeAndPop",         64'd3, SIDE_SELL, 32'd100, 32'd5,  32'd5, 32'd100, 1'b0);

        // ---- Group B: multi-level walk in a single incoming order
        reset_dut();
        run_order("RestingAddOtherSide",       64'd4, SIDE_SELL, 32'd120, 32'd5,  32'd0, 32'd0,   1'b0);
        run_order("RestingAddSecondLevel",     64'd5, SIDE_SELL, 32'd125, 32'd5,  32'd0, 32'd0,   1'b0);
        run_order("CrossesTwoLevelsAggregate", 64'd6, SIDE_BUY,  32'd130, 32'd8,  32'd8, 32'd125, 1'b0);

        // ---- Group C: level-full (M_ORDERS) rejection, clean opposite side
        reset_dut();
        run_order("FillLevelSlot0",  64'd7, SIDE_BUY, 32'd200, 32'd1, 32'd0, 32'd0, 1'b0);
        run_order("FillLevelSlot1",  64'd8, SIDE_BUY, 32'd200, 32'd1, 32'd0, 32'd0, 1'b0);
        run_order("LevelFullReject", 64'd9, SIDE_BUY, 32'd200, 32'd1, 32'd0, 32'd0, 1'b1);

        // ---- Group D: book-full (N_LEVELS) rejection, clean opposite side
        reset_dut();
        run_order("OpenLevel0",     64'd10, SIDE_BUY, 32'd100, 32'd1, 32'd0, 32'd0, 1'b0);
        run_order("OpenLevel1",     64'd11, SIDE_BUY, 32'd101, 32'd1, 32'd0, 32'd0, 1'b0);
        run_order("OpenLevel2",     64'd12, SIDE_BUY, 32'd102, 32'd1, 32'd0, 32'd0, 1'b0);
        run_order("OpenLevel3",     64'd13, SIDE_BUY, 32'd103, 32'd1, 32'd0, 32'd0, 1'b0);
        run_order("BookFullReject", 64'd14, SIDE_BUY, 32'd104, 32'd1, 32'd0, 32'd0, 1'b1);

        $display("=== SUMMARY: %0d passed, %0d failed ===", passes, errors);
        if (errors == 0)
            $display("SIMULATION PASSED");
        else
            $display("SIMULATION FAILED");

        $finish;
    end

    // Safety net in case wait_done()'s own timeout logic somehow doesn't
    // trip (e.g. a hang before the first submit_order even completes).
    initial begin
        #200000;
        $display("[TIMEOUT] global testbench watchdog fired - simulation hung");
        $display("SIMULATION FAILED");
        $finish;
    end

endmodule
