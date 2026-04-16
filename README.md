# Libero

Libero generates typed WebSocket plumbing between a Gleam server and a Lustre client. You define message types in a shared module, and libero produces a server dispatch function and client send stubs from them. No REST routes, no JSON codecs, no hand-written dispatch tables.

## Convention

Every shared module that participates in libero's codegen exports two types by convention:

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

`MsgFromClient` contains messages from the client to the server. `MsgFromServer` contains messages the server sends back, both as responses and as server-initiated pushes. A module can define one or both.

## Example usage

The client sends a message using the generated stub:

```gleam
// In your Lustre update:
import client/generated/libero/todos as todos_rpc

ToggleTodo(id) ->
  #(model, todos_rpc.send_to_server(msg: Toggle(id:), on_response: GotResponse))
```

The server handles it in the handler module:

```gleam
// server/src/server/handlers/todos.gleam

import shared/todos.{type MsgFromClient, type MsgFromServer}
import server/shared_state.{type SharedState}
import server/app_error.{type AppError}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    todos.LoadAll -> Ok(#(AllLoaded(store.all()), state))
    todos.Create(params:) -> ...
    todos.Toggle(id:) -> ...
    todos.Delete(id:) -> ...
  }
}
```

## Server push

The server can push messages to connected clients without a prior request. Uses BEAM pg groups for topic-based subscriptions, no external dependencies.

```gleam
// Server — on WebSocket connect, join a topic
push.join(topic: "todos")

// Server — in a handler, push to all subscribers
push.send_to_clients(topic: "todos", module: "shared/todos", msg: AllLoaded(store.all()))

// Server — targeted push to one client
push.register(client_id: "user:42")
push.send_to_client(client_id: "user:42", module: "shared/todos", msg: Created(item))
```

```gleam
// Client — subscribe to pushes (in init)
todos_rpc.update_from_server(handler: fn(raw) { GotPush(wire.coerce(raw)) })
```

Push is opt-in. If you never call `update_from_server`, push frames are silently dropped. If unused, tree shaking removes the generated code entirely.

## CLI clients

BEAM clients can call the same server over HTTP POST. No WebSocket, no libero dependency needed. The server's dispatch module works with any transport:

```gleam
// Server — add an HTTP route
fn handle_rpc(req, state) {
  use body <- wisp.require_body(req)
  let #(response, _, _) = dispatch.handle(state:, data: body)
  wisp.ok() |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(response)))
}
```

```gleam
// CLI client, native ETF, no libero dependency
let payload = term_to_binary(#("shared/todos", LoadAll))
let assert Ok(response) = httpc.request(Post, url, payload)
let result = binary_to_term(response.body)
```

See [`examples/todos/cli/`](./examples/todos/cli/) for a complete runnable CLI example with argument parsing.

## Codegen CLI

Run from your server package directory:

```bash
cd server
gleam run -m libero -- \
  --ws-url=wss://your.host/ws \
  --shared=../shared \
  --server=.
```

Or for multi-tenant deployments where the hostname varies:

```bash
gleam run -m libero -- \
  --ws-path=/ws \
  --shared=../shared \
  --server=.
```

### Flags

- `--ws-url=<url>` or `--ws-path=<path>` (one required): hardcodes a full URL or resolves it at runtime from `window.location`.
- `--shared=<path>`: path to the shared package root.
- `--server=<path>`: path to the server package root.
- `--client=<path>`: path to the client package root (defaults to `../client`).
- `--namespace=<name>`: optional prefix for multi-SPA setups.
- `--write-inputs`: write a `.inputs` manifest for staleness checks.

## What gets generated

From a shared module at `shared/src/shared/todos.gleam`, libero writes:

- `server/src/server/generated/libero/dispatch.gleam`: routes incoming wire calls to handler modules.
- `client/src/client/generated/libero/todos.gleam`: typed `send_to_server` and `update_from_server` stubs for the client.
- `client/src/client/generated/libero/rpc_config.gleam`: WebSocket URL configuration.
- `client/src/client/generated/libero/rpc_register.gleam` + `rpc_register_ffi.mjs`: auto-registers every custom type that may appear on the wire (called automatically on first send).

## How it works

The wire format is Erlang External Term Format (ETF) over binary WebSocket frames. Gleam's custom types, lists, options, and primitives all serialize reflectively without explicit codecs.

Server→client frames carry a 1-byte tag: `0x00` for responses (matched to pending callbacks in FIFO order), `0x01` for pushes (routed to the module's `update_from_server` handler).

The client sends a `{module_path, MsgFromClient_value}` tuple. The server dispatch decodes it, routes by module path, and calls the handler. Codec registration happens automatically on the first `send_to_server` call.

The generator scans shared modules for `MsgFromClient` and `MsgFromServer` types, walks their type graphs transitively to find all types that need codec registration, and emits the dispatch and stub files.

## Naming

Libero's API uses a directional naming convention:

| Direction | Client calls | Server calls |
|---|---|---|
| Client → Server | `send_to_server(msg:)` | `update_from_client(msg:)` |
| Server → Client | `update_from_server(handler:)` | `push.send_to_client(client_id:, ...)` / `push.send_to_clients(topic:, ...)` |

## License

MIT. See [LICENSE](https://github.com/pairshaped/libero/blob/master/LICENSE).
