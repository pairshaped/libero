# Libero

Libero generates typed WebSocket plumbing between a Gleam server and a Lustre client. You define message types in a shared module, and Libero produces a server dispatch function and client send stubs from them. No REST routes, no JSON codecs, no hand-written dispatch tables.

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

## HTTP clients

The generated `dispatch.handle(state:, data:)` function takes a `BitArray` and returns a `BitArray`. It doesn't know or care about the transport. This means any BEAM process can be a Libero client by sending ETF-encoded messages over HTTP POST. No WebSocket and no Libero dependency needed.

This works because ETF is the BEAM's native serialization format. Any BEAM client (Gleam, Erlang, Elixir) can call `term_to_binary` on the same shared types the browser uses, POST the bytes, and decode the response with `binary_to_term`. The server runs the same dispatch logic either way.

Use cases: CLI tools, background workers, inter-service calls, cron jobs, admin scripts.

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

See [`examples/todos/cli/`](./examples/todos/cli/) for a runnable CLI example with argument parsing.

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
