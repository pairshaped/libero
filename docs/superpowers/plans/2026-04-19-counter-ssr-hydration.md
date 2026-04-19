# Counter SSR + Hydration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an SSR + hydration example with client-side routing that proves shared Gleam views compile to both Erlang and JavaScript, and that adding pages scales linearly.

**Architecture:** Single Lustre SPA with two views (`/inc`, `/dec`) sharing an ETS-backed counter. Server SSR-renders the correct view per URL via `ssr.call` → dispatch, embeds counter as flags. Client hydrates, then uses WebSocket RPC for button clicks and `pushState` for navigation.

**Tech Stack:** Gleam, Lustre, Libero (codegen + SSR + wire), Mist (HTTP/WS), ETS

---

### Task 1: Scaffold the counter project with libero

**Files:**
- Create: `examples/counter/gleam.toml`
- Create: `examples/counter/shared/gleam.toml`
- Create: `examples/counter/shared/src/shared/messages.gleam`

This task scaffolds the project skeleton, shared package with message types, and runs `libero` commands to generate the server and client boilerplate.

- [ ] **Step 1: Create the root `gleam.toml`**

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

[dev-dependencies]
gleeunit = "~> 1.0"

[libero]
port = 8080

[libero.clients.web]
target = "javascript"
```

Create at `examples/counter/gleam.toml`.

- [ ] **Step 2: Create the shared package `gleam.toml`**

Create directory `examples/counter/shared/src/shared/` and file `examples/counter/shared/gleam.toml`:

```toml
name = "shared"
version = "0.1.0"

# No target specified - compiles to both Erlang and JavaScript.

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 2.0.0"
lustre = "~> 5.6"
libero = { path = "../../../" }
```

Note: `shared` depends on `lustre` because view functions live here and produce `Element(Msg)`.

- [ ] **Step 3: Create shared message types**

Create `examples/counter/shared/src/shared/messages.gleam`:

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

- [ ] **Step 4: Create the server boilerplate files**

Create `examples/counter/src/server/shared_state.gleam`:

```gleam
import ets_store

pub type SharedState {
  SharedState
}

pub fn new() -> SharedState {
  ets_store.init()
  SharedState
}
```

Create `examples/counter/src/server/app_error.gleam`:

```gleam
pub type AppError {
  AppError(reason: String)
}
```

- [ ] **Step 5: Create the ETS store**

Create `examples/counter/src/ets_store.gleam`:

```gleam
//// Simple ETS-backed integer counter.

@external(erlang, "counter_ets_ffi", "init")
pub fn init() -> Nil

@external(erlang, "counter_ets_ffi", "get")
pub fn get() -> Int

@external(erlang, "counter_ets_ffi", "increment")
pub fn increment() -> Int

@external(erlang, "counter_ets_ffi", "decrement")
pub fn decrement() -> Int
```

Create `examples/counter/src/counter_ets_ffi.erl`:

```erlang
-module(counter_ets_ffi).
-export([init/0, get/0, increment/0, decrement/0]).

init() ->
    case ets:whereis(counter) of
        undefined ->
            ets:new(counter, [named_table, public, set]),
            ets:insert(counter, {value, 0}),
            nil;
        _ ->
            ets:delete_all_objects(counter),
            ets:insert(counter, {value, 0}),
            nil
    end.

get() ->
    case ets:lookup(counter, value) of
        [{value, V}] -> V;
        [] -> 0
    end.

increment() ->
    ets:update_counter(counter, value, 1).

decrement() ->
    ets:update_counter(counter, value, -1).
```

- [ ] **Step 6: Create the handler**

Create `examples/counter/src/server/handler.gleam`:

```gleam
import ets_store
import server/app_error.{type AppError}
import server/shared_state.{type SharedState}
import shared/messages.{
  type MsgFromClient, type MsgFromServer, CounterUpdated, Decrement, GetCounter,
  Increment,
}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Increment -> Ok(#(CounterUpdated(Ok(ets_store.increment())), state))
    Decrement -> Ok(#(CounterUpdated(Ok(ets_store.decrement())), state))
    GetCounter -> Ok(#(CounterUpdated(Ok(ets_store.get())), state))
  }
}
```

- [ ] **Step 7: Run `gleam deps download` and `libero build` to generate stubs**

Run from `examples/counter/`:

```bash
cd examples/counter && gleam deps download
```

Then generate the dispatch, client stubs, and server entry point:

```bash
cd examples/counter && gleam run -m libero -- build
```

This will create:
- `src/server/generated/dispatch.gleam`
- `src/server/generated/websocket.gleam`
- `src/server/generated/messages.gleam`
- `src/counter.gleam` (server entry point — will be customized in Task 3)
- `clients/web/` with generated stubs
- Atom registration file

- [ ] **Step 8: Verify the server compiles**

```bash
cd examples/counter && gleam build
```

Expected: compiles without errors.

- [ ] **Step 9: Commit**

```bash
git add examples/counter/
git commit -m "Scaffold counter example with libero"
```

---

### Task 2: Shared views and route types

**Files:**
- Create: `examples/counter/shared/src/shared/views.gleam`

- [ ] **Step 1: Create the shared views module**

Create `examples/counter/shared/src/shared/views.gleam`:

```gleam
//// Cross-target views, model, and routing types.
//// Compiles to both Erlang (for SSR) and JavaScript (for client).

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

- [ ] **Step 2: Verify shared compiles to Erlang**

```bash
cd examples/counter && gleam build
```

Expected: compiles without errors. This proves the shared views (including lustre element types) compile on the Erlang target.

- [ ] **Step 3: Verify shared compiles to JavaScript**

```bash
cd examples/counter/clients/web && gleam build
```

Expected: compiles without errors. This proves the same views compile on the JavaScript target. (The client depends on shared, so building the client builds shared for JS.)

- [ ] **Step 4: Commit**

```bash
git add examples/counter/shared/src/shared/views.gleam
git commit -m "Add shared views with Route, Model, Msg for counter example"
```

---

### Task 3: Server entry point with SSR

**Files:**
- Modify: `examples/counter/src/counter.gleam` (the generated entry point)

The generated `counter.gleam` serves a static HTML shell. We replace it with SSR rendering that uses `ssr.call` to fetch the counter and `element.to_string` to render the view.

- [ ] **Step 1: Replace the server entry point with SSR logic**

Overwrite `examples/counter/src/counter.gleam` with:

```gleam
//// Server entry point with SSR rendering.
//// Customized from the libero-generated version to add per-route SSR.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libero/push
import libero/ssr
import libero/ws_logger
import lustre/element
import mist.{type Connection}
import server/generated/dispatch
import server/generated/websocket as ws
import server/shared_state
import shared/messages.{GetCounter}
import shared/views.{Model}

pub fn main() {
  push.init()
  dispatch.ensure_atoms()
  let state = shared_state.new()
  let logger = ws_logger.default_logger()

  let assert Ok(_) =
    fn(req: Request(Connection)) {
      case req.method, request.path_segments(req) {
        _, ["ws"] -> ws.upgrade(request: req, state:, topics: [], logger:)
        http.Post, ["rpc"] -> handle_rpc(req, state, logger)
        _, ["web", ..path] ->
          serve_file(
            "clients/web/build/dev/javascript/" <> string.join(path, "/"),
          )
        http.Get, ["inc"] -> render_ssr(views.IncPage, state)
        http.Get, ["dec"] -> render_ssr(views.DecPage, state)
        http.Get, [] -> redirect("/inc")
        _, _ ->
          response.new(404)
          |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn render_ssr(
  route: views.Route,
  state: shared_state.SharedState,
) -> response.Response(mist.ResponseData) {
  // Fetch the counter value through dispatch (same path as client RPC).
  let counter = case
    ssr.call(
      handle: dispatch.handle,
      state:,
      module: "shared/messages",
      msg: GetCounter,
    )
  {
    Ok(n) -> n
    Error(_) -> 0
  }
  // Build the model and render the view to HTML.
  let model = Model(route:, counter:)
  let body = element.to_string(views.view(model))
  let flags = ssr.encode_flags(counter)
  let html =
    ssr.document(
      title: "Counter",
      body:,
      flags:,
      client_module: "/web/web/app.mjs",
    )
  serve_html(html)
}

fn redirect(to: String) -> response.Response(mist.ResponseData) {
  response.new(302)
  |> response.set_header("location", to)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
}

fn handle_rpc(
  req: Request(Connection),
  state: shared_state.SharedState,
  logger: ws_logger.Logger,
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 1_000_000) {
    Ok(req) -> {
      let #(response_bytes, maybe_panic, _new_state) =
        dispatch.handle(state:, data: req.body)
      case maybe_panic {
        Some(info) ->
          logger.error(
            "RPC panic: "
            <> info.fn_name
            <> " (trace "
            <> info.trace_id
            <> "): "
            <> info.reason,
          )
        None -> Nil
      }
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_bit_array(response_bytes)),
      )
    }
    Error(_) ->
      response.new(400)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Bad request")))
  }
}

fn serve_html(html: String) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

fn serve_file(path: String) -> response.Response(mist.ResponseData) {
  case mist.send_file(path, offset: 0, limit: None) {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", content_type(path))
      |> response.set_body(body)
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
  }
}

fn content_type(path: String) -> String {
  case string.split(path, ".") |> list.last {
    Ok("js") | Ok("mjs") -> "application/javascript"
    Ok("css") -> "text/css"
    Ok("html") -> "text/html"
    Ok("json") -> "application/json"
    Ok("wasm") -> "application/wasm"
    Ok("svg") -> "image/svg+xml"
    Ok("png") -> "image/png"
    Ok("ico") -> "image/x-icon"
    Ok("map") -> "application/json"
    _ -> "application/octet-stream"
  }
}
```

- [ ] **Step 2: Verify the server compiles**

```bash
cd examples/counter && gleam build
```

Expected: compiles without errors. This proves `ssr.call`, `element.to_string`, and shared views all work on the Erlang target.

- [ ] **Step 3: Commit**

```bash
git add examples/counter/src/counter.gleam
git commit -m "Add SSR rendering to counter server entry point"
```

---

### Task 4: Client app with routing

**Files:**
- Create: `examples/counter/clients/web/src/router_ffi.mjs`
- Create: `examples/counter/clients/web/src/router.gleam`
- Modify: `examples/counter/clients/web/src/app.gleam` (generated starter, replace contents)

- [ ] **Step 1: Create the router FFI**

Create `examples/counter/clients/web/src/router_ffi.mjs`:

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

- [ ] **Step 2: Create the router Gleam module**

Create `examples/counter/clients/web/src/router.gleam`:

```gleam
//// Browser routing helpers: pushState, pathname reading, click interception.

import lustre/effect.{type Effect}

/// Read the current pathname from window.location.
@external(javascript, "./router_ffi.mjs", "getPathname")
pub fn get_pathname() -> String {
  panic as "get_pathname requires a browser"
}

/// Push a URL to the history stack without reloading.
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
  effect.from(fn(dispatch) {
    do_listen_nav_clicks(fn(path) { dispatch(on_click(path)) })
  })
}

@external(javascript, "./router_ffi.mjs", "listenNavClicks")
fn do_listen_nav_clicks(_callback: fn(String) -> Nil) -> Nil {
  panic as "listen_nav_clicks requires a browser"
}

/// Listen for popstate events (back/forward button).
pub fn on_popstate(on_change: fn(String) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    do_on_popstate(fn(path) { dispatch(on_change(path)) })
  })
}

@external(javascript, "./router_ffi.mjs", "onPopstate")
fn do_on_popstate(_callback: fn(String) -> Nil) -> Nil {
  panic as "on_popstate requires a browser"
}
```

- [ ] **Step 3: Write the client app**

Replace the contents of `examples/counter/clients/web/src/app.gleam` with:

```gleam
//// Client app: hydrates SSR-rendered HTML, handles RPC and routing.

import generated/messages as rpc
import gleam/dynamic.{type Dynamic}
import libero/remote_data
import libero/ssr
import lustre
import lustre/effect.{type Effect}
import router
import shared/messages.{Decrement, Increment}
import shared/views.{
  type Model, type Msg, CounterChanged, DecPage, IncPage, Model, NavigateTo,
  UserClickedAction,
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

- [ ] **Step 4: Build the client**

```bash
cd examples/counter/clients/web && gleam build
```

Expected: compiles without errors. This proves the client app (with shared views, router FFI, and generated stubs) compiles to JavaScript.

- [ ] **Step 5: Commit**

```bash
git add examples/counter/clients/web/src/
git commit -m "Add client app with routing and SSR hydration"
```

---

### Task 5: Handler test

**Files:**
- Create: `examples/counter/test/counter_test.gleam`

- [ ] **Step 1: Write the handler test**

Create `examples/counter/test/counter_test.gleam`:

```gleam
import gleeunit
import server/handler
import server/shared_state
import shared/messages.{CounterUpdated, Decrement, GetCounter, Increment}

pub fn main() {
  gleeunit.main()
}

fn fresh_state() -> shared_state.SharedState {
  shared_state.new()
}

pub fn get_counter_returns_zero_initially_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(0)), _)) =
    handler.update_from_client(msg: GetCounter, state:)
}

pub fn increment_returns_one_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(1)), _)) =
    handler.update_from_client(msg: Increment, state:)
}

pub fn decrement_returns_negative_one_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(-1)), _)) =
    handler.update_from_client(msg: Decrement, state:)
}

pub fn increment_then_decrement_returns_zero_test() {
  let state = fresh_state()
  let assert Ok(#(CounterUpdated(Ok(1)), state)) =
    handler.update_from_client(msg: Increment, state:)
  let assert Ok(#(CounterUpdated(Ok(0)), _)) =
    handler.update_from_client(msg: Decrement, state:)
}
```

- [ ] **Step 2: Run the tests**

```bash
cd examples/counter && gleam test
```

Expected: all 4 tests pass.

- [ ] **Step 3: Commit**

```bash
git add examples/counter/test/counter_test.gleam
git commit -m "Add handler tests for counter example"
```

---

### Task 6: Full build and smoke test

**Files:** None (verification only)

- [ ] **Step 1: Run `libero build` to ensure everything generates cleanly**

```bash
cd examples/counter && gleam run -m libero -- build
```

Expected: all generated files written, no errors.

- [ ] **Step 2: Build the server**

```bash
cd examples/counter && gleam build
```

Expected: compiles without errors.

- [ ] **Step 3: Build the client**

```bash
cd examples/counter/clients/web && gleam build
```

Expected: compiles without errors.

- [ ] **Step 4: Run the tests**

```bash
cd examples/counter && gleam test
```

Expected: all tests pass.

- [ ] **Step 5: Smoke test the server (manual)**

Start the server:

```bash
cd examples/counter && gleam run
```

Then in a browser:
1. Visit `http://localhost:8080/` — should redirect to `/inc`
2. Visit `http://localhost:8080/inc` — should see "Counter: 0" and a "+" button, with nav links
3. Click "+" — counter should increment via WebSocket RPC
4. Click "Decrement" nav link — should navigate to `/dec` without page reload, counter persists
5. Click "-" — counter should decrement
6. Refresh the page on `/dec` — should SSR-render the `/dec` view with the current counter value
7. Click back button — should navigate back to `/inc` via popstate

- [ ] **Step 6: Commit (if any fixes were needed)**

```bash
git add examples/counter/
git commit -m "Fix issues found during smoke test"
```

Skip this step if no fixes were needed.

---

### Task 7: Format and final commit

- [ ] **Step 1: Run gleam format on all example files**

```bash
cd examples/counter && gleam format src/ shared/src/ test/
cd examples/counter/clients/web && gleam format src/
```

- [ ] **Step 2: Commit if formatting changed anything**

```bash
git add examples/counter/
git commit -m "Format counter example with gleam format"
```
