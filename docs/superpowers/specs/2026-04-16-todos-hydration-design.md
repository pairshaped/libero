# todos-hydration example design

SSR + hydration example for Libero, demonstrating server-side rendering with Lustre and seamless client takeover.

## Goal

Show that Libero's `dispatch.handle()` can be called directly on the server to fetch data, render a Lustre view to HTML, and serve a fully-rendered page that the client hydrates without a visible re-render. After hydration, the app uses normal Libero WebSocket RPC.

## Project structure

```
examples/todos-hydration/
  shared/   -- types + view functions. Depends on lustre, gleam_stdlib.
  server/   -- handlers + SSR route. Depends on shared, libero, mist.
  client/   -- thin Lustre app (init, update, main). Depends on shared, libero, lustre.
```

Key difference from `examples/todos/`: the view functions live in `shared/` so both the server (BEAM) and client (JS) can use them. The shared package adds a `lustre` dependency.

## Shared package

### `shared/src/shared/todos.gleam`

Same as the existing todos example: `Todo`, `TodoParams`, `TodoError`, `MsgFromClient`, `MsgFromServer`.

### `shared/src/shared/views.gleam`

Extracted from the current `client/src/client/app.gleam`. Contains all view functions:

- `view(model: Model) -> Element(Msg)` - top-level view
- `view_input(model: Model) -> Element(Msg)` - form input
- `view_items(items: RemoteData(List(Todo), RpcFailure)) -> Element(Msg)` - item list with loading/error states
- `view_list(items: List(Todo)) -> Element(Msg)` - rendered todo list
- `view_item(item: Todo) -> Element(Msg)` - single todo row
- `view_action_status(rd: RemoteData(Nil, RpcFailure)) -> Element(Msg)` - action feedback

Also exports the `Model` and `Msg` types since the view depends on them.

## Server package

### `server/src/server.gleam`

HTTP router with SSR route:

```
GET /      -> SSR handler (render HTML with embedded flags)
GET /ws    -> WebSocket upgrade (libero-generated)
POST /rpc  -> HTTP RPC (libero-generated dispatch)
GET /js/*  -> static JS files from client build
```

No `priv/static/index.html`. The server generates the HTML dynamically.

### SSR handler

1. Build a `LoadAll` message.
2. Encode as wire call: `wire.encode_call("shared/todos", LoadAll)`.
3. Call `dispatch.handle(state: shared, data: encoded_call)` directly.
4. Decode the response to get `List(Todo)`.
5. Build a `Model` with `items: Success(todos)`.
6. Call `shared/views.view(model)` to get an `Element`.
7. Render to HTML string via `element.to_string()`.
8. Encode the `List(Todo)` as ETF, then base64.
9. Wrap in a full HTML document with:
   - The rendered view inside `<div id="app">`.
   - A `<script>` tag setting `window.__LIBERO_FLAGS__` to the base64 ETF string.
   - A `<script type="module">` importing and calling the client's `main()`.
10. Serve as `text/html`.

### Handler and store

Same as existing todos example: `store.gleam`, `shared_state.gleam`, `app_error.gleam`, `server_store_ffi.erl`.

## Client package

### `client/src/client/app.gleam`

Thin wrapper. Imports view from `shared/views`.

```gleam
pub fn init(flags: Dynamic) -> #(Model, Effect(Msg)) {
  let items = decode_flags(flags)
  let subscribe = rpc.update_from_server(handler: fn(raw) {
    GotPush(wire.coerce(raw))
  })
  #(
    Model(items: Success(items), input: "", last_action: NotAsked),
    effect.batch([subscribe]),
  )
}
```

- `init` receives flags as `Dynamic`, decodes base64 -> ETF -> `List(Todo)`.
- Starts with `Success(items)` instead of `Loading`. No initial `LoadAll` RPC call.
- Still subscribes to push updates for live changes.
- `update` is the same as existing todos.
- `view` is imported from shared.

### `client/src/client/flags_ffi.mjs`

Small FFI module:

- `read_flags()` - reads `window.__LIBERO_FLAGS__`, decodes base64 to `Uint8Array`.
- The Gleam side passes this to `wire.decode()` to get the typed `List(Todo)`.

### `client/src/client/app.gleam` main

```gleam
pub fn main() {
  let app = lustre.application(init, update, views.view)
  let flags = read_flags()
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}
```

Lustre's `start` detects the pre-rendered DOM inside `#app`, virtualises it, and diffs against the view output. Since the data matches, no visible change occurs.

## Flags encoding

Server side (Erlang):
- `wire.encode(todos)` produces ETF `BitArray`
- Base64-encode the BitArray to a string
- Embed as `window.__LIBERO_FLAGS__ = "base64string"`

Client side (JavaScript):
- Read `window.__LIBERO_FLAGS__`
- Base64-decode to `Uint8Array`
- `wire.decode()` produces typed `List(Todo)`

## What this example proves

- Shared view functions compile to both Erlang (SSR) and JavaScript (client).
- `dispatch.handle()` works as a direct function call for fetching data server-side.
- Lustre hydration works with server-rendered HTML (no flash of re-render).
- ETF round-trips through base64 for embedding state in HTML.
- After hydration, the app transitions seamlessly to WebSocket RPC for subsequent interactions.
- SSR is an additive pattern on top of existing Libero, not a separate architecture.
