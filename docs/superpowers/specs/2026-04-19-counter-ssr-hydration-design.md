# Counter SSR + Hydration Example Design

SSR + client-side hydration example for Libero with client-side routing, demonstrating server-side rendering with Lustre across multiple views.

## Goal

Prove that Libero's SSR pipeline works end-to-end with client-side routing:

1. Shared view functions compile to both Erlang (SSR) and JavaScript (client)
2. `ssr.call` fetches data through dispatch on the server for initial render
3. Lustre hydrates server-rendered HTML without a visible re-render
4. Client-side `pushState` navigation works between views
5. Full-page refresh on any URL SSR-renders the correct view
6. Adding N pages requires only N route variants + N case arms, no per-page plumbing

## Example behavior

Two views share a single ETS-backed counter:

- `/inc` — shows the counter value and an increment button
- `/dec` — shows the counter value and a decrement button

A nav bar links between the two. Client-side clicks navigate via `pushState` (no page reload). Refreshing either URL server-renders the correct view with the current counter value.

## Project structure

```
examples/counter/
  gleam.toml                    # server package (erlang) + [libero] config
  shared/
    gleam.toml                  # cross-target: types, views, route
    src/shared/
      messages.gleam            # MsgFromClient, MsgFromServer
      views.gleam               # Route, Model, Msg, all view functions
  clients/web/
    gleam.toml                  # client package (javascript)
    src/
      app.gleam                 # main(), init, update (client-only)
      router.gleam              # Gleam wrappers for pushState/pathname FFI
      router_ffi.mjs            # pushState, pathname, click interception
  src/
    server/
      handler.gleam             # update_from_client: Increment, Decrement, GetCounter
      shared_state.gleam        # unit SharedState type
      app_error.gleam           # AppError type
      generated/                # dispatch, websocket, push (from libero build)
    counter.gleam               # custom server entry point with SSR routes
    ets_store.gleam             # simple ETS counter: get/increment/decrement
    ets_store_ffi.erl           # ETS FFI (Erlang)
  test/
    counter_test.gleam          # handler test
```

## Shared package

### `shared/src/shared/messages.gleam`

```gleam
pub type MsgFromClient {
  Increment
  Decrement
  GetCounter
}

pub type MsgFromServer {
  CounterUpdated(Result(Int, Nil))
}
```

### `shared/src/shared/views.gleam`

Exports `Route`, `Model`, `Msg`, and all view functions. Everything here compiles to both Erlang and JavaScript.

```gleam
import gleam/int
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub type Route {
  IncPage
  DecPage
}

pub type Model {
  Model(route: Route, counter: Int)
}

/// Msg contains only what views can emit: user actions and navigation.
/// No Dynamic, no RemoteData, no JS-only types.
pub type Msg {
  UserClickedAction
  NavigateTo(Route)
  CounterChanged(Int)
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    nav(model.route),
    html.p([], [html.text("Counter: " <> int.to_string(model.counter))]),
    case model.route {
      IncPage ->
        html.button([event.on_click(UserClickedAction)], [html.text("+")])
      DecPage ->
        html.button([event.on_click(UserClickedAction)], [html.text("-")])
    },
  ])
}

fn nav(current: Route) -> Element(Msg) {
  html.nav([], [
    nav_link("/inc", "Increment", current == IncPage),
    html.text(" | "),
    nav_link("/dec", "Decrement", current == DecPage),
  ])
}

fn nav_link(href: String, label: String, active: Bool) -> Element(Msg) {
  html.a(
    [
      attribute.href(href),
      attribute.attribute("data-navlink", ""),
      ..case active {
        True -> [attribute.class("active")]
        False -> []
      }
    ],
    [html.text(label)],
  )
}

pub fn route_from_path(path: String) -> Route {
  case path {
    "/dec" -> DecPage
    _ -> IncPage
  }
}

pub fn route_to_path(route: Route) -> String {
  case route {
    IncPage -> "/inc"
    DecPage -> "/dec"
  }
}
```

## Client package

### `clients/web/src/app.gleam`

Thin shell: `main`, `init`, `update`. Views are imported from shared.

```gleam
import gleam/dynamic.{type Dynamic}
import generated/messages as rpc
import libero/remote_data
import libero/ssr
import libero/wire
import lustre
import lustre/effect.{type Effect}
import router
import shared/messages.{Decrement, Increment}
import shared/views.{
  type Model, type Msg, type Route, CounterChanged, DecPage, IncPage, Model,
  NavigateTo, UserClickedAction,
}

pub fn main() {
  let app = lustre.application(init, update, views.view)
  let flags = ssr.read_flags()
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(Msg)) {
  let counter = case ssr.decode_flags(flags) {
    Ok(n) -> n
    Error(_) -> 0
  }
  let route = views.route_from_path(router.get_pathname())
  #(
    Model(route:, counter:),
    effect.batch([
      router.listen_nav_clicks(fn(path) {
        NavigateTo(views.route_from_path(path))
      }),
      router.on_popstate(fn(path) {
        NavigateTo(views.route_from_path(path))
      }),
    ]),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserClickedAction -> {
      let rpc_msg = case model.route {
        IncPage -> Increment
        DecPage -> Decrement
      }
      #(
        model,
        rpc.send_to_server(msg: rpc_msg, on_response: fn(raw) {
          CounterChanged(decode_counter(raw))
        }),
      )
    }
    NavigateTo(route) -> #(
      Model(..model, route:),
      router.push_url(views.route_to_path(route)),
    )
    CounterChanged(n) -> #(Model(..model, counter: n), effect.none())
  }
}

fn decode_counter(raw: Dynamic) -> Int {
  let rd = remote_data.to_remote(raw:, format_domain: fn(_) { "error" })
  case rd {
    remote_data.Success(n) -> n
    _ -> 0
  }
}
```

### `clients/web/src/router.gleam`

Gleam wrappers for browser routing FFI.

```gleam
import lustre/effect.{type Effect}

/// Read the current pathname from window.location.
@external(javascript, "./router_ffi.mjs", "getPathname")
pub fn get_pathname() -> String {
  panic as "get_pathname requires a browser"
}

/// Push a URL to the history stack without reloading.
/// Returns an Effect that calls pushState.
pub fn push_url(path: String) -> Effect(msg) {
  effect.from(fn(_dispatch) { do_push_url(path) })
}

@external(javascript, "./router_ffi.mjs", "pushUrl")
fn do_push_url(_path: String) -> Nil {
  panic as "push_url requires a browser"
}

/// Listen for clicks on elements with data-navlink attribute.
/// Prevents default, reads the href, and dispatches the mapped message.
pub fn listen_nav_clicks(on_click: fn(String) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) { do_listen_nav_clicks(fn(path) { dispatch(on_click(path)) }) })
}

@external(javascript, "./router_ffi.mjs", "listenNavClicks")
fn do_listen_nav_clicks(_callback: fn(String) -> Nil) -> Nil {
  panic as "listen_nav_clicks requires a browser"
}

/// Listen for popstate events (back/forward button).
pub fn on_popstate(on_change: fn(String) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) { do_on_popstate(fn(path) { dispatch(on_change(path)) }) })
}

@external(javascript, "./router_ffi.mjs", "onPopstate")
fn do_on_popstate(_callback: fn(String) -> Nil) -> Nil {
  panic as "on_popstate requires a browser"
}
```

### `clients/web/src/router_ffi.mjs`

```javascript
export function getPathname() {
  return globalThis.location?.pathname ?? "/inc";
}

export function pushUrl(path) {
  globalThis.history?.pushState(null, "", path);
}

export function listenNavClicks(callback) {
  document.addEventListener("click", (e) => {
    const link = e.target.closest("[data-navlink]");
    if (link) {
      e.preventDefault();
      const path = new URL(link.href).pathname;
      globalThis.history?.pushState(null, "", path);
      callback(path);
    }
  });
}

export function onPopstate(callback) {
  globalThis.addEventListener("popstate", () => {
    callback(globalThis.location?.pathname ?? "/inc");
  });
}
```

## Server

### `src/ets_store.gleam`

Simple ETS-backed counter. Stores a single integer.

```gleam
@external(erlang, "ets_store_ffi", "init")
pub fn init() -> Nil

@external(erlang, "ets_store_ffi", "get")
pub fn get() -> Int

@external(erlang, "ets_store_ffi", "increment")
pub fn increment() -> Int

@external(erlang, "ets_store_ffi", "decrement")
pub fn decrement() -> Int
```

### `src/ets_store_ffi.erl`

```erlang
-module(ets_store_ffi).
-export([init/0, get/0, increment/0, decrement/0]).

init() ->
    ets:new(counter, [named_table, public, set]),
    ets:insert(counter, {value, 0}),
    nil.

get() ->
    case ets:lookup(counter, value) of
        [{value, V}] -> V;
        [] -> 0
    end.

increment() ->
    V = ets:update_counter(counter, value, 1),
    V.

decrement() ->
    V = ets:update_counter(counter, value, -1),
    V.
```

### `src/server/handler.gleam`

```gleam
import shared/messages.{type MsgFromClient, type MsgFromServer, CounterUpdated}
import server/shared_state.{type SharedState}
import server/app_error.{type AppError}
import ets_store

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    messages.Increment -> Ok(#(CounterUpdated(Ok(ets_store.increment())), state))
    messages.Decrement -> Ok(#(CounterUpdated(Ok(ets_store.decrement())), state))
    messages.GetCounter -> Ok(#(CounterUpdated(Ok(ets_store.get())), state))
  }
}
```

### `src/counter.gleam` (custom server entry point)

The server entry point is generated once by `libero build` via `write_if_missing`, then hand-edited for SSR. Key changes from the default:

- `GET /inc`, `GET /dec` → SSR handler (instead of static HTML shell)
- `GET /` → redirect to `/inc`
- Everything else (WebSocket, RPC, static files) stays the same

SSR handler flow:

1. Map request path to `Route` (404 if no match)
2. Call `ssr.call(handle: dispatch.handle, state:, module: "shared/messages", msg: GetCounter)` to get the counter value
3. Build `Model(route:, counter:)` and call `views.view(model)` to get an `Element`
4. Convert to HTML string via `element.to_string()`
5. Encode counter as flags via `ssr.encode_flags(counter)`
6. Serve via `ssr.document(title: "Counter", body:, flags:, client_module:)`

The SSR handler is a single function that works for any route — the only per-route code is the `Route` pattern match (which lives in `route_from_path` in shared).

## Configuration

### `gleam.toml` (root / server)

```toml
name = "counter"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 2.0.0"
gleam_erlang = "~> 1.0"
gleam_http = "~> 4.0"
mist = "~> 6.0"
lustre = "~> 5.6"
shared = { path = "shared" }
libero = { path = "../../" }

[libero]
port = 8080

[libero.clients.web]
target = "javascript"
```

### `shared/gleam.toml`

```toml
name = "shared"
version = "0.1.0"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 2.0.0"
lustre = "~> 5.6"
```

No target specified — compiles to both Erlang and JavaScript.

### `clients/web/gleam.toml`

Generated by `libero add web --target javascript`. Depends on `shared`, `libero`, `lustre`.

## Scaling to N pages

Adding a new page requires:

1. Add a variant to `Route` in `shared/views.gleam`
2. Add a `case` arm in `view()` for the new route's content
3. Add a link in `nav()`
4. Add a path mapping in `route_from_path` and `route_to_path`
5. If the new page needs different SSR data: add a case arm in the server's SSR handler

No new files, no new generated code, no new client entry points.

## What this proves

1. **Cross-target compilation** — Route, Model, Msg, and views compile to Erlang and JS from shared/
2. **SSR with real data** — server renders HTML with ETS counter via `ssr.call` → dispatch
3. **Hydration** — client starts with pre-rendered DOM, no visible re-render
4. **Client-side routing** — pushState navigation between /inc and /dec, no page reloads
5. **Full refresh works** — refreshing on any URL SSR-renders correctly (verifiable manually)
6. **Linear scaling** — N pages = N route variants + N case arms, no per-page boilerplate
7. **Framework integration** — uses libero scaffolding, codegen, dispatch, ssr.call end-to-end
