# Getting Started with Libero + SQLite

This guide picks up where [Getting Started](https://github.com/pairshaped/libero/blob/master/GETTING_STARTED.md) left off. The same checklist app, but with state stored in SQLite instead of an in-memory list. Same handler signatures, same client code, persistent data. The Getting Started guide is recommended reading first; this one assumes you've seen the basic shape and now want a real database.

You can also start fresh from this guide if you've used libero before.

This guide walks from an empty directory to a working checklist app: SQLite on the server, typed RPC over WebSocket, and a Lustre SPA in the browser. Every command and every file is shown.

By the end you will have:

- A scaffolded libero project using the three-peer layout (`server/`, `shared/`, `clients/web/`).
- Marmot generating Gleam query functions from `.sql` files.
- Four RPC endpoints (`get_items`, `create_item`, `toggle_item`, `delete_item`) backed by SQLite.
- A Lustre client that hydrates from server-rendered HTML and updates over WebSocket.
- A handler test that exercises the database in memory.

This guide assumes you've worked through the [Gleam tour](https://tour.gleam.run) so syntax like `pub fn`, `Result`, and labelled arguments looks familiar. Libero and marmot are explained as they appear.

## Prerequisites

You need three tools installed:

- **Gleam** (1.5 or newer): the language compiler. Install from [gleam.run/getting-started](https://gleam.run/getting-started/installing/).
- **Erlang/OTP** (27 or newer): the BEAM runtime that gleam compiles to for the server. The Gleam install instructions cover this.
- **sqlite3 CLI**: the command-line tool for creating the database file. On macOS it is preinstalled; on Linux install via your package manager (`apt install sqlite3` or similar).

Confirm each tool:

```bash
gleam --version
erl -version
sqlite3 --version
```

## 1. Scaffold the project

`bin/new` is a small bash script that downloads libero's `examples/default` template and renames it. Run it from anywhere:

```bash
curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/master/bin/new | sh -s my_checklist
cd my_checklist
```

You now have this layout:

```
my_checklist/
├── bin/                 dev/build/server/test scripts
├── server/              Erlang server package
│   ├── gleam.toml
│   ├── src/
│   │   ├── my_checklist.gleam       server entry (mist + libero wiring)
│   │   ├── handler.gleam        RPC endpoints
│   │   ├── handler_context.gleam state passed to every handler
│   │   ├── page.gleam           SSR loader and renderer
│   │   └── generated/           libero codegen output
│   └── test/my_checklist_test.gleam
├── shared/              cross-target package (compiles to Erlang and JS)
│   ├── gleam.toml
│   └── src/shared/
│       ├── router.gleam         Route enum and URL parser
│       ├── types.gleam          domain types
│       └── views.gleam          Model, Msg, view function
└── clients/web/         JavaScript client (Lustre SPA)
    ├── gleam.toml
    └── src/
        ├── app.gleam            Lustre app entry
        └── generated/           libero codegen output for the client
```

Three peer Gleam packages, each with its own `gleam.toml`. The server runs on Erlang, the client compiles to JavaScript, and shared types and views live in a target-agnostic package both sides depend on.

## 2. Run the bare scaffold

Before changing anything, confirm the scaffold works. The `bin/dev` script regenerates libero codegen, builds the JS client, then starts the server:

```bash
bin/dev
```

You'll see output like:

```
libero: found 1 handler endpoint(s) in src
libero: generating stubs for client: web
  wrote ./src/generated/dispatch.gleam
  ...
   Compiled in 0.07s
Listening on http://127.0.0.1:8080
```

Open `http://localhost:8080` in a browser. You'll see the default page with a "Ping" button. Click it and the page shows "Server says: pong". Stop the server with `Ctrl-C`.

The four scripts in `bin/` are composable:

- `bin/gen`: runs libero codegen (`gleam run -m libero` from `server/`).
- `bin/build`: builds the JS client (`gleam build --target javascript` from `clients/web/`).
- `bin/server`: starts the server (`gleam run` from `server/`).
- `bin/dev`: runs the three above in order.

Use `bin/dev` when you've changed handler signatures or shared types. Use `bin/server` alone when you've only changed handler bodies.

## 3. Add marmot to the server

Marmot reads SQL files at build time and generates typed Gleam query functions. It needs sqlight at runtime to talk to SQLite. Add both:

```bash
cd server
gleam add marmot --dev
gleam add sqlight
cd ..
```

Marmot is a dev dependency because it's only needed to generate code, not to run the server. Sqlight ships in your release because the server opens connections at runtime.

Open `server/gleam.toml` and append a marmot config block at the end:

```toml
[tools.marmot]
database = "data.db"
```

Marmot uses this path to introspect column types when generating decoders. The same file becomes the runtime database in step 5.

## 4. Create the SQLite database

In `server/`, write the schema:

```bash
cd server
cat > schema.sql <<'EOF'
CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  completed BOOLEAN NOT NULL DEFAULT 0
);
EOF
sqlite3 data.db ".read schema.sql"
sqlite3 data.db ".tables"   # should print: items
```

`data.db` now sits in `server/`. The runtime server opens it from this same path, so leave it where it is.

## 5. Write the SQL queries

Marmot looks for `.sql` files at `server/src/<dir>/sql/<name>.sql` and writes Gleam to `server/src/generated/sql/<dir>_sql.gleam`. The middle directory becomes part of the generated module name. Use `server` so the generated module is called `server_sql`:

```bash
mkdir -p src/server/sql

cat > src/server/sql/list_items.sql <<'EOF'
-- returns: ItemRow
SELECT id, title, completed
FROM items
ORDER BY id;
EOF

cat > src/server/sql/create_item.sql <<'EOF'
-- returns: ItemRow
INSERT INTO items (title, completed)
VALUES (@title, 0)
RETURNING id, title, completed;
EOF

cat > src/server/sql/toggle_item.sql <<'EOF'
-- returns: ItemRow
UPDATE items
SET completed = NOT completed
WHERE id = @id
RETURNING id, title, completed;
EOF

cat > src/server/sql/delete_item.sql <<'EOF'
-- returns: DeletedRow
DELETE FROM items
WHERE id = @id
RETURNING id;
EOF
```

Three things worth noting about the annotations and parameters:

- The `-- returns: <Name>Row` comment must end in `Row`. Marmot enforces this so generated row types are recognisable at a glance.
- Named parameters use `@name` syntax. Marmot maps these to labelled arguments in the generated function.
- `delete_item` returns just `id`, so its row type is different from the other three. Hence `DeletedRow`.

## 6. Generate query code

Still in `server/`, run marmot:

```bash
gleam run -m marmot
```

You'll see:

```
  wrote src/generated/sql/server_sql.gleam
Generated 2 module(s)
```

Look at what marmot generated:

```bash
cat src/generated/sql/server_sql.gleam | head -25
```

You'll see two row types and four query functions. The shape of `list_items`:

```gleam
pub fn list_items(
  db db: sqlight.Connection,
) -> Result(List(ItemRow), sqlight.Error)
```

Every query function takes `db` as its first labelled argument and returns `Result(List(<RowType>), sqlight.Error)`. Inserts and updates that use `RETURNING` give you back the affected rows in the same shape. Now you can call them from handlers.

Return to the project root:

```bash
cd ..
```

## 7. Define the shared types

Domain types live in `shared/` because both the server (in handler signatures) and the client (in view code) reference them. Replace `shared/src/shared/types.gleam`:

```gleam
pub type Item {
  Item(id: Int, title: String, completed: Bool)
}

pub type ItemParams {
  ItemParams(title: String)
}

pub type ItemError {
  NotFound
  TitleRequired
  DatabaseError
}
```

`Item` is the domain object. `ItemParams` is the input shape for `create_item`. `ItemError` is the typed error returned when something goes wrong. Libero uses these directly: `ItemError` shows up on the client as `Failure(NotFound)`, no string parsing required.

## 8. Update the shared views

The view function lives in `shared/` so the server can render it during SSR and the client can render it during hydration. Replace `shared/src/shared/views.gleam`:

```gleam
import gleam/list
import libero/remote_data.{
  type RemoteData, Failure, Loading, NotAsked, Success, TransportFailure,
}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/router.{type Route, Home}
import shared/types.{
  type Item, type ItemError, DatabaseError, NotFound, TitleRequired,
}

pub type Model {
  Model(
    route: Route,
    items: RemoteData(List(Item), ItemError),
    input: String,
  )
}

pub type Msg {
  NavigateTo(Route)
  NoOp
  UserTyped(value: String)
  UserSubmittedTitle
  UserToggled(id: Int)
  UserDeleted(id: Int)
}

pub fn view(model: Model) -> Element(Msg) {
  case model.route {
    Home -> home_view(model)
  }
}

fn home_view(model: Model) -> Element(Msg) {
  html.main(
    [
      attribute.styles([
        #("max-width", "32rem"),
        #("margin", "2rem auto"),
        #("font-family", "system-ui, sans-serif"),
      ]),
    ],
    [
      html.h1([], [html.text("Checklist")]),
      view_form(model.input),
      view_items(model.items),
    ],
  )
}

fn view_form(input: String) -> Element(Msg) {
  html.form(
    [
      event.on_submit(fn(_) { UserSubmittedTitle }),
      attribute.styles([#("display", "flex"), #("gap", "0.5rem")]),
    ],
    [
      html.input([
        attribute.type_("text"),
        attribute.value(input),
        attribute.placeholder("What needs doing?"),
        event.on_input(UserTyped),
        attribute.style("flex", "1"),
      ]),
      html.button([attribute.type_("submit")], [html.text("Add")]),
    ],
  )
}

fn view_items(items: RemoteData(List(Item), ItemError)) -> Element(Msg) {
  case items {
    NotAsked -> element.none()
    Loading -> html.p([], [html.text("Loading…")])
    Failure(err) ->
      html.p([attribute.style("color", "crimson")], [
        html.text(format_error(err)),
      ])
    TransportFailure(message) ->
      html.p([attribute.style("color", "crimson")], [
        html.text("Connection error: " <> message),
      ])
    Success(items) ->
      html.ul(
        [attribute.style("padding", "0")],
        list.map(items, view_item),
      )
  }
}

fn view_item(item: Item) -> Element(Msg) {
  html.li(
    [
      attribute.styles([
        #("display", "flex"),
        #("gap", "0.5rem"),
        #("align-items", "center"),
        #("padding", "0.5rem 0"),
        #("list-style", "none"),
      ]),
    ],
    [
      html.input([
        attribute.type_("checkbox"),
        attribute.checked(item.completed),
        event.on_check(fn(_) { UserToggled(item.id) }),
      ]),
      html.span(
        [
          attribute.styles([
            #("flex", "1"),
            #("text-decoration", case item.completed {
              True -> "line-through"
              False -> "none"
            }),
          ]),
        ],
        [html.text(item.title)],
      ),
      html.button(
        [event.on_click(UserDeleted(item.id))],
        [html.text("Delete")],
      ),
    ],
  )
}

fn format_error(err: ItemError) -> String {
  case err {
    NotFound -> "That item is gone."
    TitleRequired -> "Title is required."
    DatabaseError -> "Database error. Try again."
  }
}
```

`Model` holds the current route, the item list as a `RemoteData` (so loading and failure states have a place to live), and the form input string. `Msg` enumerates the things the user can do. `view` renders one of several pages based on the route; for now, `Home` is the only one.

## 9. Open the database in handler_context

Every libero handler receives a `HandlerContext`. It's the type you use to share things across handlers, like a database connection. Replace `server/src/handler_context.gleam`:

```gleam
import sqlight

pub type HandlerContext {
  HandlerContext(db: sqlight.Connection)
}

pub fn new(db db: sqlight.Connection) -> HandlerContext {
  HandlerContext(db:)
}
```

Now the server entry must open the connection and pass it in. Edit `server/src/my_checklist.gleam`. Find this line:

```gleam
let state = handler_context.new()
```

Change it to:

```gleam
let assert Ok(db) = sqlight.open("file:data.db")
let state = handler_context.new(db:)
```

And add `import sqlight` to the imports near the top of the file (the imports are alphabetised; insert it after `import shared/router`).

`sqlight.open` returns `Result(Connection, Error)`. The `let assert` panics with a clear message if the database can't be opened. For a single-process server this is fine. A production app would handle the error and exit cleanly.

## 10. Write the RPC handlers

This is where libero's "handler as contract" pattern shows up: every public function in `server/src/handler.gleam` whose last parameter is `HandlerContext` and whose return type is `#(Result(value, error), HandlerContext)` becomes an RPC endpoint automatically. No registration, no routing tables.

Replace `server/src/handler.gleam`:

```gleam
import generated/sql/server_sql
import gleam/list
import handler_context.{type HandlerContext}
import shared/types.{
  type Item, type ItemError, type ItemParams, DatabaseError, Item, NotFound,
  TitleRequired,
}

pub fn get_items(
  state state: HandlerContext,
) -> #(Result(List(Item), ItemError), HandlerContext) {
  case server_sql.list_items(db: state.db) {
    Ok(rows) -> #(Ok(list.map(rows, row_to_item)), state)
    Error(_) -> #(Error(DatabaseError), state)
  }
}

pub fn create_item(
  params params: ItemParams,
  state state: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  case params.title {
    "" -> #(Error(TitleRequired), state)
    title ->
      case server_sql.create_item(db: state.db, title:) {
        Ok([row]) -> #(Ok(row_to_item(row)), state)
        Ok(_) -> #(Error(DatabaseError), state)
        Error(_) -> #(Error(DatabaseError), state)
      }
  }
}

pub fn toggle_item(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Item, ItemError), HandlerContext) {
  case server_sql.toggle_item(db: state.db, id:) {
    Ok([row]) -> #(Ok(row_to_item(row)), state)
    Ok([]) -> #(Error(NotFound), state)
    Ok(_) -> #(Error(DatabaseError), state)
    Error(_) -> #(Error(DatabaseError), state)
  }
}

pub fn delete_item(
  id id: Int,
  state state: HandlerContext,
) -> #(Result(Int, ItemError), HandlerContext) {
  case server_sql.delete_item(db: state.db, id:) {
    Ok([row]) -> #(Ok(row.id), state)
    Ok([]) -> #(Error(NotFound), state)
    Ok(_) -> #(Error(DatabaseError), state)
    Error(_) -> #(Error(DatabaseError), state)
  }
}

fn row_to_item(row: server_sql.ItemRow) -> Item {
  Item(id: row.id, title: row.title, completed: row.completed)
}
```

Note the separation: marmot row types stay inside `server/`, while domain types in `shared/` are what cross the wire. `row_to_item` is the small adapter between the two.

The `Ok([])` arms on toggle and delete handle the case where the SQL `WHERE id = @id` matches nothing. SQLite returns an empty result set, libero translates that into the typed `NotFound` error.

## 11. Pre-fetch items during SSR

The page renderer can call handlers directly to load data for server-side rendering. The user's first paint then includes the items, no client round-trip needed.

Replace `server/src/page.gleam`:

```gleam
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import handler
import handler_context.{type HandlerContext}
import libero/remote_data.{Failure, Success}
import libero/ssr
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import mist.{type Connection, type ResponseData}
import shared/router.{type Route}
import shared/views.{type Model, type Msg, Model}

pub fn load_page(
  _req: Request(Connection),
  route: Route,
  state: HandlerContext,
) -> Result(Model, Response(ResponseData)) {
  let #(result, _) = handler.get_items(state:)
  let items = case result {
    Ok(items) -> Success(items)
    Error(err) -> Failure(err)
  }
  Ok(Model(route:, items:, input: ""))
}

pub fn render_page(_route: Route, model: Model) -> Element(Msg) {
  html.html([attribute.attribute("lang", "en")], [
    html.head([], [
      html.meta([attribute.attribute("charset", "utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.attribute("content", "width=device-width, initial-scale=1"),
      ]),
      html.title([], "Checklist"),
    ]),
    html.body([], [
      html.div([attribute.id("app")], [views.view(model)]),
      ssr.boot_script(client_module: "/web/web/app.mjs", flags: model),
    ]),
  ])
}
```

`load_page` runs on every full-page request. It calls `handler.get_items` directly, threads the resulting `RemoteData` into the model, and returns it. `render_page` wraps the shared view in an HTML shell and embeds the model as base64-encoded ETF for the client to pick up via `read_flags()`.

## 12. Update the client app

The client has two jobs: hydrate from the SSR flags, and handle user actions by calling RPCs and updating the model. Replace `clients/web/src/app.gleam`:

```gleam
import generated/messages as rpc
import generated/ssr.{read_flags}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/uri.{type Uri}
import libero/remote_data.{type RemoteData, Success}
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import lustre/element
import modem
import shared/router
import shared/types.{type Item, type ItemError, ItemParams}
import shared/views.{
  type Model, type Msg, Model, NavigateTo, NoOp, UserDeleted, UserSubmittedTitle,
  UserToggled, UserTyped,
}

pub type ClientMsg {
  ViewMsg(Msg)
  GotItems(RemoteData(List(Item), ItemError))
  GotCreated(RemoteData(Item, ItemError))
  GotToggled(RemoteData(Item, ItemError))
  GotDeleted(RemoteData(Int, ItemError))
}

pub fn main() {
  let app = lustre.application(init, update, view_wrap)
  let assert Ok(_) = lustre.start(app, "#app", read_flags())
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(ClientMsg)) {
  let model = case libero_ssr.decode_flags(flags) {
    Ok(m) -> m
    Error(_) ->
      panic as "failed to decode SSR flags. Was ssr.boot_script called on the server?"
  }
  #(model, modem.init(on_url_change))
}

fn on_url_change(uri: Uri) -> ClientMsg {
  case router.parse_route(uri) {
    Ok(route) -> ViewMsg(NavigateTo(route))
    Error(_) -> ViewMsg(NoOp)
  }
}

fn update(model: Model, msg: ClientMsg) -> #(Model, Effect(ClientMsg)) {
  case msg {
    ViewMsg(NavigateTo(route)) -> #(Model(..model, route:), effect.none())
    ViewMsg(NoOp) -> #(model, effect.none())
    ViewMsg(UserTyped(value:)) -> #(
      Model(..model, input: value),
      effect.none(),
    )
    ViewMsg(UserSubmittedTitle) ->
      case model.input {
        "" -> #(model, effect.none())
        title -> #(
          Model(..model, input: ""),
          rpc.create_item(
            params: ItemParams(title:),
            on_response: GotCreated,
          ),
        )
      }
    ViewMsg(UserToggled(id:)) -> #(
      model,
      rpc.toggle_item(id:, on_response: GotToggled),
    )
    ViewMsg(UserDeleted(id:)) -> #(
      model,
      rpc.delete_item(id:, on_response: GotDeleted),
    )
    GotItems(rd) -> #(Model(..model, items: rd), effect.none())
    GotCreated(Success(item)) -> #(
      Model(
        ..model,
        items: remote_data.map(data: model.items, transform: fn(items) {
          list.append(items, [item])
        }),
      ),
      effect.none(),
    )
    GotToggled(Success(updated)) -> #(
      Model(
        ..model,
        items: remote_data.map(data: model.items, transform: fn(items) {
          list.map(items, fn(it) {
            case it.id == updated.id {
              True -> updated
              False -> it
            }
          })
        }),
      ),
      effect.none(),
    )
    GotDeleted(Success(id)) -> #(
      Model(
        ..model,
        items: remote_data.map(data: model.items, transform: fn(items) {
          list.filter(items, fn(it) { it.id != id })
        }),
      ),
      effect.none(),
    )
    GotCreated(_) -> #(model, effect.none())
    GotToggled(_) -> #(model, effect.none())
    GotDeleted(_) -> #(model, effect.none())
  }
}

fn view_wrap(model: Model) -> element.Element(ClientMsg) {
  views.view(model) |> element.map(ViewMsg)
}
```

`ClientMsg` wraps the shared `Msg` (so user actions from the view reach the update function) plus the four `Got*` variants for RPC responses. `rpc.create_item`, `rpc.toggle_item`, and `rpc.delete_item` are the typed stubs libero generates from your handler signatures. They take an `on_response` callback that receives a `RemoteData(value, error)`.

`remote_data.map` is the helper for updating the loaded list when a single-item response arrives. It is a no-op when the list is in `NotAsked`, `Loading`, `Failure`, or `TransportFailure` states. The trailing `_ -> ` arms for `GotCreated`, `GotToggled`, and `GotDeleted` swallow non-success responses; a real app would surface the error in the UI.

## 13. Replace the starter test

The scaffold ships with a `my_checklist_test.gleam` that tests the old `handler.ping` function. Replace it with a test that exercises a real handler against an in-memory database. Open `server/test/my_checklist_test.gleam`:

```gleam
import gleeunit
import handler
import handler_context
import shared/types.{ItemParams}
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn create_item_persists_test() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE items (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         title TEXT NOT NULL,
         completed BOOLEAN NOT NULL DEFAULT 0
       )",
      on: db,
    )
  let state = handler_context.new(db:)
  let #(result, _) =
    handler.create_item(
      params: ItemParams(title: "Buy milk"),
      state:,
    )
  let assert Ok(item) = result
  let assert "Buy milk" = item.title
  let assert False = item.completed
}
```

`sqlight.open(":memory:")` opens a fresh in-memory database. `sqlight.exec` runs the schema. From there you call the handler exactly as the dispatch layer would. Run it:

```bash
bin/test
```

You'll see one passing test. The point: handlers are plain functions you can test without spinning up the server, the WebSocket, or anything else.

## 14. Run it

You're done editing. Regenerate code, build the client, and start the server:

```bash
bin/dev
```

Open `http://localhost:8080`. Add an item, toggle it, delete one. Refresh the page and the items are still there because they live in `server/data.db`.

Stop the server with `Ctrl-C`. Restart it with `bin/server` (no codegen or build needed; you didn't change handler signatures or shared types).

## Where to go next

- The simpler [Getting Started](https://github.com/pairshaped/libero/blob/master/GETTING_STARTED.md) guide if you want the same app without the database, useful as a reference for the bits that don't change.
- `examples/checklist` in the libero repo: the same shape with in-memory storage. Good for side-by-side comparison.
- `examples/default`: the bare scaffold this guide started from.
- The libero README covers the connection lifecycle (auto-reconnect, push handlers, on_connect/on_disconnect hooks) and the wire format.
- The marmot docs at `hexdocs.pm/marmot` cover advanced features: positional parameters, custom output paths, and connection configuration via env vars.

You now have the shape every libero+marmot app shares. Adding tables, queries, and routes is more of the same. Welcome aboard.
