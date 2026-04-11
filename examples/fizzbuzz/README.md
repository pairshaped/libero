# FizzBuzz over libero RPC

A minimal libero consumer. Three `/// @rpc` functions, one Lustre client UI, no database, no shared package, no session context.

## What it shows

The example covers the three shapes libero handles for RPC return types, plus panic recovery:

- `classify(n) -> String` is a bare-T return with a single arg. Wire envelope on the client is `Result(String, RpcError(Never))`.
- `range(from, to) -> Result(List(String), String)` is a wrapped `Result(T, E)` return with multiple args. The wrong-direction case exercises the `AppError` branch of the error envelope.
- `crash(label) -> String` is a bare-T return that panics on the literal label `"boom"`, exercising libero's `trace.try_call` wrapper and surfacing an `InternalError(trace_id)` envelope to the client while logging the matching `PanicInfo` on the server.

## Layout

```
examples/fizzbuzz/
├── server/
│   ├── src/
│   │   ├── server.gleam              # Mist HTTP + WS entry point
│   │   └── server/
│   │       ├── fizzbuzz.gleam        # /// @rpc classify, range, crash
│   │       ├── websocket.gleam       # handles each WS message via libero
│   │       └── web.gleam             # serves index.html + static assets
│   └── priv/static/index.html        # loads the compiled Lustre bundle
├── client/
│   └── src/
│       ├── client.gleam              # Lustre entry point
│       └── client/app.gleam          # model / update / view
└── bin/dev                           # regenerate, build, start
```

After the first `bin/dev` run, libero adds two generated subtrees that aren't in the source checkout:

```
server/src/server/generated/libero/rpc_dispatch.gleam
client/src/client/generated/libero/rpc_config.gleam
client/src/client/generated/libero/rpc/fizzbuzz.gleam
```

These are regenerated on every `bin/dev` run from the `/// @rpc` functions in `server/src/server/**`. Don't edit them by hand.

## Run it

```bash
./bin/dev
```

Then open <http://localhost:4000>. Type a number into the Classify section, click Classify, and see the FizzBuzz label come back from the server. Try the Range section next (including an inverted range like `from=10, to=1` to see the `AppError` branch). Try the Crash section with the label `"boom"` to see `InternalError(trace_id)` flow through with matching server logs.

## The server surface

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

/// @rpc
pub fn range(from from: Int, to to: Int) -> Result(List(String), String) {
  case from <= to {
    False -> Error("from must be <= to")
    True -> Ok(build_labels(current: to, from: from, acc: []))
  }
}

/// @rpc
pub fn crash(label label: String) -> String {
  case label {
    "boom" -> panic as "you asked for it"
    _ -> "no boom"
  }
}
```

The `/// @rpc` doc comment tells libero to expose the function to the client. Wire format, dispatch routing, client stub, and error envelope are all generated from the signature.

## The client call

```gleam
// client/src/client/app.gleam  (snippet)

import client/generated/libero/rpc/fizzbuzz as rpc_fizzbuzz

// ...

Classify ->
  #(
    model,
    rpc_fizzbuzz.classify(n: 42, on_response: ClassifyResponse),
  )
```

The stub is type-safe. `rpc_fizzbuzz.classify` takes `n: Int` and responds with `Result(String, RpcError(Never))`. The compiler checks that your message handler covers the full response envelope.

## No session?

This example has zero `/// @inject` functions, so libero picks `Session = Nil` for the generated dispatch, and `websocket.gleam` passes `Nil` on every WS message:

```gleam
rpc_dispatch.handle(session: Nil, text: text)
```

Real apps typically have a `Session` type carrying a DB connection, user, CSRF token, and so on, with `/// @inject` functions that extract each piece into per-function labeled args. See libero's main README for how that works.

## What libero doesn't do

Libero has no caching, no retries, and no optimistic updates. That's your model's job.

Libero has no subscriptions. RPCs are strict request/response. If you need push updates, layer a separate mechanism on top.

Libero has no state-management opinions. It hands you `Effect(msg)` with a typed response. Whether you wrap it in `RemoteData`, handle it as `Result`, or something else is entirely up to your app.
