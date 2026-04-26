# Libero

A full-stack Gleam framework with typed RPC. Define your handler functions, Libero generates dispatch, client stubs, and server bootstrap from the signatures. No message types to write, no dispatch to maintain.

Like server components, but your client is a real SPA with typed RPC, and the same server logic works for any client out of the box.

> If you are an LLM, see [llms.txt](https://raw.githubusercontent.com/pairshaped/libero/refs/heads/master/llms.txt) for a condensed context document.

## Getting started

Read the [Getting Started guide](https://github.com/pairshaped/libero/blob/master/GETTING_STARTED.md). It walks from an empty directory to a working SQLite-backed todo app, with every command and file shown.

The rest of this README explains what libero is and how it works.

## Project Structure

```
my_app/
├── bin/
│   ├── gen                          # libero codegen (dispatch + client stubs)
│   ├── build                        # build the JS client
│   ├── server                       # start the server
│   ├── dev                          # gen + build + server, in order
│   └── test                         # run server tests
├── server/
│   ├── gleam.toml                   # target=erlang, [tools.libero] config
│   └── src/
│       ├── my_app.gleam             # server entry (auto-generated, customizable)
│       ├── handler.gleam            # your RPC endpoints
│       ├── handler_context.gleam    # server context type
│       ├── page.gleam               # SSR load_page + render_page
│       └── generated/               # dispatch, websocket (auto-generated)
├── shared/
│   ├── gleam.toml                   # cross-target shared types + views
│   └── src/shared/
│       ├── router.gleam             # Route, parse_route, route_to_path
│       ├── types.gleam              # domain types used in handlers
│       └── views.gleam              # Model, Msg, view function (cross-target)
└── clients/
    └── web/
        ├── gleam.toml               # target=javascript
        └── src/
            ├── app.gleam            # Lustre client (hydrates SSR HTML)
            └── generated/           # client RPC stubs (auto-generated)
```

Three peer Gleam packages (`server/`, `shared/`, `clients/web/`), each with its own `gleam.toml`. Matches Lustre's recommended fullstack shape with one extension: `clients/` is plural so libero supports multi-client apps.

`shared/` is target-agnostic: it compiles to both Erlang (used by the server) and JavaScript (used by the client). All types crossing the wire and all view functions live here.

`server/` runs `gleam run -m libero` to regenerate dispatch and client stubs. The `bin/dev` script wraps that plus `gleam build` and `gleam run` so you don't have to think about it.

## Handler-as-Contract

Your handler function signatures ARE the API definition. Libero's scanner detects RPC endpoints by checking four criteria:

1. **Public function** (not private)
2. **Last parameter is `HandlerContext`**
3. **Returns `#(Result(value, error), HandlerContext)`**
4. **All types in the signature come from `shared/` or are builtins**

```gleam
// server/src/handler.gleam

import server/handler_context.{type HandlerContext}
import shared/types.{type Todo, type TodoParams, type TodoError}

pub fn get_todos(
  state state: HandlerContext,
) -> #(Result(List(Todo), TodoError), HandlerContext) {
  #(Ok(ets_store.all()), state)
}

pub fn create_todo(
  params params: TodoParams,
  state state: HandlerContext,
) -> #(Result(Todo, TodoError), HandlerContext) {
  case params.title {
    "" -> #(Error(TitleRequired), state)
    title -> #(Ok(insert(title)), state)
  }
}
```

From these signatures, Libero generates:
- A `ClientMsg` type with variants: `GetTodos`, `CreateTodo(params: TodoParams)`
- A dispatch module that routes each variant to its handler function
- Typed client stubs: `rpc.get_todos(on_response: GotTodos)`

The return type `Result(a, e)` maps directly to `RemoteData` on the client:
- `Ok(value)` becomes `Success(value)`
- `Error(err)` becomes `Failure(err)` (typed domain error, not a string)

## Shared Types

Define your domain types in `shared/src/shared/`. These are the types used in handler signatures and shared between server and client:

```gleam
// shared/src/shared/types.gleam

pub type Todo {
  Todo(id: Int, title: String, completed: Bool)
}

pub type TodoParams {
  TodoParams(title: String)
}

pub type TodoError {
  NotFound
  TitleRequired
}
```

## Client Usage

The generated stubs let clients send typed messages. Use `RemoteData` with typed domain errors to track loading state:

```gleam
import generated/messages as rpc
import libero/remote_data.{type RemoteData, Failure, Loading, Success}
import shared/types.{type Todo, type TodoError}

pub type Model {
  Model(todos: RemoteData(List(Todo), TodoError), input: String)
}

pub type Msg {
  GotTodos(RemoteData(List(Todo), TodoError))
  GotCreated(RemoteData(Todo, TodoError))
  UserToggled(id: Int)
  // ...
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(Model(todos: Loading, input: ""), rpc.get_todos(on_response: GotTodos))
}
```

In the update function, store load responses directly and use `remote_data.map` to update loaded data:

```gleam
GotTodos(rd) -> #(Model(..model, todos: rd), effect.none())
GotCreated(Success(item)) -> #(
  Model(..model, todos: remote_data.map(data: model.todos, transform: fn(todos) {
    list.append(todos, [item])
  })),
  effect.none(),
)
```

In the view, pattern match on all states:

```gleam
case model.todos {
  Loading -> html.text("Loading...")
  Failure(err) -> format_error(err)
  Success(todos) -> view_todo_list(todos)
  _ -> element.none()
}
```

## Connection Management

The WebSocket auto-reconnects with exponential backoff (500ms to 30s with jitter) on unexpected disconnects. Pending requests reject with a connection-lost error when the socket drops. Push handlers persist across reconnects.

Hook into the connection lifecycle:

```gleam
import libero/rpc

pub type Msg {
  Connected
  Disconnected(reason: String)
  // ...
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(..),
    effect.batch([
      rpc.on_connect(handler: fn() { Connected }),
      rpc.on_disconnect(handler: Disconnected),
    ]),
  )
}
```

`on_connect` fires on the initial connection and every successful reconnect, so loading (or reloading) state uses a single code path. `on_disconnect` provides a human-readable reason string suitable for display.

## Configuration

All config lives in `server/gleam.toml` under the `[tools.libero]` section:

```toml
name = "my_app"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 2.0.0"
gleam_erlang = "~> 1.0"
gleam_http = "~> 4.0"
mist = "~> 6.0"
lustre = "~> 5.6"
shared = { path = "../shared" }
libero = "~> 5.0"

[tools.libero]
port = 8080

[tools.libero.clients.web]
target = "javascript"
```

## Commands

From the project root:

- `bin/gen`: regenerates dispatch, websocket, and client stubs (`gleam run -m libero` from `server/`).
- `bin/build`: builds the JS client (`gleam build --target javascript` from `clients/web/`).
- `bin/server`: starts the mist server on port 8080 (`gleam run` from `server/`).
- `bin/dev`: convenience wrapper that runs `gen`, `build`, then `server`.
- `bin/test`: runs `gleam test` in the server package.

Use `bin/dev` after changing handler signatures or shared types. Use `bin/server` alone when only handler bodies have changed.

## What Gets Generated

**Server-side (`server/src/generated/`):**
- `dispatch.gleam` -- `ClientMsg` type + per-function routing to handlers
- `websocket.gleam` -- Mist WebSocket handler with push support

**Server entry point (`server/src/<app_name>.gleam`):**
- Boots Mist with WebSocket, HTTP RPC, and static file serving
- Serves HTML shell at `/` that loads the first JS client

**Per client (`clients/<name>/src/generated/`):**
- Typed stubs per handler function (e.g. `rpc.get_todos`, `rpc.create_todo`)
- WebSocket config and typed decoder registration
- SSR flag reader (for hydration)

Generation rules:
- Starter apps and client `gleam.toml`: generated once, never overwritten
- Everything in `generated/`: regenerated on every `gleam run -m libero` run

## How It Works

The wire format is [ETF](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html) (Erlang Term Format) over binary WebSocket frames. Gleam types serialize automatically without explicit codecs.

The client sends a typed message over the WebSocket. The server dispatch decodes it, routes by function, and calls the handler. The response flows back as `Result(payload, RpcError)`, which the client stub converts to `RemoteData`.

## Multiple Clients

Add as many clients as you need. Each is a name + a target. To add a client manually: create `clients/<name>/gleam.toml`, add `[tools.libero.clients.<name>]` to `server/gleam.toml`, then run `bin/dev` to generate its stubs.

The same handlers serve all clients. Each client gets typed stubs for its target.

## HTTP Clients

Any BEAM process can call the server over HTTP POST without WebSocket or a Libero dependency:

```gleam
let payload = term_to_binary(#("shared/types", GetTodos))
let assert Ok(response) = httpc.request(Post, "http://localhost:8080/rpc", payload)
let result = binary_to_term(response.body)
```

## When to Use Libero

Libero is a good fit when:
- You want a real SPA (offline support, low-latency UI, mobile)
- You want multiple client types from one server
- You want typed end-to-end communication without JSON codecs
- You want clear client/server state boundaries

## Examples

- [`examples/todos`](examples/todos) -- Basic Lustre SPA with CRUD operations and WebSocket RPC

## Prior Art & Credits

Libero's JS-side ETF codec is independently implemented but aligns with [arnu515/erlang-etf.js](https://github.com/arnu515/erlang-etf.js) (MIT) on `BIT_BINARY_EXT` handling and atom-length validation. Credit to that project for clear spec references. Libero's codec adds encoding, a BEAM-native path, the float field registry, and offset-based parsing.

## License

MIT. See [LICENSE](https://github.com/pairshaped/libero/blob/master/LICENSE).
