`timescale 1ns/1ps

module tb_lpm_engine;

    localparam NUM_ENTRIES = 32;
    localparam ADDR_WIDTH  = 32;
    localparam NH_WIDTH    = 8;
    localparam IDX_WIDTH   = 5;

    reg clk = 0;
    reg rst;

    reg                  cfg_wr_en;
    reg  [IDX_WIDTH-1:0] cfg_index;
    reg  [ADDR_WIDTH-1:0]cfg_prefix;
    reg  [5:0]           cfg_prefix_len;
    reg  [NH_WIDTH-1:0]  cfg_next_hop;
    reg                  cfg_entry_valid;

    reg                  lookup_val;
    reg  [ADDR_WIDTH-1:0]lookup_ip;

    wire                 result_val;
    wire                 result_hit;
    wire [NH_WIDTH-1:0]  result_next_hop;
    wire [5:0]           result_prefix_len;
    wire [IDX_WIDTH-1:0] result_index;

    lpm_engine #(
        .NUM_ENTRIES(NUM_ENTRIES),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NH_WIDTH(NH_WIDTH)
    ) dut (
        .clk(clk), .rst(rst),
        .cfg_wr_en(cfg_wr_en), .cfg_index(cfg_index),
        .cfg_prefix(cfg_prefix), .cfg_prefix_len(cfg_prefix_len),
        .cfg_next_hop(cfg_next_hop), .cfg_entry_valid(cfg_entry_valid),
        .lookup_val(lookup_val), .lookup_ip(lookup_ip),
        .result_val(result_val), .result_hit(result_hit),
        .result_next_hop(result_next_hop),
        .result_prefix_len(result_prefix_len),
        .result_index(result_index)
    );

    always #5 clk = ~clk;

    // -----------------------------------------------------------------
    // Software reference model — a plain-Verilog "golden" table mirror
    // -----------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] ref_prefix     [0:NUM_ENTRIES-1];
    reg [5:0]             ref_prefix_len[0:NUM_ENTRIES-1];
    reg [NH_WIDTH-1:0]    ref_next_hop  [0:NUM_ENTRIES-1];
    reg                   ref_valid     [0:NUM_ENTRIES-1];

    integer i;
    initial for (i = 0; i < NUM_ENTRIES; i = i + 1) ref_valid[i] = 1'b0;

    function [ADDR_WIDTH-1:0] mask_of;
        input [5:0] len;
        begin
            if (len == 0) mask_of = {ADDR_WIDTH{1'b0}};
            else mask_of = {ADDR_WIDTH{1'b1}} << (ADDR_WIDTH - len);
        end
    endfunction

    task automatic write_entry(
        input [IDX_WIDTH-1:0] idx,
        input [ADDR_WIDTH-1:0] pfx,
        input [5:0] plen,
        input [NH_WIDTH-1:0] nh,
        input valid
    );
        begin
            @(negedge clk);
            cfg_wr_en = 1; cfg_index = idx; cfg_prefix = pfx;
            cfg_prefix_len = plen; cfg_next_hop = nh; cfg_entry_valid = valid;
            @(negedge clk);
            cfg_wr_en = 0;
            ref_prefix[idx] = pfx; ref_prefix_len[idx] = plen;
            ref_next_hop[idx] = nh; ref_valid[idx] = valid;
        end
    endtask

    // Reference LPM computation, same tie-break policy as the RTL
    // (longest prefix wins, ties broken by lowest index).
    task automatic ref_lookup(
        input  [ADDR_WIDTH-1:0] ip,
        output exp_hit,
        output [NH_WIDTH-1:0] exp_nh,
        output [5:0] exp_len
    );
        integer k;
        reg hit_v;
        reg [5:0] best_len;
        reg [NH_WIDTH-1:0] best_nh;
        begin
            hit_v = 1'b0; best_len = 0; best_nh = 0;
            for (k = 0; k < NUM_ENTRIES; k = k + 1) begin
                if (ref_valid[k] &&
                    ((ip & mask_of(ref_prefix_len[k])) == (ref_prefix[k] & mask_of(ref_prefix_len[k])))) begin
                    if (!hit_v || ref_prefix_len[k] > best_len) begin
                        hit_v = 1'b1;
                        best_len = ref_prefix_len[k];
                        best_nh = ref_next_hop[k];
                    end
                end
            end
            exp_hit = hit_v; exp_nh = best_nh; exp_len = best_len;
        end
    endtask

    integer errors = 0;
    integer checks = 0;

    task automatic do_lookup_check(input [ADDR_WIDTH-1:0] ip);
        reg exp_hit;
        reg [NH_WIDTH-1:0] exp_nh;
        reg [5:0] exp_len;
        begin
            ref_lookup(ip, exp_hit, exp_nh, exp_len);
            @(negedge clk);
            lookup_val = 1; lookup_ip = ip;
            @(negedge clk);
            // The posedge between the two negedges above has already
            // registered the result (1-cycle latency), so it is valid now.
            lookup_val = 0;
            checks = checks + 1;
            if (result_val !== 1'b1) begin
                $display("[%0t] ERROR: result_val not asserted for ip=%h", $time, ip);
                errors = errors + 1;
            end else if (result_hit !== exp_hit) begin
                $display("[%0t] ERROR: ip=%h expected hit=%b got hit=%b", $time, ip, exp_hit, result_hit);
                errors = errors + 1;
            end else if (exp_hit && (result_next_hop !== exp_nh)) begin
                $display("[%0t] ERROR: ip=%h expected nh=%0d got nh=%0d (exp_len=%0d got_len=%0d)",
                          $time, ip, exp_nh, result_next_hop, exp_len, result_prefix_len);
                errors = errors + 1;
            end
        end
    endtask

    integer r;
    reg [ADDR_WIDTH-1:0] rnd_ip;

    initial begin
        rst = 1; cfg_wr_en = 0; lookup_val = 0;
        cfg_index = 0; cfg_prefix = 0; cfg_prefix_len = 0;
        cfg_next_hop = 0; cfg_entry_valid = 0; lookup_ip = 0;
        repeat (3) @(negedge clk);
        rst = 0;

        // -------------------------------------------------------------
        // Directed test: classic LPM scenario
        //   entry0: 0.0.0.0/0        -> next_hop 0  (default route)
        //   entry1: 10.0.0.0/8       -> next_hop 1
        //   entry2: 10.1.0.0/16      -> next_hop 2  (more specific)
        //   entry3: 10.1.2.0/24      -> next_hop 3  (most specific)
        //   entry4: 10.1.2.128/25    -> next_hop 4  (most specific still)
        // -------------------------------------------------------------
        write_entry(0, 32'h00000000, 6'd0,  8'd0, 1);
        write_entry(1, 32'h0A000000, 6'd8,  8'd1, 1);
        write_entry(2, 32'h0A010000, 6'd16, 8'd2, 1);
        write_entry(3, 32'h0A010200, 6'd24, 8'd3, 1);
        write_entry(4, 32'h0A010280, 6'd25, 8'd4, 1);

        // 10.1.2.200 -> matches /8, /16, /24? no (200 not in .0/24... wait 10.1.2.200 IS in 10.1.2.0/24)
        // and in 10.1.2.128/25 (200 = 0xC8, top bit of last octet set -> in .128/25) -> expect next_hop 4 (longest)
        do_lookup_check(32'h0A0102C8); // 10.1.2.200

        // 10.1.2.50 -> in /24 (10.1.2.0/24) but NOT in /25 (.128/25, since 50<128) -> expect next_hop 3
        do_lookup_check(32'h0A010232); // 10.1.2.50

        // 10.1.5.9 -> in /16 (10.1.0.0/16) but not /24 -> expect next_hop 2
        do_lookup_check(32'h0A010509);

        // 10.9.9.9 -> in /8 only -> expect next_hop 1
        do_lookup_check(32'h0A090909);

        // 8.8.8.8 -> no specific match, hits default /0 -> expect next_hop 0
        do_lookup_check(32'h08080808);

        // -------------------------------------------------------------
        // Corner case: exact host route /32 beats everything
        // -------------------------------------------------------------
        write_entry(5, 32'h0A010203, 6'd32, 8'd9, 1); // 10.1.2.3/32 -> next_hop 9
        do_lookup_check(32'h0A010203); // expect next_hop 9 (host route wins)
        do_lookup_check(32'h0A010204); // just next door -> falls back to /24 -> next_hop 3

        // -------------------------------------------------------------
        // Corner case: invalidate an entry, must stop matching it
        // -------------------------------------------------------------
        write_entry(5, 32'h0A010203, 6'd32, 8'd9, 0); // invalidate host route
        do_lookup_check(32'h0A010203); // now falls back to /25 -> next_hop 4? .3 is <128 so /24 -> next_hop3
                                        // wait 10.1.2.3 is in /24 (10.1.2.0/24) and NOT in /25 (.128/25 since 3<128)
                                        // -> expect next_hop 3

        // -------------------------------------------------------------
        // Corner case: no match at all (clear default route)
        // -------------------------------------------------------------
        write_entry(0, 32'h00000000, 6'd0, 8'd0, 0); // invalidate default route
        do_lookup_check(32'hFF000001); // no entry covers this -> expect miss
        write_entry(0, 32'h00000000, 6'd0, 8'd0, 1); // restore default route

        // -------------------------------------------------------------
        // Randomized regression: random table + random lookups
        // -------------------------------------------------------------
        for (i = 0; i < NUM_ENTRIES; i = i + 1) begin
            write_entry(
                i[IDX_WIDTH-1:0],
                $urandom,
                $urandom_range(0,32),
                $urandom_range(0,255),
                $urandom_range(0,1)
            );
        end
        for (r = 0; r < 500; r = r + 1) begin
            rnd_ip = $urandom;
            do_lookup_check(rnd_ip);
        end

        // -------------------------------------------------------------
        // Final report
        // -------------------------------------------------------------
        $display("---------------------------------------------------");
        $display("Total lookups checked : %0d", checks);
        $display("Errors                : %0d", errors);
        if (errors == 0)
            $display("RESULT: PASS - LPM engine matches reference model on all lookups");
        else
            $display("RESULT: FAIL");
        $display("---------------------------------------------------");
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
