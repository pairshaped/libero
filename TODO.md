# Libero TODOs

## JS decoder fallback breaks the typed-error contract

Per-endpoint JS response decoders (generated into `rpc_decoders_ffi.mjs` by `emit_response_decoders` in `src/libero/codegen.gleam`) end with a fallback:

```js
return new _Failure("RPC framework error");
```

The Gleam stub declares the return as `RemoteData(payload, DomainError)` where `DomainError` is the per-endpoint typed sum (e.g. `ThemeError`). The fallback constructs a `Failure(String)` instead. Downstream `format_*_error` helpers in consumer pages do exhaustive `case` on the typed error and will crash with `case_no_match` if they ever receive the bare-string fallback.

The fallback fires whenever the wire shape isn't `["ok", ["ok", ...]]` or `["ok", ["error", ...]]` — malformed response, version skew, codegen bug. It's not just a theoretical path.

The fix is a design decision:

**Option A: add a fifth `RemoteData` variant for transport failures**

```gleam
pub type RemoteData(value, error) {
  NotAsked
  Loading
  Failure(error)
  TransportFailure(message: String)  // new
  Success(value)
}
```

Cleanest type-wise: domain failures and transport failures are distinguishable. Breaks every exhaustive `case` on `RemoteData` — consumers must add a new arm. Compiler-driven migration, no silent breakage.

**Option B: switch per-endpoint stubs to `RemoteData(payload, RpcFailure)`**

`RpcFailure` already exists with `DomainFailure(message)` / `FrameworkFailure(message)` variants. But codegen would need a `format_domain` callback parameter to stringify arbitrary domain errors, regressing the ergonomics that motivated the typed-error stub in the first place.

**Option C: throw a JS Error in the fallback path**

Surfaces as an uncaught exception in the WS handler. Doesn't crash the pattern match, but the response is lost — the caller's `Loading` state never resolves.

Recommended: Option A. The migration is mechanical (compiler errors) and the new state is meaningful — UI can render different messaging for "connection lost" vs domain validation failure.

Files:
- `src/libero/codegen.gleam:1319` (the fallback line)
- `src/libero/remote_data.gleam` (the type)
- All `RemoteData` case arms in consuming projects

This is closely related to the next item — the test infrastructure for the JS decode path would also exercise the success and domain-failure paths.

## End-to-end JS decode/encode tests

The endpoint convention's JS runtime decode path has zero test coverage. All existing tests verify codegen output (string matching) or Gleam-side logic, not actual JS runtime behavior.

Add Node-based tests that:
- Encode ETF server-side (Erlang/Gleam)
- Decode client-side (JS per-type decoders + per-endpoint response decoders)
- Verify proper Gleam constructor instances (not raw arrays)

Cover:
- Result wrapping (Ok/Error at both RPC envelope and handler levels)
- List(X) and Option(X) parameterized types
- Custom types with multiple constructors (e.g., error unions)
- Nested types (e.g., List(Result(X, E)))
- Dict decoding
- BitArray fields
