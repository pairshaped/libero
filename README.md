# Libero

A full-stack Gleam framework with typed RPC. Define your handler functions, Libero generates dispatch, client stubs, and server bootstrap from the signatures. No message types to write, no dispatch to maintain.

Like server components, but your client is a real SPA with typed RPC, and the same server logic works for any client out of the box.

> If you are an LLM, see [llms.txt](https://raw.githubusercontent.com/pairshaped/libero/refs/heads/master/llms.txt) for a condensed context document.

## Getting started

Read the [Getting Started guide](https://github.com/pairshaped/libero/blob/master/docs/getting_started/step_1.md). It walks from an empty directory to a working checklist app, with every command and file shown. When you want persistent storage, follow [Step 2: SQLite](https://github.com/pairshaped/libero/blob/master/docs/getting_started/step_2.md).

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

Three peer Gleam packages (`server/`, `shared/`, `clients/web/`), each with its own `gleam.toml`. Matches Lustre's recommended fullstack shape with one extension: `clients/` is plural because most real apps grow more than one client. See [Multiple Clients](#multiple-clients) for the typical shapes.

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

import gleam/list
import handler_context.{type HandlerContext, HandlerContext}
import shared/types.{
  type Item, type ItemError, type ItemParams, Item, TitleRequired,
}

pub fn get_items(
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(List(Item), ItemError), HandlerContext) {
  #(Ok(handler_ctx.items), handler_ctx)
}

pub fn create_item(
  params params: ItemParams,
  handler_ctx handler_ctx: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  case params.title {
    "" -> #(Error(TitleRequired), handler_ctx)
    title -> {
      let item = Item(id: handler_ctx.next_id, title:, completed: False)
      let new_state =
        HandlerContext(
          items: list.append(handler_ctx.items, [item]),
          next_id: handler_ctx.next_id + 1,
        )
      #(Ok(item), new_state)
    }
  }
}
```

From these signatures, Libero generates:
- A `ClientMsg` type with variants: `GetItems`, `CreateItem(params: ItemParams)`
- A dispatch module that routes each variant to its handler function
- Typed client stubs: `rpc.get_items(on_response: GotItems)`

The return type `Result(a, e)` maps directly to `RemoteData` on the client:
- `Ok(value)` becomes `Success(value)`
- `Error(err)` becomes `Failure(err)` (typed domain error, not a string)

## Shared Types

Define your domain types in `shared/src/shared/`. These are the types used in handler signatures and shared between server and client:

```gleam
// shared/src/shared/types.gleam

pub type Item {
  Item(id: Int, title: String, completed: Bool)
}

pub type ItemParams {
  ItemParams(title: String)
}

pub type ItemError {
  NotFound
  TitleRequired
}
```

## Client Usage

The generated stubs let clients send typed messages. Use `RemoteData` with typed domain errors to track loading state:

```gleam
import generated/messages as rpc
import libero/remote_data.{type RemoteData, Failure, Loading, Success}
import shared/types.{type Item, type ItemError}

pub type Model {
  Model(items: RemoteData(List(Item), ItemError), input: String)
}

pub type Msg {
  GotItems(RemoteData(List(Item), ItemError))
  GotCreated(RemoteData(Item, ItemError))
  UserToggled(id: Int)
  // ...
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(Model(items: Loading, input: ""), rpc.get_items(on_response: GotItems))
}
```

In the update function, store load responses directly and use `remote_data.map` to update loaded data:

```gleam
GotItems(rd) -> #(Model(..model, items: rd), effect.none())
GotCreated(Success(item)) -> #(
  Model(..model, items: remote_data.map(data: model.items, transform: fn(items) {
    list.append(items, [item])
  })),
  effect.none(),
)
```

In the view, pattern match on all states:

```gleam
case model.items {
  Loading -> html.text("Loading...")
  Failure(err) -> format_error(err)
  Success(items) -> view_item_list(items)
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

**Atom registration (`server/src/<app_name>@generated@rpc_atoms.erl`):**
- Pre-registers every constructor atom so ETF decoding is safe before the first message arrives

**Per client (`clients/<name>/src/generated/`):**
- `messages.gleam` -- typed stubs per handler function (e.g. `rpc.get_items`, `rpc.create_item`)
- `rpc_config.gleam` (+ `rpc_config_ffi.mjs` for path-only mode) -- WebSocket URL resolution
- `rpc_decoders.gleam` (+ `rpc_decoders_ffi.mjs`) -- typed decoder registration
- `ssr.gleam` (+ `ssr_ffi.mjs`) -- SSR flag reader for hydration

Generation rules:
- Starter apps and client `gleam.toml`: generated once, never overwritten
- Everything in `generated/`: regenerated on every `gleam run -m libero` run

## How It Works

The wire format is [ETF](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html) (Erlang Term Format) over binary WebSocket frames. Gleam types serialize automatically without explicit codecs.

The client sends a typed message over the WebSocket. The server dispatch decodes it, routes by function, and calls the handler. The response flows back as `Result(payload, RpcError)`, which the client stub converts to `RemoteData`.

## Multiple Clients

`clients/` is plural because most real apps end up with more than one. Common shapes:

- **`clients/web/` + `clients/admin/`**: a public-facing SPA and a separate admin SPA, both compiled to JavaScript. Different routes, different views, often different bundle sizes (you don't ship the admin code to every visitor).
- **`clients/web/` + `clients/cli/`**: a web SPA plus a BEAM-target CLI that talks to the same server. Useful for ops tools, scripted workflows, or letting power users hit the same RPC endpoints from a terminal.
- **`clients/web/` + `clients/native/`**: a web client plus a Lustre-driven native client (e.g. iOS or Android via embedded JS), or any other JavaScript target with different dependencies.

The handlers don't change. Each client gets typed stubs generated from the same `handler.gleam` signatures, so the contract stays consistent across surfaces. You can't accidentally drift the admin client's idea of `Item` from the web client's, because both decode the same `shared/types.Item`.

To add a client: create `clients/<name>/gleam.toml`, add `[tools.libero.clients.<name>]` to `server/gleam.toml`, then run `bin/gen` to generate its stubs.

### Two SSR-hydrated SPAs (admin + public)

This is the question every two-app team hits: how does adding a second SPA affect the rest of the code? Here's what changes per peer.

**`server/` stays mostly intact.** `handler.gleam` is still one set of RPC endpoints; both SPAs call whichever they need. `handler_context.gleam` doesn't change. `page.gleam` splits per role into `admin_page.gleam` and `public_page.gleam`, each with its own `load_page` and `render_page` pair. The server entry routes `/admin/*` to the admin pair and `/*` to the public pair, and serves both client bundles via static-file routes (`/web/admin/app.mjs`, `/web/public/app.mjs`).

**`shared/` splits along the UI seam.** Domain types in `shared/types.gleam` stay unified: both SPAs decode the same `Item`, so wire compatibility is automatic and free. View modules and routers split per role into `shared/admin/{router,views}.gleam` and `shared/public/{router,views}.gleam`. Each gets its own `Route`, `Model`, `Msg`, `view`. Reusable widgets (a date picker, a table component) extract into `shared/ui/` and get imported by both.

**Why split the views?** Bundle-bleed protection. Cram both UIs into one `shared/views.gleam` and every public visitor downloads your admin code. Splitting keeps `clients/admin/`'s output to admin code and `clients/public/`'s output to public code, with shared types and shared widgets as the bridge.

The wire contract is shared. The UI surface stays per-client.

## HTTP Clients

Any BEAM process can call the server over HTTP POST without WebSocket or a Libero dependency:

```gleam
// Envelope: #(module_path, request_id, ClientMsg). The request_id is
// echoed back in the 4-byte response header so concurrent calls match.
let payload = term_to_binary(#("rpc", 1, GetItems))
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

- [`examples/checklist`](examples/checklist) -- SSR-hydrated Lustre SPA with CRUD over WebSocket. Output of the [Getting Started guide](docs/getting_started/step_1.md).
- [`examples/default`](examples/default) -- Bare SSR scaffold with one ping handler. The starting point `bin/new` clones.

## Prior Art & Credits

Libero's JS-side ETF codec is independently implemented but aligns with [arnu515/erlang-etf.js](https://github.com/arnu515/erlang-etf.js) (MIT) on `BIT_BINARY_EXT` handling and atom-length validation. Credit to that project for clear spec references. Libero's codec adds encoding, a BEAM-native path, the float field registry, and offset-based parsing.

## License

MIT. See [LICENSE](https://github.com/pairshaped/libero/blob/master/LICENSE).
