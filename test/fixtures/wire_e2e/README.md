## Wire E2E fixture

A self-contained Gleam project that mirrors the layout of `examples/todos`. Used by `test/js/wire_e2e_setup.sh` to produce compiled artifacts for E2E wire tests.

### Directory layout

The fixture uses template directories instead of the conventional Gleam `src/` layout. `shared_src/`, `server_src/`, and `client_src/` contain `.gleam.template` files rather than `.gleam` files. This prevents the root `gleam test` from compiling the nested fixture as part of libero itself.

During `wire_e2e_setup.sh`, the fixture sources are copied to an external staging directory under `$TMPDIR` arranged as a three-peer monorepo (`server/`, `shared/`, `clients/web/`). The script renames `.gleam.template` to `.gleam` and copies each `_src` directory under the matching peer's `src/` tree. Building the fixture in-place would create a `build/` directory visible to gleam when compiling libero as a path dependency, causing duplicate native Erlang module errors.

### Files

- `gleam.toml` — server package config (lands at `server/gleam.toml` after staging); libero as a path dependency, declares the `web` client
- `shared_src/shared/types.gleam.template` — type coverage matrix (Status, Item, Tree, ItemError, WithFloats, NestedRecord)
- `server_src/server/handler.gleam.template` — echo handlers, one per type, plus `echo_int_negated` and `echo_panic`
- `server_src/server/handler_context.gleam.template` — stub handler context
- `client_src/app.gleam.template` — minimal client app that imports generated modules
- `shared/gleam.toml` — shared package definition
- `clients/web/gleam.toml` — web client package definition
