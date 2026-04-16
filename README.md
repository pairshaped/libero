# Libero

Libero generates typed messaging between clients and a [Gleam](https://gleam.run) server. You define message types in a shared module, and Libero produces a server dispatch function and client stubs from them. Browser clients (like [Lustre](https://hexdocs.pm/lustre/)) connect over WebSocket, [BEAM](https://www.erlang.org/blog/a-brief-beam-primer/) clients (Gleam, [Erlang](https://www.erlang.org), [Elixir](https://elixir-lang.org)) connect over HTTP. No REST routes, no JSON codecs, no hand-written dispatch tables.

## Convention

Every shared module that participates in Libero's codegen exports two types by convention:

```gleam
// shared/src/shared/todos.gleam

pub type MsgFromClient {
  Create(params: TodoParams)
  Toggle(id: Int)
  Delete(id: Int)
  LoadAll
}

pub type MsgFromServer {
  Created(Todo)
  Toggled(Todo)
  Deleted(id: Int)
  AllLoaded(List(Todo))
  TodoFailed(TodoError)
}
```

[`MsgFromClient`](https://github.com/pairshaped/libero/blob/master/examples/todos/shared/src/shared/todos.gleam) contains messages from the client to the server. `MsgFromServer` contains messages the server sends back, both as responses and as server-initiated pushes. A module can define one or both.

## Example usage

The client sends a message using the [generated stub](https://github.com/pairshaped/libero/blob/master/examples/todos/client/src/client/generated/libero/todos.gleam):

```gleam
// In your Lustre update:
import client/generated/libero/todos as todos_rpc

ToggleTodo(id) ->
  #(model, todos_rpc.send_to_server(msg: Toggle(id:), on_response: GotResponse))
```

The server handles it in the [handler module](https://github.com/pairshaped/libero/blob/master/examples/todos/server/src/server/store.gleam):

```gleam
// server/src/server/store.gleam

import shared/todos.{type MsgFromClient, type MsgFromServer}
import server/shared_state.{type SharedState}
import server/app_error.{type AppError}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    todos.LoadAll -> Ok(#(AllLoaded(all()), state))
    todos.Create(params:) -> ...
    todos.Toggle(id:) -> ...
    todos.Delete(id:) -> ...
  }
}
```

## WebSocket setup

The generated [`websocket.gleam`](https://github.com/pairshaped/libero/blob/master/examples/todos/server/src/server/generated/libero/websocket.gleam) handles dispatch, push frame forwarding, and topic cleanup. One call in your server:

```gleam
import server/generated/libero/websocket as ws

_, ["ws"] ->
  ws.upgrade(request: req, state: shared, topics: ["todos"])
```

The `topics` parameter controls which pg groups the client joins on connect. The generated handler automatically leaves all topics on disconnect.

## Server push

The server can push messages to connected clients without a prior request. Uses BEAM [pg](https://www.erlang.org/doc/apps/kernel/pg.html) groups for topic-based subscriptions, no external dependencies.

```gleam
// Server — in a handler, push to all subscribers via generated wrapper
import server/generated/libero/todos as todos_push
todos_push.send_to_clients(topic: "todos", msg: AllLoaded(all()))

// Server — targeted push to one client
push.register(client_id: "user:42")
todos_push.send_to_client(client_id: "user:42", msg: Created(item))
```

```gleam
// Client — subscribe to pushes (in init)
todos_rpc.update_from_server(handler: fn(raw) { GotPush(wire.coerce(raw)) })
```

Push is opt-in. If you never call `update_from_server`, push frames are silently dropped. If unused, tree shaking removes the generated code.

## HTTP clients

The generated `dispatch.handle(state:, data:)` function takes a `BitArray` and returns a `BitArray`. It doesn't know or care about the transport. This means any BEAM process can be a Libero client by sending ETF-encoded messages over HTTP POST. No WebSocket and no Libero dependency needed.

This works because [ETF](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html) is the BEAM's native serialization format. Any BEAM client (Gleam, Erlang, Elixir) can call `term_to_binary` on the same shared types the browser uses, POST the bytes, and decode the response with `binary_to_term`. The server runs the same dispatch logic either way.

```gleam
// Server: add an HTTP route that calls the same dispatch
fn handle_rpc(req, state) {
  use body <- wisp.require_body(req)
  let #(response, _, _) = dispatch.handle(state:, data: body)
  wisp.ok() |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(response)))
}
```

```gleam
// Any BEAM client: encode, POST, decode
let payload = term_to_binary(#("shared/todos", LoadAll))
let assert Ok(response) = httpc.request(Post, url, payload)
let result = binary_to_term(response.body)
```

See [`examples/todos/cli/`](https://github.com/pairshaped/libero/blob/master/examples/todos/cli/) for a runnable CLI example with argument parsing.

## Codegen CLI

Run from your server package directory:

```bash
cd server
gleam run -m libero -- \
  --ws-url=wss://your.host/ws \
  --shared=../shared \
  --server=.
```

Or when the hostname varies between environments:

```bash
gleam run -m libero -- \
  --ws-path=/ws \
  --shared=../shared \
  --server=.
```

### Flags

| Flag | Description |
|---|---|
| `--ws-url=<url>` | Hardcode a full WebSocket URL. One of `--ws-url` or `--ws-path` is required. |
| `--ws-path=<path>` | Resolve the WebSocket URL at runtime from `window.location`. |
| `--shared=<path>` | Path to the shared package root. |
| `--server=<path>` | Path to the server package root. |
| `--client=<path>` | Path to the client package root (defaults to `../client`). |
| `--namespace=<name>` | Optional prefix for multi-SPA setups. |
| `--write-inputs` | Write a `.inputs` manifest for staleness checks. |

## What gets generated

From a shared module at `shared/src/shared/todos.gleam`, Libero writes:

- [`dispatch.gleam`](https://github.com/pairshaped/libero/blob/master/examples/todos/server/src/server/generated/libero/dispatch.gleam): routes incoming wire calls to handler modules.
- [`websocket.gleam`](https://github.com/pairshaped/libero/blob/master/examples/todos/server/src/server/generated/libero/websocket.gleam): mist WebSocket handler with dispatch, push forwarding, and topic cleanup.
- [`todos.gleam`](https://github.com/pairshaped/libero/blob/master/examples/todos/client/src/client/generated/libero/todos.gleam) (client): typed `send_to_server` and `update_from_server` stubs.
- [`todos.gleam`](https://github.com/pairshaped/libero/blob/master/examples/todos/server/src/server/generated/libero/todos.gleam) (server): typed `send_to_client` and `send_to_clients` push wrappers.
- [`rpc_config.gleam`](https://github.com/pairshaped/libero/blob/master/examples/todos/client/src/client/generated/libero/rpc_config.gleam): WebSocket URL configuration.
- [`rpc_register.gleam`](https://github.com/pairshaped/libero/blob/master/examples/todos/client/src/client/generated/libero/rpc_register.gleam) + [`rpc_register_ffi.mjs`](https://github.com/pairshaped/libero/blob/master/examples/todos/client/src/client/generated/libero/rpc_register_ffi.mjs): auto-registers framework and application types for wire codec reconstruction (called automatically on first send).

## How it works

The wire format is ETF over binary WebSocket frames. Gleam's custom types, lists, options, and primitives all serialize automatically without explicit codecs.

The client sends a `{module_path, MsgFromClient_value}` tuple. The server dispatch decodes it, routes by module path, and calls the handler. Codec registration happens automatically on the first `send_to_server` call.

The generator scans shared modules for `MsgFromClient` and `MsgFromServer` types, walks their type graphs to find all types that need codec registration, and emits the dispatch and stub files.

## Naming

Libero's API uses a directional naming convention:

| Direction | Client calls | Server calls |
|---|---|---|
| Client → Server | `send_to_server(msg:)` | `update_from_client(msg:)` |
| Server → Client | `update_from_server(handler:)` | generated `send_to_client(client_id:, ...)` / `send_to_clients(topic:, ...)` |

## License

MIT. See [LICENSE](https://github.com/pairshaped/libero/blob/master/LICENSE).
