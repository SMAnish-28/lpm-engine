# LPM Engine — Longest Prefix Match IP Lookup

[![Verilog](https://img.shields.io/badge/HDL-Verilog-blue)]()
[![Simulator](https://img.shields.io/badge/tested%20with-Icarus%20Verilog-green)]()
[![Status](https://img.shields.io/badge/tests-509%2F509%20passing-brightgreen)]()

A parallel, TCAM-style **Longest Prefix Match (LPM)** engine for IPv4 route lookup, written and
self-verified in Verilog. This is a **datapath project**: it models the core lookup stage of a
router's Packet Forwarding Engine — the same operation that decides, for every packet, which output
port to send it out on based on the destination IP address.

Built to demonstrate:
- A router-style hardware lookup (mask-and-compare, longest-prefix-wins)
- An area/latency tradeoff-driven architecture choice (parallel compare vs. trie vs. hash)
- Reference-model-based verification with directed corner cases + randomized regression

---

## Table of contents

- [Problem statement](#problem-statement)
- [Architecture](#architecture)
- [Interface](#interface)
- [Design decisions](#design-decisions)
- [Verification](#verification)
- [Area / timing notes](#area--timing-notes)
- [Repo structure](#repo-structure)
- [Getting started](#getting-started)
- [Roadmap / advancements](#roadmap--advancements)
- [License](#license)

---

## Problem statement

Given a routing table of `(prefix, prefix_length, next_hop)` entries and an incoming 32-bit IPv4
destination address, find the entry whose prefix matches the **most specific (longest)** number of
leading bits of the address, and return its `next_hop`. This is exactly how every IP router decides
where to forward a packet — the FIB lookup on the fast path of every router ASIC.

Example table:

| Index | Prefix/Length | Next hop |
|---|---|---|
| 0 | `0.0.0.0/0` (default) | 0 |
| 1 | `10.0.0.0/8` | 1 |
| 2 | `10.1.0.0/16` | 2 |
| 3 | `10.1.2.0/24` | 3 |
| 4 | `10.1.2.128/25` | 4 |

A lookup for `10.1.2.200` matches entries 0, 1, 2, 3, **and** 4 — only the **longest** matching
prefix (entry 4, `/25`) is correct. Multiple entries matching simultaneously, resolved
deterministically every cycle, is the core difficulty this design solves.

---

## Architecture

```
                 cfg_wr_en / index / prefix / len / next_hop
                                  │
                                  ▼
                        ┌─────────────────────┐
                        │    Table storage    │   N x {valid, prefix,
                        │                     │        prefix_len, next_hop}
                        └──────────┬──────────┘
                                   │  (broadcast lookup_ip to all entries)
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
        ┌───────────┐        ┌───────────┐         ┌─────────────┐
        │  Entry 0  │        │  Entry 1  │  ...    │ Entry N-1   │
        │ masked cmp│        │ masked cmp│         │ masked cmp  │
        └─────┬─────┘        └─────┬─────┘         └──────┬──────┘
              │ match[0]           │ match[1]             │ match[N-1]
              └────────────────────┴──────────────────────┘
                                   ▼
                          ┌──────────────────────┐
                          │   Priority select    │  longest prefix_len
                          │                      │  wins; tie = lowest idx
                          └───────────┬──────────┘
                                      ▼
                          ┌──────────────────────┐
                          │   Output register    │  1-cycle lookup latency
                          └───────────┬──────────┘
                                      ▼
                result_val / result_hit / result_next_hop / result_prefix_len
```

**Pipeline:** table write and lookup match are combinational; the final result is registered, giving
a fixed 1-cycle lookup latency independent of which entry (or how many entries) matched.

---

## Interface

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

Parameters: `NUM_ENTRIES` (default 32), `ADDR_WIDTH` (default 32, IPv4), `NH_WIDTH` (default 8).

---

## Design decisions

**Why parallel/TCAM-style match instead of a trie?**
At this table size (tens of entries), a fully parallel comparator array gives a fixed 1-cycle lookup
latency regardless of table contents or which entry matches, and is simpler to verify than a
pointer-chasing trie walk. This mirrors what real hardware TCAMs do at small-to-medium table sizes.
The cost is `O(N)` comparators — fine at 32 entries, prohibitive in area/power at hundreds of
thousands of entries (see [Roadmap](#roadmap--advancements)).

**Why register the output instead of leaving it combinational?**
The match + priority-select logic is a wide combinational reduction across all `N` entries — at
larger `N` this becomes the critical path. Registering the result decouples lookup throughput from
that combinational depth, at the cost of 1 cycle of latency.

**Why "longest prefix wins, tie = lowest index"?**
Longest-prefix-wins is the definition of correct IP routing (RFC 1519 / CIDR), not a design choice.
The tie-break (identical `prefix_len` — which shouldn't occur in a well-formed table, since two
different prefixes of the same length can't both contain the same address unless they're literally
identical) is a defensive, deterministic fallback rather than an ambiguous race.

**Why a single write port for the config interface?**
Route table updates happen far less often than lookups (control-plane events, not per-packet), so a
single write port matches real traffic patterns and keeps the write path cheap.

---

## Verification

- **Reference model**: an independent Verilog table + linear-scan lookup function in the testbench
  mirrors every write the DUT receives and computes the expected longest-prefix answer using the
  same tie-break policy. Every DUT lookup is checked against this model.
- **Directed corner cases**:
  - overlapping-prefix chain (`/0`, `/8`, `/16`, `/24`, `/25`) — longest match at every specificity level
  - exact host route (`/32`) overriding all shorter matches
  - entry invalidation — a previously-matching entry stops matching once invalidated
  - no-match case — `result_hit = 0` when nothing in the table covers the address
- **Randomized regression**: 32 entries with random prefixes/lengths/next-hops/validity, then 500
  random IP lookups, each checked against the reference model.

**Result: 509/509 lookups passed (9 directed + 500 random), 0 mismatches.**

```
---------------------------------------------------
Total lookups checked : 509
Errors                : 0
RESULT: PASS - LPM engine matches reference model on all lookups
---------------------------------------------------
```

---

## Area / timing notes

- Comparator count scales linearly with `NUM_ENTRIES` — the dominant area cost at this scale.
- The priority-select reduction (a `for`-loop scan) synthesizes to a reduction tree; at larger `N`
  it should be explicitly pipelined rather than left as one large combinational block, to keep
  `Fmax` independent of table size.
- Mask generation (`len_to_mask`) is a per-entry constant barrel shift — a resource-sharing
  candidate if area becomes the binding constraint at larger table sizes.

---

## Repo structure

```
.
├── README.md            # this file
├── lpm_engine.v          # synthesizable RTL: table, comparators, priority-select, output register
└── tb_lpm_engine.v       # self-checking testbench: reference model, directed + randomized tests
```

---

## Getting started

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog` / `vvp`).

```bash
git clone <this-repo-url>
cd <this-repo>
iverilog -g2012 -o sim_lpm.out lpm_engine.v tb_lpm_engine.v
vvp sim_lpm.out
```

Expected output ends with:
```
RESULT: PASS - LPM engine matches reference model on all lookups
```

---

## Roadmap / advancements

This 32-entry parallel design is intentionally a *minimal, provably correct* starting point. A real
router's FIB handles 500K+ IPv4 entries plus full IPv6 tables, which calls for a different
architecture at scale:

- [ ] **Trie-based lookup** (multi-bit trie / Patricia trie) — trade fixed 1-cycle latency for
      O(log N) cycles, with far better area/power scaling
- [ ] **Tree Bitmap algorithm** (Eatherton et al.) — the technique most SRAM-based router lookup
      engines actually use: compresses a multi-bit trie into bitmap-indexed SRAM lookups, avoiding
      TCAM's power cost while staying fast
- [ ] **Hitless / non-blocking table updates** — shadow table + atomic pointer swap so control-plane
      route updates never stall or corrupt an in-flight lookup
- [ ] **IPv6 support** — extend `ADDR_WIDTH` to 128 bits
- [ ] **Multi-context / VRF lookups** — per-entry table-ID tagging for isolated routing contexts
- [ ] **Pipeline the priority-select tree** — split the linear scan into 2–3 pipeline stages so
      `Fmax` stays high as `NUM_ENTRIES` grows
- [ ] **Route caching** — small fast cache in front of the full FIB, exploiting traffic locality
- [ ] **UVM testbench** — replace the directed/random Verilog testbench with a UVM environment
      (driver/monitor/scoreboard/sequences) plus functional coverage on prefix-length distribution,
      overlap depth, and hit/miss ratio

---

## License

MIT — see `LICENSE` (add one if this repo doesn't have it yet).
