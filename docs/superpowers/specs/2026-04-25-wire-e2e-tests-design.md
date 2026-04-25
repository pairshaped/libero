# Wire end-to-end test design

**Status:** draft
**Author:** dave (with claude)
**Date:** 2026-04-25

## Background

Libero generates code that crosses a runtime boundary: the BEAM produces ETF binaries, JS consumes them through a stack of generated decoders (`rpc_decoders_ffi.mjs`, the typed decoder, `wire.decode_response`). The recent handler-as-contract migration added a per-endpoint decoder layer (commits `5464b8a`, `83a9c79`) that wasn't covered by any test that loaded actual built output.

This gap let a hard runtime regression ship: the JS bundle for both example apps failed at module load because the FFI didn't export `decode_msg_from_server`. The existing tests passed because they either tested codegen output as strings (not as loaded modules) or tested handwritten JS modules in isolation with mocked Gleam stdlib classes.

Existing test layers that this spec does not replace:

- `test/js/etf_codec_test.mjs`: ETF binary codec, primitives only, cross-runtime against `erl`.
- `test/js/decoders_prelude_test.mjs`: unit tests for `decoders_prelude.mjs` with mock stdlib classes.
- `test/libero/endpoint_dispatch_test.gleam`: codegen output as strings.
- `test/libero/endpoint_filter_test.gleam`: scanner filtering rules.

What's missing: any test that builds a real fixture project, generates code through `libero gen`, runs `gleam build` for both targets, and exercises the produced artifacts against actual BEAM-encoded payloads.

## Goals

- Catch the bug class "the unit test passed but the real app blew up at runtime" by loading and exercising real generated code.
- Cover every primitive, every Gleam stdlib wrapper, every custom-type variant shape, and meaningful compositions of the above.
- Cover both directions: BEAM-encode -> JS-decode and JS-encode -> BEAM-decode.
- Cover dispatch routing: right handler picked, unknown function rejected, malformed envelope rejected.

## Non-goals

- Fuzzing or property-based testing. Every case is deterministic and checked-in.
- Performance regression testing.
- Replacing the existing ETF codec or prelude unit tests. Those run faster and bound the scope of what an E2E failure could be.

## Architecture

### Fixture project

A self-contained Gleam project at `test/fixtures/wire_e2e/`, mirroring the layout of `examples/todos`:

```
test/fixtures/wire_e2e/
├── gleam.toml                     # libero as path dep, declares one js client
├── shared/src/shared/
│   └── types.gleam                # type coverage matrix
├── src/
│   ├── server/handler.gleam       # one echo_<shape> endpoint per type
│   └── server/handler_context.gleam
└── clients/web/
    ├── gleam.toml
    └── src/app.gleam              # minimal: imports messages so codegen runs
```

What gets committed: sources only. Build artifacts live in gitignored `build/` directories. Test setup produces them fresh each run.

The fixture's `gleam.toml` declares libero as a path dep (`{ path = "../../.." }`), so it picks up whatever libero is on disk. CI runs the fixture against the same libero source the rest of the test suite is testing.

### Test entry points

Three JS test files under `test/js/`, each invoked the same way as the existing files (a bespoke `test()` runner consistent with `etf_codec_test.mjs`):

- `wire_e2e_decode_test.mjs`: BEAM-encode -> JS-decode for every shape in the matrix.
- `wire_e2e_encode_test.mjs`: JS-encode -> BEAM-decode for every shape.
- `wire_e2e_dispatch_test.mjs`: routing cases (right handler, unknown function, malformed envelope).

Each file loads the fixture's compiled artifacts (custom-type constructors from `build/dev/javascript/wire_e2e/...`, generated decoders from `clients/web/build/...`, `gleam_stdlib` classes for `Some`/`None`/`Ok`/`Error`/`NonEmpty`/`Empty`), initializes the prelude setters, and runs its assertions.

### Setup script

`test/js/wire_e2e_setup.sh` runs once before the test files. It does:

1. `cd test/fixtures/wire_e2e`
2. `gleam run --module libero -- gen` (codegen)
3. `gleam build --target erlang` (server)
4. `cd clients/web && gleam build --target javascript` (client)

The script is idempotent. If a previous run produced the artifacts and nothing changed, the second run is a fast no-op.

## Type coverage matrix

### Type definitions (`shared/src/shared/types.gleam`)

```gleam
pub type Status { Pending | Active | Cancelled }

pub type Item {
  Item(id: Int, name: String, price: Float, in_stock: Bool)
}

pub type Tree {
  Leaf
  Node(value: Int, left: Tree, right: Tree)
}

pub type ItemError {
  NotFound
  ValidationFailed(field: String, reason: String)
}

pub type WithFloats {
  WithFloats(x: Float, y: Float, label: String)
}

pub type NestedRecord {
  NestedRecord(
    items: List(Item),
    primary: Option(Item),
    statuses: List(Status),
    by_id: Dict(String, Item),
  )
}
```

### Endpoint matrix (`src/server/handler.gleam`)

Each endpoint is a pure echo: `pub fn echo_X(value: X, state: HC) -> #(Result(X, _), HC)` with body `#(Ok(value), state)`.

| Group | Endpoint | Verifies |
|---|---|---|
| Primitives | `echo_int`, `echo_float`, `echo_string`, `echo_bool`, `echo_bit_array` | Each primitive ETF tag round-trips through the typed decoder |
| Unit | `echo_unit` | `Result(Nil, _)` success path |
| Stdlib wrappers | `echo_list_int`, `echo_option_string`, `echo_result_int_string`, `echo_dict_string_int`, `echo_tuple_int_string` | Each Gleam container with primitive payload |
| Custom types | `echo_status`, `echo_item`, `echo_tree`, `echo_item_error`, `echo_with_floats` | 0-arity variants, record, recursion, mixed-arity multi-variant, float field registry |
| Compositions | `echo_list_of_items`, `echo_option_item`, `echo_dict_string_item`, `echo_nested_record` | Custom-type-in-wrapper, wrapper-in-custom-type |
| Typed errors | `echo_typed_err` returning `Result(Item, ItemError)` | Custom-type Err side of the per-endpoint decoder |
| Dispatch | `echo_int_negated` (in addition to `echo_int`) | Same input shape, different routing |

Total: 22 endpoints. Each gets multiple test cases (empty, populated, edge values, both Ok and Error paths where applicable). Estimated 60-80 assertions per direction.

### Float field canary

`echo_with_floats` is the canary for the float field registry. The JS encoder must emit tag 70 (`NEW_FLOAT_EXT`) for `WithFloats(x: 2.0, y: 3.0, ...)`, not tag 97 (small int), or BEAM rejects coercion back to a `WithFloats` record. The reverse direction (BEAM-encoded `{with_floats, 2.0, 3.0, ...}` decoded in JS) verifies the JS side reads the float tag correctly.

## Test patterns

### Pattern A: BEAM-encode -> JS-decode

Per case:

1. Build an `erl -noshell -eval` invocation that constructs the response tuple, e.g. `Term = {ok, {item, 1, <<"apple">>, 1.5, true}}, io:format("~s", [base64:encode(erlang:term_to_binary(Term))])`.
2. JS test reads the base64, runs it through the JS ETF decoder (raw mode, returns plain arrays for atom-tagged tuples).
3. Calls the fixture's `decode_response_<endpoint>(rawValue)` from the loaded `rpc_decoders_ffi.mjs`.
4. Asserts the returned object is the expected `RemoteData` instance with the right Gleam-shaped contents (e.g. `Success(Item(1, "apple", 1.5, true))`).

Custom-type construction in `erl` does not require loading user modules. Gleam custom types compile to Erlang records: `pub type Item { Item(id: Int, ...) }` -> `{item, 1, ...}`. The atom names follow `to_snake_case`.

### Pattern B: JS-encode -> BEAM-decode

Per case:

1. Test constructs a Gleam value using fixture class constructors (e.g. `new Item(1, "apple", 1.5, true)`).
2. Runs it through the JS encoder (typed encoder + ETF encoder) to produce the request payload.
3. Sends the binary to `erl` via base64, runs `binary_to_term/1`, prints with `io:format("~p", ...)`.
4. Asserts the printed Erlang term matches expected (e.g. `"{item,1,<<\"apple\">>,1.5,true}"`).

For the JS-encode path we use the request-encoding side that real client code uses, so we exercise the same code path that breaks for end users.

### Pattern C: dispatch routing

Per case:

1. Construct a full wire envelope binary in `erl`: `<<131, ...>>` containing `{ModuleName, RequestId, MsgVariant}`.
2. Send to `erl -pa <fixture>/build/dev/erlang/*/ebin -eval` which loads the fixture's compiled dispatch and calls `server@generated@dispatch:handle/2` with a synthetic state.
3. Capture the returned response binary, base64-encode, send back to the JS test.
4. JS test decodes the response, verifies the envelope's request_id round-tripped, and asserts the response body matches the handler's behavior.

Three cases:

- **Right handler wins.** Call `echo_int` with `5`, expect `Ok(5)`. Call `echo_int_negated` with `5`, expect `Ok(-5)`. Identical input shape, different routing.
- **Unknown function.** Call envelope with a non-existent function atom. Expect `Error(UnknownFunction("..."))`.
- **Malformed envelope.** Send a binary that decodes as ETF but isn't a 3-tuple. Expect `Error(MalformedRequest)`.

## Build orchestration and CI

The fixture's build is independent of `gleam test` for the libero project (libero doesn't have a JS target itself). The flow:

1. `gleam test` runs the existing root-level Gleam tests (scanner, walker, codegen). Unchanged.
2. A new wrapper `test/run_js_tests.sh` runs `wire_e2e_setup.sh`, then invokes each `test/js/*.mjs` test file via `node`.
3. CI runs both. Local devs can run either independently.

The setup script and test files are POSIX shell + plain Node, no extra deps.

## Implementation order

1. Scaffold the fixture project (gleam.toml, types, handler, client app shell).
2. Write the setup script.
3. Pattern A test file: get one case working end-to-end (e.g. `echo_int`) to validate the harness.
4. Fill out the rest of Pattern A (decode side) for the full type matrix.
5. Pattern B (encode side) for the full type matrix.
6. Pattern C (dispatch routing).
7. Wire into CI.

Each phase is independently committable. Phase 3 is the highest-value single increment because it proves the harness; phases 4-6 fill in coverage.

## Open questions

- **Which Node version to target?** Existing tests use top-level `import`, no Node-specific features. Node 18+ probably sufficient. Verify before scaffolding.
- **Do we need the Gleam stdlib's actual list constructors at test time?** Pattern A asserts on `NonEmpty` and `Empty` instances. We load these from the fixture's `gleam_stdlib` build output. If that's awkward (path resolution), fall back to mock classes like `decoders_prelude_test.mjs` does and document the limitation.
- **Float edge cases.** `NaN` and `Infinity` are not Gleam-representable but the decoder might see them from a misbehaving server. Decide whether Pattern A includes these (test that we throw clearly) or excludes them (out of scope).

## Out of scope

- Property-based testing.
- Latency or throughput measurement.
- WebSocket transport tests (the fixture doesn't run a real server, only its dispatch module).
- The classic convention (MsgFromClient/MsgFromServer). The fixture targets the handler-as-contract convention only. If we later need classic-convention wire tests, they go in a parallel fixture.
