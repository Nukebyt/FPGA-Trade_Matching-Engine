// bounded_order_book
//
// Single-instrument, single-clock-domain (core_clk) bounded price-time
// priority matching engine. See docs/adr/ADR-007-fpga-bounded-order-book.md
// (low_latency_trading_infra repo) for the full design rationale; summary:
//
//   - N_LEVELS distinct price levels per side, unordered (no sorted
//     array, no shift-on-insert). "Best price" is a max/min reduction
//     across all N_LEVELS slots - see the pipelined-reduction note below
//     for why this is no longer a single-cycle combinational block.
//   - M_ORDERS resting orders per level, time-priority FIFO (index 0 =
//     front = oldest = next to trade).
//   - Trade price convention matches docs/matching-engine.md: a trade
//     always executes at the RESTING order's price, never the
//     aggressor's.
//   - Matching can never overflow (it only ever consumes existing
//     slots). Only resting an unfilled remainder can overflow, and only
//     then is REJECTED asserted - whatever already traded still stands.
//   - Register-level reporting is aggregate: TRADE_QTY sums every fill
//     this order caused, TRADE_PRICE is only the *last* fill's price.
//
// CANCEL/MODIFY are out of scope (see ADR-007) - this module only
// implements ADD_ORDER (submit, match, rest-or-reject).
//
// Pipelined reduction (fpga_docs/bugs.md #12 fix):
//   The N_LEVELS-wide "find best price" / "find matching or free level"
//   searches used to be written as a single-cycle for-loop reduction and
//   assumed Quartus would restructure it into a balanced comparator tree
//   (see the removed comment that used to sit here, and
//   fpga_docs/interview-questions.md). It didn't - post-fit timing
//   analysis on real hardware showed a 76-logic-level, 66.9ns
//   register-to-register path from buy_price[0] to sell_qty[11][0]
//   against a 20ns (50MHz) budget, i.e. Quartus emitted an O(N) serial
//   priority chain, not a tree. That is the real, structural root cause
//   most likely behind bug #12's board-wide hang (silicon running ~47ns
//   past its setup budget on every single order produces exactly the
//   kind of nondeterministic, corner-sensitive register corruption that
//   looked like "reset never happened").
//
//   Fix: an explicit, hand-built binary-tree reduction, registered
//   between every pairwise compare (RB_STAGES = $clog2(N_LEVELS) cycles;
//   4 cycles at the real N_LEVELS=16 bound). Each stage is a single
//   pairwise compare-and-select - a few logic levels, nowhere near the
//   20ns budget - instead of one N-deep chain. This assumes N_LEVELS is
//   a power of two (true for every current instantiation: 16 in the real
//   design, 4 in the smaller directed testbenches); a non-power-of-two
//   N_LEVELS would need the halving arithmetic below adjusted.
//
//   This costs extra clock cycles per order (matching loops through
//   ST_REDUCE_BEST once per crossed level, ST_REDUCE_REST once at the
//   end) instead of being instant, which is the right trade here:
//   correctness and real timing closure over raw single-cycle latency.
module bounded_order_book #(
    parameter int N_LEVELS   = 16,
    parameter int M_ORDERS   = 8,
    parameter int PRICE_W    = 32,
    parameter int QTY_W      = 32,
    parameter int ID_W       = 64
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                   start_pulse,
    input  logic [ID_W-1:0]        in_order_id,
    input  logic                   in_side,      // 0 = BUY, 1 = SELL
    input  logic signed [PRICE_W-1:0] in_price,
    input  logic [QTY_W-1:0]       in_qty,

    output logic                   busy,
    output logic                   done_pulse,
    output logic [QTY_W-1:0]       out_trade_qty,      // aggregate filled
    output logic signed [PRICE_W-1:0] out_trade_price, // last fill's price
    output logic [ID_W-1:0]        out_trade_id,       // last fill's trade id
    output logic                   out_rejected,       // remainder couldn't rest
    output logic [31:0]            out_latency_cycles
);

    localparam int LVL_W = (N_LEVELS <= 1) ? 1 : $clog2(N_LEVELS);
    localparam int CNT_W = $clog2(M_ORDERS + 1);
    localparam logic SIDE_BUY  = 1'b0;
    localparam logic SIDE_SELL = 1'b1;

    // Number of registered pairwise-merge stages needed to reduce
    // N_LEVELS candidates down to one winner. Assumes N_LEVELS is a
    // power of two (see module header note).
    localparam int RB_STAGES = (N_LEVELS <= 1) ? 1 : $clog2(N_LEVELS);
    localparam int RB_CNT_W  = $clog2(RB_STAGES + 1);

    // ------------------------------------------------------------------
    // Book storage - two sides, N_LEVELS unordered slots each.
    // ------------------------------------------------------------------
    logic                      buy_valid [N_LEVELS];
    logic signed [PRICE_W-1:0] buy_price [N_LEVELS];
    logic [CNT_W-1:0]          buy_count [N_LEVELS];
    logic [ID_W-1:0]           buy_oid   [N_LEVELS][M_ORDERS];
    logic [QTY_W-1:0]          buy_qty   [N_LEVELS][M_ORDERS];

    logic                      sell_valid [N_LEVELS];
    logic signed [PRICE_W-1:0] sell_price [N_LEVELS];
    logic [CNT_W-1:0]          sell_count [N_LEVELS];
    logic [ID_W-1:0]           sell_oid   [N_LEVELS][M_ORDERS];
    logic [QTY_W-1:0]          sell_qty   [N_LEVELS][M_ORDERS];

    // ------------------------------------------------------------------
    // Pipelined best-price reduction (buy = max, sell = min). Registers
    // are reused as ping-pong storage: stage L reads width (N_LEVELS>>L)
    // candidates (from the raw book when L==0, else from these same
    // registers) and writes width (N_LEVELS>>(L+1)) winners back into the
    // low half of these arrays. After RB_STAGES cycles, index 0 holds the
    // final winner.
    // ------------------------------------------------------------------
    logic [RB_CNT_W-1:0]       rb_level;

    // Sized N_LEVELS (not RB_W) even though only the first (in_width/2)
    // entries are ever meaningful at a given level: Quartus statically
    // unrolls the for-loop below across the full compile-time loop bound
    // and checks the a_i/b_i index expressions' declared range regardless
    // of the runtime "j < in_width/2" guard (in_width depends on the
    // rb_level register, not a compile-time constant, so the guard can't
    // be resolved at elaboration time) - a_i/b_i range up to N_LEVELS-1
    // structurally, so the arrays must too, or Quartus errors with an
    // out-of-range index even though that branch is never dynamically
    // reached. See fpga_docs/bugs.md #12 fix notes.
    logic                      buy_rb_valid  [N_LEVELS];
    logic signed [PRICE_W-1:0] buy_rb_price  [N_LEVELS];
    logic [LVL_W-1:0]          buy_rb_idx    [N_LEVELS];
    logic                      sell_rb_valid [N_LEVELS];
    logic signed [PRICE_W-1:0] sell_rb_price [N_LEVELS];
    logic [LVL_W-1:0]          sell_rb_idx   [N_LEVELS];

    logic                      buy_rb_next_valid  [N_LEVELS];
    logic signed [PRICE_W-1:0] buy_rb_next_price  [N_LEVELS];
    logic [LVL_W-1:0]          buy_rb_next_idx    [N_LEVELS];
    logic                      sell_rb_next_valid [N_LEVELS];
    logic signed [PRICE_W-1:0] sell_rb_next_price [N_LEVELS];
    logic [LVL_W-1:0]          sell_rb_next_idx   [N_LEVELS];

    // Latched final winners, held stable through ST_MATCH (and any
    // ST_POP_LEVEL / re-reduce loop back through ST_REDUCE_BEST).
    logic                      buy_best_valid_r;
    logic signed [PRICE_W-1:0] buy_best_price_r;
    logic [LVL_W-1:0]          buy_best_idx_r;
    logic                      sell_best_valid_r;
    logic signed [PRICE_W-1:0] sell_best_price_r;
    logic [LVL_W-1:0]          sell_best_idx_r;

    always_comb begin
        int in_width;
        int a_i, b_i;
        in_width = N_LEVELS >> rb_level;

        for (int j = 0; j < N_LEVELS; j++) begin
            buy_rb_next_valid[j]  = 1'b0;
            buy_rb_next_price[j]  = '0;
            buy_rb_next_idx[j]    = '0;
            sell_rb_next_valid[j] = 1'b0;
            sell_rb_next_price[j] = '0;
            sell_rb_next_idx[j]   = '0;

            // The "j < N_LEVELS/2" half is a compile-time-constant bound
            // (independent of the rb_level-derived, runtime-only
            // "j < in_width/2" half) that lets Quartus statically prove
            // no a_i/b_i indexing hardware is needed for j >= N_LEVELS/2,
            // which is what keeps a_i/b_i providably within the N_LEVELS
            // array bounds declared above - see fpga_docs/bugs.md #12.
            if (j < N_LEVELS / 2 && j < in_width / 2) begin
                a_i = 2 * j;
                b_i = 2 * j + 1;

                // --- buy side: keep the higher price ---
                if (rb_level == 0) begin
                    if (!buy_valid[a_i] && !buy_valid[b_i]) begin
                        buy_rb_next_valid[j] = 1'b0;
                    end else if (buy_valid[a_i] && (!buy_valid[b_i] || buy_price[a_i] > buy_price[b_i])) begin
                        buy_rb_next_valid[j] = 1'b1;
                        buy_rb_next_price[j] = buy_price[a_i];
                        buy_rb_next_idx[j]   = a_i[LVL_W-1:0];
                    end else begin
                        buy_rb_next_valid[j] = 1'b1;
                        buy_rb_next_price[j] = buy_price[b_i];
                        buy_rb_next_idx[j]   = b_i[LVL_W-1:0];
                    end
                end else begin
                    if (!buy_rb_valid[a_i] && !buy_rb_valid[b_i]) begin
                        buy_rb_next_valid[j] = 1'b0;
                    end else if (buy_rb_valid[a_i] && (!buy_rb_valid[b_i] || buy_rb_price[a_i] > buy_rb_price[b_i])) begin
                        buy_rb_next_valid[j] = 1'b1;
                        buy_rb_next_price[j] = buy_rb_price[a_i];
                        buy_rb_next_idx[j]   = buy_rb_idx[a_i];
                    end else begin
                        buy_rb_next_valid[j] = 1'b1;
                        buy_rb_next_price[j] = buy_rb_price[b_i];
                        buy_rb_next_idx[j]   = buy_rb_idx[b_i];
                    end
                end

                // --- sell side: keep the lower price ---
                if (rb_level == 0) begin
                    if (!sell_valid[a_i] && !sell_valid[b_i]) begin
                        sell_rb_next_valid[j] = 1'b0;
                    end else if (sell_valid[a_i] && (!sell_valid[b_i] || sell_price[a_i] < sell_price[b_i])) begin
                        sell_rb_next_valid[j] = 1'b1;
                        sell_rb_next_price[j] = sell_price[a_i];
                        sell_rb_next_idx[j]   = a_i[LVL_W-1:0];
                    end else begin
                        sell_rb_next_valid[j] = 1'b1;
                        sell_rb_next_price[j] = sell_price[b_i];
                        sell_rb_next_idx[j]   = b_i[LVL_W-1:0];
                    end
                end else begin
                    if (!sell_rb_valid[a_i] && !sell_rb_valid[b_i]) begin
                        sell_rb_next_valid[j] = 1'b0;
                    end else if (sell_rb_valid[a_i] && (!sell_rb_valid[b_i] || sell_rb_price[a_i] < sell_rb_price[b_i])) begin
                        sell_rb_next_valid[j] = 1'b1;
                        sell_rb_next_price[j] = sell_rb_price[a_i];
                        sell_rb_next_idx[j]   = sell_rb_idx[a_i];
                    end else begin
                        sell_rb_next_valid[j] = 1'b1;
                        sell_rb_next_price[j] = sell_rb_price[b_i];
                        sell_rb_next_idx[j]   = sell_rb_idx[b_i];
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Pipelined own-side search (needed only before ST_REST): "is there
    // already a level at exactly reg_price" (match) and "first free
    // slot" (free). Same registered binary-tree shape as the best-price
    // reduction above, run for both sides in parallel. Slot selection
    // does not need to be leftmost - levels are unordered (see header) -
    // so an arbitrary tie-break (prefer the 'a' side of each pair) is
    // fine.
    // ------------------------------------------------------------------
    logic signed [PRICE_W-1:0] reg_price;

    // Sized N_LEVELS for the same reason as buy_rb_valid etc. above.
    logic                buy_rr_match_valid [N_LEVELS];
    logic [LVL_W-1:0]    buy_rr_match_idx   [N_LEVELS];
    logic                buy_rr_free_valid  [N_LEVELS];
    logic [LVL_W-1:0]    buy_rr_free_idx    [N_LEVELS];
    logic                sell_rr_match_valid [N_LEVELS];
    logic [LVL_W-1:0]    sell_rr_match_idx   [N_LEVELS];
    logic                sell_rr_free_valid  [N_LEVELS];
    logic [LVL_W-1:0]    sell_rr_free_idx    [N_LEVELS];

    logic                buy_rr_next_match_valid [N_LEVELS];
    logic [LVL_W-1:0]    buy_rr_next_match_idx   [N_LEVELS];
    logic                buy_rr_next_free_valid  [N_LEVELS];
    logic [LVL_W-1:0]    buy_rr_next_free_idx    [N_LEVELS];
    logic                sell_rr_next_match_valid [N_LEVELS];
    logic [LVL_W-1:0]    sell_rr_next_match_idx   [N_LEVELS];
    logic                sell_rr_next_free_valid  [N_LEVELS];
    logic [LVL_W-1:0]    sell_rr_next_free_idx    [N_LEVELS];

    logic             buy_match_valid_r, buy_free_valid_r;
    logic [LVL_W-1:0] buy_match_idx_r,   buy_free_idx_r;
    logic             sell_match_valid_r, sell_free_valid_r;
    logic [LVL_W-1:0] sell_match_idx_r,   sell_free_idx_r;

    always_comb begin
        int in_width;
        int a_i, b_i;
        logic a_m, b_m, a_f, b_f;
        in_width = N_LEVELS >> rb_level;

        for (int j = 0; j < N_LEVELS; j++) begin
            buy_rr_next_match_valid[j]  = 1'b0;
            buy_rr_next_match_idx[j]    = '0;
            buy_rr_next_free_valid[j]   = 1'b0;
            buy_rr_next_free_idx[j]     = '0;
            sell_rr_next_match_valid[j] = 1'b0;
            sell_rr_next_match_idx[j]   = '0;
            sell_rr_next_free_valid[j]  = 1'b0;
            sell_rr_next_free_idx[j]    = '0;

            // See the matching comment in the best-price reduction block
            // above - the "j < N_LEVELS/2" half is what keeps a_i/b_i
            // provably in-bounds at compile time.
            if (j < N_LEVELS / 2 && j < in_width / 2) begin
                a_i = 2 * j;
                b_i = 2 * j + 1;

                // buy: match
                if (rb_level == 0) begin
                    a_m = buy_valid[a_i] && (buy_price[a_i] == reg_price);
                    b_m = buy_valid[b_i] && (buy_price[b_i] == reg_price);
                    a_f = !buy_valid[a_i];
                    b_f = !buy_valid[b_i];
                end else begin
                    a_m = buy_rr_match_valid[a_i];
                    b_m = buy_rr_match_valid[b_i];
                    a_f = buy_rr_free_valid[a_i];
                    b_f = buy_rr_free_valid[b_i];
                end
                buy_rr_next_match_valid[j] = a_m || b_m;
                buy_rr_next_match_idx[j]   = a_m ? (rb_level == 0 ? a_i[LVL_W-1:0] : buy_rr_match_idx[a_i])
                                                  : (rb_level == 0 ? b_i[LVL_W-1:0] : buy_rr_match_idx[b_i]);
                buy_rr_next_free_valid[j]  = a_f || b_f;
                buy_rr_next_free_idx[j]    = a_f ? (rb_level == 0 ? a_i[LVL_W-1:0] : buy_rr_free_idx[a_i])
                                                  : (rb_level == 0 ? b_i[LVL_W-1:0] : buy_rr_free_idx[b_i]);

                // sell: match/free
                if (rb_level == 0) begin
                    a_m = sell_valid[a_i] && (sell_price[a_i] == reg_price);
                    b_m = sell_valid[b_i] && (sell_price[b_i] == reg_price);
                    a_f = !sell_valid[a_i];
                    b_f = !sell_valid[b_i];
                end else begin
                    a_m = sell_rr_match_valid[a_i];
                    b_m = sell_rr_match_valid[b_i];
                    a_f = sell_rr_free_valid[a_i];
                    b_f = sell_rr_free_valid[b_i];
                end
                sell_rr_next_match_valid[j] = a_m || b_m;
                sell_rr_next_match_idx[j]   = a_m ? (rb_level == 0 ? a_i[LVL_W-1:0] : sell_rr_match_idx[a_i])
                                                   : (rb_level == 0 ? b_i[LVL_W-1:0] : sell_rr_match_idx[b_i]);
                sell_rr_next_free_valid[j]  = a_f || b_f;
                sell_rr_next_free_idx[j]    = a_f ? (rb_level == 0 ? a_i[LVL_W-1:0] : sell_rr_free_idx[a_i])
                                                   : (rb_level == 0 ? b_i[LVL_W-1:0] : sell_rr_free_idx[b_i]);
            end
        end
    end

    // ------------------------------------------------------------------
    // FSM state + latched transaction registers
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_DECODE,
        ST_REDUCE_BEST,
        ST_MATCH,
        ST_POP_LEVEL,
        ST_REDUCE_REST,
        ST_REST,
        ST_DONE
    } state_t;

    state_t state;

    logic [ID_W-1:0]     reg_order_id;
    logic                reg_side;
    logic [QTY_W-1:0]    reg_remaining_qty;
    logic [QTY_W-1:0]    reg_total_filled;
    logic signed [PRICE_W-1:0] reg_last_trade_price;
    logic [ID_W-1:0]     reg_last_trade_id;
    logic                reg_rejected;

    logic [31:0] cycle_counter;
    logic [31:0] start_cycle;
    logic [ID_W-1:0] trade_id_ctr;

    // Latched at the moment ST_MATCH decides to pop the front resting
    // order of the opposite side's best level - consumed one cycle later
    // in ST_POP_LEVEL, once the FIFO shift itself is a synchronous update.
    logic             pop_is_sell;
    logic [LVL_W-1:0] pop_idx;

    // ------------------------------------------------------------------
    // Combinational "what would ST_MATCH do right now" logic, hoisted out
    // of the always_ff so the FSM body only ever reads plain module-level
    // signals. Operates on the already-reduced (registered) best-price
    // winners, so this stays shallow: a side mux, one indexed (16:1-ish)
    // read into the opposite book, and one magnitude compare - nowhere
    // near deep enough to need its own pipeline stage.
    // ------------------------------------------------------------------
    logic                      opp_valid;
    logic signed [PRICE_W-1:0] opp_price;
    logic [LVL_W-1:0]          opp_idx;
    logic                      crosses;
    logic [QTY_W-1:0]          resting_qty;
    logic [QTY_W-1:0]          trade_qty;

    always_comb begin
        if (reg_side == SIDE_BUY) begin
            opp_valid = sell_best_valid_r;
            opp_price = sell_best_price_r;
            opp_idx   = sell_best_idx_r;
            crosses   = opp_valid && (reg_price >= opp_price);
        end else begin
            opp_valid = buy_best_valid_r;
            opp_price = buy_best_price_r;
            opp_idx   = buy_best_idx_r;
            crosses   = opp_valid && (reg_price <= opp_price);
        end

        resting_qty = (reg_side == SIDE_BUY) ? sell_qty[opp_idx][0] : buy_qty[opp_idx][0];
        trade_qty   = (reg_remaining_qty < resting_qty) ? reg_remaining_qty : resting_qty;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            busy          <= 1'b0;
            done_pulse    <= 1'b0;
            trade_id_ctr  <= '0;
            cycle_counter <= 32'd0;
            start_cycle   <= 32'd0;

            reg_order_id          <= '0;
            reg_side               <= 1'b0;
            reg_price               <= '0;
            reg_remaining_qty      <= '0;
            reg_total_filled       <= '0;
            reg_last_trade_price   <= '0;
            reg_last_trade_id      <= '0;
            reg_rejected            <= 1'b0;
            pop_is_sell             <= 1'b0;
            pop_idx                 <= '0;

            rb_level          <= '0;
            buy_best_valid_r  <= 1'b0;
            buy_best_price_r  <= '0;
            buy_best_idx_r    <= '0;
            sell_best_valid_r <= 1'b0;
            sell_best_price_r <= '0;
            sell_best_idx_r   <= '0;

            buy_match_valid_r  <= 1'b0;
            buy_match_idx_r    <= '0;
            buy_free_valid_r   <= 1'b0;
            buy_free_idx_r     <= '0;
            sell_match_valid_r <= 1'b0;
            sell_match_idx_r   <= '0;
            sell_free_valid_r  <= 1'b0;
            sell_free_idx_r    <= '0;

            for (int i = 0; i < N_LEVELS; i++) begin
                buy_rb_valid[i]  <= 1'b0;
                buy_rb_price[i]  <= '0;
                buy_rb_idx[i]    <= '0;
                sell_rb_valid[i] <= 1'b0;
                sell_rb_price[i] <= '0;
                sell_rb_idx[i]   <= '0;
                buy_rr_match_valid[i]  <= 1'b0;
                buy_rr_match_idx[i]    <= '0;
                buy_rr_free_valid[i]   <= 1'b0;
                buy_rr_free_idx[i]     <= '0;
                sell_rr_match_valid[i] <= 1'b0;
                sell_rr_match_idx[i]   <= '0;
                sell_rr_free_valid[i]  <= 1'b0;
                sell_rr_free_idx[i]    <= '0;
            end

            for (int i = 0; i < N_LEVELS; i++) begin
                buy_valid[i]  <= 1'b0;
                buy_count[i]  <= '0;
                sell_valid[i] <= 1'b0;
                sell_count[i] <= '0;
            end

            out_trade_qty       <= '0;
            out_trade_price     <= '0;
            out_trade_id        <= '0;
            out_rejected        <= 1'b0;
            out_latency_cycles  <= '0;
        end else begin
            done_pulse    <= 1'b0;
            cycle_counter <= cycle_counter + 32'd1;

            unique case (state)

                ST_IDLE: begin
                    if (start_pulse) begin
                        reg_order_id <= in_order_id;
                        reg_side     <= in_side;
                        reg_price    <= in_price;
                        start_cycle  <= cycle_counter;
                        busy         <= 1'b1;
                        state        <= ST_DECODE;
                    end
                end

                ST_DECODE: begin
                    reg_remaining_qty     <= in_qty;
                    reg_total_filled      <= '0;
                    reg_last_trade_price  <= '0;
                    reg_last_trade_id     <= '0;
                    reg_rejected          <= 1'b0;
                    rb_level              <= '0;
                    state                 <= ST_REDUCE_BEST;
                end

                ST_REDUCE_BEST: begin
                    for (int i = 0; i < N_LEVELS; i++) begin
                        buy_rb_valid[i]  <= buy_rb_next_valid[i];
                        buy_rb_price[i]  <= buy_rb_next_price[i];
                        buy_rb_idx[i]    <= buy_rb_next_idx[i];
                        sell_rb_valid[i] <= sell_rb_next_valid[i];
                        sell_rb_price[i] <= sell_rb_next_price[i];
                        sell_rb_idx[i]   <= sell_rb_next_idx[i];
                    end
                    if (rb_level == RB_STAGES[RB_CNT_W-1:0] - 1'b1) begin
                        buy_best_valid_r  <= buy_rb_next_valid[0];
                        buy_best_price_r  <= buy_rb_next_price[0];
                        buy_best_idx_r    <= buy_rb_next_idx[0];
                        sell_best_valid_r <= sell_rb_next_valid[0];
                        sell_best_price_r <= sell_rb_next_price[0];
                        sell_best_idx_r   <= sell_rb_next_idx[0];
                        state             <= ST_MATCH;
                    end else begin
                        rb_level <= rb_level + 1'b1;
                    end
                end

                ST_MATCH: begin
                    if (reg_remaining_qty == '0 || !crosses) begin
                        rb_level <= '0;
                        state    <= ST_REDUCE_REST;
                    end else begin
                        reg_total_filled     <= reg_total_filled + trade_qty;
                        reg_last_trade_price <= opp_price;
                        reg_remaining_qty    <= reg_remaining_qty - trade_qty;
                        trade_id_ctr          <= trade_id_ctr + 1'b1;
                        reg_last_trade_id     <= trade_id_ctr + 1'b1;

                        if (trade_qty == resting_qty) begin
                            // Fully consumed the resting order - pop it
                            // next cycle (FIFO shift gets its own
                            // synchronous step).
                            pop_is_sell <= (reg_side == SIDE_BUY);
                            pop_idx     <= opp_idx;
                            state       <= ST_POP_LEVEL;
                        end else begin
                            // Resting order only partially consumed ->
                            // our order is fully filled (trade_qty ==
                            // reg_remaining_qty in this branch). Reduce
                            // the resting order's quantity in place,
                            // preserving its time priority exactly like
                            // OrderBook::modify_order()'s same-price case.
                            if (reg_side == SIDE_BUY)
                                sell_qty[opp_idx][0] <= sell_qty[opp_idx][0] - trade_qty;
                            else
                                buy_qty[opp_idx][0] <= buy_qty[opp_idx][0] - trade_qty;
                            rb_level <= '0;
                            state    <= ST_REDUCE_REST;
                        end
                    end
                end

                ST_POP_LEVEL: begin
                    if (pop_is_sell) begin
                        for (int k = 0; k < M_ORDERS - 1; k++) begin
                            sell_oid[pop_idx][k] <= sell_oid[pop_idx][k+1];
                            sell_qty[pop_idx][k] <= sell_qty[pop_idx][k+1];
                        end
                        sell_count[pop_idx] <= sell_count[pop_idx] - 1'b1;
                        if (sell_count[pop_idx] == 1)
                            sell_valid[pop_idx] <= 1'b0;
                    end else begin
                        for (int k = 0; k < M_ORDERS - 1; k++) begin
                            buy_oid[pop_idx][k] <= buy_oid[pop_idx][k+1];
                            buy_qty[pop_idx][k] <= buy_qty[pop_idx][k+1];
                        end
                        buy_count[pop_idx] <= buy_count[pop_idx] - 1'b1;
                        if (buy_count[pop_idx] == 1)
                            buy_valid[pop_idx] <= 1'b0;
                    end
                    // Book changed - the previous best-price winners may
                    // now be stale, so re-run the reduction before the
                    // next ST_MATCH decision.
                    rb_level <= '0;
                    state    <= ST_REDUCE_BEST;
                end

                ST_REDUCE_REST: begin
                    for (int i = 0; i < N_LEVELS; i++) begin
                        buy_rr_match_valid[i]  <= buy_rr_next_match_valid[i];
                        buy_rr_match_idx[i]    <= buy_rr_next_match_idx[i];
                        buy_rr_free_valid[i]   <= buy_rr_next_free_valid[i];
                        buy_rr_free_idx[i]     <= buy_rr_next_free_idx[i];
                        sell_rr_match_valid[i] <= sell_rr_next_match_valid[i];
                        sell_rr_match_idx[i]   <= sell_rr_next_match_idx[i];
                        sell_rr_free_valid[i]  <= sell_rr_next_free_valid[i];
                        sell_rr_free_idx[i]    <= sell_rr_next_free_idx[i];
                    end
                    if (rb_level == RB_STAGES[RB_CNT_W-1:0] - 1'b1) begin
                        buy_match_valid_r  <= buy_rr_next_match_valid[0];
                        buy_match_idx_r    <= buy_rr_next_match_idx[0];
                        buy_free_valid_r   <= buy_rr_next_free_valid[0];
                        buy_free_idx_r     <= buy_rr_next_free_idx[0];
                        sell_match_valid_r <= sell_rr_next_match_valid[0];
                        sell_match_idx_r   <= sell_rr_next_match_idx[0];
                        sell_free_valid_r  <= sell_rr_next_free_valid[0];
                        sell_free_idx_r    <= sell_rr_next_free_idx[0];
                        state              <= ST_REST;
                    end else begin
                        rb_level <= rb_level + 1'b1;
                    end
                end

                ST_REST: begin
                    if (reg_remaining_qty == '0) begin
                        state <= ST_DONE;
                    end else begin
                        if (reg_side == SIDE_BUY) begin
                            if (buy_match_valid_r && buy_count[buy_match_idx_r] < M_ORDERS) begin
                                buy_oid[buy_match_idx_r][buy_count[buy_match_idx_r]] <= reg_order_id;
                                buy_qty[buy_match_idx_r][buy_count[buy_match_idx_r]] <= reg_remaining_qty;
                                buy_count[buy_match_idx_r] <= buy_count[buy_match_idx_r] + 1'b1;
                            end else if (!buy_match_valid_r && buy_free_valid_r) begin
                                buy_valid[buy_free_idx_r] <= 1'b1;
                                buy_price[buy_free_idx_r] <= reg_price;
                                buy_count[buy_free_idx_r] <= 1;
                                buy_oid[buy_free_idx_r][0] <= reg_order_id;
                                buy_qty[buy_free_idx_r][0] <= reg_remaining_qty;
                            end else begin
                                reg_rejected <= 1'b1;
                            end
                        end else begin
                            if (sell_match_valid_r && sell_count[sell_match_idx_r] < M_ORDERS) begin
                                sell_oid[sell_match_idx_r][sell_count[sell_match_idx_r]] <= reg_order_id;
                                sell_qty[sell_match_idx_r][sell_count[sell_match_idx_r]] <= reg_remaining_qty;
                                sell_count[sell_match_idx_r] <= sell_count[sell_match_idx_r] + 1'b1;
                            end else if (!sell_match_valid_r && sell_free_valid_r) begin
                                sell_valid[sell_free_idx_r] <= 1'b1;
                                sell_price[sell_free_idx_r] <= reg_price;
                                sell_count[sell_free_idx_r] <= 1;
                                sell_oid[sell_free_idx_r][0] <= reg_order_id;
                                sell_qty[sell_free_idx_r][0] <= reg_remaining_qty;
                            end else begin
                                reg_rejected <= 1'b1;
                            end
                        end
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    out_trade_qty      <= reg_total_filled;
                    out_trade_price    <= reg_last_trade_price;
                    out_trade_id       <= reg_last_trade_id;
                    out_rejected       <= reg_rejected;
                    out_latency_cycles <= cycle_counter - start_cycle;
                    done_pulse         <= 1'b1;
                    busy               <= 1'b0;
                    state              <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
