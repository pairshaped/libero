# Libero

Libero is the defensive specialist in volleyball, who handles passes and digs so the rest of the team can focus on hits. This library handles the wire plumbing (serialization, dispatch, error envelopes, panic recovery) so your app can focus on its domain logic.

Wiring a Gleam server to a Lustre SPA usually means, for every interaction: define a REST route, write a JSON encoder for the request, write a JSON decoder for the response, write a `fetch` wrapper on the client, and keep the type definitions on both sides in sync by hand. Every new endpoint is the same boilerplate, and every mistake (typo, missing field, drifted shape) waits for runtime to bite.

Libero replaces the whole loop. You write a normal server function, annotate it with `/// @rpc`, and call it from the client as if it were a local function. Routes, encoders, decoders, dispatch, and error envelopes are all generated from the function's signature, and the compiler catches drift between the two sides at build time. Server and client talk to each other over WebSocket.

The wire format is reflective. Custom types, tuples, Options, Results, and primitives all serialize and rebuild automatically without `Decoder`s or `encode` functions. The on-wire shape is `{"fn": "...", "args": [...]}` for the call and `{"@": "ok", "v": [...]}` for the response: simple enough to `tcpdump` and read.

## Install

In your server package:

```bash
gleam add libero
```

And the same in your client package. Libero is cross-target (Erlang + JavaScript), so server and client both depend on it.

## Quick tour

### The server function

```gleam
// server/src/server/records.gleam

import shared/record.{type Record, type SaveError}
import sqlight

/// @rpc
pub fn save(
  conn conn: sqlight.Connection,
  name name: String,
  email email: String,
) -> Result(Record, SaveError) {
  // ... run some sql, return a Record or a SaveError ...
}
```

The first labelled parameter (`conn`) matches a `/// @inject` function declared elsewhere. Libero plumbs the session-derived value in automatically at dispatch time. Subsequent labelled parameters (`name`, `email`) are wire-exposed, so the client stub takes them. The return type can be a bare `T` or `Result(T, E)`, and both shapes are handled.

### The inject function

```gleam
// server/src/server/rpc_inject.gleam

import server/session.{type Session}
import sqlight

/// @inject
pub fn conn(session: Session) -> sqlight.Connection {
  session.db
}
```

Every `@rpc` function's first labelled parameter whose label matches an `@inject` function's name gets the inject fn's result injected at dispatch time. Inject fns take your `Session` type as input. The `Session` type is inferred from the first inject fn found, and all inject fns in a namespace must share the same `Session` type.

If you have zero inject fns, libero uses `Session = Nil`. Your WebSocket handler passes `Nil` to the dispatch entry point.

### The generated dispatch

After `gleam run -m libero -- --ws-url=wss://your.host/ws/rpc`, libero writes:

```
server/src/server/generated/libero/rpc_dispatch.gleam    # pub fn handle(session:, text:)
client/src/client/generated/libero/rpc/records.gleam     # pub fn save(..., on_response:)
client/src/client/generated/libero/rpc_config.gleam      # pub const ws_url
```

### Your WebSocket handler

Hand-written, stays tiny:

```gleam
// server/src/server/websocket.gleam

import libero/error.{type PanicInfo, PanicInfo}
import server/generated/libero/rpc_dispatch

pub fn handle_message(state, message, conn) {
  case message {
    mist.Text(text) -> {
      let #(response, maybe_panic) =
        rpc_dispatch.handle(session: state.session, text: text)
      log_panic(maybe_panic)
      let _ = mist.send_text_frame(conn, response)
      mist.continue(state)
    }
    _ -> mist.continue(state)
  }
}
```

`handle` returns both the wire response and an `Option(PanicInfo)`. If a server fn panicked, `PanicInfo` carries the trace id, function name, and stringified reason. Route that to `wisp.log_error`, Sentry, Datadog, or wherever you want. Libero itself has no logging dependency.

### The client call

```gleam
import client/generated/libero/rpc/records as rpc_records
import shared/record.{type Record, type SaveError}
import libero/error.{type RpcError, AppError, InternalError, MalformedRequest, UnknownFunction}

pub type Msg {
  RecordSaved(Result(Record, RpcError(SaveError)))
  // ...
}

// In your update:
FormSubmitted -> #(
  Model(..model, saving: True),
  rpc_records.save(
    name: model.form.name,
    email: model.form.email,
    on_response: RecordSaved,
  ),
)

RecordSaved(Ok(record)) -> { /* merge into list, clear form */ }
RecordSaved(Error(AppError(DuplicateEmail))) -> { /* show form error */ }
RecordSaved(Error(InternalError(trace_id))) -> { /* show generic error */ }
RecordSaved(Error(_)) -> { /* framework fallthrough */ }
```

The compiler statically checks that you handle every `RpcError` variant.

## CLI flags

Libero's generator is driven by three flags:

- **`--ws-url=<url>`** — *required*, no default. WebSocket URL baked into the generated `rpc_config.gleam`. Forcing it at the call site means nobody accidentally ships stubs pointing at a dev URL.
- **`--namespace=<name>`** — optional, no default. When set, drives every path by directory convention and prefixes wire names.
- **`--client=<path>`** — optional, defaults to `../client`. Path to the client package root. Only needed for non-standard layouts.

All other paths are derived by convention.

Without a namespace:

- scan root: `src/server`
- dispatch output: `src/server/generated/libero/rpc_dispatch.gleam`
- stub root: `{client}/src/client/generated/libero/rpc`
- config output: `{client}/src/client/generated/libero/rpc_config.gleam`

With `--namespace=admin`:

- scan root: `src/server/admin`
- dispatch output: `src/server/generated/libero/admin/rpc_dispatch.gleam`
- stub root: `{client}/src/client/generated/libero/admin/rpc`
- config output: `{client}/src/client/generated/libero/admin/rpc_config.gleam`

Invoke from your server package directory:

```bash
cd server
gleam run -m libero -- --ws-url=wss://your.host/ws/rpc
```

## Multi-SPA

When your project has multiple SPAs sharing a server (admin + public, say), invoke libero once per namespace:

```bash
gleam run -m libero -- --ws-url=wss://your.host/admin/ws/rpc --namespace=admin
gleam run -m libero -- --ws-url=wss://your.host/public/ws/rpc --namespace=public
```

Each namespace scans `src/server/<ns>/**` recursively and gets its own `/// @inject` functions, `Session` type, and `handle_<ns>` entry point — so admin can carry `User + DB` while public carries `CartCookie`. Wire names are prefixed with the namespace, so `admin.items.save` is distinct from `public.items.save` even if the function names collide. Your server router mounts one WebSocket endpoint per namespace and calls the matching dispatch.

## Error envelope

Every RPC response follows this shape:

```gleam
pub type RpcError(e) {
  /// Server function returned a Result(T, E) with Error(value).
  /// Only present when the function's return type is Result(T, E).
  AppError(e)

  /// The server couldn't decode the incoming envelope. Usually a
  /// client-side bug or deployment skew.
  MalformedRequest

  /// The wire `fn` name doesn't match any dispatch case. Usually
  /// deployment skew (client built against a newer server).
  UnknownFunction(name: String)

  /// Server function panicked. The real panic is logged server-side
  /// under this opaque trace_id.
  InternalError(trace_id: String)
}
```

Bare-return functions are exposed as `Result(T, RpcError(Never))`. `Never` is an uninhabited type, so the `AppError(_)` arm is statically unreachable and you can omit it from your pattern match. Functions that return `Result(T, E)` use `RpcError(E)` and require the full match.

## Runnable example

See [`examples/fizzbuzz/`](./examples/fizzbuzz/) for a self-contained FizzBuzz calculator with three RPC functions that exercise different parts of the generator:

- `classify(n) -> String` is a bare return with a single arg, using only primitives.
- `range(from, to) -> Result(List(String), String)` is a wrapped return with multi-arg, demonstrating the `AppError` envelope branch.
- `crash(label) -> String` is a bare return that panics on a specific input, demonstrating libero's panic recovery and `trace_id` flow.

Run it:

```bash
cd examples/fizzbuzz
./bin/dev
```

Then open <http://localhost:4000>.

## License

MIT. See [LICENSE](./LICENSE).
