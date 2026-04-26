# Build a SQLite-backed checklist app with Libero

This guide starts with no app and ends with a working Libero app: SQLite on the server, typed RPC, and a Lustre SPA in the browser. It should compile. If it does not, the guide is wrong!

```sh
gleam run -m libero -- new checklist --database sqlite --web
cd checklist
```

Create the SQLite table and the Marmot query files:

```sh
cat > schema.sql <<'EOF'
CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  completed BOOLEAN NOT NULL DEFAULT 0
);
EOF

sqlite3 data.db ".read schema.sql"

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
DELETE FROM items
WHERE id = @id
RETURNING id;
EOF

gleam run -m marmot
```

Replace the shared API types. Handler signatures can only use builtins and types from `shared/`, so these types are the RPC contract:

```sh
cat > shared/src/shared/messages.gleam <<'EOF'
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
EOF
```

Replace the server handlers. Libero turns each public function into a typed RPC endpoint:

```sh
cat > src/server/handler.gleam <<'EOF'
import generated/sql/server_sql
import gleam/list
import server/handler_context.{type HandlerContext}
import shared/messages.{type Item, type ItemError, type ItemParams, DatabaseError, Item, NotFound, TitleRequired}

pub fn get_items(state state: HandlerContext) -> #(Result(List(Item), ItemError), HandlerContext) {
  case server_sql.list_items(db: state.db) {
    Ok(rows) -> #(Ok(list.map(rows, row_to_item)), state)
    Error(_) -> #(Error(DatabaseError), state)
  }
}

pub fn create_item(params params: ItemParams, state state: HandlerContext) -> #(Result(Item, ItemError), HandlerContext) {
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

pub fn toggle_item(id id: Int, state state: HandlerContext) -> #(Result(Item, ItemError), HandlerContext) {
  case server_sql.toggle_item(db: state.db, id:) {
    Ok([row]) -> #(Ok(row_to_item(row)), state)
    Ok([]) -> #(Error(NotFound), state)
    Ok(_) -> #(Error(DatabaseError), state)
    Error(_) -> #(Error(DatabaseError), state)
  }
}

pub fn delete_item(id id: Int, state state: HandlerContext) -> #(Result(Int, ItemError), HandlerContext) {
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
EOF
```

Replace the web client. It asks the server for the initial list in `init`, then uses generated RPC stubs for create, toggle, and delete:

```sh
cat > clients/web/src/app.gleam <<'EOF'
import generated/messages as rpc
import gleam/list
import libero/remote_data.{type RemoteData, Success}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/messages.{type Item, type ItemError, ItemParams}

pub type Model {
  Model(items: List(Item), input: String, error: String, loading: Bool)
}

pub type Msg {
  UserTyped(String)
  UserSubmitted
  UserToggled(Int)
  UserDeleted(Int)
  GotItems(RemoteData(List(Item), ItemError))
  GotCreated(RemoteData(Item, ItemError))
  GotToggled(RemoteData(Item, ItemError))
  GotDeleted(RemoteData(Int, ItemError))
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(items: [], input: "", error: "", loading: True),
    rpc.get_items(on_response: GotItems),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserTyped(input) -> #(Model(..model, input:, error: ""), effect.none())
    UserSubmitted ->
      case model.input {
        "" -> #(Model(..model, error: "Title is required"), effect.none())
        title -> #(
          Model(..model, input: "", error: ""),
          rpc.create_item(params: ItemParams(title:), on_response: GotCreated),
        )
      }
    UserToggled(id) -> #(model, rpc.toggle_item(id:, on_response: GotToggled))
    UserDeleted(id) -> #(model, rpc.delete_item(id:, on_response: GotDeleted))
    GotItems(Success(items)) -> #(
      Model(..model, items:, loading: False),
      effect.none(),
    )
    GotCreated(Success(item)) -> #(
      Model(..model, items: list.append(model.items, [item])),
      effect.none(),
    )
    GotToggled(Success(item)) -> #(
      Model(
        ..model,
        items: list.map(model.items, fn(existing) {
          case existing.id == item.id {
            True -> item
            False -> existing
          }
        }),
      ),
      effect.none(),
    )
    GotDeleted(Success(id)) -> #(
      Model(..model, items: list.filter(model.items, fn(item) { item.id != id })),
      effect.none(),
    )
    GotItems(_) -> #(Model(..model, error: "Could not load items", loading: False), effect.none())
    GotCreated(_) -> #(Model(..model, error: "Could not create item"), effect.none())
    GotToggled(_) -> #(Model(..model, error: "Could not toggle item"), effect.none())
    GotDeleted(_) -> #(Model(..model, error: "Could not delete item"), effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  html.main(
    [attribute.styles([
      #("max-width", "36rem"),
      #("margin", "2rem auto"),
      #("font-family", "system-ui, sans-serif"),
    ])],
    [
      html.h1([], [html.text("Checklist")]),
      view_form(model.input),
      case model.error {
        "" -> html.text("")
        error -> html.p([attribute.style("color", "crimson")], [html.text(error)])
      },
      case model.loading {
        True -> html.p([], [html.text("Loading...")])
        False -> html.ul([attribute.style("padding", "0")], list.map(model.items, view_item))
      },
    ],
  )
}

fn view_form(input: String) -> Element(Msg) {
  html.form(
    [event.on_submit(fn(_) { UserSubmitted }), attribute.styles([#("display", "flex"), #("gap", "0.5rem")])],
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

fn view_item(item: Item) -> Element(Msg) {
  html.li(
    [attribute.styles([#("display", "flex"), #("gap", "0.5rem"), #("align-items", "center"), #("padding", "0.5rem 0"), #("list-style", "none")])],
    [
      html.input([attribute.type_("checkbox"), attribute.checked(item.completed), event.on_check(fn(_) { UserToggled(item.id) })]),
      html.span(
        [attribute.styles([#("flex", "1"), #("text-decoration", case item.completed { True -> "line-through" False -> "none" })])],
        [html.text(item.title)],
      ),
      html.button([event.on_click(UserDeleted(item.id))], [html.text("Delete")]),
    ],
  )
}
EOF
```

Replace the starter test so it checks real database-backed handlers:

```sh
cat > test/checklist_test.gleam <<'EOF'
import gleeunit
import gleam/list
import server/handler
import server/handler_context
import shared/messages.{ItemParams}

pub fn main() {
  gleeunit.main()
}

pub fn checklist_flow_test() {
  let state = handler_context.new()
  let assert #(Ok(created), state) = handler.create_item(params: ItemParams(title: "Ship guide"), state:)
  let assert True = created.title == "Ship guide"
  let assert #(Ok(items), state) = handler.get_items(state:)
  let assert True = list.any(items, fn(item) { item.id == created.id })
  let assert #(Ok(toggled), state) = handler.toggle_item(id: created.id, state:)
  let assert True = toggled.completed
  let assert #(Ok(_), state) = handler.delete_item(id: created.id, state:)
  let assert #(Ok(items), _) = handler.get_items(state:)
  let assert False = list.any(items, fn(item) { item.id == created.id })
}
EOF
```

Build and run it:

```sh
gleam format
gleam test
gleam run -m libero -- build
gleam run
```

Open `http://localhost:8080`. Add an item, refresh, and it is still there because the handlers write to `data.db`. That is the whole loop!
