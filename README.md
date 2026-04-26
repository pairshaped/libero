# Libero

A full-stack Gleam framework with typed RPC. Define your handler functions, Libero generates dispatch, client stubs, and server bootstrap from the signatures. No message types to write, no dispatch to maintain.

Like server components, but your client is a real SPA with typed RPC, and the same server logic works for any client out of the box.

> If you are an LLM, see [llms.txt](https://raw.githubusercontent.com/pairshaped/libero/refs/heads/master/llms.txt) for a condensed context document.

## Getting Started

```bash
gleam run -m libero -- new my_app --web
cd my_app
gleam run -m libero -- build
gleam run
# Server running on http://localhost:8080
```

## Project Structure

```
my_app/
  gleam.toml                         # server package + [tools.libero] config
  src/
    server/
      handler.gleam                  # your business logic (RPC endpoints)
      handler_context.gleam          # server context type
      generated/                     # dispatch, websocket (auto-generated)
    my_app.gleam                     # server entry point (auto-generated)
  shared/
    gleam.toml                       # target-agnostic package
    src/shared/
      types.gleam                    # your domain types (shared between server + client)
  clients/
    web/
      gleam.toml                     # client package (auto-generated if missing)
      src/
        app.gleam                    # your Lustre SPA
        generated/                   # client stubs (auto-generated)
  test/
    my_app_test.gleam                # handler test
```

The root `gleam.toml` is the **server package** (target: erlang). It also holds the `[tools.libero]` config that declares clients and settings. `src/server/` is where your handlers and business logic live.

`shared/` and `clients/` are **separate Gleam packages** nested inside the project, each with their own `gleam.toml`. This is necessary because Gleam compiles to a single target per package: the server targets Erlang while JS clients target JavaScript. They can't live in the same package.

`shared/` exists so both sides can import the same domain types. It has no target specified, so it compiles to both Erlang and JavaScript. Without it, JS clients would need to depend on the server package and pull in Erlang-only dependencies (mist, ETS, etc.).

```
root (server)     -> shared, libero, mist     [target: erlang]
clients/web       -> shared, libero, lustre   [target: javascript]
```

## Handler-as-Contract

Your handler function signatures ARE the API definition. Libero's scanner detects RPC endpoints by checking four criteria:

1. **Public function** (not private)
2. **Last parameter is `HandlerContext`**
3. **Returns `#(Result(value, error), HandlerContext)`**
4. **All types in the signature come from `shared/` or are builtins**

```gleam
// src/server/handler.gleam

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

All config lives in `gleam.toml` under the `[tools.libero]` section:

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

[tools.libero]
port = 8080

[tools.libero.clients.web]
target = "javascript"

[tools.libero.clients.cli]
target = "erlang"
```

## CLI

```
gleam run -m libero -- <command>

Commands:
  new <name> [--database pg|sqlite] [--web]  Create a new project
  add <name> --target <target>  Add a client
  gen                           Regenerate stubs
  build                         Gen + build server + all clients
```

### `libero new <name> [--database pg|sqlite] [--web]`
Scaffolds a project with `src/server/` (skeleton handler), `shared/` (skeleton types), `test/` (handler test), `README.md`, and `gleam.toml`.

Pass `--database pg` to include [pog](https://hexdocs.pm/pog/) and [squirrel](https://hexdocs.pm/squirrel/) for type-safe Postgres queries. Pass `--database sqlite` to include [sqlight](https://hexdocs.pm/sqlight/) and [marmot](https://hexdocs.pm/marmot/) for type-safe SQLite queries. Both options add a `src/server/db.gleam` connection module and a `src/server/sql/` directory for query files.

Pass `--web` to add the default JavaScript client named `web` during scaffold. It is the same result as running `gleam run -m libero -- add web --target javascript` after `new`.

### `libero add <name> --target <target>`
Adds a client. Creates `clients/<name>/` with its own `gleam.toml` (generated once, never overwritten) and a starter app.

### `libero gen`
Scans handler functions and generates dispatch, stubs, and server entry point. Run after changing handler signatures.

### `libero build`
Runs `gen`, then builds the server and each client package.

## What Gets Generated

**Server-side (`src/server/generated/`):**
- `dispatch.gleam` -- `ClientMsg` type + per-function routing to handlers
- `websocket.gleam` -- Mist WebSocket handler with push support

**Server entry point (`src/<app_name>.gleam`):**
- Boots Mist with WebSocket, HTTP RPC, and static file serving
- Serves HTML shell at `/` that loads the first JS client

**Per client (`clients/<name>/src/generated/`):**
- Typed stubs per handler function (e.g. `rpc.get_todos`, `rpc.create_todo`)
- WebSocket config and typed decoder registration
- SSR flag reader (for hydration)

Generation rules:
- Starter apps and client `gleam.toml`: generated once, never overwritten
- Everything in `generated/`: regenerated every `libero gen` or `libero build`

## How It Works

The wire format is [ETF](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html) (Erlang Term Format) over binary WebSocket frames. Gleam types serialize automatically without explicit codecs.

The client sends a typed message over the WebSocket. The server dispatch decodes it, routes by function, and calls the handler. The response flows back as `Result(payload, RpcError)`, which the client stub converts to `RemoteData`.

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
- [`examples/ssr_hydration`](examples/ssr_hydration) -- SSR + hydration with shared views across Erlang and JavaScript

## Prior Art & Credits

Libero's JS-side ETF codec is independently implemented but aligns with [arnu515/erlang-etf.js](https://github.com/arnu515/erlang-etf.js) (MIT) on `BIT_BINARY_EXT` handling and atom-length validation. Credit to that project for clear spec references. Libero's codec adds encoding, a BEAM-native path, the float field registry, and offset-based parsing.

## License

MIT. See [LICENSE](https://github.com/pairshaped/libero/blob/master/LICENSE).
