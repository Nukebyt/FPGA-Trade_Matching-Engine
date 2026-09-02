// tb_trace_replay_wrapper
//
// Same trace-replay idea as tb_trace_replay.sv, but drives the REAL
// deployed wrapper (fpga_matching_core, including its Avalon register
// interface and CDC pulse synchronizers) instead of bounded_order_book
// directly - tb_trace_replay.sv already proved bounded_order_book's
// matching logic matches the C++ reference exactly across all 1M
// orders, so this test isolates whether the wrapper/CDC layer (the only
// other RTL between the C++ reference and the real, divergent hardware
// numbers - see fpga_docs/bugs.md #11) introduces the real, reproducible
// 53.275% vs 72.4% reject-rate gap on its own, given a genuinely clean
// reset.
//
// avs_clk and core_clk are tied to the SAME clock here, matching
// soc_system.qsys's actual deployed wiring (both driven from clk_0,
// which is CLOCK_50 on real hardware) - not the deliberately-different
// clocks tb_fpga_matching_core.sv uses to stress the CDC generically.
// This is specifically trying to reproduce what's actually synthesized
// and running on the board, not to re-prove CDC robustness in general.
`timescale 1ns/1ps

module tb_trace_replay_wrapper;

    localparam int N_LEVELS = 16;
    localparam int M_ORDERS = 8;

    localparam logic [3:0] ADDR_ORDER_ID_LO = 4'h0;
    localparam logic [3:0] ADDR_ORDER_ID_HI = 4'h1;
    localparam logic [3:0] ADDR_SIDE        = 4'h2;
    localparam logic [3:0] ADDR_PRICE       = 4'h3;
    localparam logic [3:0] ADDR_QTY         = 4'h4;
    localparam logic [3:0] ADDR_CONTROL     = 4'h5;
    localparam logic [3:0] ADDR_STATUS      = 4'h6;
    localparam logic [3:0] ADDR_TRADE_QTY   = 4'h7;
    localparam logic [3:0] ADDR_TRADE_PRICE = 4'h8;
    localparam logic [3:0] ADDR_TRADE_ID_LO = 4'h9;
    localparam logic [3:0] ADDR_TRADE_ID_HI = 4'hA;

    logic clk = 0; // single shared clock - matches real hardware's avs_clk == core_clk
    logic rst_n = 0;

    logic [3:0]  avs_address;
    logic        avs_write;
    logic        avs_read;
    logic [31:0] avs_writedata;
    logic [31:0] avs_readdata;

    always #10 clk = ~clk; // 20 ns / 50 MHz, matching CLOCK_50

    fpga_matching_core #(
        .N_LEVELS (N_LEVELS),
        .M_ORDERS (M_ORDERS)
    ) dut (
        .avs_clk       (clk),
        .avs_rst_n     (rst_n),
        .avs_address   (avs_address),
        .avs_write     (avs_write),
        .avs_read      (avs_read),
        .avs_writedata (avs_writedata),
        .avs_readdata  (avs_readdata),
        .core_clk      (clk),
        .core_rst_n    (rst_n)
    );

    task automatic reset_dut();
        rst_n = 0;
        avs_write = 0;
        avs_read = 0;
        avs_address = '0;
        avs_writedata = '0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);
    endtask

    task automatic write_reg(input logic [3:0] addr, input logic [31:0] data);
        @(negedge clk);
        avs_address   = addr;
        avs_writedata = data;
        avs_write     = 1'b1;
        @(negedge clk);
        avs_write     = 1'b0;
    endtask

    task automatic read_reg(input logic [3:0] addr, output logic [31:0] data);
        @(negedge clk);
        avs_address = addr;
        avs_read    = 1'b1;
        #1;
        data = avs_readdata;
        @(negedge clk);
        avs_read    = 1'b0;
    endtask

    task automatic submit_and_wait(
        input logic [63:0]        order_id,
        input logic                side,
        input logic signed [31:0] price,
        input logic [31:0]        qty
    );
        logic [31:0] status;
        int timeout;
        write_reg(ADDR_ORDER_ID_LO, order_id[31:0]);
        write_reg(ADDR_ORDER_ID_HI, order_id[63:32]);
        write_reg(ADDR_SIDE, {31'b0, side});
        write_reg(ADDR_PRICE, price);
        write_reg(ADDR_QTY, qty);
        write_reg(ADDR_CONTROL, 32'h1);

        status = 0;
        timeout = 0;
        while (!status[1] && timeout < 1000) begin
            read_reg(ADDR_STATUS, status);
            timeout++;
        end
        if (timeout >= 1000)
            $display("[TIMEOUT] order_id=%0d never saw STATUS.DONE", order_id);
    endtask

    int fd;
    int r;
    longint unsigned order_id;
    int side_i;
    int price_i;
    int qty_i;
    int exp_rejected_i;
    int unsigned exp_trade_qty;
    int exp_trade_price;
    longint unsigned exp_trade_id;

    logic [31:0] act_status, act_trade_qty, act_trade_price, act_trade_id_lo, act_trade_id_hi;
    logic [63:0] act_trade_id;

    longint checked;
    longint mismatches;
    string line;

    initial begin
        checked = 0;
        mismatches = 0;

        fd = $fopen("trace.csv", "r");
        if (fd == 0) begin
            $display("[ERROR] could not open trace.csv");
            $finish;
        end
        r = $fgets(line, fd);

        reset_dut();

        while (!$feof(fd) && mismatches == 0) begin
            r = $fscanf(fd, "%d,%d,%d,%d,%d,%d,%d,%d\n", order_id, side_i, price_i, qty_i,
                        exp_rejected_i, exp_trade_qty, exp_trade_price, exp_trade_id);
            if (r != 8) begin
                if (!$feof(fd))
                    $display("[WARN] short read (r=%0d) at checked=%0d, stopping", r, checked);
                break;
            end

            submit_and_wait(order_id, side_i[0], price_i, qty_i);
            checked++;

            read_reg(ADDR_STATUS, act_status);
            read_reg(ADDR_TRADE_QTY, act_trade_qty);
            read_reg(ADDR_TRADE_PRICE, act_trade_price);
            read_reg(ADDR_TRADE_ID_LO, act_trade_id_lo);
            read_reg(ADDR_TRADE_ID_HI, act_trade_id_hi);
            act_trade_id = {act_trade_id_hi, act_trade_id_lo};

            if (act_status[2] !== exp_rejected_i[0] || act_trade_qty !== exp_trade_qty
                || act_trade_price !== exp_trade_price || act_trade_id !== exp_trade_id) begin
                mismatches++;
                $display("========================================================");
                $display("[MISMATCH] at order #%0d (order_id=%0d) after %0d clean matches",
                          checked, order_id, checked - 1);
                $display("  input:    side=%0d price=%0d qty=%0d", side_i, price_i, qty_i);
                $display("  RTL:      rejected=%0b trade_qty=%0d trade_price=%0d trade_id=%0d",
                          act_status[2], act_trade_qty, act_trade_price, act_trade_id);
                $display("  C++ ref:  rejected=%0d trade_qty=%0d trade_price=%0d trade_id=%0d",
                          exp_rejected_i, exp_trade_qty, exp_trade_price, exp_trade_id);
                $display("========================================================");
            end

            if (checked % 100000 == 0)
                $display("... %0d orders checked, %0d mismatches so far", checked, mismatches);
        end

        $fclose(fd);

        if (mismatches == 0)
            $display("ALL %0d ORDERS MATCHED THE C++ REFERENCE EXACTLY (through the real Avalon wrapper + CDC)", checked);
        else
            $display("STOPPED after first mismatch: %0d orders checked, %0d mismatch(es)", checked, mismatches);

        $finish;
    end

endmodule
