# Ideas

## `libero new --database sqlite`

Scaffold marmot integration when creating a new project. The flag adds:

- `marmot` as a dev dependency in the server's `gleam.toml`
- A `[marmot]` config section pointing at a starter SQLite database
- A starter `sql/` directory with an example query
- A handler that demonstrates calling the marmot-generated module from
  `update_from_client`

Marmot is the implementation detail behind the flag. The developer just
declares intent ("I want a database") and gets type-safe SQLite wired up
end-to-end: SQL file -> marmot codegen -> handler -> RPC -> Lustre view.

### Future: `--database postgres`

Squirrel could fill this role for Postgres. Currently blocked by Squirrel's
output layout (generates `sql.gleam` as a sibling of the `sql/` directory
with no configurable output path), which doesn't fit cleanly into libero's
project structure. Revisit if Squirrel adds an `output` config option.
