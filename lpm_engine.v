// =============================================================================
// lpm_engine.v
// Longest Prefix Match (LPM) engine — parallel (TCAM-style) IPv4 route lookup
//
// ARCHITECTURE
//   - NUM_ENTRIES parallel comparators, one per routing table entry.
//   - Each entry stores {valid, prefix, prefix_len, next_hop}.
//   - On a lookup, every valid entry is compared against the input IP,
//     masked to that entry's prefix_len, IN PARALLEL (same cycle) — this is
//     the same principle a hardware TCAM uses, modeled here in RTL as an
//     array of masked comparators instead of true CAM cells.
//   - Among all entries that match, a priority-select tree picks the one
//     with the LONGEST prefix_len (that is the definition of LPM routing:
//     the most specific matching route wins). Ties (identical prefix_len)
//     are broken by lowest table index — documented, deterministic policy.
//   - Lookup result is registered (1-cycle latency) for clean timing
//     closure; the match/select logic itself is combinational.
//
// WHY PARALLEL MATCH INSTEAD OF A TRIE:
//   For a small table (tens of entries, as sized here) a fully parallel
//   comparator array is both simpler to verify and faster (fixed 1-cycle
//   latency regardless of table contents) than a trie walk, at the cost of
//   O(N) comparators. Real router ASICs use actual TCAM cells for exactly
//   this reason at small-to-medium scale; large IPv6 tables move to
//   trie/tree-bitmap or hash-based schemes to control power (see
//   "advancements" notes in the project README) since exhaustive parallel
//   compare over 500K+ entries is a TCAM-power/area problem.
//
// CONFIG INTERFACE:
//   Single write port to add/update/invalidate one table entry per cycle
//   (models CPU/control-plane programming the FIB into the data-plane
//   lookup table — the RIB → FIB push described in the networking notes).
// =============================================================================

module lpm_engine #(
    parameter NUM_ENTRIES = 32,
    parameter ADDR_WIDTH  = 32,   // IPv4 address width
    parameter NH_WIDTH    = 8,    // next-hop / output-port ID width
    parameter IDX_WIDTH   = (NUM_ENTRIES <= 1) ? 1 : $clog2(NUM_ENTRIES)
) (
    input  wire                     clk,
    input  wire                     rst,

    // ---------------- Config / table write port ----------------
    input  wire                     cfg_wr_en,
    input  wire [IDX_WIDTH-1:0]     cfg_index,
    input  wire [ADDR_WIDTH-1:0]    cfg_prefix,
    input  wire [5:0]               cfg_prefix_len,  // 0..32 (0 = default route)
    input  wire [NH_WIDTH-1:0]      cfg_next_hop,
    input  wire                     cfg_entry_valid, // 0 = invalidate this entry

    // ---------------- Lookup port ----------------
    input  wire                     lookup_val,
    input  wire [ADDR_WIDTH-1:0]    lookup_ip,

    // ---------------- Result (registered, 1 cycle after lookup_val) --------
    output reg                      result_val,
    output reg                      result_hit,
    output reg  [NH_WIDTH-1:0]      result_next_hop,
    output reg  [5:0]               result_prefix_len,  // debug/observability
    output reg  [IDX_WIDTH-1:0]     result_index         // debug/observability
);

    // -----------------------------------------------------------------
    // Table storage
    // -----------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] tbl_prefix     [0:NUM_ENTRIES-1];
    reg [5:0]             tbl_prefix_len[0:NUM_ENTRIES-1];
    reg [NH_WIDTH-1:0]    tbl_next_hop  [0:NUM_ENTRIES-1];
    reg                   tbl_valid     [0:NUM_ENTRIES-1];

    integer ri;
    always @(posedge clk) begin
        if (rst) begin
            for (ri = 0; ri < NUM_ENTRIES; ri = ri + 1)
                tbl_valid[ri] <= 1'b0;
        end else if (cfg_wr_en) begin
            tbl_prefix[cfg_index]      <= cfg_prefix;
            tbl_prefix_len[cfg_index]  <= cfg_prefix_len;
            tbl_next_hop[cfg_index]    <= cfg_next_hop;
            tbl_valid[cfg_index]       <= cfg_entry_valid;
        end
    end

    // -----------------------------------------------------------------
    // Mask generation: top prefix_len bits set, rest zero
    // -----------------------------------------------------------------
    function [ADDR_WIDTH-1:0] len_to_mask;
        input [5:0] len;
        begin
            if (len == 0)
                len_to_mask = {ADDR_WIDTH{1'b0}};
            else
                len_to_mask = {ADDR_WIDTH{1'b1}} << (ADDR_WIDTH - len);
        end
    endfunction

    // -----------------------------------------------------------------
    // Parallel match (combinational) — one comparator per table entry
    // -----------------------------------------------------------------
    wire [NUM_ENTRIES-1:0] match;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_ENTRIES; gi = gi + 1) begin : GEN_MATCH
            wire [ADDR_WIDTH-1:0] mask_g = len_to_mask(tbl_prefix_len[gi]);
            assign match[gi] = tbl_valid[gi] &&
                                ((lookup_ip & mask_g) == (tbl_prefix[gi] & mask_g));
        end
    endgenerate

    // -----------------------------------------------------------------
    // Priority select: among matching entries, pick the one with the
    // LONGEST prefix_len. Tie -> lowest index wins (deterministic policy).
    // -----------------------------------------------------------------
    reg                  sel_hit;
    reg [IDX_WIDTH-1:0]  sel_index;
    reg [5:0]            sel_len;
    reg [NH_WIDTH-1:0]   sel_next_hop;

    integer si;
    always @(*) begin
        sel_hit      = 1'b0;
        sel_index    = {IDX_WIDTH{1'b0}};
        sel_len      = 6'd0;
        sel_next_hop = {NH_WIDTH{1'b0}};
        for (si = 0; si < NUM_ENTRIES; si = si + 1) begin
            if (match[si] && (!sel_hit || tbl_prefix_len[si] > sel_len)) begin
                sel_hit      = 1'b1;
                sel_index    = si[IDX_WIDTH-1:0];
                sel_len      = tbl_prefix_len[si];
                sel_next_hop = tbl_next_hop[si];
            end
        end
    end

    // -----------------------------------------------------------------
    // Register the result for clean timing closure (1-cycle lookup latency)
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            result_val         <= 1'b0;
            result_hit          <= 1'b0;
            result_next_hop     <= {NH_WIDTH{1'b0}};
            result_prefix_len   <= 6'd0;
            result_index        <= {IDX_WIDTH{1'b0}};
        end else begin
            result_val          <= lookup_val;
            result_hit           <= sel_hit;
            result_next_hop      <= sel_next_hop;
            result_prefix_len    <= sel_len;
            result_index         <= sel_index;
        end
    end

endmodule

// =============================================================================
// ADVANCEMENT HOOKS (see README "More advancements" section for full detail):
//   - Swap the parallel-comparator table for a multi-bit trie / tree-bitmap
//     structure to scale past a few hundred entries without O(N) power.
//   - Add a shadow table + atomic pointer swap for hitless route updates.
//   - Extend ADDR_WIDTH to 128 for IPv6, and add VRF/table-ID tagging for
//     multi-context (multi-tenant routing) lookups.
//   - Pipeline the priority-select tree (currently a single-cycle for-loop)
//     across 2-3 stages for higher NUM_ENTRIES / higher clock targets.
// =============================================================================
