# Libero

Typed RPC for Gleam + Lustre SPAs, generated from `/// @rpc` annotations. No REST routes, no JSON codecs, no hand-written dispatch tables.

Libero is the defensive specialist in volleyball, who handles passes and digs so the rest of the team can focus on hits. This library handles the wire plumbing (serialization, dispatch, error envelopes, panic recovery) so your app can focus on its domain logic.

```gleam
// server/src/server/fizzbuzz.gleam
import gleam/int

/// @rpc
pub fn classify(n n: Int) -> String {
  case int.modulo(n, 3), int.modulo(n, 5) {
    Ok(0), Ok(0) -> "FizzBuzz"
    Ok(0), _ -> "Fizz"
    _, Ok(0) -> "Buzz"
    _, _ -> int.to_string(n)
  }
}
```

```gleam
// client/src/client/app.gleam  (snippet)
import client/generated/libero/rpc/fizzbuzz as rpc_fizzbuzz

// Somewhere in your Lustre update function:
Classify ->
  #(
    model,
    rpc_fizzbuzz.classify(n: 15, on_response: ClassifyResponse),
  )
```

The client stub's signature (`n: Int`, `on_response: fn(Result(String, RpcError(Never))) -> msg`) is generated at build time from the server function's signature. Types go in, types come out, and the compiler catches every mismatch.

## What it does

Mark a `pub fn` with `/// @rpc` and libero generates a dispatch case on the server side and a typed stub on the client side. Both talk to each other over WebSocket.

Every response is `Result(T, RpcError(E))`. The four `RpcError` variants cover domain errors (`AppError(e)`), malformed wire traffic, unknown functions, and runtime panics with a trace id.

Generated dispatch wraps every call in `trace.try_call`, so a server panic becomes a typed `InternalError(trace_id)` envelope for the client plus a `PanicInfo` bubble for your WebSocket handler to log. The WebSocket connection is never dropped.

The wire format is reflective. Custom types, tuples, Options, Results, and primitives all serialize and rebuild automatically without `Decoder`s or `encode` functions. The on-wire shape is `{"fn": "...", "args": [...]}` for the call and `{"@": "ok", "v": [...]}` for the response: simple enough to `tcpdump` and read.

Multi-SPA is a flag. Pass `--namespace=admin` for an admin SPA, `--namespace=public` for a public SPA, and libero generates parallel dispatch files with namespaced wire names like `admin.items.save` or `public.cart.add`.

## What it isn't

Libero is not a framework. It generates code and provides a wire format plus an error envelope. Everything else (state management, caching, optimistic updates, subscriptions, retries) lives in your app. A consumer that wants Elm-style `RemoteData` wraps responses themselves. A consumer that wants inline state does the same.

Libero is not a REST replacement for public APIs. The wire is designed for same-origin WebSocket traffic between your own server and your own SPA. If you're exposing a JSON API for third-party clients, keep REST.

Libero is not stateful. Every RPC is a strict request/response. If you need server push, layer a separate mechanism on top.

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

The compiler statically checks that you handle every `RpcError` variant. The `AppError(e)` arm is only present when the server function returns `Result(T, E)` with a non-`Never` error type. Bare-return functions use `RpcError(Never)` and the exhaustiveness checker lets you skip the `AppError` arm.

## CLI flags

Libero's generator is driven by three flags:

- **`--ws-url=<url>`** — *required*, no default. WebSocket URL baked into the generated `rpc_config.gleam`. There's no default, not even localhost. Forcing it at the call site means nobody accidentally ships stubs pointing at a dev URL.
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

Each namespace scans `src/server/<ns>/**` recursively (nested directories are fine). Each namespace gets its own `/// @inject` functions and `Session` type, so admin can carry `User + DB` while public carries `CartCookie`. Wire names are prefixed with the namespace, so `admin.items.save` is distinct from `public.items.save` even if the function names collide. Each namespace also gets its own `handle_<ns>` entry point (`handle_admin`, `handle_public`), and your server router mounts one WebSocket endpoint per namespace and calls the matching dispatch.

Nothing is shared between namespaces at the wire level. Two SPAs, two dispatch files, two `Session` types, zero cross-contamination.

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

## Testing

Libero's own test suite covers the wire codec (`libero/wire`) and the panic primitive (`libero/trace`):

```bash
gleam test
```

End-to-end validation of the generator happens through the fizzbuzz example. If the templates regress, the example fails to compile.

## License

MIT. See [LICENSE](./LICENSE).
