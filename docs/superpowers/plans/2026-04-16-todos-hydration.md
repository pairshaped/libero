# todos-hydration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `todos-hydration` example demonstrating SSR + Lustre hydration with Libero.

**Architecture:** Fork of the todos example where view functions live in `shared/` (cross-target). The server renders the initial page via `dispatch.handle()` + `element.to_string()`, embeds state as base64 ETF in flags. The client hydrates the pre-rendered DOM and connects WebSocket for subsequent RPC.

**Tech Stack:** Gleam, Lustre, Mist, Libero, ETF, base64

---

## File map

```
examples/todos-hydration/
  shared/
    gleam.toml                          -- create (adds lustre + libero deps)
    src/shared/todos.gleam              -- create (copy from todos example)
    src/shared/views.gleam              -- create (extracted view + Model/Msg types)
  server/
    gleam.toml                          -- create (copy from todos, no changes)
    src/server.gleam                    -- create (new SSR route, no static index.html)
    src/server/shared_state.gleam       -- create (copy from todos)
    src/server/app_error.gleam          -- create (copy from todos)
    src/server/store.gleam              -- create (copy from todos)
    src/server_store_ffi.erl            -- create (copy from todos)
  client/
    gleam.toml                          -- create (copy from todos)
    src/client/app.gleam                -- create (thin: init with flags, update, main)
    src/client/flags_ffi.mjs            -- create (read window.__LIBERO_FLAGS__, base64 decode)
```

Generated files (produced by running codegen, not hand-written):
```
  server/src/server/generated/libero/   -- dispatch, websocket, todos push, atoms
  client/src/client/generated/libero/   -- todos rpc stubs, rpc_config, rpc_register
```

---

### Task 1: Scaffold shared package

**Files:**
- Create: `examples/todos-hydration/shared/gleam.toml`
- Create: `examples/todos-hydration/shared/src/shared/todos.gleam`

- [ ] **Step 1: Create shared/gleam.toml**

```toml
name = "shared"
version = "0.1.0"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
lustre = "~> 5.6"
libero = { path = "../../.." }
```

No target specified - this package must compile on both erlang and javascript.

- [ ] **Step 2: Create shared/src/shared/todos.gleam**

Copy directly from `examples/todos/shared/src/shared/todos.gleam`:

```gleam
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

pub type MsgFromClient {
  Create(params: TodoParams)
  Toggle(id: Int)
  Delete(id: Int)
  LoadAll
}

pub type MsgFromServer {
  TodoCreated(Result(Todo, TodoError))
  TodoToggled(Result(Todo, TodoError))
  TodoDeleted(Result(Int, TodoError))
  TodosLoaded(Result(List(Todo), TodoError))
}
```

- [ ] **Step 3: Commit**

```bash
git add examples/todos-hydration/shared/
git commit -m "Scaffold todos-hydration shared package with types"
```

---

### Task 2: Add shared view functions

**Files:**
- Create: `examples/todos-hydration/shared/src/shared/views.gleam`

- [ ] **Step 1: Create shared/src/shared/views.gleam**

This file contains the Model, Msg types and all view functions extracted from the todos client. The key difference: these compile on both BEAM (for SSR) and JS (for the client).

```gleam
import gleam/list
import libero/remote_data.{
  type RemoteData, type RpcFailure, Failure, Loading, NotAsked, Success,
}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/todos.{type MsgFromServer, type Todo, TodosLoaded}

pub type Model {
  Model(
    items: RemoteData(List(Todo), RpcFailure),
    input: String,
    last_action: RemoteData(Nil, RpcFailure),
  )
}

pub type Msg {
  InputChanged(String)
  Submit
  ToggleClicked(Int)
  DeleteClicked(Int)
  TodosLoadedMsg(RemoteData(List(Todo), RpcFailure))
  TodoCreatedMsg(RemoteData(Todo, RpcFailure))
  TodoToggledMsg(RemoteData(Todo, RpcFailure))
  TodoDeletedMsg(RemoteData(Int, RpcFailure))
  GotPush(MsgFromServer)
}

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("max-width", "400px"),
        #("margin", "2em auto"),
        #("font-family", "system-ui, sans-serif"),
      ]),
    ],
    [
      html.h1([], [element.text("Todos (hydrated)")]),
      view_input(model),
      view_action_status(model.last_action),
      view_items(model.items),
    ],
  )
}

fn view_input(model: Model) -> Element(Msg) {
  html.form(
    [
      event.on_submit(fn(_formdata) { Submit }),
      attribute.styles([#("display", "flex"), #("gap", "0.5em")]),
    ],
    [
      html.input([
        attribute.value(model.input),
        attribute.placeholder("What needs to be done?"),
        event.on_input(InputChanged),
        attribute.style("flex", "1"),
        attribute.style("padding", "0.5em"),
      ]),
      html.button(
        [attribute.type_("submit"), attribute.style("padding", "0.5em 1em")],
        [element.text("Add")],
      ),
    ],
  )
}

fn view_action_status(rd: RemoteData(Nil, RpcFailure)) -> Element(Msg) {
  case rd {
    Failure(err) ->
      html.p([attribute.style("color", "red")], [element.text(err.message)])
    _ -> element.none()
  }
}

fn view_items(items: RemoteData(List(Todo), RpcFailure)) -> Element(Msg) {
  case items {
    NotAsked | Loading ->
      html.p([attribute.style("opacity", "0.5")], [element.text("Loading...")])
    Failure(err) ->
      html.p([attribute.style("color", "red")], [element.text(err.message)])
    Success(todos) -> view_list(todos)
  }
}

fn view_list(items: List(Todo)) -> Element(Msg) {
  html.ul(
    [attribute.styles([#("list-style", "none"), #("padding", "0")])],
    list.map(items, view_item),
  )
}

fn view_item(item: Todo) -> Element(Msg) {
  let text_styles = case item.completed {
    True -> [#("text-decoration", "line-through"), #("opacity", "0.5")]
    False -> []
  }
  html.li(
    [
      attribute.styles([
        #("display", "flex"),
        #("align-items", "center"),
        #("gap", "0.5em"),
        #("padding", "0.5em 0"),
      ]),
    ],
    [
      html.span(
        [
          event.on_click(ToggleClicked(item.id)),
          attribute.styles([
            #("cursor", "pointer"),
            #("flex", "1"),
            ..text_styles
          ]),
        ],
        [element.text(item.title)],
      ),
      html.button(
        [
          event.on_click(DeleteClicked(item.id)),
          attribute.styles([
            #("cursor", "pointer"),
            #("border", "none"),
            #("background", "none"),
            #("color", "red"),
          ]),
        ],
        [element.text("x")],
      ),
    ],
  )
}
```

- [ ] **Step 2: Verify shared compiles on erlang target**

```bash
cd examples/todos-hydration/shared && gleam check
```

Expected: compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add examples/todos-hydration/shared/src/shared/views.gleam
git commit -m "Add shared view functions for SSR + client hydration"
```

---

### Task 3: Scaffold server package

**Files:**
- Create: `examples/todos-hydration/server/gleam.toml`
- Create: `examples/todos-hydration/server/src/server/shared_state.gleam`
- Create: `examples/todos-hydration/server/src/server/app_error.gleam`
- Create: `examples/todos-hydration/server/src/server/store.gleam`
- Create: `examples/todos-hydration/server/src/server_store_ffi.erl`

- [ ] **Step 1: Create server/gleam.toml**

```toml
name = "server"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
gleam_erlang = "~> 1.0"
gleam_otp = "~> 1.2"
mist = "~> 6.0"
gleam_http = "~> 4.0"
shared = { path = "../shared" }
libero = { path = "../../.." }
```

- [ ] **Step 2: Copy server support files**

Copy these files directly from `examples/todos/server/`:
- `src/server/shared_state.gleam`
- `src/server/app_error.gleam`
- `src/server/store.gleam`
- `src/server_store_ffi.erl`

These are identical to the todos example. The store handler references `server/generated/libero/todos` for push, which will exist after codegen in Task 5.

- [ ] **Step 3: Commit**

```bash
git add examples/todos-hydration/server/
git commit -m "Scaffold todos-hydration server package"
```

---

### Task 4: Scaffold client package

**Files:**
- Create: `examples/todos-hydration/client/gleam.toml`
- Create: `examples/todos-hydration/client/src/client/flags_ffi.mjs`
- Create: `examples/todos-hydration/client/src/client/app.gleam`

- [ ] **Step 1: Create client/gleam.toml**

```toml
name = "client"
version = "0.1.0"
target = "javascript"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
lustre = "~> 5.6"
shared = { path = "../shared" }
libero = { path = "../../.." }
```

- [ ] **Step 2: Create client/src/client/flags_ffi.mjs**

Reads base64-encoded ETF flags from the page and decodes to a BitArray that Gleam can pass to `wire.decode`.

```javascript
export function read_flags() {
  const encoded = window.__LIBERO_FLAGS__;
  if (!encoded) return new Uint8Array(0);
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}
```

- [ ] **Step 3: Create client/src/client/app.gleam**

Thin client: imports view from shared, decodes flags for initial state, subscribes to push.

```gleam
import client/generated/libero/todos as rpc
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import libero/remote_data.{NotAsked, Success, to_remote}
import libero/wire
import lustre
import lustre/effect
import shared/todos.{
  type MsgFromServer, type Todo, Create, Delete, LoadAll, NotFound,
  TitleRequired, TodoParams, TodosLoaded, Toggle,
}
import shared/views.{
  type Model, type Msg, DeleteClicked, GotPush, InputChanged, Model, Submit,
  ToggleClicked, TodoCreatedMsg, TodoDeletedMsg, TodoToggledMsg, TodosLoadedMsg,
}

// ---- Init ----

pub fn init(flags: Dynamic) -> #(Model, effect.Effect(Msg)) {
  let items = decode_flags(flags)
  let subscribe =
    rpc.update_from_server(handler: fn(raw: Dynamic) {
      GotPush(wire.coerce(raw))
    })
  #(
    Model(items: Success(items), input: "", last_action: NotAsked),
    effect.batch([subscribe]),
  )
}

fn decode_flags(flags: Dynamic) -> List(Todo) {
  let assert Ok(etf) = bit_array.base64_decode(coerce_string(flags))
  wire.decode(etf)
}

@external(javascript, "../client/flags_ffi.mjs", "read_flags")
fn read_flags_raw() -> Dynamic

fn coerce_string(value: Dynamic) -> String {
  let assert Ok(s) = dynamic.string(value)
  s
}

// ---- Effects ----

fn format_todo_error(err: todos.TodoError) -> String {
  case err {
    NotFound -> "Todo not found"
    TitleRequired -> "Title is required"
  }
}

fn load_all() -> effect.Effect(Msg) {
  rpc.send_to_server(msg: LoadAll, on_response: fn(raw) {
    TodosLoadedMsg(to_remote(raw: raw, format_domain: format_todo_error))
  })
}

fn create(title: String) -> effect.Effect(Msg) {
  rpc.send_to_server(
    msg: Create(params: TodoParams(title:)),
    on_response: fn(raw) {
      TodoCreatedMsg(to_remote(raw: raw, format_domain: format_todo_error))
    },
  )
}

fn toggle(id: Int) -> effect.Effect(Msg) {
  rpc.send_to_server(msg: Toggle(id:), on_response: fn(raw) {
    TodoToggledMsg(to_remote(raw: raw, format_domain: format_todo_error))
  })
}

fn delete(id: Int) -> effect.Effect(Msg) {
  rpc.send_to_server(msg: Delete(id:), on_response: fn(raw) {
    TodoDeletedMsg(to_remote(raw: raw, format_domain: format_todo_error))
  })
}

// ---- Update ----

pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    InputChanged(value) -> #(Model(..model, input: value), effect.none())

    Submit -> {
      case model.input {
        "" -> #(model, effect.none())
        title -> #(
          Model(..model, input: "", last_action: remote_data.Loading),
          create(title),
        )
      }
    }

    ToggleClicked(id) -> #(
      Model(..model, last_action: remote_data.Loading),
      toggle(id),
    )

    DeleteClicked(id) -> #(
      Model(..model, last_action: remote_data.Loading),
      delete(id),
    )

    TodosLoadedMsg(rd) -> #(Model(..model, items: rd), effect.none())

    TodoCreatedMsg(rd) -> #(
      Model(..model, last_action: remote_data.map(rd, fn(_) { Nil })),
      effect.none(),
    )
    TodoToggledMsg(rd) -> #(
      Model(..model, last_action: remote_data.map(rd, fn(_) { Nil })),
      effect.none(),
    )
    TodoDeletedMsg(rd) -> #(
      Model(..model, last_action: remote_data.map(rd, fn(_) { Nil })),
      effect.none(),
    )

    GotPush(TodosLoaded(Ok(items))) -> #(
      Model(..model, items: Success(items)),
      effect.none(),
    )
    GotPush(_) -> #(model, effect.none())
  }
}

// ---- Main ----

pub fn main() {
  let app = lustre.application(init, update, views.view)
  let flags = read_flags_raw()
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}
```

- [ ] **Step 4: Commit**

```bash
git add examples/todos-hydration/client/
git commit -m "Scaffold todos-hydration client with flags-aware init"
```

---

### Task 5: Run codegen

**Files:**
- Generated: `examples/todos-hydration/server/src/server/generated/libero/` (multiple files)
- Generated: `examples/todos-hydration/client/src/client/generated/libero/` (multiple files)

- [ ] **Step 1: Build shared and server dependencies**

```bash
cd examples/todos-hydration/server && gleam deps download
```

- [ ] **Step 2: Run libero codegen**

```bash
cd examples/todos-hydration/server && gleam run -m libero -- \
  --ws-path=/ws \
  --shared=../shared \
  --server=. \
  --client=../client
```

Expected: generates dispatch, websocket, push wrappers, RPC stubs, config, and register files.

- [ ] **Step 3: Verify server compiles**

```bash
cd examples/todos-hydration/server && gleam check
```

Expected: compiles with no errors.

- [ ] **Step 4: Verify client compiles**

```bash
cd examples/todos-hydration/client && gleam check
```

Expected: compiles with no errors. (Fix any import issues in app.gleam if needed - the generated module names and exports must match.)

- [ ] **Step 5: Commit generated files**

```bash
git add examples/todos-hydration/server/src/server/generated/ examples/todos-hydration/client/src/client/generated/
git commit -m "Generate libero dispatch and client stubs for todos-hydration"
```

---

### Task 6: Add SSR server route

**Files:**
- Create: `examples/todos-hydration/server/src/server.gleam`

- [ ] **Step 1: Create server/src/server.gleam**

The SSR handler calls `dispatch.handle()` directly, renders the shared view to HTML, encodes state as base64 ETF flags, and serves a complete HTML document.

```gleam
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None}
import gleam/string
import libero/push
import libero/remote_data.{NotAsked, Success}
import libero/wire
import libero/ws_logger
import lustre/element
import mist
import server/generated/libero/dispatch
import server/generated/libero/websocket as ws
import server/shared_state
import server/store
import shared/todos.{LoadAll}
import shared/views.{Model}

pub fn main() {
  store.init()
  push.init()
  let shared = shared_state.new()

  let assert Ok(_) =
    fn(req: request.Request(mist.Connection)) {
      case req.method, request.path_segments(req) {
        _, ["ws"] ->
          ws.upgrade(
            request: req,
            state: shared,
            topics: ["todos"],
            logger: ws_logger.default_logger(),
          )
        http.Post, ["rpc"] -> handle_rpc(req, shared)
        _, ["js", ..path] ->
          serve_file(
            "../client/build/dev/javascript/" <> string.join(path, "/"),
            "application/javascript",
          )
        _, _ -> handle_ssr(shared)
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn handle_ssr(
  shared: shared_state.SharedState,
) -> response.Response(mist.ResponseData) {
  // 1. Call dispatch directly with LoadAll
  let call = wire.encode_call(module: "shared/todos", msg: LoadAll)
  let #(response_bytes, _, _) = dispatch.handle(state: shared, data: call)

  // 2. Decode the response to get List(Todo)
  //    Wire response has a 1-byte tag prefix (0x00 = response), then
  //    Result(payload, RpcError) in ETF. Strip the tag, decode, unwrap.
  let assert <<_tag, etf_payload:bytes>> = response_bytes
  let assert Ok(items) = wire.decode_safe(etf_payload)

  // 3. Build model and render view
  let model = Model(items: Success(items), input: "", last_action: NotAsked)
  let rendered = element.to_string(views.view(model))

  // 4. Encode items as base64 ETF for client flags
  let flags_etf = wire.encode(items)
  let flags_b64 = bit_array.base64_encode(flags_etf, True)

  // 5. Build HTML document
  let html =
    "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\" />\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n  <title>Todos - hydration example</title>\n</head>\n<body>\n  <div id=\"app\">"
    <> rendered
    <> "</div>\n  <script>window.__LIBERO_FLAGS__ = \""
    <> flags_b64
    <> "\";</script>\n  <script type=\"module\">\n    import { main } from \"/js/client/client/app.mjs\";\n    main();\n  </script>\n</body>\n</html>"

  response.new(200)
  |> response.set_header("content-type", "text/html")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

fn handle_rpc(
  req: request.Request(mist.Connection),
  shared: shared_state.SharedState,
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 1_000_000) {
    Ok(req) -> {
      let #(response_bytes, _maybe_panic, _new_state) =
        dispatch.handle(state: shared, data: req.body)
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

fn serve_file(
  path: String,
  content_type: String,
) -> response.Response(mist.ResponseData) {
  case mist.send_file(path, offset: 0, limit: None) {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(body)
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
  }
}
```

- [ ] **Step 2: Verify server compiles**

```bash
cd examples/todos-hydration/server && gleam check
```

Expected: compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add examples/todos-hydration/server/src/server.gleam
git commit -m "Add SSR route with dispatch.handle + element.to_string"
```

---

### Task 7: Integration test

- [ ] **Step 1: Build the client JS**

```bash
cd examples/todos-hydration/client && gleam build
```

- [ ] **Step 2: Start the server**

```bash
cd examples/todos-hydration/server && gleam run &
```

- [ ] **Step 3: Verify SSR response**

```bash
curl -s http://localhost:8080/ | head -20
```

Expected: a complete HTML document with:
- `<div id="app">` containing rendered HTML (not empty)
- A `<script>` tag with `window.__LIBERO_FLAGS__` set to a base64 string
- A `<script type="module">` importing the client app

- [ ] **Step 4: Verify the HTML contains pre-rendered content**

The response should contain todo markup (or an empty list representation) inside `<div id="app">`, not just an empty div.

- [ ] **Step 5: Stop the server and commit any fixes**

If any adjustments were needed during testing, commit them:

```bash
git add examples/todos-hydration/
git commit -m "Fix integration issues in todos-hydration example"
```

---

### Task 8: Format, lint, final commit

- [ ] **Step 1: Format all example files**

```bash
gleam format examples/todos-hydration/
```

- [ ] **Step 2: Verify the main libero tests still pass**

```bash
gleam test
```

Expected: 137 passed, no failures.

- [ ] **Step 3: Final commit**

```bash
git add examples/todos-hydration/
git commit -m "Add todos-hydration example: SSR + Lustre hydration with Libero"
```
