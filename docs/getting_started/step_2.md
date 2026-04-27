# Getting Started, Step 2: Persistent Storage with SQLite

This guide picks up where [Step 1](step_1.md) left off. You should have a working in-memory checklist app: four handlers (`get_items`, `create_item`, `toggle_item`, `delete_item`), a Lustre client with SSR hydration, and a passing handler test. Refresh the page and your items disappear.

This step swaps the in-memory list for SQLite, with [marmot](https://hexdocs.pm/marmot) generating typed query functions from `.sql` files. Your handler signatures and client code stay as they are; items persist across reloads.

By the end:

- `data.db` lives in `server/`, holding your items.
- Marmot generates query functions from `.sql` files in `server/src/server/sql/`.
- Handlers call those query functions instead of operating on a list.

## New prerequisite

You already have Gleam and Erlang. Add one more tool:

- **sqlite3 CLI**: command-line tool for creating the database file. Preinstalled on macOS; on Linux install via your package manager (`apt install sqlite3` or similar).

```bash
sqlite3 --version
```

## 1. Add marmot to the server

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

Marmot uses this path to introspect column types when generating decoders. The same file becomes the runtime database in the next step.

## 2. Create the SQLite database

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

## 3. Write the SQL queries

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

A few notes about the annotations and parameters:

- The `-- returns: <Name>Row` comment must end in `Row`. Marmot enforces this so generated row types are recognisable at a glance.
- Named parameters use `@name` syntax. Marmot maps these to labelled arguments in the generated function.
- `delete_item` returns just `id`, so its row type differs from the other three. Hence `DeletedRow`.

## 4. Generate query code

Still in `server/`, run marmot:

```bash
gleam run -m marmot
```

You'll see:

```
  wrote src/generated/sql/server_sql.gleam
Generated 2 module(s)
```

Look at the shape of `list_items`:

```gleam
pub fn list_items(
  db db: sqlight.Connection,
) -> Result(List(ItemRow), sqlight.Error)
```

Every query function takes `db` as its first labelled argument and returns `Result(List(<RowType>), sqlight.Error)`. Inserts and updates that use `RETURNING` give you back the affected rows in the same shape.

Return to the project root:

```bash
cd ..
```

## 5. Add the database error variant

The handlers need a way to surface SQL failures to the client. Add `DatabaseError` to `shared/src/shared/types.gleam`:

```gleam
pub type ItemError {
  NotFound
  TitleRequired
  DatabaseError
}
```

Then update `shared/src/shared/views.gleam`. Change the import line to bring `DatabaseError` into scope:

```gleam
import shared/types.{
  type Item, type ItemError, DatabaseError, NotFound, TitleRequired,
}
```

And add a match arm in `format_error`:

```gleam
fn format_error(err: ItemError) -> String {
  case err {
    NotFound -> "That item is gone."
    TitleRequired -> "Title is required."
    DatabaseError -> "Database error. Try again."
  }
}
```

## 6. Open the database in handler_context

The in-memory `HandlerContext` no longer fits. Replace `server/src/handler_context.gleam`:

```gleam
import sqlight

pub type HandlerContext {
  HandlerContext(db: sqlight.Connection)
}

pub fn new(db db: sqlight.Connection) -> HandlerContext {
  HandlerContext(db:)
}
```

The constructor now takes a connection. The server entry must open it. Open `server/src/<your_app>.gleam` and find this line:

```gleam
let handler_ctx = handler_context.new()
```

Change it to:

```gleam
let assert Ok(db) = sqlight.open("file:data.db")
let handler_ctx = handler_context.new(db:)
```

Add `import sqlight` to the imports near the top of the file (the imports are alphabetised; insert it after `import shared/router`).

`sqlight.open` returns `Result(Connection, Error)`. The `let assert` panics with a clear message if the database cannot be opened. For a single-process server this is fine. A production app would handle the error and exit cleanly.

## 7. Rewrite the handlers

Step 1's mutating handlers used the tuple form `#(Result(_, _), HandlerContext)` because each call produced a new in-memory list. SQLite changes the picture: state lives in the database, not in `HandlerContext`, so every handler returns the inbound context unchanged. That makes all four handlers read-only from libero's perspective, and they can use the bare-Result return shape. Less ceremony, same wire contract.

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
  handler_ctx handler_ctx: HandlerContext,
) -> Result(List(Item), ItemError) {
  case server_sql.list_items(db: handler_ctx.db) {
    Ok(rows) -> Ok(list.map(rows, row_to_item))
    Error(_) -> Error(DatabaseError)
  }
}

pub fn create_item(
  params params: ItemParams,
  handler_ctx handler_ctx: HandlerContext,
) -> Result(Item, ItemError) {
  case params.title {
    "" -> Error(TitleRequired)
    title ->
      case server_sql.create_item(db: handler_ctx.db, title:) {
        Ok([row]) -> Ok(row_to_item(row))
        Ok(_) -> Error(DatabaseError)
        Error(_) -> Error(DatabaseError)
      }
  }
}

pub fn toggle_item(
  id id: Int,
  handler_ctx handler_ctx: HandlerContext,
) -> Result(Item, ItemError) {
  case server_sql.toggle_item(db: handler_ctx.db, id:) {
    Ok([row]) -> Ok(row_to_item(row))
    Ok([]) -> Error(NotFound)
    Ok(_) -> Error(DatabaseError)
    Error(_) -> Error(DatabaseError)
  }
}

pub fn delete_item(
  id id: Int,
  handler_ctx handler_ctx: HandlerContext,
) -> Result(Int, ItemError) {
  case server_sql.delete_item(db: handler_ctx.db, id:) {
    Ok([row]) -> Ok(row.id)
    Ok([]) -> Error(NotFound)
    Ok(_) -> Error(DatabaseError)
    Error(_) -> Error(DatabaseError)
  }
}

fn row_to_item(row: server_sql.ItemRow) -> Item {
  Item(id: row.id, title: row.title, completed: row.completed)
}
```

Marmot row types stay inside `server/`. Domain types in `shared/` are what cross the wire. `row_to_item` is the small adapter between the two.

The `Ok([])` arms on toggle and delete catch the case where `WHERE id = @id` matches nothing. SQLite returns an empty result set; libero translates that into the typed `NotFound` error.

You don't need to touch `server/src/page.gleam` or `clients/web/src/app.gleam`. They were already working off `Result(value, ItemError)`. The page renderer still calls `handler.get_items(handler_ctx:)` to load state during SSR; only now the call hits SQLite instead of an empty in-memory list.

## 8. Update the test

The in-memory test from step 1 no longer compiles because `handler_context.new()` requires a database. Replace `server/test/<your_app>_test.gleam`:

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
  let handler_ctx = handler_context.new(db:)
  let assert Ok(item) =
    handler.create_item(
      params: ItemParams(title: "Buy milk"),
      handler_ctx:,
    )
  let assert "Buy milk" = item.title
  let assert False = item.completed
}
```

`sqlight.open(":memory:")` opens a fresh in-memory database for each test. `sqlight.exec` runs the schema. From there you call the handler exactly as the dispatch layer would. Run it:

```bash
bin/test
```

You'll see one passing test.

## 9. Run it

You're done editing. Regenerate code, build the client, and start the server:

```bash
bin/dev
```

Open `http://localhost:8080`. Add an item, toggle it, delete one. Refresh the page and the items are still there because they live in `server/data.db`.

Stop the server with `Ctrl-C`. Restart it with `bin/server` (no codegen or build needed; you didn't change handler signatures or shared types).

## Where to go next

- The marmot docs at `hexdocs.pm/marmot` cover advanced features: positional parameters, custom output paths, connection configuration via env vars.
- The libero README covers the connection lifecycle (auto-reconnect, push handlers, on_connect/on_disconnect hooks) and the wire format.
- `examples/checklist` in the libero repo: the in-memory version this guide started from. Useful as a reference for which files were already in place at the end of step 1.

You now have the shape every libero+marmot app shares. Adding tables, queries, and routes is more of the same.
