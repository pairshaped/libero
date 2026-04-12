# Libero Wire Format Benchmarks

Compares ETF (Erlang Term Format) vs JSON for Libero's RPC wire format.

## Results

### Small payload (admin discounts — 5 records, ~20 fields each)

**Server-side (BEAM, 100k iterations):**

| | Encode | Decode | Size |
|---|---|---|---|
| ETF | 7 µs/op | 21 µs/op | 2.4 KB |
| JSON | 73 µs/op | 69 µs/op | 3.8 KB |
| **Speedup** | **9.8x** | **3.3x** | JSON 58% larger |

**Client-side (V8/Node, 100k iterations):**

| | Decode | vs JSON.parse | vs JSON+rebuild |
|---|---|---|---|
| ETF | 91 µs/op | 1.6x slower | 1.4x slower |
| JSON.parse | 57 µs/op | — | — |
| JSON+rebuild | 63 µs/op | — | — |

### Scaling with payload size

Tested with realistic competition data modeled after a Brier event (18 teams, 80 games, ~11,700 shots per stage).

**Server-side (BEAM):**

| Payload | ETF enc | JSON enc | Speedup | ETF dec | JSON dec | Speedup | ETF size | JSON size |
|---|---|---|---|---|---|---|---|---|
| 5 discounts | 7 µs | 73 µs | 9.8x | 21 µs | 69 µs | 3.3x | 2.4 KB | 3.8 KB |
| 50 discounts | 66 µs | 704 µs | 10.8x | 201 µs | 691 µs | 3.4x | 21.6 KB | 35.2 KB |
| 80 games (no shots) | 60 µs | 773 µs | 12.9x | 118 µs | 551 µs | 4.7x | 23.2 KB | 26.5 KB |
| 80 games + shots | 1,167 µs | 27,728 µs | **23.8x** | 1,901 µs | 19,776 µs | **10.4x** | 374 KB | 446 KB |

**Client-side (V8/Node):**

| Payload | ETF decode | JSON.parse | JSON+rebuild | ETF vs rebuild |
|---|---|---|---|---|
| 5 discounts | 91 µs | 57 µs | 63 µs | 1.4x slower |
| 50 discounts | 823 µs | 528 µs | 601 µs | 1.4x slower |
| 80 games (no shots) | 677 µs | 343 µs | 440 µs | 1.5x slower |
| 80 games + shots | 12,547 µs | 6,136 µs | 7,400 µs | 1.7x slower |

### Key findings

**Server-side ETF advantage grows with payload size.** Encode speedup goes from 9.8x (small) to 23.8x (large) because JSON's tree-walk + string-building overhead compounds with nested structures, while `erlang:term_to_binary` is a single C-level pass. Decode speedup grows from 3.3x to 10.4x.

**Client-side JSON advantage is modest and stable.** `JSON.parse` is a native C function in V8, while the ETF decoder is interpreted JavaScript walking an ArrayBuffer. The gap widens slightly from 1.4x to 1.7x at large payloads, but remains small in absolute terms (5ms extra for a 374KB payload).

**Size gap narrows at scale.** JSON is 58% larger for small payloads (the `{"@":"tag","v":[...]}` wrapper overhead dominates), but only 19% larger for large payloads (shot data is mostly small integers, compact in both formats). WebSocket frames are not compressed by default.

**Net round-trip strongly favors ETF.** For the large competition payload, ETF saves ~26ms encoding + ~18ms decoding on the server, while the client pays ~5ms extra. The server processes every request under load; the client has idle capacity between renders.

**ETF eliminates type-mapping bugs.** Beyond performance, ETF preserves BEAM type structure natively — no more None vs Nil confusion, tuple/list conflation, Dict encoding issues, or server-side rebuild failures.

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

# Client
node ../lib/libero/benchmarks/bench_scaling_client.mjs
```

Requires `gleam_json` and `gleam_stdlib` compiled in `build/dev/erlang/`. Run `gleam build` first if needed. Client benchmarks require Node.js 18+.
