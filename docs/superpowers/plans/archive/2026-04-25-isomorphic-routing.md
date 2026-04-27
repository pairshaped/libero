# Isomorphic Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ssr.handle_request` and `ssr.boot_script` to `libero/ssr`, migrate the `examples/ssr_hydration` example to use them, add a cross-target shared-module test fixture, and remove the now-superseded `ssr.document`.

**Architecture:** Pure runtime helpers in `libero/ssr` — no codegen, no new module. `handle_request` orchestrates parse → load → render → wrap into a `Response(mist.ResponseData)`. `boot_script` produces a lustre fragment of two `<script>` elements (flag-embedding + ESM import). Modem owns browser routing on the client. `ssr.document` is removed once the example no longer depends on it. The follow-up scaffold work (default `libero new` shape, `--no-client` flag) is filed as bean `libero-jqaj` and is out of scope here.

**Tech Stack:** Gleam (Erlang + JavaScript targets), lustre 5.6+, modem 2.1+, mist 6.0+, gleeunit. Tests use the existing `test/libero/ssr_test.gleam` patterns.

**Spec:** `docs/superpowers/specs/2026-04-25-isomorphic-routing-design.md`

---

## Phase 1 — Library helpers

### Task 1: Add `ssr.boot_script`

**Files:**
- Modify: `src/libero/ssr.gleam`
- Modify: `test/libero/ssr_test.gleam`

- [ ] **Step 1: Write failing tests for `boot_script`**

Append to `test/libero/ssr_test.gleam` (after the existing tests, before `// --- escape_html XSS ---`):

```gleam
// --- ssr.boot_script ---

import lustre/element as lustre_element

pub fn boot_script_embeds_encoded_flags_test() {
  let flags = "hello world"
  let encoded = ssr.encode_flags(flags)
  let el = ssr.boot_script(client_module: "/web/app.mjs", flags:)
  let html_str = lustre_element.to_string(el)
  let assert True = string.contains(html_str, encoded)
}

pub fn boot_script_includes_client_module_test() {
  let el = ssr.boot_script(client_module: "/web/app.mjs", flags: 0)
  let html_str = lustre_element.to_string(el)
  let assert True = string.contains(html_str, "/web/app.mjs")
  let assert True = string.contains(html_str, "main()")
}

pub fn boot_script_sets_window_flags_global_test() {
  let el = ssr.boot_script(client_module: "/x.mjs", flags: 1)
  let html_str = lustre_element.to_string(el)
  let assert True = string.contains(html_str, "window.__LIBERO_FLAGS__")
}

pub fn boot_script_module_script_is_module_type_test() {
  let el = ssr.boot_script(client_module: "/x.mjs", flags: 1)
  let html_str = lustre_element.to_string(el)
  // The import script must be type="module" or the import statement is invalid.
  let assert True = string.contains(html_str, "type=\"module\"")
}
```

The `import lustre/element as lustre_element` must be added to the import block at the top of the file (near `import libero/ssr`).

- [ ] **Step 2: Run the failing tests**

```sh
gleam test --target erlang
```
Expected: compile error (`ssr.boot_script` undefined) or "function not found" — confirms tests are exercising the new API.

- [ ] **Step 3: Implement `boot_script`**

Add at the end of `src/libero/ssr.gleam` (after `escape_html`):

```gleam
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Render a fragment of two `<script>` elements that boot the client app:
/// one assigns the base64-encoded ETF flags to `window.__LIBERO_FLAGS__`,
/// the other imports `client_module` as an ES module and calls `main()`.
///
/// Drop this in your document tree (typically at the end of `<body>`)
/// when building a server-rendered page.
///
/// ```gleam
/// html.body([], [
///   html.div([attribute.id("app")], [views.view(model)]),
///   ssr.boot_script(client_module: "/web/app.mjs", flags: model),
/// ])
/// ```
pub fn boot_script(
  client_module client_module: String,
  flags flags: a,
) -> Element(msg) {
  let encoded = encode_flags(flags)
  element.fragment([
    html.script(
      [],
      "window.__LIBERO_FLAGS__ = \"" <> encoded <> "\";",
    ),
    html.script(
      [attribute.type_("module")],
      "import { main } from \"" <> client_module <> "\";\nmain();",
    ),
  ])
}
```

The new imports (`lustre/attribute`, `lustre/element`, `lustre/element/html`) go in the import block at the top of the file.

- [ ] **Step 4: Run the tests, confirm pass**

```sh
gleam test --target erlang
```
Expected: all four `boot_script_*_test` cases pass; existing tests still pass.

- [ ] **Step 5: Format and lint**

```sh
gleam format src/libero/ssr.gleam test/libero/ssr_test.gleam
gleam run -m glinter
```
Expected: no diff from format, glinter exits 0.

- [ ] **Step 6: Commit**

```sh
git add src/libero/ssr.gleam test/libero/ssr_test.gleam
git commit -m "Add ssr.boot_script for SSR flag-embedding + ESM boot

Returns a lustre fragment with two script tags: one that sets
window.__LIBERO_FLAGS__ to the base64 ETF flags, one that imports
the client module as ESM and calls main(). Composes inside any
user-built document tree."
```

---

### Task 2: Add `ssr.handle_request`

**Files:**
- Modify: `src/libero/ssr.gleam`
- Modify: `test/libero/ssr_test.gleam`
- Modify: `gleam.toml` (add `gleam_http`, `mist` to dev-dependencies for tests; check first if already there for tests)

- [ ] **Step 1: Confirm test deps available**

```sh
grep -E "gleam_http|mist" gleam.toml
```
Expected: neither package is currently a dep. They're needed for the unit tests because `handle_request` takes `Request(body)` and returns `Response(mist.ResponseData)`.

- [ ] **Step 2: Add gleam_http and mist as dev-dependencies**

Edit `gleam.toml` `[dev-dependencies]` section to add:
```toml
gleam_http = "~> 4.0"
mist = "~> 6.0"
```

Then:
```sh
gleam deps download
```
Expected: deps resolve and download.

- [ ] **Step 3: Write failing tests for `handle_request`**

Append to `test/libero/ssr_test.gleam`:

```gleam
// --- ssr.handle_request ---

import gleam/bit_array as ba
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import lustre/element/html as html_el
import mist

type FakeRoute {
  HomeRoute
  PostRoute(id: Int)
}

type FakeModel {
  FakeModel(route: FakeRoute, value: Int)
}

type FakeState {
  FakeState(default: Int)
}

fn fake_parse(uri: gleam_uri.Uri) -> Result(FakeRoute, Nil) {
  case gleam_uri.path_segments(uri.path) {
    [] | ["home"] -> Ok(HomeRoute)
    ["posts", id_str] ->
      case int.parse(id_str) {
        Ok(id) -> Ok(PostRoute(id))
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn fake_render(_route: FakeRoute, model: FakeModel) -> lustre_element.Element(Nil) {
  html_el.html([], [
    html_el.body([], [
      html_el.p([], [html_el.text("value=" <> int.to_string(model.value))]),
    ]),
  ])
}

fn fake_load_ok(
  _req: request.Request(String),
  route: FakeRoute,
  state: FakeState,
) -> Result(FakeModel, response.Response(mist.ResponseData)) {
  Ok(FakeModel(route:, value: state.default))
}

fn fake_load_err(
  _req: request.Request(String),
  _route: FakeRoute,
  _state: FakeState,
) -> Result(FakeModel, response.Response(mist.ResponseData)) {
  Error(
    response.new(302)
    |> response.set_header("location", "/login")
    |> response.set_body(mist.Bytes(bytes_tree.new())),
  )
}

fn get_request(path: String) -> request.Request(String) {
  request.new()
  |> request.set_method(http.Get)
  |> request.set_path(path)
}

fn extract_body_string(resp: response.Response(mist.ResponseData)) -> String {
  case resp.body {
    mist.Bytes(tree) -> {
      let bits = bytes_tree.to_bit_array(tree)
      case ba.to_string(bits) {
        Ok(s) -> s
        Error(_) -> ""
      }
    }
    _ -> ""
  }
}

pub fn handle_request_returns_405_on_post_test() {
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/home")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_ok,
      render: fake_render,
      state: FakeState(default: 0),
    )
  let assert 405 = resp.status
}

pub fn handle_request_returns_404_when_parse_fails_test() {
  let req = get_request("/no-such-route")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_ok,
      render: fake_render,
      state: FakeState(default: 0),
    )
  let assert 404 = resp.status
}

pub fn handle_request_returns_loader_error_response_test() {
  let req = get_request("/home")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_err,
      render: fake_render,
      state: FakeState(default: 0),
    )
  let assert 302 = resp.status
  let assert Ok("/login") = response.get_header(resp, "location")
}

pub fn handle_request_renders_200_on_success_test() {
  let req = get_request("/home")
  let resp =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fake_load_ok,
      render: fake_render,
      state: FakeState(default: 7),
    )
  let assert 200 = resp.status
  let assert Ok("text/html") = response.get_header(resp, "content-type")
  let body = extract_body_string(resp)
  let assert True = string.contains(body, "<!doctype html>")
  let assert True = string.contains(body, "value=7")
}

pub fn handle_request_passes_route_with_params_to_loader_test() {
  let req = get_request("/posts/42")
  let captured =
    ssr.handle_request(
      req:,
      parse: fake_parse,
      load: fn(_req, route, _state) {
        case route {
          PostRoute(id) -> Ok(FakeModel(route:, value: id))
          _ -> Ok(FakeModel(route:, value: -1))
        }
      },
      render: fake_render,
      state: FakeState(default: 0),
    )
  let body = extract_body_string(captured)
  let assert True = string.contains(body, "value=42")
}
```

Add these imports at the top of the file. `gleam/string` and `import libero/ssr` are already there from earlier tests; the rest are new. `gleam/uri` is aliased to `gleam_uri` only to keep test code's `uri` parameter name unambiguous from the module.

```gleam
import gleam/bit_array as ba
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/uri as gleam_uri
import lustre/element/html as html_el
import mist
```

(`import lustre/element as lustre_element` was already added in Task 1 — keep it.)

- [ ] **Step 4: Run the failing tests**

```sh
gleam test --target erlang
```
Expected: compile error (`ssr.handle_request` undefined) — confirms tests are exercising new API.

- [ ] **Step 5: Implement `handle_request`**

Add at the end of `src/libero/ssr.gleam`:

```gleam
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/uri.{type Uri}
import mist.{type ResponseData}

/// Render a server-side page for an HTTP request.
///
/// Pipeline: `parse(uri)` → `load(req, route, state)` → `render(route, model)` →
/// HTML response.
///
/// - Non-GET requests get a `405 Method Not Allowed`.
/// - `parse` returning `Error(Nil)` gets a bare `404 Not Found`. Custom 404
///   pages: handle the catch-all in your mist router and only call
///   `handle_request` for paths you recognize.
/// - `load` returning `Error(response)` returns that exact response — the
///   loader owns auth redirects, soft 404s with custom bodies, etc.
/// - `load` returning `Ok(model)` renders the document tree from `render`
///   into a `200 OK` HTML response.
///
/// ```gleam
/// ssr.handle_request(
///   req:,
///   parse: views.parse_route,
///   load: load_page,
///   render: render_page,
///   state:,
/// )
/// ```
pub fn handle_request(
  req req: Request(body),
  parse parse: fn(Uri) -> Result(route, Nil),
  load load: fn(Request(body), route, state) -> Result(model, Response(ResponseData)),
  render render: fn(route, model) -> Element(msg),
  state state: state,
) -> Response(ResponseData) {
  case req.method {
    http.Get -> handle_get(req, parse, load, render, state)
    _ -> empty_response(405)
  }
}

fn handle_get(
  req: Request(body),
  parse: fn(Uri) -> Result(route, Nil),
  load: fn(Request(body), route, state) -> Result(model, Response(ResponseData)),
  render: fn(route, model) -> Element(msg),
  state: state,
) -> Response(ResponseData) {
  let uri = request_to_uri(req)
  case parse(uri) {
    Error(Nil) -> empty_response(404)
    Ok(route) ->
      case load(req, route, state) {
        Error(response) -> response
        Ok(model) -> render_response(render(route, model))
      }
  }
}

fn request_to_uri(req: Request(body)) -> Uri {
  Uri(
    scheme: option.None,
    userinfo: option.None,
    host: option.None,
    port: option.None,
    path: req.path,
    query: req.query,
    fragment: option.None,
  )
}

fn render_response(el: Element(msg)) -> Response(ResponseData) {
  let html_str = element.to_document_string(el)
  response.new(200)
  |> response.set_header("content-type", "text/html")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html_str)))
}

fn empty_response(status: Int) -> Response(ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}
```

The `option` import is already in the file. The `gleam/uri.{type Uri}` import is new — add to the import block. Same for `gleam/bytes_tree`, `gleam/http`, `gleam/http/request`, `gleam/http/response`, and `mist`.

- [ ] **Step 6: Run the tests, confirm pass**

```sh
gleam test --target erlang
```
Expected: all five `handle_request_*_test` cases pass; all existing tests still pass.

- [ ] **Step 7: Format and lint**

```sh
gleam format src/libero/ssr.gleam test/libero/ssr_test.gleam
gleam run -m glinter
```
Expected: no diff from format, glinter exits 0.

- [ ] **Step 8: Commit**

```sh
git add src/libero/ssr.gleam test/libero/ssr_test.gleam gleam.toml manifest.toml
git commit -m "Add ssr.handle_request — SSR page orchestration

Wraps parse → load → render → mist Response in one helper. Loader
returns Result(Model, Response) so it owns failure responses
(auth redirects, soft 404s with custom bodies, etc.). Pure
orchestration: no new primitives, all existing ssr.call /
encode_flags / decode_flags semantics preserved."
```

---

## Phase 2 — Migrate `examples/ssr_hydration`

This phase validates the new helpers against a real working example and lets us delete the hand-rolled `router.gleam` browser shim.

### Task 3: Add modem dep + `parse_route` to shared

**Files:**
- Modify: `examples/ssr_hydration/clients/web/gleam.toml` (add modem dep)
- Modify: `examples/ssr_hydration/shared/src/shared/views.gleam` (add `parse_route`)

- [ ] **Step 1: Add modem dep to the web client**

Edit `examples/ssr_hydration/clients/web/gleam.toml`. Append to `[dependencies]`:

```toml
modem = "~> 2.1"
```

Then resolve from inside the client crate:
```sh
cd examples/ssr_hydration/clients/web && gleam deps download && cd -
```
Expected: modem 2.1.x downloads.

- [ ] **Step 2: Add `parse_route` to shared views**

Edit `examples/ssr_hydration/shared/src/shared/views.gleam`. Add `import gleam/uri.{type Uri}` to the imports, then add this function (between `route_from_path` and the end of file):

```gleam
/// Parse a URI to a Route. Used by both the server (to route requests)
/// and the client (modem hands us a Uri on navigation events).
/// Cross-target: compiles to BEAM and JS.
pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    [] | ["inc"] -> Ok(IncPage)
    ["dec"] -> Ok(DecPage)
    _ -> Error(Nil)
  }
}
```

The `import gleam/uri.{type Uri}` may need `import gleam/uri` adjusted — check current imports first and add what's missing.

- [ ] **Step 3: Verify shared compiles for both targets**

```sh
cd examples/ssr_hydration/shared && gleam build --target erlang && gleam build --target javascript && cd -
```
Expected: both targets build without error.

- [ ] **Step 4: Commit**

```sh
git add examples/ssr_hydration/clients/web/gleam.toml \
        examples/ssr_hydration/clients/web/manifest.toml \
        examples/ssr_hydration/shared/src/shared/views.gleam
git commit -m "ssr_hydration: add modem dep and shared parse_route

parse_route takes a gleam/uri Uri so it can be called from both
the BEAM server (via Uri built from request) and the JS client
(via modem's URL change callback)."
```

---

### Task 4: Migrate server entry to `ssr.handle_request`

**Files:**
- Modify: `examples/ssr_hydration/src/ssr_hydration.gleam`

- [ ] **Step 1: Replace `render_ssr` and the per-route case with `ssr.handle_request`**

Open `examples/ssr_hydration/src/ssr_hydration.gleam`. Replace its full contents with:

```gleam
//// Generated by libero as a starting point. Customized to use ssr.handle_request.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import libero/push
import libero/ssr
import libero/ws_logger
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import mist.{type Connection, type ResponseData}
import server/generated/dispatch.{GetCounter}
import server/generated/websocket as ws
import server/handler_context.{type HandlerContext}
import shared/views.{type Model, type Msg, Model}

pub fn main() {
  let _ = push.init()
  let _ = dispatch.ensure_atoms()
  let state = handler_context.new()
  let logger = ws_logger.default_logger()

  let assert Ok(_) =
    fn(req: Request(Connection)) {
      case req.method, request.path_segments(req) {
        _, ["ws"] -> ws.upgrade(request: req, state:, topics: [], logger:)
        http.Post, ["rpc"] -> handle_rpc(req, state, logger)
        _, ["web", ..path] ->
          serve_file("clients/web/build/dev/javascript/" <> string.join(path, "/"))
        _, _ ->
          ssr.handle_request(
            req:,
            parse: views.parse_route,
            load: load_page,
            render: render_page,
            state:,
          )
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn load_page(
  _req: Request(Connection),
  route: views.Route,
  state: HandlerContext,
) -> Result(Model, response.Response(ResponseData)) {
  let counter_result =
    ssr.call(
      handle: dispatch.handle,
      state:,
      module: "shared/messages",
      msg: GetCounter,
      expect: fn(resp) { result.unwrap(resp, 0) },
    )
  case counter_result {
    Ok(counter) -> Ok(Model(route:, counter:))
    Error(_) ->
      Error(
        response.new(500)
        |> response.set_body(mist.Bytes(bytes_tree.from_string("Server error"))),
      )
  }
}

fn render_page(_route: views.Route, model: Model) -> Element(Msg) {
  html.html([attribute.attribute("lang", "en")], [
    html.head([], [
      html.meta([attribute.attribute("charset", "utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.attribute("content", "width=device-width, initial-scale=1"),
      ]),
      html.title([], "Counter"),
    ]),
    html.body([], [
      html.div([attribute.id("app")], [views.view(model)]),
      ssr.boot_script(client_module: "/web/web/app.mjs", flags: model),
    ]),
  ])
}

fn handle_rpc(
  req: Request(Connection),
  state: HandlerContext,
  logger: ws_logger.Logger,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1_000_000) {
    Ok(req) -> {
      let #(response_bytes, maybe_panic, _new_state) =
        dispatch.handle(state:, data: req.body)
      case maybe_panic {
        Some(info) ->
          logger.error(
            "RPC panic: " <> info.fn_name <> " (trace " <> info.trace_id <> "): " <> info.reason,
          )
        None -> Nil
      }
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(response_bytes)))
    }
    Error(_) ->
      response.new(400)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Bad request")))
  }
}

fn serve_file(path: String) -> response.Response(ResponseData) {
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

Note that the unused `gleam/uri` import is intentional during migration — remove it after Step 2 confirms compile.

- [ ] **Step 2: Build the example to confirm**

```sh
cd examples/ssr_hydration && gleam build --target erlang && cd -
```
Expected: compile succeeds. Remove any unused imports the compiler warns about (likely `gleam/uri` if it's not referenced).

- [ ] **Step 3: Boot server and smoke-test `/inc`**

```sh
cd examples/ssr_hydration && gleam run --target erlang &
SERVER_PID=$!
sleep 3
curl -s http://localhost:8080/inc | grep -E "<!doctype html>|window.__LIBERO_FLAGS__|Counter:"
kill $SERVER_PID
cd -
```
Expected: response contains `<!doctype html>`, `window.__LIBERO_FLAGS__`, and `Counter:` text.

- [ ] **Step 4: Commit**

```sh
git add examples/ssr_hydration/src/ssr_hydration.gleam
git commit -m "ssr_hydration: migrate server entry to ssr.handle_request

Replaces the per-route render_ssr function with a single
handle_request call + load_page + render_page. The page-rendering
logic now goes through libero's runtime helper instead of a
hand-rolled wrapper around ssr.document."
```

---

### Task 5: Migrate client to modem; delete hand-rolled router

**Files:**
- Modify: `examples/ssr_hydration/clients/web/src/app.gleam`
- Delete: `examples/ssr_hydration/clients/web/src/router.gleam`
- Delete: `examples/ssr_hydration/clients/web/src/router_ffi.mjs`
- Create: `examples/ssr_hydration/clients/web/src/flags_ffi.mjs`

- [ ] **Step 1: Create the tiny flags FFI**

Create `examples/ssr_hydration/clients/web/src/flags_ffi.mjs`:

```javascript
export function getFlags() {
  return globalThis.window?.__LIBERO_FLAGS__ ?? "";
}
```

- [ ] **Step 2: Replace `app.gleam` to use modem and read flags**

Replace contents of `examples/ssr_hydration/clients/web/src/app.gleam`:

```gleam
//// Client app: hydrates SSR-rendered HTML, handles RPC and routing via modem.

import generated/messages as rpc
import gleam/dynamic.{type Dynamic}
import gleam/uri.{type Uri}
import libero/remote_data.{type RemoteData, Success}
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import modem
import shared/views.{
  type Model, type Msg, CounterChanged, DecPage, IncPage, Model, NavigateTo,
  UserClickedAction,
}

pub fn main() {
  let app = lustre.application(init, update, views.view)
  let assert Ok(_) = lustre.start(app, "#app", get_flags())
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(Msg)) {
  let assert Ok(model) = libero_ssr.decode_flags(flags)
  #(model, modem.init(on_url_change))
}

fn on_url_change(uri: Uri) -> Msg {
  case views.parse_route(uri) {
    Ok(route) -> NavigateTo(route)
    // Modem only fires for in-app navigations; bad URLs shouldn't get here,
    // but if they do we keep the user on whatever they're already viewing.
    Error(_) -> NavigateTo(IncPage)
  }
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserClickedAction -> {
      let effect = case model.route {
        IncPage ->
          rpc.increment(on_response: fn(rd) { CounterChanged(unwrap_counter(rd)) })
        DecPage ->
          rpc.decrement(on_response: fn(rd) { CounterChanged(unwrap_counter(rd)) })
      }
      #(model, effect)
    }
    NavigateTo(route) -> #(Model(..model, route:), effect.none())
    CounterChanged(n) -> #(Model(..model, counter: n), effect.none())
  }
}

fn unwrap_counter(rd: RemoteData(Int, Nil)) -> Int {
  case rd {
    Success(n) -> n
    _ -> 0
  }
}

@external(javascript, "./flags_ffi.mjs", "getFlags")
fn get_flags() -> Dynamic {
  panic as "get_flags requires a browser"
}
```

Note: `NavigateTo` no longer pushes a URL itself — modem is wired to intercept link clicks, so navigation triggers automatically when `data-navlink` is removed and replaced with regular `href` links. Step 3 handles the view change.

- [ ] **Step 3: Update `views.gleam` to use plain `href` links**

The previous `nav_link` in `examples/ssr_hydration/shared/src/shared/views.gleam` adds a `data-navlink` attribute that the hand-rolled router intercepts. With modem, plain `href` links work — modem intercepts same-origin link clicks by default.

In `examples/ssr_hydration/shared/src/shared/views.gleam`, edit the `nav_link` function — remove the `attribute.attribute("data-navlink", "")` line:

```gleam
fn nav_link(href: String, label: String, active: Bool) -> Element(Msg) {
  html.a(
    [
      attribute.href(href),
      ..case active {
        True -> [attribute.class("active")]
        False -> []
      }
    ],
    [html.text(label)],
  )
}
```

- [ ] **Step 4: Delete the hand-rolled router files**

```sh
rm examples/ssr_hydration/clients/web/src/router.gleam
rm examples/ssr_hydration/clients/web/src/router_ffi.mjs
```

- [ ] **Step 5: Build the client crate to confirm**

```sh
cd examples/ssr_hydration/clients/web && gleam build --target javascript && cd -
```
Expected: compile succeeds. No reference to `router` should remain.

- [ ] **Step 6: Smoke-test the full app end-to-end**

```sh
cd examples/ssr_hydration && gleam run --target erlang &
SERVER_PID=$!
sleep 3
# Check /inc returns rendered HTML with flags
curl -s http://localhost:8080/inc | grep -q "Counter:" && echo "/inc OK"
# Check /dec returns rendered HTML with flags
curl -s http://localhost:8080/dec | grep -q "Counter:" && echo "/dec OK"
# Check unknown route returns 404
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/no-such-route
kill $SERVER_PID
cd -
```
Expected: `/inc OK`, `/dec OK`, and `404` printed.

- [ ] **Step 7: Commit**

```sh
git add examples/ssr_hydration/clients/web/src/app.gleam \
        examples/ssr_hydration/clients/web/src/flags_ffi.mjs \
        examples/ssr_hydration/shared/src/shared/views.gleam
git rm examples/ssr_hydration/clients/web/src/router.gleam \
       examples/ssr_hydration/clients/web/src/router_ffi.mjs
git commit -m "ssr_hydration: migrate client to modem, delete hand-rolled router

Modem now owns link-click interception, pushState, and popstate.
Init reads flags via a tiny FFI shim and decodes them into the
starting Model. Removed data-navlink attribute from nav_link
since modem intercepts same-origin links by default."
```

---

## Phase 3 — Cross-target test fixture

### Task 6: Add fixture proving shared parse_route compiles + runs on both targets

**Files:**
- Create: `test/fixtures/iso_routing/gleam.toml`
- Create: `test/fixtures/iso_routing/src/iso_routing.gleam` (placeholder so package builds)
- Create: `test/fixtures/iso_routing/test/iso_routing_test.gleam` (BEAM test)
- Create: `test/fixtures/iso_routing/clients/web/gleam.toml`
- Create: `test/fixtures/iso_routing/clients/web/src/web_test_runner.gleam` (JS test)
- Modify: `.gitignore` (ignore fixture build dir)
- Create: `test/iso_routing_setup.sh` (runs both targets, reports)

The fixture is small (one file in shared) and proves: a single `parse_route` function compiles and behaves identically on Erlang and JavaScript targets.

- [ ] **Step 1: Create fixture project skeleton**

```sh
mkdir -p test/fixtures/iso_routing/src \
         test/fixtures/iso_routing/test \
         test/fixtures/iso_routing/shared/src/shared \
         test/fixtures/iso_routing/clients/web/src
```

- [ ] **Step 2: Write `test/fixtures/iso_routing/gleam.toml`**

```toml
name = "iso_routing"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 2.0.0"
shared = { path = "shared" }
libero = { path = "../../.." }

[dev-dependencies]
gleeunit = "~> 1.0"
```

- [ ] **Step 3: Write `test/fixtures/iso_routing/shared/gleam.toml`**

```toml
name = "shared"
version = "0.1.0"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 2.0.0"
```

- [ ] **Step 4: Write the shared route module**

`test/fixtures/iso_routing/shared/src/shared/routes.gleam`:

```gleam
//// Shared route module — must compile and run identically on Erlang and JS.

import gleam/int
import gleam/result
import gleam/uri.{type Uri}

pub type Route {
  Home
  Post(id: Int)
  User(slug: String)
}

pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    [] | ["home"] -> Ok(Home)
    ["posts", id_str] -> int.parse(id_str) |> result.map(Post)
    ["users", slug] -> Ok(User(slug))
    _ -> Error(Nil)
  }
}

pub fn route_to_path(route: Route) -> String {
  case route {
    Home -> "/home"
    Post(id) -> "/posts/" <> int.to_string(id)
    User(slug) -> "/users/" <> slug
  }
}

/// Returns a deterministic test name for a Route — used by both
/// the BEAM and JS test runners to assert identical behavior.
pub fn route_name(route: Route) -> String {
  case route {
    Home -> "home"
    Post(_) -> "post"
    User(_) -> "user"
  }
}
```

- [ ] **Step 5: Write the BEAM test**

`test/fixtures/iso_routing/test/iso_routing_test.gleam`:

```gleam
import gleam/option
import gleam/uri.{Uri}
import gleeunit
import shared/routes.{Home, Post, User}

pub fn main() {
  gleeunit.main()
}

fn make_uri(path: String) -> Uri {
  Uri(
    scheme: option.None,
    userinfo: option.None,
    host: option.None,
    port: option.None,
    path:,
    query: option.None,
    fragment: option.None,
  )
}

pub fn parse_home_test() {
  let assert Ok(Home) = routes.parse_route(make_uri("/home"))
  let assert Ok(Home) = routes.parse_route(make_uri(""))
}

pub fn parse_post_test() {
  let assert Ok(Post(42)) = routes.parse_route(make_uri("/posts/42"))
}

pub fn parse_user_test() {
  let assert Ok(User("alice")) = routes.parse_route(make_uri("/users/alice"))
}

pub fn parse_unknown_test() {
  let assert Error(Nil) = routes.parse_route(make_uri("/no-such-thing"))
}

pub fn parse_post_invalid_id_test() {
  let assert Error(Nil) = routes.parse_route(make_uri("/posts/notanumber"))
}

pub fn route_to_path_roundtrip_test() {
  let routes_to_test = [Home, Post(7), User("bob")]
  let assert True = list_all_roundtrip(routes_to_test)
}

fn list_all_roundtrip(routes_list: List(routes.Route)) -> Bool {
  case routes_list {
    [] -> True
    [r, ..rest] -> {
      let path = routes.route_to_path(r)
      case routes.parse_route(make_uri(path)) {
        Ok(parsed) if parsed == r -> list_all_roundtrip(rest)
        _ -> False
      }
    }
  }
}
```

- [ ] **Step 6: Write JS client crate gleam.toml**

`test/fixtures/iso_routing/clients/web/gleam.toml`:

```toml
name = "web"
version = "0.1.0"
target = "javascript"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 2.0.0"
shared = { path = "../../shared" }
```

- [ ] **Step 7: Write a JS-target test runner that exercises the same routes**

`test/fixtures/iso_routing/clients/web/src/web_test_runner.gleam`:

```gleam
//// Compiles to JS and runs the same parse_route assertions.
//// On any failure, panics — `gleam run` exits non-zero. On success, prints "OK".

import gleam/option
import gleam/uri.{Uri}
import shared/routes.{Home, Post, User}

fn make_uri(path: String) -> Uri {
  Uri(
    scheme: option.None,
    userinfo: option.None,
    host: option.None,
    port: option.None,
    path:,
    query: option.None,
    fragment: option.None,
  )
}

pub fn main() {
  let assert Ok(Home) = routes.parse_route(make_uri("/home"))
  let assert Ok(Home) = routes.parse_route(make_uri(""))
  let assert Ok(Post(42)) = routes.parse_route(make_uri("/posts/42"))
  let assert Ok(User("alice")) = routes.parse_route(make_uri("/users/alice"))
  let assert Error(Nil) = routes.parse_route(make_uri("/no-such-thing"))
  let assert Error(Nil) = routes.parse_route(make_uri("/posts/notanumber"))
  echo "OK"
  Nil
}
```

(`echo` writes to stdout on JS; if the runtime doesn't support it, swap for `io.println` from `gleam/io` and import accordingly.)

- [ ] **Step 8: Write a placeholder root module**

`test/fixtures/iso_routing/src/iso_routing.gleam`:

```gleam
//// Placeholder so the iso_routing package builds — all logic is in shared/.

pub fn main() {
  Nil
}
```

- [ ] **Step 9: Write the cross-target setup script**

`test/iso_routing_setup.sh`:

```bash
#!/usr/bin/env bash
# Builds and tests the iso_routing fixture on both Erlang and JS targets.
# Used by CI to prove the shared parse_route compiles and runs identically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/iso_routing"

cd "$FIXTURE"

echo "==> Building shared on Erlang target"
(cd shared && gleam build --target erlang)

echo "==> Building shared on JavaScript target"
(cd shared && gleam build --target javascript)

echo "==> Running BEAM tests"
gleam test

echo "==> Building JS web crate"
cd clients/web
gleam build --target javascript

echo "==> Running JS test runner"
output="$(gleam run --target javascript 2>&1)"
echo "$output"
echo "$output" | grep -q "^OK$" || {
  echo "JS test runner did not print OK"
  exit 1
}

echo "==> All cross-target tests passed"
```

Make it executable:
```sh
chmod +x test/iso_routing_setup.sh
```

- [ ] **Step 10: Add fixture build outputs to `.gitignore`**

Append to `.gitignore`:

```
# iso_routing test fixture build artifacts
test/fixtures/iso_routing/build/
test/fixtures/iso_routing/shared/build/
test/fixtures/iso_routing/clients/web/build/
```

- [ ] **Step 11: Run the setup script**

```sh
./test/iso_routing_setup.sh
```
Expected: ends with `==> All cross-target tests passed`.

- [ ] **Step 12: Commit**

```sh
git add test/fixtures/iso_routing/ test/iso_routing_setup.sh .gitignore
git commit -m "Add iso_routing test fixture: shared parse_route on both targets

Fixture project exercises the same parse_route/route_to_path
functions on Erlang (via gleeunit) and JavaScript (via gleam run
on a small assertion script). Proves a shared cross-target
routing module works identically on BEAM and JS — the load-
bearing assumption of libero's SSR-with-hydration story."
```

---

## Phase 4 — Remove `ssr.document`

The example no longer uses `ssr.document`, so the function can go.

### Task 7: Delete `ssr.document` and its tests

**Files:**
- Modify: `src/libero/ssr.gleam` (remove `document` and `escape_html`)
- Modify: `test/libero/ssr_test.gleam` (remove `document_*_test` cases)

- [ ] **Step 1: Verify nothing else uses `ssr.document`**

```sh
grep -rn "ssr\.document\|libero/ssr.*document\|libero_ssr\.document" \
  src test examples \
  --exclude-dir=build --exclude-dir=manifest.toml
```
Expected: no matches in source code (only the tests in `test/libero/ssr_test.gleam`).

- [ ] **Step 2: Remove `document` and `escape_html` from `src/libero/ssr.gleam`**

Delete the `document` function (lines roughly 105-121 in current file) and `escape_html` (lines roughly 124-131).

If after removal the `import gleam/string` line is no longer used by anything else in the file, remove it too. Check:
```sh
grep -n "string\." src/libero/ssr.gleam
```

- [ ] **Step 3: Remove `document` tests from `test/libero/ssr_test.gleam`**

Delete:
- `pub fn document_contains_title_and_body_test()` (the whole function)
- `pub fn document_escapes_xss_in_title_test()` (the whole function)
- The `// --- ssr.document ---` comment header

- [ ] **Step 4: Run all tests**

```sh
gleam test --target erlang
```
Expected: all remaining tests pass; no compile errors from missing `document`.

- [ ] **Step 5: Format and lint**

```sh
gleam format src/libero/ssr.gleam test/libero/ssr_test.gleam
gleam run -m glinter
```
Expected: no diff from format, glinter exits 0.

- [ ] **Step 6: Bump libero version (breaking change)**

Edit `gleam.toml`, change `version = "5.0.0"` to `version = "6.0.0"`.

Then update `libero_version` in `src/libero/cli/templates.gleam`:
```gleam
const libero_version = "~> 6.0"
```

- [ ] **Step 7: Run full test suite end-to-end**

```sh
gleam test --target erlang
./test/iso_routing_setup.sh
cd examples/ssr_hydration && gleam build --target erlang && gleam build --target javascript && cd -
```
Expected: everything passes.

- [ ] **Step 8: Commit**

```sh
git add src/libero/ssr.gleam test/libero/ssr_test.gleam gleam.toml src/libero/cli/templates.gleam
git commit -m "Remove ssr.document — replaced by handle_request + boot_script

The canned (title, body, flags, client_module) shell can't express
what real apps need (per-request html attributes, multiple
stylesheets, vendor scripts, custom elements). Users now build
their own document tree via render: fn(Route, Model) -> Element(msg)
and drop ssr.boot_script() in for the flag-embedding script tag.

Bumps libero to 6.0 — breaking change."
```

---

## Verification before completion

After all phases:

- [ ] `gleam test --target erlang` passes
- [ ] `./test/iso_routing_setup.sh` passes
- [ ] `cd examples/ssr_hydration && gleam build --target erlang` succeeds
- [ ] `cd examples/ssr_hydration/clients/web && gleam build --target javascript` succeeds
- [ ] Smoke test: boot ssr_hydration server, GET `/inc` and `/dec` return rendered HTML with flag-embedding script; GET `/no-such-route` returns 404
- [ ] No grep hits for `ssr\.document` outside of build artifacts
- [ ] No grep hits for `examples/ssr_hydration/clients/web/src/router\.gleam` (file deleted)

After verification passes, file the follow-up:
- bean `libero-jqaj` is already filed (Plan B — scaffold work). Update it with any API rough-edges discovered during this plan that should inform scaffold defaults.
