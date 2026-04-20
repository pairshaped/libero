# Libero Context

Libero is a full-stack Gleam framework with typed RPC. Define message types, write handlers, Libero generates dispatch, client stubs, and server bootstrap. Transport is WebSocket with ETF encoding. No REST, no JSON codecs, no manual dispatch.

## Project Structure

```
my_app/
  gleam.toml                       # server package (erlang) + [libero] config
  src/
    server/
      handler.gleam                # update_from_client function
      shared_state.gleam           # server state type
      app_error.gleam              # error type
      generated/                   # dispatch, websocket, push (auto-generated)
    my_app.gleam                   # server entry point (auto-generated)
  shared/
    gleam.toml                     # target-agnostic package
    src/shared/
      messages.gleam               # MsgFromClient, MsgFromServer types
  clients/
    web/
      gleam.toml                   # client package (javascript), generated if missing
      src/
        app.gleam                  # Lustre SPA
        generated/                 # client stubs (auto-generated)
  test/
    my_app_test.gleam
```

The root `gleam.toml` is the **server package** (target: erlang). It also holds the `[libero]` config that declares clients and settings. Gleam compiles to a single target per package, so `shared/` and `clients/` are separate nested packages (each with their own `gleam.toml`). `shared/` has no target, so it compiles to both Erlang and JavaScript — this lets both the server and JS clients import the same message types without the client pulling in Erlang-only dependencies.

```
root (server)     → shared, libero, mist     [target: erlang]
clients/web       → shared, libero, lustre   [target: javascript]
```

Rules:
- `src/server/` is server code. Handlers, state, and business logic live here.
- `shared/src/shared/` holds message types and domain types shared across targets.
- `clients/<name>/` are consumer apps, each a separate Gleam package.
- Never edit files in `generated/` directories.
- Each client's `gleam.toml` is generated once by `libero add`, never overwritten.

## CLI

```bash
gleam run -m libero -- new <name>                     # scaffold project
gleam run -m libero -- add <name> --target <target>   # add a client
gleam run -m libero -- gen                            # regenerate stubs
gleam run -m libero -- build                          # gen + build server + all clients
```

## Configuration

Libero config lives in `gleam.toml` under `[libero]`:

```toml
name = "my_app"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
gleam_erlang = "~> 1.0"
gleam_http = "~> 4.0"
mist = "~> 6.0"
lustre = "~> 5.6"
shared = { path = "shared" }
libero = { path = "../libero" }

[libero]
port = 8080

[libero.clients.web]
target = "javascript"
```

## Message Types

Libero scans `shared/src/shared/` for modules exporting `MsgFromClient` and/or `MsgFromServer`:

```gleam
// shared/src/shared/messages.gleam

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
- Wrap that field in `Result(payload, DomainError)` for RemoteData integration.
- File layout is free. Libero scans for the type names, not file paths.
- Multiple message modules are supported (e.g., `messages.gleam`, `auth.gleam`). Each gets its own stubs.

## Server Handler

Handlers export `update_from_client` with this signature:

```gleam
// src/server/handler.gleam

import shared/messages.{type MsgFromClient, type MsgFromServer}
import server/shared_state.{type SharedState}
import server/app_error.{type AppError}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    messages.LoadAll -> Ok(#(TodosLoaded(Ok(all())), state))
    messages.Create(params:) -> Ok(#(TodoCreated(Ok(insert(params.title))), state))
    // ...
  }
}
```

- Domain errors go inside the `MsgFromServer` field: `Ok(#(TodoCreated(Error(NotFound)), state))`.
- App-level errors go in the outer Result: `Error(AppError("db connection lost"))`.
- Multiple handlers per module supported. Return `Error(UnhandledMessage)` to pass to the next handler.
- `SharedState` is typically a unit type. Actual state lives in ETS or a database.

## Client Usage (Lustre)

```gleam
// clients/web/src/app.gleam

import generated/messages as rpc
import libero/remote_data.{type RemoteData, type RpcFailure, Loading, Success, Failure}
import libero/wire

pub type Model {
  Model(items: RemoteData(List(Todo), RpcFailure))
}

pub type Msg {
  TodosLoadedMsg(RemoteData(List(Todo), RpcFailure))
  GotPush(MsgFromServer)
}

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  let subscribe = rpc.update_from_server(handler: fn(raw) {
    GotPush(wire.coerce(raw))
  })
  #(Model(items: Loading), effect.batch([load_all(), subscribe]))
}

fn load_all() -> Effect(Msg) {
  rpc.send_to_server(msg: LoadAll, on_response: fn(raw) {
    TodosLoadedMsg(remote_data.to_remote(raw:, format_domain: format_error))
  })
}
```

Key patterns:
- `rpc.send_to_server()` returns a Lustre `Effect`. Wire encoding handled internally.
- `remote_data.to_remote(raw, format_error)` converts wire response to `RemoteData`.
- `wire.coerce(raw)` casts `Dynamic` to a typed value (safe when built from same types).
- Push messages arrive via `rpc.update_from_server()` subscription.

## BEAM Clients (CLI, Services)

Any BEAM process can call the server over HTTP POST with native ETF:

```gleam
let payload = term_to_binary(#("shared/messages", LoadAll))
let assert Ok(response) = httpc.request(Post, "http://localhost:8080/rpc", payload)
let result = binary_to_term(response.body)
```

No WebSocket, no generated stubs, no Libero dependency needed. Push is WebSocket-only.

## Server Push

Server can broadcast to connected clients using BEAM pg groups:

```gleam
import server/generated/messages as messages_push

// Broadcast to all clients on a topic
messages_push.send_to_clients(topic: "todos", msg: TodosLoaded(Ok(items)))

// Send to a specific client
messages_push.send_to_client(client_id: "user:42", msg: TodoCreated(Ok(item)))
```

Topics are set during WebSocket upgrade (in the generated server entry point).

## Server-Side Rendering (SSR)

SSR lets the server pre-render the initial page HTML with real data so the browser displays content immediately — no loading spinner, no blank page while JavaScript boots. The client then hydrates the pre-rendered DOM (attaches event handlers, connects WebSocket) and takes over as a normal SPA. Users see content faster, and search engines see fully rendered pages.

The `libero/ssr` module provides four functions:

### `ssr.call` -- fetch data on the server

Calls `dispatch.handle` directly (no network) to fetch data for rendering. The `expect` parameter unwraps the `MsgFromServer` response into the value you need (like Elm's `Http.expect`):

```gleam
import libero/ssr
import shared/messages.{CounterUpdated, GetCounter}

let assert Ok(counter) =
  ssr.call(
    handle: dispatch.handle,
    state:,
    module: "shared/messages",
    msg: GetCounter,
    expect: fn(resp) {
      let assert CounterUpdated(Ok(n)) = resp
      n
    },
  )
// counter: Int
```

The `expect` function receives the `MsgFromServer` variant and extracts the payload. Without it, the caller would get the full envelope (e.g. `CounterUpdated(Ok(0))`) instead of the inner value, which compiles but crashes at runtime due to type coercion in the wire layer.

### `ssr.encode_flags` / `ssr.decode_flags` -- pass state to client

Server encodes a value as base64 ETF. Client decodes it in `init`:

```gleam
// Server: encode for embedding in HTML
let flags = ssr.encode_flags(counter)

// Client: decode in Lustre init
fn init(flags: Dynamic) -> #(Model, Effect(Msg)) {
  let counter = case ssr.decode_flags(flags) {
    Ok(n) -> n
    Error(_) -> 0
  }
  // ...
}
```

The flags are embedded as `window.__LIBERO_FLAGS__` by `ssr.document`. The generated `ssr.read_flags()` (in `clients/<name>/src/generated/ssr.gleam`) reads them from the DOM.

### `ssr.document` -- render the full HTML page

Wraps pre-rendered HTML, flags, and a client module import into a complete document:

```gleam
let body = element.to_string(views.view(model))
let flags = ssr.encode_flags(counter)
let html =
  ssr.document(
    title: "My App",
    body:,
    flags:,
    client_module: "/web/web/app.mjs",
  )
```

### SSR project structure

For SSR, view functions must live in `shared/` so they compile to both Erlang (server rendering) and JavaScript (client hydration). The `shared/` package needs a `lustre` dependency.

```
shared/src/shared/
  messages.gleam     # MsgFromClient, MsgFromServer (same as non-SSR)
  views.gleam        # view functions, Model, Msg, Route types
```

The server entry point (`src/<app>.gleam`) is generated once and never overwritten, so it can be customized to add SSR routes. See `examples/counter/` for a working example.

## What Gets Generated

**Server dispatch (`src/server/generated/`):**
- `dispatch.gleam` -- routes messages to handlers
- `websocket.gleam` -- Mist WebSocket handler with push (pure Gleam, no FFI)
- `<module>.gleam` -- push wrappers per message module

**Server entry point (`src/<app_name>.gleam`):**
- Boots Mist with WebSocket on `/ws`, HTTP RPC on `/rpc`
- Serves HTML shell at `/` loading the first JS client
- Serves client JS bundles at `/<client_name>/*`

**Per client (`clients/<name>/src/generated/`):**
- `<module>.gleam` -- `send_to_server` and `update_from_server` stubs
- `rpc_config.gleam` -- WebSocket URL
- `rpc_decoders.gleam` + `.mjs` -- typed decoder for ETF decoding
- `ssr.gleam` + `.mjs` -- SSR flag reader

**Atom registration (`src/<app>@generated@rpc_atoms.erl`):**
- Pre-registers Erlang atoms for safe ETF decoding

## Wire Protocol

- Format: ETF (Erlang External Term Format). Binary, not text.
- Call envelope: `{module_path, MsgFromClient_value}` (e.g., `{"shared/messages", LoadAll}`).
- Response: `Result(payload, RpcError(AppError))`. The `MsgFromServer` variant wrapper is stripped.
- Frame tags: byte `0` = response, byte `1` = push.

## Error Model

Three tiers:
1. **Domain errors** -- inside `MsgFromServer` field: `Result(payload, DomainError)`. User-facing.
2. **App errors** -- handler returns `Error(AppError(...))`. Wire envelope: `Error(AppError(value))`.
3. **Framework errors** -- `MalformedRequest`, `UnknownFunction(name)`, `InternalError(trace_id, message)`.

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

## Key Dependencies

- `lustre` -- Gleam UI framework (client, compiles to JS)
- `mist` -- HTTP/WebSocket server (server, runs on BEAM)
- `glance` -- Gleam parser (used by codegen to scan modules)
- `tom` -- TOML parser (reads `[libero]` config from gleam.toml)
