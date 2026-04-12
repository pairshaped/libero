# Libero Wire Format Benchmarks

Compares ETF (Erlang Term Format) vs JSON for Libero's RPC wire format.

## Methodology

Both benchmarks faithfully mirror the real encode/decode paths:

- **ETF encode:** `erlang:term_to_binary/1` (single C-level BIF) — matches `wire.gleam`
- **ETF decode (server):** `erlang:binary_to_term/1` — matches `libero_wire_ffi:decode_call/1`
- **ETF decode (client):** JS `ETFDecoder` class parsing `ArrayBuffer`, building linked lists for Gleam `List` values — matches `rpc_ffi.mjs`
- **JSON encode:** Recursive walk building a `gleam_json` tree, then `to_string` — matches `wire.gleam` on the `json-wire` branch
- **JSON decode (server):** `json:decode/1` + recursive `rebuild` (tagged objects → tuples via `list_to_tuple`, dicts → maps, `null` → `nil` atom, 0-arity tags → bare atoms) — matches `wire.gleam` `decode_call`
- **JSON decode (client):** `JSON.parse` + recursive `rebuild` (constructor instantiation, linked list construction, Dict/Map reconstruction) — matches `rpc_ffi.mjs` `rebuild`

Test data uses bare atoms for 0-arity constructors (e.g., `none` not `{none}`) to match real BEAM representation.

## Results

### Small payload (admin discounts — 5 records, ~20 fields each)

**Server-side (BEAM, 100k iterations):**

| | Encode | Decode | Size |
|---|---|---|---|
| ETF | 6 µs/op | 17 µs/op | 2.0 KB |
| JSON | 56 µs/op | 79 µs/op | 3.4 KB |
| **Speedup** | **10.1x** | **4.6x** | JSON 69% larger |

**Client-side (V8/Node, 100k iterations):**

| | Decode |
|---|---|
| ETF decode | 70 µs/op |
| JSON.parse only | 44 µs/op |
| JSON.parse + rebuild | 100 µs/op |
| **ETF vs JSON+rebuild** | **ETF 30% faster** |

`JSON.parse` alone is 1.6x faster than the ETF decoder (native C vs interpreted JS). But the mandatory `rebuild` pass — converting `{"@":"tag","v":[...]}` objects back into constructor instances and linked lists — makes JSON+rebuild 30% slower than ETF overall.

### Scaling with payload size

Tested with realistic competition data modeled after a Brier event (18 teams, 80 games, ~10,240 shots).

**Server-side (BEAM):**

| Payload | ETF enc | JSON enc | Speedup | ETF dec | JSON dec | Speedup | ETF size | JSON size |
|---|---|---|---|---|---|---|---|---|
| 5 discounts | 8 µs | 72 µs | 9.5x | 21 µs | 100 µs | 4.8x | 2.4 KB | 3.8 KB |
| 50 discounts | 62 µs | 697 µs | 11.2x | 200 µs | 970 µs | 4.9x | 21.4 KB | 35.2 KB |
| 80 games (no shots) | 58 µs | 740 µs | 12.8x | 134 µs | 708 µs | 5.3x | 23.0 KB | 26.5 KB |
| 80 games + shots | 1,169 µs | 28,750 µs | **24.6x** | 1,988 µs | 18,349 µs | **9.2x** | 374 KB | 446 KB |

**Client-side (V8/Node):**

| Payload | ETF decode | JSON.parse | JSON+rebuild | ETF vs rebuild |
|---|---|---|---|---|
| 5 discounts | 89 µs | 56 µs | 120 µs | ETF 30% faster |
| 50 discounts | 820 µs | 541 µs | 1,157 µs | ETF 29% faster |
| 80 games (no shots) | 694 µs | 354 µs | 735 µs | ETF 6% faster |
| 80 games + shots | 12,820 µs | 6,002 µs | 14,677 µs | ETF 13% faster |

### Key findings

**ETF is faster on both server and client.** Previous benchmarks that omitted the JSON rebuild step made JSON appear faster on the client. With a faithful rebuild (constructor instantiation + linked list construction), ETF decode is faster across all payload sizes.

**Server-side ETF advantage grows with payload size.** Encode speedup goes from 9.5x (small) to 24.6x (large) because JSON's tree-walk + string-building overhead compounds with nested structures, while `erlang:term_to_binary` is a single C-level pass. Decode speedup grows from 4.8x to 9.2x.

**Client-side advantage is modest but consistent.** ETF decode is 6-30% faster than JSON parse+rebuild. The margin narrows for payloads dominated by small integers (shot data), where JSON.parse's native C advantage partially closes the gap.

**JSON payloads are 19-69% larger.** The `{"@":"tag","v":[...]}` wrapper for every custom type adds overhead. The gap narrows for large payloads dominated by primitive values (small integers in shot data). WebSocket frames are not compressed by default (no `permessage-deflate`).

**ETF eliminates type-mapping bugs.** Beyond performance, ETF preserves BEAM type structure natively — no more None vs Nil confusion, tuple/list conflation, Dict encoding issues, 0-arity constructor ambiguity, or server-side rebuild failures. The JSON wire format required ~200 lines of server-side rebuild code and caused 5+ bugs during the v3 pilot.

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
