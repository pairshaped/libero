# Libero Wire Format Benchmarks

Compares ETF (Erlang Term Format) vs JSON for Libero's RPC wire format.

## Results

Tested with a realistic admin RPC response: 5 discount records with ~20 fields each, plus item options, question options, and a dict of question values.

### Server-side (BEAM)

```
         Encode         Decode         Size
ETF        6.1 µs/op    18.0 µs/op     2,185 bytes
JSON      59.0 µs/op    55.9 µs/op     3,423 bytes
```

- **ETF is 9.7x faster to encode** — `erlang:term_to_binary` is a single C-level BIF vs walking the term tree and building JSON strings.
- **ETF is 3.1x faster to decode** — `erlang:binary_to_term` reconstructs native BEAM terms directly vs parsing JSON and then rebuilding tuples/atoms from maps.
- **JSON is 57% larger on the wire** — the `{"@":"tag","v":[...]}` wrapper for every custom type adds significant overhead. WebSocket frames are not compressed by default.

### Client-side (V8)

```
                    Per-op
ETF decode          75.3 µs/op
JSON.parse          44.5 µs/op
JSON parse+rebuild  49.5 µs/op
```

- **JSON.parse is 1.5x faster** — it's a native C function in V8. The ETF decoder is interpreted JavaScript walking an ArrayBuffer byte-by-byte.
- The `rebuild` step (converting `{"@":"tag","v":[...]}` objects back to constructor instances) adds ~11% on top of `JSON.parse`.

### Net assessment

ETF is faster overall for the round-trip because the server-side savings (9.7x encode, 3.1x decode) dwarf the client-side cost (1.5x slower decode). The server processes every request; the client processes one response at a time with plenty of idle capacity.

ETF also eliminates an entire class of type-mapping bugs (None vs Nil, tuples vs lists, Dict encoding, 0-arity constructors, server-side rebuild) because it preserves BEAM type structure natively.

## Running the benchmarks

From the **server** package directory:

### Server benchmark (Erlang/BEAM)

```bash
cd server
erlc ../lib/libero/benchmarks/bench_server.erl
erl -pa build/dev/erlang/*/ebin -noshell -eval 'bench_server:run(), halt().'
rm bench_server.beam
```

Requires `gleam_json` to be compiled in `build/dev/erlang/`. Run `gleam build` first if needed.

### Client benchmark (Node.js/V8)

```bash
cd server
node ../lib/libero/benchmarks/bench_client.mjs
```

Generates ETF and JSON test data by shelling out to `erl`, then benchmarks V8 decode performance. Requires Node.js 18+ and the Erlang build artifacts (same as above).
