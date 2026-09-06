# LPM Engine — Longest Prefix Match IP Lookup

A parallel, TCAM-style Longest Prefix Match engine for IPv4 route lookup, written and self-verified
in Verilog. Built as a datapath project demonstrating router-style hardware lookup, an area/latency
tradeoff-driven architecture choice, and reference-model-based verification with directed corner
cases and randomized regression.

---

## 1. Problem statement

Given a routing table of `(prefix, prefix_length, next_hop)` entries and an incoming 32-bit IPv4
destination address, find the entry whose prefix **matches the most specific (longest) number of
leading bits** of the address, and return its `next_hop`. This is literally how every IP router on
the internet decides where to send a packet — it's the FIB lookup sitting on the fast path of every
router ASIC.

Example table:

| Index | Prefix/Length | Next hop |
|---|---|---|
| 0 | `0.0.0.0/0` (default) | 0 |
| 1 | `10.0.0.0/8` | 1 |
| 2 | `10.1.0.0/16` | 2 |
| 3 | `10.1.2.0/24` | 3 |
| 4 | `10.1.2.128/25` | 4 |

A lookup for `10.1.2.200` matches entries 0, 1, 2, 3, and 4 — but only the **longest** matching
prefix (entry 4, `/25`) is correct. This is the core difficulty: multiple entries can match
simultaneously, and the hardware must pick the most specific one, every cycle, without ambiguity.

---

## 2. Design procedure

*(Tap through the interactive flowchart shared alongside this note for the same steps with
click-through detail.)*

1. **Define the spec** — 32-bit IPv4 address, configurable table size (`NUM_ENTRIES`, implemented
   with 32), configurable next-hop width, one lookup per cycle, one table-write per cycle.
2. **Choose the algorithm** — parallel (TCAM-style) compare vs. trie walk vs. hash-based lookup.
   Chose parallel compare for this scale (see Section 4, Design Decisions).
3. **Design the table entry format** — `{valid, prefix, prefix_len, next_hop}` per entry.
4. **Design match + priority-select logic** — mask-and-compare per entry, then a priority reduction
   that picks the longest matching `prefix_len` (ties broken by lowest index — a documented,
   deterministic policy, not an arbitrary race).
5. **Design the config/update interface** — a single write port that programs one entry per cycle,
   modeling how a control-plane CPU pushes the computed FIB down into data-plane lookup hardware
   (the RIB → FIB step from standard router architecture).
6. **Write the RTL** — table storage, per-entry comparators (`generate` loop), priority-select
   (`always @(*)` reduction), and a registered output stage for timing closure.
7. **Verify against a software reference model** — a plain-Verilog mirror of the table computes the
   expected answer independently or every lookup, and the testbench compares the DUT's registered
   result against it, cycle by cycle. Directed corner cases first, then randomized regression.
8. **Optimize area/timing** — discussed in Section 6.
9. **Document and present** — this README, the block diagram, and the flowchart.

---

## 3. Architecture / block diagram

*(See the accompanying block diagram widget for the visual version.)*

```
                 cfg_wr_en / index / prefix / len / next_hop
                                  │
                                  ▼
                        ┌───────────────────┐
                        │   Table storage   │   N x {valid, prefix,
                        │                   │        prefix_len, next_hop}
                        └─────────┬─────────┘
                                  │  (broadcast lookup_ip to all entries)
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
        ┌───────────┐       ┌───────────┐       ┌─────────────┐
        │  Entry 0  │       │  Entry 1  │  ...  │ Entry N-1   │
        │masked cmp │       │masked cmp │       │ masked cmp  │
        └─────┬─────┘       └─────┬─────┘       └──────┬──────┘
              │  match[0]         │  match[1]          │ match[N-1]
              └───────────────────┼────────────────────┘
                                  ▼
                          ┌───────────────────┐
                          │  Priority select  │  longest prefix_len
                          │                   │  wins; tie = lowest idx
                          └─────────┬─────────┘
                                    ▼
                          ┌───────────────────┐
                          │  Output register  │  1-cycle lookup latency
                          └─────────┬─────────┘
                                    ▼
                result_val / result_hit / result_next_hop / result_prefix_len
```

### Interface summary

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `clk`, `rst` | in | 1 | clock, synchronous reset |
| `cfg_wr_en` | in | 1 | write one table entry this cycle |
| `cfg_index` | in | `IDX_WIDTH` | which table row to write |
| `cfg_prefix` | in | 32 | prefix bits for that row |
| `cfg_prefix_len` | in | 6 | 0–32, prefix length |
| `cfg_next_hop` | in | `NH_WIDTH` | next-hop / output-port ID for that row |
| `cfg_entry_valid` | in | 1 | 0 invalidates the row |
| `lookup_val` | in | 1 | perform a lookup this cycle |
| `lookup_ip` | in | 32 | destination IP to look up |
| `result_val` | out | 1 | lookup result valid (1 cycle after `lookup_val`) |
| `result_hit` | out | 1 | 1 if any entry matched |
| `result_next_hop` | out | `NH_WIDTH` | selected next hop |
| `result_prefix_len` | out | 6 | matched prefix length (debug/observability) |
| `result_index` | out | `IDX_WIDTH` | matched table row (debug/observability) |

---

## 4. Design decisions (be ready to justify these out loud)

**Why parallel/TCAM-style match instead of a trie?**
For a small table (tens of entries, as implemented — `NUM_ENTRIES = 32`), a fully parallel
comparator array gives a fixed 1-cycle lookup latency regardless of table contents or which entry
matches, and is simpler to verify (no pointer-chasing FSM). This mirrors what real hardware TCAMs
do at small-to-medium table sizes. The cost is `O(N)` comparators — fine at 32 entries, prohibitive
in area/power at hundreds of thousands of entries (see Section 7 for how real routers handle that
scale).

**Why register the output instead of leaving it combinational?**
The match + priority-select logic is a wide combinational reduction across all `N` entries — at
larger `N` this becomes the critical path. Registering the result decouples lookup throughput
(pipelined) from that combinational depth, at the cost of 1 cycle of latency. This is the same
timing-closure argument used for the crossbar output register in the companion `switch_8x8` project.

**Why "longest prefix wins, tie = lowest index" as the priority policy?**
Longest-prefix-wins is not a choice — it's the definition of correct IP routing (RFC 1519 / CIDR).
The tie-break (identical `prefix_len`, which shouldn't happen in a well-formed routing table, since
two different prefixes of the same length can't both contain the same address unless they're
literally the same prefix) is a defensive, deterministic fallback rather than an X-propagation risk
— worth mentioning if asked "what if two entries tie?"

**Why a single write port for config, not a multi-port table?**
Route table updates happen far less often than lookups (control-plane events, not per-packet), so a
single write port matches real traffic patterns and keeps the write path cheap — same 90/10
reasoning used to size the FIFO depth in the `switch_8x8` project relative to its 40% traffic load.

---

## 5. Verification approach and results

- **Software reference model**: a second, independent Verilog table + linear-scan lookup function
  in the testbench, mirroring every write the DUT receives, computing the same longest-prefix
  answer via the same tie-break policy. Every DUT lookup is checked against this model — this is a
  scoreboard, the same verification pattern used in the `switch_8x8` project.
- **Directed corner cases**:
  - classic overlapping-prefix chain (`/0`, `/8`, `/16`, `/24`, `/25`) — checks the longest match is
    correctly selected at every specificity level
  - exact host route (`/32`) overriding all shorter matches
  - entry invalidation — a previously-matching entry must stop matching once invalidated
  - no-match case — lookup must report `result_hit = 0` when nothing in the table covers the
    address (e.g. after removing the default route)
- **Randomized regression**: 32 entries programmed with random prefixes/lengths/next-hops/validity,
  followed by 500 random IP lookups, each checked against the reference model.
- **Result**: 509 total lookups checked (9 directed + 500 random), **0 errors** — full match against
  the reference model, including every corner case above.

---

## 6. Area / timing notes

- Comparator count scales linearly with `NUM_ENTRIES` — the dominant area cost at this table size.
- The priority-select reduction is a linear scan (`for` loop) in this implementation — synthesizes
  to a reduction tree; at larger `N` this should be explicitly pipelined (see Advancements) rather
  than left as one large combinational block, to keep `Fmax` independent of table size.
- The mask generation (`len_to_mask`) is a barrel-shift-by-constant per entry, computed once and
  reused for both the write path and (implicitly) resynthesized per comparator — an area/timing
  knob if resource sharing across entries becomes worthwhile at larger scale.

---

## 7. More advancements (how this scales toward a real router FIB)

This 32-entry parallel design is intentionally a *minimal, provably correct* starting point. A real
router's FIB has to handle 500K+ IPv4 entries and full IPv6 tables, which changes the right
architecture entirely. Talking through these shows you understand the scaling story, not just the
toy version:

1. **Trie-based lookup (multi-bit trie / Patricia trie)** — replace the O(N) parallel compare with a
   tree walk, trading fixed 1-cycle latency for O(log N) cycles but far better area/power scaling.
2. **Tree Bitmap algorithm** (Eatherton et al.) — the real technique most SRAM-based router lookup
   engines use: compresses a multi-bit trie into bitmap-indexed SRAM lookups, avoiding TCAM's power
   cost while staying fast. Good one-line answer if asked "how would you actually build this at
   scale": *"Move from parallel TCAM compare to a tree-bitmap structure in SRAM — same LPM
   semantics, far better power/area at hundreds of thousands of entries."*
3. **Hitless / non-blocking table updates** — a shadow table plus atomic pointer swap, so route
   updates from the control plane never stall or corrupt an in-flight lookup (directly relevant to
   DV: this is exactly the kind of race condition a verification engineer is hired to catch).
4. **IPv6 support** — extend `ADDR_WIDTH` to 128 bits; the comparator/mask logic is unchanged in
   principle, but the mask-generation and storage cost roughly quadruple, reinforcing why parallel
   compare doesn't scale and a trie/tree-bitmap approach becomes necessary.
5. **Multi-context / VRF lookups** — tag each entry (or use separate table instances) with a
   VRF/table-ID so the same physical lookup engine serves multiple isolated routing contexts
   (common in provider-edge routers — squarely in Juniper's product space).
6. **Pipelining the priority-select tree** — split the linear-scan reduction into 2–3 pipeline
   stages (e.g. reduce in groups of 8, then reduce the group winners) so `Fmax` stays high as
   `NUM_ENTRIES` grows, instead of one large combinational reduction.
7. **Route caching** — cache recently-looked-up destinations in a small fast table in front of the
   full FIB, since real traffic exhibits strong locality — trades a cache-coherency verification
   problem for average-case latency improvement.
8. **UVM-ify this testbench** — replace the directed/random Verilog testbench with a UVM
   environment (driver/monitor/scoreboard/sequences) plus functional coverage on prefix-length
   distribution, overlap depth, and hit/miss ratio — the natural next step for this project,
   mirroring the same upgrade path suggested for the `switch_8x8` project.

---

## 8. Files in this project

| File | Purpose |
|---|---|
| `lpm_engine.v` | Top-level synthesizable RTL — table storage, parallel match, priority select, registered output |
| `tb_lpm_engine.v` | Self-checking testbench — software reference model, directed corner cases, randomized regression |
| `lpm_engine_block_diagram` (widget) | Architecture block diagram |
| `lpm_engine_design_procedure_flowchart` (widget) | Design procedure flowchart |
| This README | Full write-up for interview presentation |

**How to simulate** (Icarus Verilog):
```
iverilog -g2012 -o sim_lpm.out lpm_engine.v tb_lpm_engine.v
vvp sim_lpm.out
```
Expected output ends with `RESULT: PASS - LPM engine matches reference model on all lookups`.
