# Database scaffold flag for `libero new`

Add `--database pg|sqlite` flag to the `libero new` scaffold command, generating
a project with database dependencies, connection setup, and query codegen tooling
pre-configured.

## Motivation

Users who run `libero new` currently get a project with no persistence. Adding a
database requires manually finding the right packages, wiring up connections, and
configuring codegen tools. This flag removes that friction.

## CLI

```
gleam run -m libero -- new my_app --database pg
gleam run -m libero -- new my_app --database sqlite
gleam run -m libero -- new my_app              # no database (unchanged)
```

Flag goes after the project name, consistent with `add`'s `--target` flag.

Invalid values produce an error: `"--database must be pg or sqlite"`.

## Architecture

### New type in `cli.gleam`

```gleam
pub type Database {
  Postgres
  Sqlite
}

pub type Command {
  New(name: String, database: Option(Database))
  // ... rest unchanged
}
```

### New file: `src/libero/cli/templates/db.gleam`

All database-specific template functions live here. Base templates in
`templates.gleam` stay untouched except for one change: `gleam_toml()` gains a
`db_deps: String` parameter (default `""`) that gets inserted into the
dependencies section.

The `new.gleam` scaffold logic calls into `templates/db.gleam` when the database
flag is present, falling back to existing base templates when it is not.

### What gets scaffolded

**No flag (default):** identical to today. Simple `SharedState`, no persistence.

**`--database pg`:**

Files added:
- `src/server/db.gleam` - pog connection pool setup
- `src/server/sql/` - empty directory for squirrel `.sql` files

Dependencies added to `gleam.toml`:
```toml
pog = "~> 4.1"
squirrel = "~> 4.6"
```

No extra toml config. Squirrel reads `DATABASE_URL` or Postgres defaults.

**`--database sqlite`:**

Files added:
- `src/server/db.gleam` - sqlight connection with PRAGMAs + query wrapper
- `src/server/sql/` - empty directory for marmot `.sql` files

Dependencies added to `gleam.toml`:
```toml
sqlight = "~> 1.0"
marmot = "~> 1.0"
logging = "~> 1.5"
```

Config added to `gleam.toml`:
```toml
[tools.marmot]
database = "data.db"
query_function = "server/db.query"
```

### Shared changes (both pg and sqlite)

`shared_state.gleam` is swapped for a db-aware variant that includes the
connection in the type:

```gleam
// pg variant
pub type SharedState {
  SharedState(db: pog.Connection)
}

// sqlite variant
pub type SharedState {
  SharedState(db: sqlight.Connection)
}
```

`handler.gleam` is unchanged. It already receives `state: SharedState`, so
`state.db` is accessible without modification.

`starter_test.gleam` is unchanged. The ping/pong test does not need a db
connection.

## Template content details

### SQLite `db.gleam`

Includes:
- `connect()` function that opens the database and sets PRAGMAs
- WAL mode, busy timeout (5000ms), foreign keys on
- `query()` wrapper with the same signature as `sqlight.query`, called by
  marmot-generated code via the `query_function` config
- Debug logging of queries using the `logging` package

### Postgres `db.gleam`

Includes:
- `connect()` function that creates a pog connection pool with defaults
- Connection pool configuration (host, port, database, etc.)

### SQLite `gleam.toml` marmot config

```toml
[tools.marmot]
database = "data.db"
query_function = "server/db.query"
```

## Comments and documentation

All scaffolded files must be well-commented for someone new to libero, marmot,
squirrel, pog, and sqlight. Comments explain what each piece does and why, not
just what the code says. Examples:

- "Marmot reads .sql files from this directory and generates type-safe Gleam
  query functions. Run: gleam run -m marmot"
- "This wrapper is called by marmot-generated code (configured via
  query_function in gleam.toml)"
- "WAL mode allows concurrent reads while writing, which is necessary for web
  apps serving multiple requests"
- "Squirrel connects to your Postgres database at codegen time to check query
  types. Run: gleam run -m squirrel"

A `README.md` is generated for every scaffolded project (including no-database
projects). It covers: what's in the project, how to run the server, how to add
clients, and how to run codegen. When a database flag is used, the README also
explains how to add queries and run the database codegen tool (marmot or
squirrel).

### Writing style

All comments, README content, and prose follow these rules:
- Simple verbs ("is", "has", not "serves as", "boasts")
- No promotional or AI-sounding language (no "crucial", "seamlessly",
  "leverage", "enhance", etc.)
- No em dashes (use commas, colons, or periods)
- Sentence case for headings
- No emoji unless the user adds them
- Write like a human explaining code to another human

## Files changed

| File | Change |
|------|--------|
| `src/libero/cli.gleam` | Add `Database` type, parse `--database` flag |
| `src/libero.gleam` | Update help text |
| `src/libero/cli/new.gleam` | Thread database option, write db files |
| `src/libero/cli/templates.gleam` | Add `db_deps` param to `gleam_toml()`, add `starter_readme()` |
| `src/libero/cli/templates/db.gleam` | **New.** All database-specific templates |

## Out of scope

- Migrations (no sample tables or schema)
- Database-aware test helpers
- Runtime database health checks
- Multiple database support in a single project
