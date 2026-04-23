# Database scaffold flag implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--database pg|sqlite` flag to `libero new` that scaffolds database deps, connection module, query codegen config, and a README.

**Architecture:** New `Database` type in CLI parsing. New `templates/db.gleam` module holds all database-specific templates. Base `gleam_toml()` gets a `db_deps` slot. `new.gleam` conditionally writes db files and swaps `shared_state.gleam` for a db-aware variant.

**Tech Stack:** Gleam, simplifile, pog, squirrel, sqlight, marmot, logging

---

### Task 1: Add Database type and parse --database flag

**Files:**
- Modify: `src/libero/cli.gleam`

- [ ] **Step 1: Write the failing test**

Create `test/libero/cli_parse_database_test.gleam`:

```gleam
import gleam/option.{None, Some}
import libero/cli

pub fn parse_new_no_database_test() {
  let assert cli.New(name: "my_app", database: None) =
    cli.parse_args(["new", "my_app"])
}

pub fn parse_new_pg_test() {
  let assert cli.New(name: "my_app", database: Some(cli.Postgres)) =
    cli.parse_args(["new", "my_app", "--database", "pg"])
}

pub fn parse_new_sqlite_test() {
  let assert cli.New(name: "my_app", database: Some(cli.Sqlite)) =
    cli.parse_args(["new", "my_app", "--database", "sqlite"])
}

pub fn parse_new_invalid_database_test() {
  let assert cli.Unknown = cli.parse_args(["new", "my_app", "--database", "mongo"])
}

pub fn parse_new_database_missing_value_test() {
  let assert cli.Unknown = cli.parse_args(["new", "my_app", "--database"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test -- --test-filter=cli_parse_database 2>&1`
Expected: compilation errors (Database type, parse_args function don't exist yet)

- [ ] **Step 3: Implement the CLI changes**

Update `src/libero/cli.gleam`:

```gleam
//// CLI command router for the Libero framework.
////
//// Usage: gleam run -m libero -- <command> [args]
//// Commands: new, add, gen, build

import argv
import gleam/io
import gleam/option.{type Option, None, Some}

pub type Database {
  Postgres
  Sqlite
}

pub type Command {
  New(name: String, database: Option(Database))
  Add(name: String, target: String)
  Gen
  Build
  Unknown
}

/// Parse CLI arguments into a Command.
pub fn parse_command() -> Command {
  parse_args(argv.load().arguments)
}

/// Parse a list of argument strings into a Command.
/// Separated from parse_command so tests can call it without argv.
pub fn parse_args(args: List(String)) -> Command {
  case args {
    ["new", name, "--database", db, ..] ->
      case parse_database(db) {
        Ok(database) -> New(name:, database: Some(database))
        Error(Nil) -> {
          io.println_error(
            "error: --database must be pg or sqlite, got: " <> db,
          )
          Unknown
        }
      }
    ["new", name, ..] -> New(name:, database: None)
    ["add", name, "--target", target, ..] -> Add(name:, target:)
    ["add", _name, ..] -> {
      io.println_error("error: --target is required")
      io.println_error(
        "  Usage: gleam run -m libero -- add <name> --target <javascript|erlang>",
      )
      Unknown
    }
    ["gen", ..] -> Gen
    ["build", ..] -> Build
    _ -> Unknown
  }
}

fn parse_database(value: String) -> Result(Database, Nil) {
  case value {
    "pg" -> Ok(Postgres)
    "sqlite" -> Ok(Sqlite)
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 4: Update libero.gleam to pass database through**

Update `src/libero.gleam` lines 16-19. The `cli.New` match now includes `database:`:

```gleam
    cli.New(name:, database:) -> {
      case cli_new.scaffold(name:, path: name, database:) {
        Ok(Nil) -> io.println("Created " <> name <> ". Happy hacking!")
        Error(reason) -> io.println_error("error: " <> reason)
      }
      Nil
    }
```

Also add `import gleam/option` to the imports.

Update help text (line 57):

```gleam
      io.println("  new <name> [--database pg|sqlite]  Create a new project")
```

- [ ] **Step 5: Update scaffold signature to accept database (stub)**

Update `src/libero/cli/new.gleam` to accept the database parameter. Change the
`scaffold` function signature (line 17) to:

```gleam
pub fn scaffold(
  name _name: String,
  path path: String,
  database database: Option(Database),
) -> Result(Nil, String) {
```

Add imports at top:

```gleam
import gleam/option.{type Option}
import libero/cli.{type Database}
```

Thread `database` through `scaffold_validated` and `scaffold_files` signatures
(add `database database: Option(Database)` parameter to both). Don't use it yet,
just pass it through.

- [ ] **Step 6: Run tests**

Run: `gleam test 2>&1`
Expected: all tests pass (new and existing)

- [ ] **Step 7: Commit**

```bash
git add src/libero/cli.gleam src/libero.gleam src/libero/cli/new.gleam test/libero/cli_parse_database_test.gleam
git commit -m "Add --database pg|sqlite flag to CLI parser"
```

---

### Task 2: Add db_deps slot to gleam_toml template

**Files:**
- Modify: `src/libero/cli/templates.gleam`
- Modify: `src/libero/cli/new.gleam`
- Modify: `test/libero/cli_new_test.gleam`

- [ ] **Step 1: Update gleam_toml to accept db_deps parameter**

Change `templates.gleam` `gleam_toml` function (line 8) to accept a `db_deps`
parameter and an `extra_toml` parameter:

```gleam
/// Returns gleam.toml content for a new project (the server package).
/// Libero config lives under the [tools.libero] section.
/// db_deps: extra dependency lines (e.g. "pog = \"~> 4.1\"\n")
/// extra_toml: extra toml sections appended after [tools.libero] (e.g. [tools.marmot])
pub fn gleam_toml(
  name name: String,
  db_deps db_deps: String,
  extra_toml extra_toml: String,
) -> String {
  "name = \"" <> name <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
gleam_erlang = \"~> 1.0\"
gleam_http = \"~> 4.0\"
mist = \"~> 6.0\"
lustre = \"~> 5.6\"
shared = { path = \"shared\" }
libero = \"~> 4.2\"
" <> db_deps <> "
[dev-dependencies]
gleeunit = \"~> 1.0\"

[tools.libero]
port = 8080
" <> extra_toml
}
```

- [ ] **Step 2: Update new.gleam to pass empty db_deps**

In `scaffold_files` (line 93-96), update the `gleam_toml` call:

```gleam
  use _ <- map_err(simplifile.write(
    path <> "/gleam.toml",
    templates.gleam_toml(name:, db_deps: "", extra_toml: ""),
  ))
```

- [ ] **Step 3: Run tests**

Run: `gleam test 2>&1`
Expected: all tests pass (existing scaffold test still works since output is same)

- [ ] **Step 4: Commit**

```bash
git add src/libero/cli/templates.gleam src/libero/cli/new.gleam
git commit -m "Add db_deps and extra_toml slots to gleam_toml template"
```

---

### Task 3: Create database template module

**Files:**
- Create: `src/libero/cli/templates/db.gleam`

- [ ] **Step 1: Create the templates directory**

Run: `mkdir -p src/libero/cli/templates`

- [ ] **Step 2: Write the db template module**

Create `src/libero/cli/templates/db.gleam` with all database-specific templates.
This is a long file. All template strings must include comments written for
someone new to libero, marmot, squirrel, pog, and sqlight.

Follow the writing guide: simple verbs, no AI vocabulary, no em dashes, sentence
case, no emoji.

```gleam
//// Database-specific templates for `libero new --database`.
////
//// Each function returns file content as a String. These are used only
//// when the --database flag is passed to the scaffold command.

import libero/cli.{type Database, Postgres, Sqlite}

/// Extra dependency lines for gleam.toml.
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

/// Extra toml sections appended after [tools.libero].
/// Only sqlite needs this (marmot config). Postgres/squirrel uses env vars.
pub fn extra_toml(database: Database) -> String {
  case database {
    Postgres -> ""
    Sqlite ->
      "
[tools.marmot]
# Path to the SQLite database file. Marmot connects to this database
# at codegen time to check your query types.
database = \"data.db\"

# Marmot-generated code calls this function instead of sqlight.query
# directly. This lets you add logging, timing, or other wrappers
# without changing generated code.
query_function = \"server/db.query\"
"
  }
}

/// SharedState module with a database connection included.
pub fn shared_state(database: Database) -> String {
  case database {
    Postgres ->
      "import pog
import server/db

/// Shared application state passed to every handler call.
/// The db field holds a pog connection pool for Postgres queries.
pub type SharedState {
  SharedState(db: pog.Connection)
}

/// Create a new SharedState with a database connection pool.
/// Called once at app startup.
pub fn new() -> SharedState {
  SharedState(db: db.connect())
}
"
    Sqlite ->
      "import sqlight
import server/db

/// Shared application state passed to every handler call.
/// The db field holds an open SQLite connection.
pub type SharedState {
  SharedState(db: sqlight.Connection)
}

/// Create a new SharedState with a database connection.
/// Called once at app startup.
pub fn new() -> SharedState {
  SharedState(db: db.connect())
}
"
  }
}

/// Database connection module for Postgres.
pub fn db_module_pg() -> String {
  "import pog

/// Create a connection pool to the Postgres database.
///
/// pog is a Postgres client for Gleam. It manages a pool of connections
/// so your app can handle multiple concurrent requests without running
/// out of database connections.
///
/// By default this connects to localhost:5432 with user \"postgres\" and
/// no password. Set the DATABASE_URL environment variable to override,
/// or change the config below.
pub fn connect() -> pog.Connection {
  pog.default_config()
  |> pog.connect
}
"
}

/// Database connection module for SQLite.
pub fn db_module_sqlite() -> String {
  "import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import logging
import sqlight

/// Open a SQLite database connection with recommended settings.
///
/// sqlight is a SQLite driver for Gleam. Unlike Postgres, SQLite runs
/// in-process, so there is no separate database server to manage.
/// The database is a single file on disk.
pub fn connect() -> sqlight.Connection {
  let assert Ok(conn) = open(\"data.db\")
  conn
}

fn open(path: String) -> Result(sqlight.Connection, sqlight.Error) {
  use conn <- result.try(sqlight.open(path))

  // WAL mode allows concurrent reads while writing. Without this,
  // readers block writers and vice versa, which causes timeouts
  // under load.
  use _ <- result.try(sqlight.exec(\"PRAGMA journal_mode=WAL;\", on: conn))

  // If another connection holds a lock, wait up to 5 seconds before
  // returning a \"database is locked\" error.
  use _ <- result.try(sqlight.exec(\"PRAGMA busy_timeout=5000;\", on: conn))

  // Enforce foreign key constraints. SQLite does not do this by default,
  // so without this pragma, foreign key columns are not checked.
  use _ <- result.try(sqlight.exec(\"PRAGMA foreign_keys=ON;\", on: conn))

  Ok(conn)
}

/// Query wrapper called by marmot-generated code.
///
/// Marmot generates type-safe Gleam functions from your .sql files.
/// Those generated functions call this wrapper (configured via
/// query_function in gleam.toml) instead of sqlight.query directly.
/// This lets you add logging or timing without touching generated code.
pub fn query(
  sql sql: String,
  on conn: sqlight.Connection,
  with params: List(sqlight.Value),
  expecting decoder: decode.Decoder(a),
) -> Result(List(a), sqlight.Error) {
  let result = sqlight.query(sql, on: conn, with: params, expecting: decoder)
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

/// Database connection module, dispatched by database type.
pub fn db_module(database: Database) -> String {
  case database {
    Postgres -> db_module_pg()
    Sqlite -> db_module_sqlite()
  }
}

/// README section about the database setup.
pub fn readme_section(database: Database) -> String {
  case database {
    Postgres ->
      "
## Database (Postgres)

This project uses [pog](https://hexdocs.pm/pog/) for database connections
and [squirrel](https://hexdocs.pm/squirrel/) for type-safe SQL codegen.

Add your SQL queries as `.sql` files in `src/server/sql/`:

```
src/server/sql/get_user.sql
src/server/sql/list_posts.sql
```

Then run squirrel to generate typed Gleam functions:

```sh
gleam run -m squirrel
```

Squirrel connects to your Postgres database to check query types. Set
`DATABASE_URL` or use the default (localhost:5432, user postgres).
"
    Sqlite ->
      "
## Database (SQLite)

This project uses [sqlight](https://hexdocs.pm/sqlight/) for database
connections and [marmot](https://hexdocs.pm/marmot/) for type-safe SQL codegen.

Add your SQL queries as `.sql` files in `src/server/sql/`:

```
src/server/sql/get_user.sql
src/server/sql/list_posts.sql
```

Then run marmot to generate typed Gleam functions:

```sh
gleam run -m marmot
```

The database file is `data.db` in the project root (configured in gleam.toml
under `[tools.marmot]`).
"
  }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `gleam build 2>&1`
Expected: compiles with no errors

- [ ] **Step 4: Commit**

```bash
git add src/libero/cli/templates/db.gleam
git commit -m "Add database-specific template module"
```

---

### Task 4: Add README template

**Files:**
- Modify: `src/libero/cli/templates.gleam`

- [ ] **Step 1: Add starter_readme function to templates.gleam**

Add at the end of `src/libero/cli/templates.gleam`:

```gleam
/// Returns a README.md for a new project.
/// db_section: optional database-specific content appended to the README.
pub fn starter_readme(name name: String, db_section db_section: String) -> String {
  "# " <> name <> "

A [Libero](https://hexdocs.pm/libero/) project.

## Getting started

Start the development server:

```sh
gleam run -m libero -- build
gleam run
```

The server runs on the port configured in `gleam.toml` under `[tools.libero]`.

## Project structure

- `src/server/` - server-side Gleam code (handlers, state, business logic)
- `shared/` - types shared between server and clients (messages, models)
- `clients/` - client packages (added with `gleam run -m libero -- add`)
- `test/` - tests

## Commands

```sh
gleam run -m libero -- build    # generate stubs + build server and all clients
gleam run -m libero -- gen      # regenerate libero stubs only
gleam run -m libero -- add <name> --target <javascript|erlang>  # add a client
gleam test                      # run tests
```

## How it works

Define your message types in `shared/src/shared/messages.gleam`. Libero scans
for `MsgFromClient` and `MsgFromServer` types and generates typed dispatch and
client stubs. Handle messages in `src/server/handler.gleam`.
" <> db_section
}
```

- [ ] **Step 2: Verify it compiles**

Run: `gleam build 2>&1`
Expected: compiles with no errors

- [ ] **Step 3: Commit**

```bash
git add src/libero/cli/templates.gleam
git commit -m "Add README template for scaffolded projects"
```

---

### Task 5: Wire database option into scaffold logic

**Files:**
- Modify: `src/libero/cli/new.gleam`
- Modify: `test/libero/cli_new_test.gleam`

- [ ] **Step 1: Write failing tests for database scaffold variants**

Add to `test/libero/cli_new_test.gleam`:

```gleam
import gleam/option.{None, Some}
import gleam/string
import libero/cli
import libero/cli/new as cli_new
import simplifile

pub fn scaffold_project_test() {
  let dir = "build/.test_cli_new/test_scaffold"
  let _ = simplifile.delete("build/.test_cli_new")

  let assert Ok(Nil) =
    cli_new.scaffold(name: "my_app", path: dir, database: None)

  let assert Ok(True) = simplifile.is_file(dir <> "/gleam.toml")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/server")
  let assert Ok(True) = simplifile.is_directory(dir <> "/shared/src/shared")

  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "name = \"test_scaffold\"")
  let assert True = string.contains(gleam_toml, "target = \"erlang\"")
  let assert True = string.contains(gleam_toml, "[tools.libero]")
  let assert True = string.contains(gleam_toml, "shared = { path = \"shared\"")

  // No database deps when no flag
  let assert False = string.contains(gleam_toml, "pog")
  let assert False = string.contains(gleam_toml, "sqlight")

  let assert Ok(True) = simplifile.is_file(dir <> "/shared/gleam.toml")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/shared/src/shared/messages.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/handler.gleam")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/src/server/shared_state.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/app_error.gleam")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/test/test_scaffold_test.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/README.md")

  // No db.gleam or sql dir when no database flag
  let assert Ok(False) = simplifile.is_file(dir <> "/src/server/db.gleam")

  let _ = simplifile.delete("build/.test_cli_new")
  Nil
}

pub fn scaffold_pg_test() {
  let dir = "build/.test_cli_new/test_pg"
  let _ = simplifile.delete("build/.test_cli_new")

  let assert Ok(Nil) =
    cli_new.scaffold(name: "my_app", path: dir, database: Some(cli.Postgres))

  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "pog")
  let assert True = string.contains(gleam_toml, "squirrel")
  let assert False = string.contains(gleam_toml, "sqlight")
  let assert False = string.contains(gleam_toml, "[tools.marmot]")

  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/db.gleam")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/server/sql")

  let assert Ok(db_gleam) = simplifile.read(dir <> "/src/server/db.gleam")
  let assert True = string.contains(db_gleam, "import pog")

  let assert Ok(shared_state) =
    simplifile.read(dir <> "/src/server/shared_state.gleam")
  let assert True = string.contains(shared_state, "pog.Connection")

  let assert Ok(readme) = simplifile.read(dir <> "/README.md")
  let assert True = string.contains(readme, "squirrel")

  let _ = simplifile.delete("build/.test_cli_new")
  Nil
}

pub fn scaffold_sqlite_test() {
  let dir = "build/.test_cli_new/test_sqlite"
  let _ = simplifile.delete("build/.test_cli_new")

  let assert Ok(Nil) =
    cli_new.scaffold(name: "my_app", path: dir, database: Some(cli.Sqlite))

  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "sqlight")
  let assert True = string.contains(gleam_toml, "marmot")
  let assert True = string.contains(gleam_toml, "logging")
  let assert True = string.contains(gleam_toml, "[tools.marmot]")
  let assert True = string.contains(gleam_toml, "query_function")
  let assert False = string.contains(gleam_toml, "pog")

  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/db.gleam")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/server/sql")

  let assert Ok(db_gleam) = simplifile.read(dir <> "/src/server/db.gleam")
  let assert True = string.contains(db_gleam, "import sqlight")
  let assert True = string.contains(db_gleam, "PRAGMA journal_mode=WAL")
  let assert True = string.contains(db_gleam, "pub fn query(")

  let assert Ok(shared_state) =
    simplifile.read(dir <> "/src/server/shared_state.gleam")
  let assert True = string.contains(shared_state, "sqlight.Connection")

  let assert Ok(readme) = simplifile.read(dir <> "/README.md")
  let assert True = string.contains(readme, "marmot")

  let _ = simplifile.delete("build/.test_cli_new")
  Nil
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test -- --test-filter=cli_new 2>&1`
Expected: failures (scaffold doesn't write db files or README yet)

- [ ] **Step 3: Implement the scaffold logic**

Update `src/libero/cli/new.gleam` to wire everything together:

```gleam
//// `libero new` — scaffold a new Libero project at the given path.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libero/cli.{type Database}
import libero/cli/templates
import libero/cli/templates/db as db_templates
import simplifile

/// Scaffold a new project under `path`.
///
/// The project name is derived from the last segment of the path
/// (e.g. "tmp/test_app" -> "test_app").
///
/// Creates the directory tree and writes starter source files so the
/// project compiles and runs out of the box.
/// nolint: stringly_typed_error -- CLI module, String errors are user-facing messages
pub fn scaffold(
  name _name: String,
  path path: String,
  database database: Option(Database),
) -> Result(Nil, String) {
  let name =
    string.split(path, "/")
    |> list.last
    |> result.unwrap(path)

  case validate_name(name) {
    Error(msg) -> Error(msg)
    Ok(Nil) -> scaffold_validated(name:, path:, database:)
  }
}

// nolint: stringly_typed_error
fn scaffold_validated(
  name name: String,
  path path: String,
  database database: Option(Database),
) -> Result(Nil, String) {
  // Abort if the project already exists
  case simplifile.is_file(path <> "/gleam.toml") {
    Ok(True) ->
      Error("project already exists at " <> path <> " (gleam.toml found)")
    _ -> {
      let server_dir = path <> "/src/server"
      scaffold_files(name:, path:, server_dir:, database:)
    }
  }
}

// nolint: stringly_typed_error
fn validate_name(name: String) -> Result(Nil, String) {
  case string.to_graphemes(name) {
    [] -> Error("project name cannot be empty")
    [first, ..rest] ->
      case is_lowercase_letter(first) {
        False ->
          Error(
            "project name must start with a lowercase letter, got: " <> name,
          )
        True ->
          case
            list.all(rest, fn(ch) {
              is_lowercase_letter(ch) || is_digit(ch) || ch == "_"
            })
          {
            False ->
              Error(
                "project name must contain only lowercase letters, digits, and underscores, got: "
                <> name,
              )
            True -> Ok(Nil)
          }
      }
  }
}

const lowercase_letters = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

fn is_lowercase_letter(ch: String) -> Bool {
  string.contains(lowercase_letters, ch)
}

fn is_digit(ch: String) -> Bool {
  string.contains(digits, ch)
}

// nolint: stringly_typed_error
fn scaffold_files(
  name name: String,
  path path: String,
  server_dir server_dir: String,
  database database: Option(Database),
) -> Result(Nil, String) {
  use _ <- map_err(simplifile.create_directory_all(server_dir))

  // Compute database-specific template values
  let #(db_deps, extra_toml, db_readme) = case database {
    None -> #("", "", "")
    Some(db) -> #(
      db_templates.deps(db),
      db_templates.extra_toml(db),
      db_templates.readme_section(db),
    )
  }

  // Root (server) package
  use _ <- map_err(simplifile.write(
    path <> "/gleam.toml",
    templates.gleam_toml(name:, db_deps:, extra_toml:),
  ))
  use _ <- map_err(simplifile.write(
    server_dir <> "/handler.gleam",
    templates.starter_handler(),
  ))
  use _ <- map_err(simplifile.write(
    server_dir <> "/shared_state.gleam",
    case database {
      None -> templates.starter_shared_state()
      Some(db) -> db_templates.shared_state(db)
    },
  ))
  use _ <- map_err(simplifile.write(
    server_dir <> "/app_error.gleam",
    templates.starter_app_error(),
  ))

  // Database files (only when --database is used)
  case database {
    None -> Ok(Nil)
    Some(db) -> {
      use _ <- map_err(simplifile.write(
        server_dir <> "/db.gleam",
        db_templates.db_module(db),
      ))
      use _ <- map_err(simplifile.create_directory_all(
        server_dir <> "/sql",
      ))
      Ok(Nil)
    }
  }
  |> result.try(fn(_) {
    // Shared package - messages live here so JS clients can import them
    // without pulling in Erlang-only server dependencies.
    let shared_dir = path <> "/shared/src/shared"
    use _ <- map_err(simplifile.create_directory_all(shared_dir))
    use _ <- map_err(simplifile.write(
      path <> "/shared/gleam.toml",
      templates.shared_gleam_toml(),
    ))
    use _ <- map_err(simplifile.write(
      shared_dir <> "/messages.gleam",
      templates.starter_messages(),
    ))

    let test_dir = path <> "/test"
    use _ <- map_err(simplifile.create_directory_all(test_dir))
    use _ <- map_err(simplifile.write(
      test_dir <> "/" <> name <> "_test.gleam",
      templates.starter_test(),
    ))

    // README
    use _ <- map_err(simplifile.write(
      path <> "/README.md",
      templates.starter_readme(name:, db_section: db_readme),
    ))
    Ok(Nil)
  })
}

// nolint: stringly_typed_error
fn map_err(
  result: Result(a, simplifile.FileError),
  next: fn(a) -> Result(Nil, String),
) -> Result(Nil, String) {
  case result {
    Ok(value) -> next(value)
    Error(err) -> Error(simplifile.describe_error(err))
  }
}
```

- [ ] **Step 4: Run tests**

Run: `gleam test 2>&1`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add src/libero/cli/new.gleam test/libero/cli_new_test.gleam
git commit -m "Wire --database flag into scaffold, write db files and README"
```

---

### Task 6: Manual integration test

**Files:** none (verification only)

- [ ] **Step 1: Test no-database scaffold**

```bash
gleam run -m libero -- new tmp/test_no_db
cd tmp/test_no_db && gleam build
```

Expected: builds clean, no database deps, README exists.

- [ ] **Step 2: Test pg scaffold**

```bash
cd /path/to/libero
gleam run -m libero -- new tmp/test_pg --database pg
cd tmp/test_pg && gleam build
```

Expected: builds clean, pog and squirrel in deps, `src/server/db.gleam` exists
with pog import, `src/server/sql/` directory exists, README mentions squirrel.

- [ ] **Step 3: Test sqlite scaffold**

```bash
cd /path/to/libero
gleam run -m libero -- new tmp/test_sqlite --database sqlite
cd tmp/test_sqlite && gleam build
```

Expected: builds clean, sqlight and marmot in deps, `src/server/db.gleam` exists
with sqlight import and PRAGMA setup, `src/server/sql/` directory exists,
`[tools.marmot]` in gleam.toml, README mentions marmot.

- [ ] **Step 4: Test invalid database value**

```bash
cd /path/to/libero
gleam run -m libero -- new tmp/test_bad --database mongo
```

Expected: error message printed, no directory created.

- [ ] **Step 5: Clean up test directories**

```bash
rm -rf tmp/test_no_db tmp/test_pg tmp/test_sqlite tmp/test_bad
```

- [ ] **Step 6: Commit (if any fixes were needed)**

Only if manual testing revealed issues that required code changes.
