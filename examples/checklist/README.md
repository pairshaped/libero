# default

Minimal libero starter: SSR-hydrated SPA with one route, one handler, and one button.

## Run

```sh
bin/dev
```

Open http://localhost:8080. The page renders server-side, hydrates on the client, and the Ping button calls the `ping` handler over RPC.

## Tests

```sh
bin/test
```

## Layout

```
default/
├── server/         backend (Erlang), runs the libero RPC + SSR server
├── shared/         cross-target types, views, and routing
├── clients/web/    Lustre SPA (JavaScript)
└── bin/            dev and test entry points
```

## Adding a route

Edit `shared/src/shared/router.gleam` to add a `Route` variant and update `parse_route` and `route_to_path`. Then update `shared/src/shared/views.gleam` to handle the new variant in `view`. The server picks it up via `ssr.handle_request` automatically.

## Adding a handler

Add a function in `server/src/handler.gleam`. It must:
- Be `pub`
- Take `HandlerContext` as its last parameter (named `state`)
- Return `#(Result(value, error), HandlerContext)`
- Use only types from `shared/` or builtins

Then run `bin/dev` (or `cd server && gleam run -m libero`) to regenerate dispatch + client stubs.

## Adding a client

Create `clients/<name>/` with a gleam.toml that declares the right target and lists shared + libero as deps. Add a `[tools.libero.clients.<name>]` block to `server/gleam.toml`.
