# Libero

A full-stack Gleam framework with typed RPC. Define your messages, write your handlers, Libero handles everything between your code and the wire.

Like server components, but your client is a real SPA with typed RPC — and the same server logic works for any client out of the box.

## Getting Started

```bash
# From a project that depends on libero:
gleam run -m libero -- new my_app
cd my_app
gleam run -m libero -- add web --target javascript
gleam run -m libero -- build
gleam run
# Server running on http://localhost:8080
```

## Project Structure

```
my_app/
  gleam.toml                         # server package + [libero] config
  src/
    server/
      handler.gleam                  # your business logic
      shared_state.gleam             # server state type
      app_error.gleam                # error type
      generated/                     # dispatch, websocket, push (auto-generated)
    my_app.gleam                     # server entry point (auto-generated)
  shared/
    gleam.toml                       # target-agnostic package
    src/shared/
      messages.gleam                 # your message types
  clients/
    web/
      gleam.toml                     # client package (auto-generated if missing)
      src/
        app.gleam                    # your Lustre SPA
        generated/                   # client stubs (auto-generated)
  test/
    my_app_test.gleam                # handler test
```

The root `gleam.toml` is the **server package** (target: erlang). It also holds the `[libero]` config that declares clients and settings. `src/server/` is where your handlers and business logic live.

`shared/` and `clients/` are **separate Gleam packages** nested inside the project, each with their own `gleam.toml`. This is necessary because Gleam compiles to a single target per package — the server targets Erlang while JS clients target JavaScript. They can't live in the same package.

`shared/` exists so both sides can import the same message types. It has no target specified, so it compiles to both Erlang and JavaScript. Without it, JS clients would need to depend on the server package and pull in Erlang-only dependencies (mist, ETS, etc.).

```
root (server)     → shared, libero, mist     [target: erlang]
clients/web       → shared, libero, lustre   [target: javascript]
```

## Messages

Define `MsgFromClient` and `MsgFromServer` in any module under `shared/src/shared/`. Libero scans for these types and generates dispatch + client stubs from them.

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

Each `MsgFromServer` variant wraps a single value, typically a `Result(payload, error)`.

## Handlers

Export `update_from_client` in any module under `src/`. Libero discovers it by scanning for the function signature.

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

## Client Usage

The generated stubs let clients send typed messages:

```gleam
// In a Lustre SPA:
import generated/messages as rpc

ToggleTodo(id) ->
  #(model, rpc.send_to_server(msg: Toggle(id:), on_response: GotResponse))
```

## Configuration

All config lives in `gleam.toml` under the `[libero]` section:

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

[libero.clients.cli]
target = "erlang"
```

## CLI

```
gleam run -m libero -- <command>

Commands:
  new <name>                    Create a new project
  add <name> --target <target>  Add a client
  gen                           Regenerate stubs
  build                         Gen + build server + all clients
```

### `libero new <name>`
Scaffolds a project with `src/server/` (skeleton handler), `shared/` (skeleton messages), `test/` (handler test), and `gleam.toml`.

### `libero add <name> --target <target>`
Adds a client. Creates `clients/<name>/` with its own `gleam.toml` (generated once, never overwritten) and a starter app.

### `libero gen`
Scans `shared/src/shared/` for message types and generates dispatch, stubs, and server entry point. Run after changing message types.

### `libero build`
Runs `gen`, then builds the server and each client package.

## What Gets Generated

**Server-side (`src/server/generated/`):**
- `dispatch.gleam` -- routes incoming messages to handlers
- `websocket.gleam` -- Mist WebSocket handler with push support
- Per-module push wrappers (`send_to_client`, `send_to_clients`)

**Server entry point (`src/<app_name>.gleam`):**
- Boots Mist with WebSocket, HTTP RPC, and static file serving
- Serves HTML shell at `/` that loads the first JS client

**Per client (`clients/<name>/src/generated/`):**
- Typed `send_to_server` and `update_from_server` stubs
- WebSocket config and typed decoder registration
- SSR flag reader (for hydration)

Generation rules:
- Starter apps and client `gleam.toml` -- generated once, never overwritten
- Everything in `generated/` -- regenerated every `libero gen` or `libero build`

## How It Works

The wire format is [ETF](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html) (Erlang Term Format) over binary WebSocket frames. Gleam types serialize automatically without explicit codecs.

The client sends a `{module_path, MsgFromClient_value}` tuple. The server dispatch decodes it, routes by module path, and calls the handler. The response flows back as `Result(payload, RpcError)`.

## Server Push

The server can push messages to connected clients without a prior request. Uses BEAM [pg](https://www.erlang.org/doc/apps/kernel/pg.html) groups -- no external dependencies.

```gleam
// Server -- push to all subscribers
import server/generated/messages as messages_push
messages_push.send_to_clients(topic: "todos", msg: TodosLoaded(Ok(all())))

// Client -- subscribe to pushes (in init)
rpc.update_from_server(handler: fn(raw) { GotPush(wire.coerce(raw)) })
```

## Multiple Clients

Add as many clients as you need. Each is a name + a target:

```bash
gleam run -m libero -- add web --target javascript      # Lustre SPA
gleam run -m libero -- add cli --target erlang           # BEAM CLI
gleam run -m libero -- add admin --target javascript     # separate admin SPA
```

The same handlers serve all clients. Each client gets typed stubs for its target.

## HTTP Clients

Any BEAM process can call the server over HTTP POST without WebSocket or a Libero dependency:

```gleam
let payload = term_to_binary(#("shared/messages", LoadAll))
let assert Ok(response) = httpc.request(Post, "http://localhost:8080/rpc", payload)
let result = binary_to_term(response.body)
```

## When to Use Libero

Libero is a good fit when:
- You want a real SPA (offline support, low-latency UI, mobile)
- You want multiple client types from one server
- You want typed end-to-end communication without JSON codecs
- You want clear client/server state boundaries

## Prior Art & Credits

Libero's JS-side ETF codec is independently implemented but aligns with [arnu515/erlang-etf.js](https://github.com/arnu515/erlang-etf.js) (MIT) on `BIT_BINARY_EXT` handling and atom-length validation. Credit to that project for clear spec references — libero's codec adds encoding, a BEAM-native path, the float field registry, and offset-based parsing.

## License

MIT. See [LICENSE](https://github.com/pairshaped/libero/blob/master/LICENSE).
