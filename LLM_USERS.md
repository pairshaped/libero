# Libero Context

Libero is a typed RPC framework for Gleam SPAs using Lustre. It generates client/server glue from shared message type definitions. Transport is WebSocket with ETF (Erlang Term Format) encoding. No REST, no JSON codecs, no manual dispatch.

## Project Structure

A Libero app is three Gleam packages:

```
shared/   -- Gleam, target: erlang. Message types + domain types only. No logic.
server/   -- Gleam, target: erlang. Handlers, bootstrap, state. Depends on shared + libero + mist.
client/   -- Gleam, target: javascript. Lustre SPA. Depends on shared + libero + lustre.
```

Codegen writes into `server/src/<app>/generated/libero/` and `client/src/<app>/generated/libero/`. Never hand-edit generated files.

## Message Types (The Core Contract)

All of Libero flows from two type names in shared modules:

```gleam
// shared/src/shared/todos.gleam

pub type MsgFromClient {
  Create(params: TodoParams)
  Toggle(id: Int)
  Delete(id: Int)
  LoadAll
}

pub type MsgFromServer {
  TodoCreated(Result(Todo, TodoError))
  TodoToggled(Result(Todo, TodoError))
  TodoDeleted(Result(Int, TodoError))
  TodosLoaded(Result(List(Todo), TodoError))
}
```

Rules:
- Every `MsgFromServer` variant must have exactly one field.
- Wrap that field in `Result(payload, DomainError)` to get RemoteData integration.
- File layout is free. Libero scans for the type names `MsgFromClient` and `MsgFromServer`, not file paths.
- You can have multiple shared modules (e.g., `shared/todos.gleam`, `shared/auth.gleam`). Each gets its own generated stubs.

## Server Handler

Handlers must export this exact signature:

```gleam
// server/src/server/store.gleam

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError)
```

- Pattern match on `msg` to handle each `MsgFromClient` variant.
- Return `#(response_msg, new_state)` wrapped in `Result`.
- Domain errors go inside the `MsgFromServer` field: `Ok(#(TodoCreated(Error(NotFound)), state))`.
- App-level errors go in the outer Result: `Error(AppError("db connection lost"))`.
- Multiple handlers per module are supported. Return `Error(UnhandledMessage)` to pass to the next handler in the chain.

`SharedState` is typically a unit type. Actual state lives in ETS, a database, or OTP processes. Handlers query/mutate external stores directly.

## Client Usage (Lustre)

```gleam
// client/src/client/app.gleam

import client/generated/libero/todos as rpc
import libero/remote_data.{type RemoteData, Loading, NotAsked, Success, Failure}
import libero/remote_data
import libero/wire
import shared/todos.{type MsgFromServer, type Todo}

pub type Model {
  Model(
    items: RemoteData(List(Todo), String),
  )
}

pub type Msg {
  TodosLoadedMsg(RemoteData(List(Todo), String))
  GotPush(MsgFromServer)
}

pub fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  // Subscribe to server pushes + fetch initial data
  let subscribe = rpc.update_from_server(handler: fn(raw) {
    GotPush(wire.coerce(raw))
  })
  #(Model(items: Loading), effect.batch([load_all(), subscribe]))
}

fn load_all() -> Effect(Msg) {
  rpc.send_to_server(msg: todos.LoadAll, on_response: fn(raw) {
    TodosLoadedMsg(remote_data.to_remote(raw, format_error))
  })
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TodosLoadedMsg(rd) -> #(Model(..model, items: rd), effect.none())
    GotPush(todos.TodosLoaded(Ok(items))) -> #(Model(..model, items: Success(items)), effect.none())
    GotPush(_) -> #(model, effect.none())
  }
}

pub fn view(model: Model) -> Element(Msg) {
  case model.items {
    NotAsked | Loading -> html.p([], [element.text("Loading...")])
    Failure(err) -> html.p([], [element.text("Error: " <> err)])
    Success(items) -> view_list(items)
  }
}
```

Key patterns:
- `rpc.send_to_server()` returns a Lustre `Effect`. Wire encoding is handled internally.
- `remote_data.to_remote(raw, format_error)` converts the wire response into `RemoteData`.
- `wire.coerce(raw)` casts a `Dynamic` to a typed value (safe when client/server are built from the same shared types).
- Push messages arrive via `rpc.update_from_server()` subscription, separate from request/response flow.

## BEAM Clients (CLI, Services, Scripts)

Any BEAM process (Gleam, Erlang, Elixir) can be a Libero client over HTTP with no Libero dependency. The wire format is native ETF, so you just use `term_to_binary`/`binary_to_term`:

```gleam
// cli/src/cli.gleam

// Call envelope is a tuple: {module_name, MsgFromClient_value}
let payload = term_to_binary(#("shared/todos", LoadAll))

// POST to the server's /rpc endpoint
let response = httpc.request(Post, "http://localhost:8080/rpc", payload)

// Response is Result(payload, RpcError) in ETF
let result: Result(List(Todo), String) = binary_to_term(response.body)
```

No WebSocket, no generated stubs, no Libero import. The server's `dispatch.handle()` handles both HTTP and WebSocket calls identically. This works for CLI tools, backend services, batch jobs, or any BEAM process that needs to call Libero handlers.

Push (server-initiated messages) is WebSocket-only. HTTP clients only get request/response.

## JavaScript Clients (Non-Lustre)

Libero includes a JavaScript ETF encoder/decoder (`rpc_ffi.mjs`) that the generated Lustre client uses internally. Non-Lustre JS clients (Node, Deno, browser fetch) can use the same codec to call the `/rpc` HTTP endpoint:

```javascript
// Encode a call envelope: {module_name, MsgFromClient_value}
const payload = ETFEncoder.encode(["shared/todos", constructLoadAll()]);

// POST to the server
const response = await fetch("http://localhost:8080/rpc", {
  method: "POST",
  body: payload,
});

// Decode the ETF response: Result(payload, RpcError)
const result = ETFDecoder.decode(new Uint8Array(await response.arrayBuffer()));
```

The codec requires constructor registration (so it can reconstruct typed Gleam values from ETF atoms). The generated `rpc_register.gleam`/`.mjs` files handle this for Lustre clients. Non-Lustre JS clients would need equivalent registration for the types they use.

For languages without an ETF library (Python, Ruby, Go, etc.), there is currently no JSON wire format. Non-BEAM, non-JS clients would need a third-party ETF library or a JSON gateway in front of Libero.

## RemoteData

```gleam
pub type RemoteData(value, error) {
  NotAsked    // No request made
  Loading     // Request in flight
  Failure(error)
  Success(value)
}
```

Helpers: `to_remote`, `to_result`, `map`, `map_error`, `unwrap`, `to_option`, `is_success`, `is_loading`.

## Server Push

Server can broadcast to clients subscribed to a topic:

```gleam
// In server handler or anywhere on the BEAM
import server/generated/libero/todos as todos_push

// Broadcast to all clients on a topic
todos_push.send_to_clients(topic: "todos", msg: TodosLoaded(Ok(all_items)))

// Send to a specific client
todos_push.send_to_client(client_id: client_id, msg: TodoCreated(Ok(item)))
```

Topic subscriptions are set during WebSocket upgrade:

```gleam
ws.upgrade(request: req, state: shared, topics: ["todos"], logger: logger)
```

Push uses BEAM pg (process groups). No external dependencies.

## Server Bootstrap

```gleam
// server/src/server.gleam
import server/generated/libero/websocket as ws

pub fn main() {
  store.init()
  push.init()
  let shared = shared_state.new()

  let assert Ok(_) =
    fn(req) {
      case req.method, request.path_segments(req) {
        _, ["ws"] -> ws.upgrade(request: req, state: shared, topics: ["todos"], logger: logger)
        http.Post, ["rpc"] -> handle_rpc(req, shared)  // HTTP endpoint (optional)
        _, _ -> serve_static(req)
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}
```

The HTTP `/rpc` endpoint calls `dispatch.handle(state, body)` directly -- same handler as WebSocket, different transport.

## Codegen

Run from the server package:

```bash
gleam run -m libero -- \
  --ws-path=/ws \
  --shared=../shared \
  --server=. \
  --client=../client
```

Flags:
- `--ws-url=<url>` or `--ws-path=<path>` (one required). `--ws-path` resolves from `window.location` at runtime.
- `--shared=<path>` (required). Path to shared package.
- `--server=<path>` (optional, defaults to `.`).
- `--client=<path>` (optional, defaults to `../client`).
- `--namespace=<name>` (optional). Scopes generated paths for multi-SPA setups.

Generated files:
- **Server:** `dispatch.gleam` (routes messages to handlers), `websocket.gleam` (Mist WebSocket handler), `<module>.gleam` (push wrappers per shared module), `rpc_atoms.erl` (atom pre-registration).
- **Client:** `<module>.gleam` (RPC stubs per shared module), `rpc_config.gleam` (WebSocket URL), `rpc_register.gleam` + `.mjs` (type registry for ETF decoder).

## Wire Protocol

- Format: ETF (Erlang External Term Format). Binary, not text.
- Call envelope: `{module_name_string, MsgFromClient_value}` (e.g., `{"shared/todos", LoadAll}`).
- Response envelope: `Result(payload, RpcError(AppError))`. The `MsgFromServer` variant wrapper is stripped (client pairs responses via FIFO order).
- Frame tags: byte `0` prefix = response (routed to FIFO callback queue), byte `1` prefix = push (routed to push handler).
- BEAM clients (Gleam/Erlang/Elixir) can call the HTTP endpoint directly using native `term_to_binary`/`binary_to_term` with no Libero dependency.

## Error Model

Three tiers:

1. **Domain errors** -- inside `MsgFromServer` field: `Result(payload, DomainError)`. Expected, user-facing. Surfaces via RemoteData.
2. **App errors** -- handler returns `Error(AppError(...))`. Unexpected but recoverable. Wire envelope: `Error(AppError(value))`.
3. **Framework errors** -- `MalformedRequest`, `UnknownFunction(name)`, `InternalError(trace_id, message)`. Panics are caught, assigned a trace_id, and surfaced to the WebSocket logger.

## FIFO Response Matching

Client sends requests sequentially over WebSocket. Server responds in the same order. Client matches responses by position in a FIFO queue, not by message type. This is why the `MsgFromServer` variant wrapper is stripped from responses -- the client already knows which variant to expect based on request order.

## Key Dependencies

- `lustre` -- Gleam UI framework (client, compiles to JS)
- `mist` -- HTTP/WebSocket server (server, runs on BEAM)
- `gleam_crypto` -- used for trace IDs
- `glance` -- Gleam parser (used by codegen to scan shared modules)
