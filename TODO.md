# Libero TODOs

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
