# Libero Wire Format Benchmarks

Compares ETF (Erlang Term Format) vs JSON for Libero's RPC wire format.

## Methodology

Both benchmarks faithfully mirror the real encode/decode paths:

- **ETF encode:** `erlang:term_to_binary/1` (single C-level BIF) - matches `wire.gleam`
- **ETF decode (server):** `erlang:binary_to_term/1` - matches `libero_wire_ffi:decode_call/1`
- **ETF decode (client):** JS `ETFDecoder` class parsing `ArrayBuffer`, building linked lists for Gleam `List` values - matches `rpc_ffi.mjs`
- **JSON encode:** Recursive walk building a `gleam_json` tree, then `to_string` - matches `wire.gleam` on the `json-wire` branch
- **JSON decode (server):** `json:decode/1` + recursive `rebuild` (tagged objects → tuples via `list_to_tuple`, dicts → maps, `null` → `nil` atom, 0-arity tags → bare atoms) - matches `wire.gleam` `decode_call`
- **JSON decode (client):** `JSON.parse` + recursive `rebuild` (constructor instantiation, linked list construction, Dict/Map reconstruction) - matches `rpc_ffi.mjs` `rebuild`

Test data uses bare atoms for 0-arity constructors (e.g., `none` not `{none}`) to match real BEAM representation.

## Results

### Small payload (admin discounts - 5 records, ~20 fields each)

100k iterations. All times are per-operation.

| | Server encode | Server decode | Client decode | Wire size |
|---|---|---|---|---|
| ETF | 6 µs | 17 µs | 70 µs | 2.0 KB |
| JSON | 56 µs | 79 µs | 100 µs | 3.4 KB |
| **ETF speedup** | **10.1x** | **4.6x** | **1.4x** | **JSON 69% larger** |

### Scaling with payload size

Tested with realistic competition data modeled after a Brier event (18 teams, 80 games, ~10,240 shots).

**Server-side encode (BEAM):**

| Payload | ETF | JSON | ETF speedup |
|---|---|---|---|
| 5 discounts | 8 µs | 72 µs | 9.5x |
| 50 discounts | 62 µs | 697 µs | 11.2x |
| 80 games (no shots) | 58 µs | 740 µs | 12.8x |
| 80 games + shots | 1,169 µs | 28,750 µs | **24.6x** |

**Server-side decode (BEAM):**

| Payload | ETF | JSON | ETF speedup |
|---|---|---|---|
| 5 discounts | 21 µs | 100 µs | 4.8x |
| 50 discounts | 200 µs | 970 µs | 4.9x |
| 80 games (no shots) | 134 µs | 708 µs | 5.3x |
| 80 games + shots | 1,988 µs | 18,349 µs | **9.2x** |

**Client-side decode (V8/Node):**

| Payload | ETF | JSON | ETF speedup |
|---|---|---|---|
| 5 discounts | 89 µs | 120 µs | 1.3x |
| 50 discounts | 820 µs | 1,157 µs | 1.4x |
| 80 games (no shots) | 694 µs | 735 µs | 1.1x |
| 80 games + shots | 12,820 µs | 14,677 µs | **1.1x** |

JSON decode = `JSON.parse` + `rebuild` (constructor instantiation + linked list construction). `JSON.parse` alone is 1.6-2.1x faster than the ETF decoder, but the mandatory rebuild makes the full path slower.

**Wire size:**

| Payload | ETF | JSON | JSON overhead |
|---|---|---|---|
| 5 discounts | 2.4 KB | 3.8 KB | 58% larger |
| 50 discounts | 21.4 KB | 35.2 KB | 64% larger |
| 80 games (no shots) | 23.0 KB | 26.5 KB | 15% larger |
| 80 games + shots | 374 KB | 446 KB | 19% larger |

### Findings

**ETF is faster on both server and client.** Every operation - server encode, server decode, client decode - is faster with ETF across all payload sizes tested.

**ETF advantage grows with payload size.** Server encode speedup goes from 9.5x (small) to 24.6x (large). Server decode from 4.8x to 9.2x. Client decode from 1.4x to 1.1x - the client advantage narrows at scale but ETF stays ahead.

**Client decode: `JSON.parse` is fast, but `rebuild` is the bottleneck.** `JSON.parse` alone is 1.6-2.1x faster than the ETF decoder (native C vs interpreted JS). But every JSON value must then be walked a second time to reconstruct Gleam types. This `rebuild` pass makes JSON+rebuild slower than ETF's single-pass decoder.

**JSON payloads are 19-69% larger.** The `{"@":"tag","v":[...]}` wrapper for every custom type adds overhead. The gap narrows for large payloads dominated by primitive values. WebSocket frames are not compressed by default (no `permessage-deflate`).

**ETF eliminates type-mapping bugs.** Beyond performance, ETF preserves BEAM type structure natively, so there's no None vs Nil confusion, tuple/list conflation, Dict encoding issues, 0-arity constructor ambiguity, or server-side rebuild failures. The JSON wire format required around 200 lines of server-side rebuild code and caused several bugs during the JSON-wire pilot.

### Why ETF is faster

**Server-side:** `erlang:term_to_binary` and `binary_to_term` are C-level BIFs that operate on BEAM terms in a single pass. The JSON path must do two passes: first a recursive Gleam/Erlang walk to build an intermediate JSON tree (allocating wrapper objects for every node), then serialization to a string. Decoding is the same story in reverse - `json:decode` produces generic maps and lists, then a second recursive pass (`rebuild`) must pattern-match tagged objects, call `binary_to_atom` and `list_to_tuple` to reconstruct the actual Erlang terms. ETF skips all intermediate representations.

The advantage compounds with nesting depth and payload size because every level of structure means another layer of intermediate allocation and traversal for JSON, while ETF's single pass stays linear.

**Client-side:** This one is counterintuitive - `JSON.parse` is a native C function in V8, while the ETF decoder is interpreted JavaScript walking an `ArrayBuffer` byte-by-byte. In isolation, `JSON.parse` is 1.6-2.1x faster than the ETF decoder.

But `JSON.parse` produces plain JS objects and arrays, not Gleam-compatible values. The mandatory `rebuild` pass must walk every parsed value to convert `{"@":"tag","v":[...]}` objects into constructor instances (class allocation + property assignment) and convert JSON arrays into Gleam linked lists (right-to-left fold creating cons cells). This rebuild allocates heavily and touches every node a second time.

The ETF decoder does equivalent work - constructor lookup, linked list construction - but in a single pass while reading the binary. One pass with allocation beats two passes with allocation, even when the first pass of the two is native C.

The client-side margin narrows for shot-heavy payloads (6% vs 30%) because shots are flat tuples of small integers with minimal nesting. JSON.parse handles flat arrays of numbers efficiently, and the rebuild pass has little tag-matching work to do. For deeply nested custom types (discount records with Option fields, enum variants, lists of compound types), the rebuild overhead is proportionally larger and ETF's single-pass advantage is more pronounced.

### Test environment

- Erlang/OTP 28, Gleam 1.9
- Node.js v25.9.0 (V8)
- Debian 13, Linux 6.12

## Running the benchmarks

From the **server** package directory:

### Small payload (server + client)

```bash
cd server

# Server
erlc ../lib/libero/benchmarks/bench_server.erl
erl -pa build/dev/erlang/*/ebin -noshell -eval 'bench_server:run(), halt().'
rm bench_server.beam

# Client
node ../lib/libero/benchmarks/bench_client.mjs
```

### Scaling (server + client)

```bash
cd server

# Server
erlc ../lib/libero/benchmarks/bench_scaling.erl
erl -pa build/dev/erlang/*/ebin -noshell -eval 'bench_scaling:run(), halt().'
rm bench_scaling.beam

# Client (generates data via erl, requires bench_scaling.beam)
erlc ../lib/libero/benchmarks/bench_scaling.erl
node ../lib/libero/benchmarks/bench_scaling_client.mjs
rm bench_scaling.beam
```

Requires `gleam_json` and `gleam_stdlib` compiled in `build/dev/erlang/`. Run `gleam build` first if needed. Client benchmarks require Node.js 18+.
