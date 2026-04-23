//// Database-specific templates for `libero new --database`.
////
//// Each function returns file content as a String. These are used only
//// when the --database flag is passed to the scaffold command.

import libero/cli.{type Database, Postgres, Sqlite}

/// Returns extra dependency lines to insert into the server's gleam.toml.
///
/// Postgres uses pog (a connection pool for PostgreSQL) and squirrel
/// (generates type-safe Gleam code from .sql files).
///
/// Sqlite uses sqlight (FFI bindings to SQLite), marmot (generates
/// type-safe Gleam code from .sql files, like squirrel but for SQLite),
/// and logging (so the db module can log queries at debug level).
pub fn deps(database: Database) -> String {
  case database {
    Postgres ->
      "pog = \"~> 4.1\"
squirrel = \"~> 4.6\"
"
    Sqlite ->
      "sqlight = \"~> 1.0\"
marmot = \"~> 1.0\"
logging = \"~> 1.5\"
"
  }
}

/// Returns extra TOML sections to append after [tools.libero].
///
/// Postgres needs nothing here because squirrel reads the database URL
/// from the DATABASE_URL environment variable.
///
/// Sqlite needs a [tools.marmot] section that tells marmot where the
/// database file lives and which query function the generated code
/// should call.
pub fn extra_toml(database: Database) -> String {
  case database {
    Postgres -> ""
    Sqlite ->
      "
# Marmot generates type-safe Gleam functions from your .sql query files.
# It's the SQLite equivalent of squirrel (which is Postgres-only).
[tools.marmot]
# Path to the SQLite database file. Marmot opens this at codegen time
# to validate your queries against the actual schema.
database = \"data.db\"
# The function marmot-generated code calls to run queries. This points
# to the wrapper in server/db.gleam that adds logging and opens the
# right database file.
query_function = \"server/db.query\"
"
  }
}

/// Returns shared_state.gleam content with a database connection field.
///
/// SharedState is created once at server startup and passed into every
/// handler call. Storing the database connection here means handlers
/// don't need to open their own connections.
pub fn shared_state(database: Database) -> String {
  case database {
    Postgres ->
      "import pog
import server/db

/// Shared state passed to every handler call.
/// The `db` field holds a pog connection pool, so handlers can run
/// queries without managing connections themselves.
pub type SharedState {
  SharedState(db: pog.Connection)
}

pub fn new() -> SharedState {
  SharedState(db: db.connect())
}
"
    Sqlite ->
      "import sqlight
import server/db

/// Shared state passed to every handler call.
/// The `db` field holds an open SQLite connection, so handlers can
/// run queries without opening their own connections.
pub type SharedState {
  SharedState(db: sqlight.Connection)
}

pub fn new() -> SharedState {
  SharedState(db: db.connect())
}
"
  }
}

/// Returns server/db.gleam content with connection setup and helpers.
///
/// Postgres: a thin wrapper around pog that configures connection pooling.
/// Sqlite: opens the database, sets performance PRAGMAs, and provides a
/// query wrapper that marmot-generated code calls.
pub fn db_module(database: Database) -> String {
  case database {
    Postgres ->
      "import gleam/erlang/process
import pog

/// Start a PostgreSQL connection pool using pog.
///
/// pog manages a pool of connections for you, so calling this once at
/// startup is enough. Handlers share the pool through SharedState.
///
/// By default pog connects to localhost:5432 with the \"postgres\" user
/// and database \"postgres\". To change this, modify the config below:
///
///   pog.default_config(pool_name)
///   |> pog.host(\"db.example.com\")
///   |> pog.database(\"my_app\")
///   |> pog.password(option.Some(\"secret\"))
///   |> pog.pool_size(10)
///   |> pog.start
///
pub fn connect() -> pog.Connection {
  let pool_name = process.new_name(prefix: \"db_pool\")
  let assert Ok(started) =
    pog.default_config(pool_name:)
    |> pog.start
  started.data
}
"
    Sqlite ->
      "import gleam/dynamic/decode
import gleam/int
import gleam/list
import logging
import sqlight

/// Connect to the SQLite database at the default path.
/// Called once at startup; the connection lives in SharedState.
pub fn connect() -> sqlight.Connection {
  open(\"data.db\")
}

/// Open a SQLite database at the given path and configure it for
/// concurrent web server use.
pub fn open(path: String) -> sqlight.Connection {
  let assert Ok(db) = sqlight.open(path)

  // WAL (Write-Ahead Logging) mode lets readers and a single writer
  // work at the same time. Without this, any write locks the entire
  // database and blocks all reads.
  let assert Ok(_) = sqlight.exec(\"PRAGMA journal_mode = WAL;\", db)

  // If another connection holds a write lock, wait up to 5 seconds
  // before returning SQLITE_BUSY. This avoids immediate failures
  // under moderate concurrency.
  let assert Ok(_) = sqlight.exec(\"PRAGMA busy_timeout = 5000;\", db)

  // Enforce foreign key constraints. SQLite has them off by default
  // for backwards compatibility, which means your ON DELETE CASCADE
  // and reference checks silently do nothing unless you turn this on.
  let assert Ok(_) = sqlight.exec(\"PRAGMA foreign_keys = ON;\", db)

  db
}

/// Run a query against a SQLite database.
///
/// This is the function marmot-generated code calls (configured via
/// query_function in gleam.toml). It wraps sqlight.query and logs
/// each query at debug level so you can see what's running during
/// development.
pub fn query(
  query sql: String,
  on db: sqlight.Connection,
  with arguments: List(sqlight.Value),
  expecting decoder: decode.Decoder(a),
) -> Result(List(a), sqlight.Error) {
  let result = sqlight.query(sql, db, arguments, decoder)
  case result {
    Ok(rows) ->
      logging.log(
        logging.Debug,
        sql <> \" (\" <> int.to_string(list.length(rows)) <> \" rows)\",
      )
    Error(_) -> logging.log(logging.Warning, \"Query failed: \" <> sql)
  }
  result
}
"
  }
}

/// Returns a database-specific section to include in the project README.
pub fn readme_section(database: Database) -> String {
  case database {
    Postgres ->
      "
## Database (PostgreSQL)

This project uses **pog** for database connections and **squirrel** for
type-safe query generation.

### Adding queries

1. Create a `.sql` file in `src/server/sql/` (or wherever you like).
   Each file should contain a single SQL query with parameter
   placeholders like `$1`, `$2`.

2. Run squirrel to generate Gleam functions from your queries:

   ```sh
   gleam run -m squirrel
   ```

   Squirrel connects to your database, validates the SQL, and writes a
   Gleam module with a function per `.sql` file. The generated functions
   have typed parameters and return typed rows.

3. Import the generated module in your handler and call the function,
   passing `state.db` as the connection.

### Configuration

Squirrel and pog both read from the `DATABASE_URL` environment variable.
Set it before running your app:

```sh
export DATABASE_URL=\"postgres://user:password@localhost:5432/my_db\"
```
"
    Sqlite ->
      "
## Database (SQLite)

This project uses **sqlight** for database access and **marmot** for
type-safe query generation.

### Adding queries

1. Create a `.sql` file in `src/server/sql/` (or wherever you like).
   Each file should contain a single SQL query with parameter
   placeholders like `?1`, `?2`.

2. Run marmot to generate Gleam functions from your queries:

   ```sh
   gleam run -m marmot
   ```

   Marmot reads the `[tools.marmot]` config in gleam.toml, opens the
   database file to validate your SQL against the real schema, and
   writes a Gleam module with typed functions.

3. Import the generated module in your handler and call the function,
   passing `state.db` as the connection.

### Where the database lives

The database file is `data.db` in the project root. It's created
automatically the first time the server starts. You'll probably want to
add `data.db` to your `.gitignore`.
"
  }
}
