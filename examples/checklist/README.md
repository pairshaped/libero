# checklist

Companion app for the [Getting Started guide](../../docs/getting_started/step_1.md). A small SSR-hydrated checklist with create, toggle, and delete handlers, backed by an in-memory `HandlerContext`.

## Run

```sh
bin/dev
```

Open http://localhost:8080. The page renders server-side, hydrates on the client, and each button calls a handler over RPC.

## Tests

```sh
bin/test
```

## Layout

```
checklist/
├── server/         backend (Erlang), runs the libero RPC + SSR server
├── shared/         cross-target types, views, and routing
├── clients/web/    Lustre SPA (JavaScript)
└── bin/            dev and test entry points
```

## Handlers

`server/src/handler.gleam` defines four endpoints, each returning `#(Result(_, ItemError), HandlerContext)`:

- `get_items` lists the current items
- `create_item(params: ItemParams)` appends a new item, validating `TitleRequired`
- `toggle_item(id: Int)` flips `completed`
- `delete_item(id: Int)` removes the item by id

State lives on the `HandlerContext` record and is threaded through each call. Swap it out for a database-backed context per [Step 2 of the Getting Started guide](../../docs/getting_started/step_2.md).

## Regenerating

After editing handler signatures or shared types, run `bin/dev` (or `cd server && gleam run -m libero`) to regenerate dispatch and client stubs.
