// fpga_matching_core
//
// Avalon-MM slave wrapper around bounded_order_book (see that file, and
// docs/adr/ADR-007-fpga-bounded-order-book.md, for the matching semantics
// themselves). This module owns the clock-domain crossing between the
// register-access bus (avs_clk - stands in for the real LWH2F bridge
// clock until Phase 24 wires this onto the real HPS bridge; golden_top's
// CLOCK_50 is used for it meanwhile) and the matching FSM's own core_clk,
// which is deliberately a separate, faster domain - the whole point of
// building this in hardware is to run the matching loop faster than the
// bus that talks to it, and Phase 22's checklist explicitly calls for a
// real CDC boundary here, not a same-clock shortcut.
//
// Register map (word-addressed, avs_address is a 4-bit WORD address -
// each step is 4 bytes, matching typical Platform Designer convention):
//
//   0x0  ORDER_ID_LO      W   low 32 bits of the 64-bit order id
//   0x1  ORDER_ID_HI      W   high 32 bits
//   0x2  SIDE             W   bit0: 0 = BUY, 1 = SELL
//   0x3  PRICE            W   signed, ticks (kPriceScale = 10000)
//   0x4  QTY              W   unsigned
//   0x5  CONTROL          W   bit0 = START (write 1 to pulse; self-clears)
//   0x6  STATUS           R   bit0 = BUSY, bit1 = DONE (sticky until next
//                              START), bit2 = REJECTED
//   0x7  TRADE_QTY        R   aggregate filled quantity for the last order
//   0x8  TRADE_PRICE      R   last fill's price (resting side's price)
//   0x9  TRADE_ID_LO      R   low 32 bits of the last fill's trade id
//   0xA  TRADE_ID_HI      R   high 32 bits
//   0xB  LATENCY_CYCLES   R   core_clk cycles, START accept -> DONE
//
// A host must poll STATUS.BUSY (or .DONE) low before reading results and
// before issuing the next START - this module does not queue requests.
module fpga_matching_core #(
    parameter int N_LEVELS = 16,
    parameter int M_ORDERS = 8,
    parameter int PRICE_W  = 32,
    parameter int QTY_W    = 32,
    parameter int ID_W     = 64
) (
    input  logic        avs_clk,
    input  logic        avs_rst_n,
    input  logic [3:0]  avs_address,
    input  logic        avs_write,
    input  logic        avs_read,
    input  logic [31:0] avs_writedata,
    output logic [31:0] avs_readdata,

    input  logic         core_clk,
    input  logic         core_rst_n
);

    localparam logic [3:0] ADDR_ORDER_ID_LO   = 4'h0;
    localparam logic [3:0] ADDR_ORDER_ID_HI   = 4'h1;
    localparam logic [3:0] ADDR_SIDE          = 4'h2;
    localparam logic [3:0] ADDR_PRICE         = 4'h3;
    localparam logic [3:0] ADDR_QTY           = 4'h4;
    localparam logic [3:0] ADDR_CONTROL       = 4'h5;
    localparam logic [3:0] ADDR_STATUS        = 4'h6;
    localparam logic [3:0] ADDR_TRADE_QTY     = 4'h7;
    localparam logic [3:0] ADDR_TRADE_PRICE   = 4'h8;
    localparam logic [3:0] ADDR_TRADE_ID_LO   = 4'h9;
    localparam logic [3:0] ADDR_TRADE_ID_HI   = 4'hA;
    localparam logic [3:0] ADDR_LATENCY       = 4'hB;

    // ------------------------------------------------------------------
    // avs_clk domain: input holding registers + status/result readback
    // ------------------------------------------------------------------
    logic [31:0] order_id_lo_r, order_id_hi_r;
    logic        side_r;
    logic signed [PRICE_W-1:0] price_r;
    logic [QTY_W-1:0]          qty_r;

    logic avs_busy;
    logic avs_start_pulse;

    logic done_latched;
    logic [QTY_W-1:0]          result_trade_qty;
    logic signed [PRICE_W-1:0] result_trade_price;
    logic [ID_W-1:0]           result_trade_id;
    logic                      result_rejected;
    logic [31:0]                result_latency_cycles;

    assign avs_start_pulse = avs_write && (avs_address == ADDR_CONTROL) && avs_writedata[0];

    // Declared here (ahead of first use below) rather than down by their
    // driving instances further down the file - vlog requires a signal's
    // declaration to textually precede its use within a module, unlike
    // e.g. VHDL's fully declarative elaboration. Originally declared next
    // to u_start_sync/u_done_sync/u_book below and hit six
    // "Undefined variable" errors from vlog for exactly this reason - see
    // fpga_docs/bugs.md.
    logic avs_done_pulse;
    logic [QTY_W-1:0]          out_trade_qty;
    logic signed [PRICE_W-1:0] out_trade_price;
    logic [ID_W-1:0]           out_trade_id;
    logic                      out_rejected;
    logic [31:0]                out_latency_cycles;

    always_ff @(posedge avs_clk or negedge avs_rst_n) begin
        if (!avs_rst_n) begin
            order_id_lo_r <= '0;
            order_id_hi_r <= '0;
            side_r        <= 1'b0;
            price_r       <= '0;
            qty_r         <= '0;
            avs_busy      <= 1'b0;
            done_latched  <= 1'b0;

            result_trade_qty      <= '0;
            result_trade_price    <= '0;
            result_trade_id       <= '0;
            result_rejected       <= 1'b0;
            result_latency_cycles <= '0;
        end else begin
            if (avs_write) begin
                unique case (avs_address)
                    ADDR_ORDER_ID_LO: order_id_lo_r <= avs_writedata;
                    ADDR_ORDER_ID_HI: order_id_hi_r <= avs_writedata;
                    ADDR_SIDE:        side_r        <= avs_writedata[0];
                    ADDR_PRICE:       price_r        <= PRICE_W'(avs_writedata);
                    ADDR_QTY:         qty_r          <= QTY_W'(avs_writedata);
                    default: ;
                endcase
            end

            if (avs_start_pulse) begin
                avs_busy     <= 1'b1;
                done_latched <= 1'b0;
            end else if (avs_done_pulse) begin
                avs_busy     <= 1'b0;
                done_latched <= 1'b1;

                result_trade_qty      <= out_trade_qty;
                result_trade_price    <= out_trade_price;
                result_trade_id       <= out_trade_id;
                result_rejected       <= out_rejected;
                result_latency_cycles <= out_latency_cycles;
            end
        end
    end

    always_comb begin
        unique case (avs_address)
            ADDR_STATUS:       avs_readdata = {29'b0, result_rejected, done_latched, avs_busy};
            ADDR_TRADE_QTY:    avs_readdata = 32'(result_trade_qty);
            ADDR_TRADE_PRICE:  avs_readdata = 32'(result_trade_price);
            ADDR_TRADE_ID_LO:  avs_readdata = result_trade_id[31:0];
            ADDR_TRADE_ID_HI:  avs_readdata = (ID_W > 32) ? 32'(result_trade_id >> 32) : 32'b0;
            ADDR_LATENCY:      avs_readdata = result_latency_cycles;
            default:           avs_readdata = 32'b0;
        endcase
    end

    // ------------------------------------------------------------------
    // Clock-domain crossing: one pulse synchronizer each way. See
    // cdc_pulse_sync.sv for why only the control pulses cross bit-by-bit
    // and the data bus does not.
    // ------------------------------------------------------------------
    logic core_start_pulse;
    logic core_done_pulse;

    cdc_pulse_sync u_start_sync (
        .src_clk    (avs_clk),
        .src_rst_n  (avs_rst_n),
        .src_pulse  (avs_start_pulse),
        .dst_clk    (core_clk),
        .dst_rst_n  (core_rst_n),
        .dst_pulse  (core_start_pulse)
    );

    cdc_pulse_sync u_done_sync (
        .src_clk    (core_clk),
        .src_rst_n  (core_rst_n),
        .src_pulse  (core_done_pulse),
        .dst_clk    (avs_clk),
        .dst_rst_n  (avs_rst_n),
        .dst_pulse  (avs_done_pulse)
    );

    // ------------------------------------------------------------------
    // core_clk domain: the matching engine itself
    // ------------------------------------------------------------------
    logic [ID_W-1:0] core_order_id;
    assign core_order_id = {order_id_hi_r, order_id_lo_r};

    logic core_busy;

    bounded_order_book #(
        .N_LEVELS (N_LEVELS),
        .M_ORDERS (M_ORDERS),
        .PRICE_W  (PRICE_W),
        .QTY_W    (QTY_W),
        .ID_W     (ID_W)
    ) u_book (
        .clk                 (core_clk),
        .rst_n               (core_rst_n),
        .start_pulse         (core_start_pulse),
        .in_order_id         (core_order_id),
        .in_side             (side_r),
        .in_price            (price_r),
        .in_qty              (qty_r),
        .busy                (core_busy),
        .done_pulse          (core_done_pulse),
        .out_trade_qty       (out_trade_qty),
        .out_trade_price     (out_trade_price),
        .out_trade_id        (out_trade_id),
        .out_rejected        (out_rejected),
        .out_latency_cycles  (out_latency_cycles)
    );

endmodule
