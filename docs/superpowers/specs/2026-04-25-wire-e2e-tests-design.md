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
├── shared_src/shared/
│   └── types.gleam.template       # type coverage matrix
├── server_src/
│   ├── server/handler.gleam.template       # one echo_<shape> endpoint per type
│   └── server/handler_context.gleam.template
├── client_src/
│   └── app.gleam.template         # copied to clients/web/src/app.gleam
└── clients/web/
    └── gleam.toml
```

What gets committed: handwritten fixture source templates only. Template directories avoid the name `src`, and template files use `.gleam.template`, so root `gleam test` does not compile the nested fixture as part of libero itself. The fixture is copied to an external staging directory before codegen/build, where templates are mapped back to normal Gleam package paths and `.gleam` filenames. Do not build it in place under the libero repo: a nested fixture `build/` directory is visible while compiling libero as a path dependency and causes duplicate native Erlang module errors.

Build artifacts live in the external staging directory. Generated source directories produced by `libero gen` are test outputs too:

- `test/fixtures/wire_e2e/src/server/generated/`
- `test/fixtures/wire_e2e/clients/web/src/generated/`

Either add these paths to `.gitignore`, or commit them intentionally and make the tests fail when regeneration changes them. The default should be to ignore them and produce them fresh during test setup, because this fixture exists to test the generator currently on disk.

The fixture's `gleam.toml` declares libero as a path dep (`{ path = "../../.." }`), so it picks up whatever libero is on disk. CI runs the fixture against the same libero source the rest of the test suite is testing.

### Test entry points

Four JS test files under `test/js/`, each invoked the same way as the existing files (a bespoke `test()` runner consistent with `etf_codec_test.mjs`):

- `wire_e2e_module_load_test.mjs`: imports the real compiled generated JS modules and fails on missing FFI exports.
- `wire_e2e_decode_test.mjs`: BEAM-encode -> JS-decode for every shape in the matrix.
- `wire_e2e_encode_test.mjs`: JS-encode -> BEAM-decode for every shape.
- `wire_e2e_dispatch_test.mjs`: routing cases (right handler, unknown function, malformed envelope).

The module-load test imports the compiled client artifacts directly:

- `test/fixtures/wire_e2e/clients/web/build/dev/javascript/web/generated/messages.mjs`
- `test/fixtures/wire_e2e/clients/web/build/dev/javascript/web/generated/rpc_decoders.mjs`
- `test/fixtures/wire_e2e/clients/web/build/dev/javascript/web/generated/rpc_decoders_ffi.mjs`
- `test/fixtures/wire_e2e/clients/web/build/dev/javascript/web/app.mjs`

This catches the specific regression where a compiled generated module imports an FFI export that does not exist.

The other files load the fixture's compiled artifacts: custom-type constructors from the shared package output (`clients/web/build/dev/javascript/shared/shared/types.mjs`), generated decoders from `clients/web/build/dev/javascript/web/generated/`, and `gleam_stdlib` classes for `Some`/`None`/`Ok`/`Error`/`NonEmpty`/`Empty`. Importing `rpc_decoders_ffi.mjs` runs the generated prelude setter initialization, so test code should only call setters manually when it imports lower-level prelude modules in isolation.

### Setup script

`test/js/wire_e2e_setup.sh` runs once before the test files. It does:

1. `cd test/fixtures/wire_e2e`
2. Copy the fixture sources to an external staging directory under `${TMPDIR:-/tmp}`.
3. Rewrite staged `libero` path dependencies to the absolute repo root.
4. `gleam run -m libero -- gen` in the staged fixture (codegen).
5. `gleam build --target erlang` in the staged fixture (server).
6. `cd clients/web && gleam build --target javascript` in the staged fixture (client).
7. Write the staged fixture path to `test/js/.wire_e2e_build_root`.
8. Generate batched fixture manifests for Pattern A and Pattern C.

Before scaffolding the fixture, verify that step 2 works from inside a path-dep consumer project. If it does not, change the setup script to invoke libero from the repo root with an explicit fixture path instead of discovering `"."`.

The script is idempotent. If a previous run produced the artifacts and nothing changed, the second run is a fast no-op. It also accepts `--clean`, which removes the fixture build directories, generated source directories, and manifest files before regenerating them. Use `--clean` when changing libero source, generated paths, or fixture dependencies.

### Batched fixtures

Avoid `erl -noshell -eval` per assertion. BEAM cold-start cost is high enough that per-case process startup will make the suite slow once the matrix is filled in.

Setup should use one Erlang invocation to emit a checked-in-shape manifest for all Pattern A payloads:

```json
{
  "echo_int/positive": "g3QAAA...",
  "echo_string/utf8_cafe": "g3QAAA..."
}
```

Each manifest value is base64 ETF for the raw response term. JS tests load the manifest once, decode each payload through the JS ETF decoder, then pass the raw term to the generated per-endpoint decoder.

Pattern B should batch in the other direction: the JS test builds all request-envelope binaries first, writes an input manifest of base64 payloads, then calls one Erlang helper to decode and print every term into an output manifest.

Pattern C should use the same batching idea: one Erlang invocation builds and dispatches all routing cases, then emits a manifest of response frames keyed by case name.

Runtime target: the full JS E2E suite should stay under 60 seconds on a normal development laptop. If it exceeds that, batch more work inside the Erlang helper rather than adding more per-case shell calls.

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

Total: 22 endpoints in the full matrix. Do not try to land the whole matrix as the first increment. The first executable slice should prove the harness with:

- compiled generated module-load smoke test
- BEAM `Ok(Int)` -> JS `decode_response_echo_int`
- JS `WithFloats(2.0, 3.0, "whole")` -> BEAM term with float fields preserved
- dispatch route for `echo_int` vs `echo_int_negated`

After that, fill out the remaining matrix. Each endpoint gets multiple test cases (empty, populated, edge values, both Ok and Error paths where applicable). Estimated 60-80 assertions per direction once complete.

Pin the endpoint list before filling out the matrix:

`echo_int`, `echo_float`, `echo_string`, `echo_bool`, `echo_bit_array`, `echo_unit`, `echo_list_int`, `echo_option_string`, `echo_result_int_string`, `echo_dict_string_int`, `echo_tuple_int_string`, `echo_status`, `echo_item`, `echo_tree`, `echo_item_error`, `echo_with_floats`, `echo_list_of_items`, `echo_option_item`, `echo_dict_string_item`, `echo_nested_record`, `echo_typed_err`, `echo_int_negated`.

Required edge cases:

- `echo_string`: include `"café"` and at least one CJK string such as `"漢字"`, so UTF-8/multibyte binary handling is covered.
- `echo_tree`: include `Leaf` and a 3-deep `Node`, so recursion is exercised at runtime.

### Float field canary

`echo_with_floats` is the canary for the float field registry. The JS encoder must emit tag 70 (`NEW_FLOAT_EXT`) for `WithFloats(x: 2.0, y: 3.0, ...)`, not tag 97 (small int), or BEAM rejects coercion back to a `WithFloats` record. The reverse direction (BEAM-encoded `{with_floats, 2.0, 3.0, ...}` decoded in JS) verifies the JS side reads the float tag correctly.

## Test patterns

### Pattern A: BEAM-encode -> JS-decode

Per manifest entry:

1. Read the base64 ETF response term from the manifest generated during setup.
2. JS test reads the base64, runs it through the JS ETF decoder (raw mode, returns plain arrays for atom-tagged tuples).
3. Calls the fixture's `decode_response_<endpoint>(rawValue)` from the loaded `rpc_decoders_ffi.mjs`.
4. Asserts the returned object is the expected `RemoteData` instance with the right Gleam-shaped contents (e.g. `Success(Item(1, "apple", 1.5, true))`).

Custom-type construction in `erl` does not require loading user modules. Gleam custom types compile to Erlang records: `pub type Item { Item(id: Int, ...) }` -> `{item, 1, ...}`. The atom names follow `to_snake_case`.

Import `rpc_decoders_ffi.mjs` before decoding. That import runs the generated prelude setter initialization. Test code should only call setters manually when it imports lower-level prelude modules in isolation.

### Pattern B: JS-encode -> BEAM-decode

Per encoded request entry:

1. Test constructs a Gleam value using fixture class constructors (e.g. `new Item(1, "apple", 1.5, true)`).
2. Runs it through the request-envelope encoding path the real client uses by importing `encode_call` through the compiled `clients/web/build/dev/javascript/libero/libero/wire.mjs` path.
3. Writes the base64 request payload to a JS-created input manifest.
4. Runs one Erlang helper for the whole file. The helper reads every base64 payload, runs `binary_to_term/1`, and writes a decoded-term manifest.
5. Asserts each printed Erlang term matches the expected request envelope, including module name, request ID, message variant, and variant payload.

For the JS-encode path we use the request-encoding side that real client code uses, so we exercise the same code path that breaks for end users.

The float canary must import the generated decoder/registration module before encoding. Without that import, the float field registry may be empty and the test would be exercising the codec without the generated metadata real clients rely on. The assertion must inspect the decoded message variant payload for `WithFloats(2.0, 3.0, "whole")`, not just the outer envelope, because the bug is an integer-vs-float tag error inside the payload fields.

If step 1 of the implementation order proves `encode_call` cannot be imported directly from the compiled `wire.mjs` artifact, fallback to capturing the compiled generated client send path's outgoing binary. Treat that as a harness adaptation, not a runtime choice inside the test design.

### Pattern C: dispatch routing

Per dispatch manifest entry:

1. The setup helper constructs a full wire envelope binary in `erl`: `<<131, ...>>` containing `{ModuleName, RequestId, MsgVariant}`.
2. The same helper loads the fixture's compiled dispatch and calls `server@generated@dispatch:handle/2` with a synthetic state for each routing case.
3. The helper captures each returned response binary, base64-encodes it, and writes it to the dispatch manifest.
4. JS test decodes the response, verifies the envelope's request_id round-tripped, and asserts the response body matches the handler's behavior.

This test boundary intentionally starts at generated dispatch, not the Mist WebSocket handler. It covers `wire.decode_call`, handler routing, response encoding, and response frame tagging. WebSocket upgrade, frame send failures, topic cleanup, and live socket behavior remain out of scope for this fixture.

Three cases:

- **Right handler wins.** Call `echo_int` with `5`, expect `Ok(5)`. Call `echo_int_negated` with `5`, expect `Ok(-5)`. Identical input shape, different routing.
- **Unknown function.** Call envelope with a non-existent function atom. Expect `Error(UnknownFunction("..."))`.
- **Malformed envelope.** Send a binary that decodes as ETF but isn't a 3-tuple. Expect `Error(MalformedRequest)`.

## Build orchestration and CI

The fixture's build is independent of `gleam test` for the libero project (libero doesn't have a JS target itself). The flow:

1. `gleam test` runs the existing root-level Gleam tests (scanner, walker, codegen). Unchanged.
2. A new wrapper `test/run_js_tests.sh` runs `wire_e2e_setup.sh`, then invokes each `test/js/*.mjs` test file via `node`.
3. CI runs both. Local devs can run either independently.

The setup script and test files are POSIX shell + plain Node, no extra deps. CI should also run `test/js/wire_e2e_setup.sh --clean` at least once to catch stale-artifact assumptions.

## Implementation order

1. Create the smallest throwaway path-dep fixture and verify `gleam run -m libero -- gen` works from inside it.
2. Scaffold the real fixture project (gleam.toml, types, handler, client app shell).
3. Add fixture generated-source paths to `.gitignore`, unless choosing to commit generated sources intentionally.
4. Write the setup script with `--clean` support.
5. Add batched Erlang manifest generation for Pattern A and Pattern C.
6. Add `wire_e2e_module_load_test.mjs` and make it import the compiled generated client modules.
7. Add the first Pattern A case (`echo_int`) to prove BEAM -> JS decode.
8. Add the first Pattern B canary (`WithFloats`) to prove JS -> BEAM encode with generated float metadata.
9. Add the first Pattern C case (`echo_int` vs `echo_int_negated`) to prove dispatch routing.
10. Fill out the rest of Pattern A for the full type matrix.
11. Fill out Pattern B for the full type matrix.
12. Fill out Pattern C error cases.
13. Wire into CI.

Each phase is independently committable. Phase 6 is the highest-value single increment because it directly guards the module-load failure that shipped. Phases 7-9 prove the harness in each direction. Phases 10-12 fill in coverage.

## Open questions

- **Which Node version to target?** Existing tests use top-level `import`, no Node-specific features. Node 18+ probably sufficient. Verify before scaffolding.
- **Float edge cases.** `NaN` and `Infinity` are not Gleam-representable but the decoder might see them from a misbehaving server. Decide whether Pattern A includes these (test that we throw clearly) or excludes them (out of scope).

## Out of scope

- Property-based testing.
- Latency or throughput measurement.
- WebSocket transport tests. The fixture starts at generated dispatch because `dispatch.handle/2` already covers request envelope decoding and response frame tagging; Mist integration gets separate transport tests if needed.
- The classic convention (MsgFromClient/MsgFromServer). The fixture targets the handler-as-contract convention only. If we later need classic-convention wire tests, they go in a parallel fixture rather than a second client target because the server handler shape, generated messages, and expected decoder exports differ enough that sharing one fixture would blur the assertions.
